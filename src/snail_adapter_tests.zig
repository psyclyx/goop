//! Test-only assets and contracts for `goop_snail`.
//!
//! Keeping the embedded fonts in this root means production consumers do not
//! acquire test payloads or asset imports through the public adapter module.

const std = @import("std");
const adapter = @import("goop_snail");
const image = @import("goop_image");
const snail = @import("snail");

const BitmapDecoder = struct {
    calls: usize = 0,

    fn capability(self: *BitmapDecoder) image.Decoder {
        return .{ .context = self, .decode_fn = decode };
    }

    fn decode(
        context_ptr: *anyopaque,
        format: image.EncodedFormat,
        _: []const u8,
        allocator: std.mem.Allocator,
    ) image.DecodeError!image.Pixels {
        const self: *BitmapDecoder = @ptrCast(@alignCast(context_ptr));
        self.calls += 1;
        if (format != .png) return error.UnsupportedFormat;
        return image.Pixels.init(allocator, 2, 2, &.{
            255, 0, 0,   255, 0,   255, 0,   255,
            0,   0, 255, 255, 255, 255, 255, 255,
        });
    }
};

test "bitmap glyphs use the explicit decoder and cache one ppem record" {
    var decoder = BitmapDecoder{};
    var engine = try adapter.TextEngine.init(
        std.testing.allocator,
        @embedFile("test_bitmap_font"),
        .{ .image_decoder = decoder.capability() },
    );
    defer engine.deinit();

    var first = try engine.prepareText(
        std.testing.allocator,
        "\u{e903}\u{e903}",
        .{ .baseline = .{ .x = 2, .y = 20 }, .world_to_pixel = .identity },
        16,
        .rgb(20, 40, 60),
    );
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 2), first.shapes.len);
    for (first.shapes) |shape| {
        try std.testing.expectEqual(snail.record_key.ns.color_bitmap_glyph, shape.key.namespace);
        try std.testing.expectEqualDeep([4]f32{ 1, 1, 1, 1 }, shape.local_color);
    }
    try std.testing.expectEqual(@as(usize, 1), decoder.calls);

    var repeated = try engine.prepareText(
        std.testing.allocator,
        "\u{e903}",
        .{ .baseline = .{ .x = 2, .y = 20 }, .world_to_pixel = .identity },
        16,
        .rgb(255, 255, 255),
    );
    defer repeated.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoder.calls);
    try std.testing.expectEqual(snail.record_key.ns.color_bitmap_glyph, repeated.shapes[0].key.namespace);

    var transformed = try engine.prepareText(
        std.testing.allocator,
        "\u{e903}",
        .{
            .baseline = .{ .x = 2, .y = 20 },
            .world_to_pixel = .{ .xx = 1, .xy = 0.25, .yy = 1 },
        },
        16,
        .rgb(255, 255, 255),
    );
    defer transformed.deinit();
    try std.testing.expectEqual(snail.record_key.ns.color_bitmap_glyph, transformed.shapes[0].key.namespace);
}

test "application images use a distinct reusable Snail atlas" {
    var text = try adapter.TextEngine.init(
        std.testing.allocator,
        @embedFile("test_primary_font"),
        .{},
    );
    defer text.deinit();
    var images = try adapter.ImageEngine.init(std.testing.allocator, text.pool());
    defer images.deinit();

    var pixels = try image.Pixels.init(std.testing.allocator, 2, 1, &.{
        255, 0,   0, 255,
        0,   255, 0, 255,
    });
    defer pixels.deinit();
    const value = @import("goop_visual").Image{
        .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .source = pixels.view(.{ .value = 42, .revision = 1 }),
        .fit = .contain,
    };
    var first = try images.prepareImage(std.testing.allocator, value);
    defer first.deinit();
    const recorded = images.atlasIdentity();
    try std.testing.expectEqual(snail.record_key.ns.user_base, first.shapes[0].key.namespace);

    var repeated = try images.prepareImage(std.testing.allocator, value);
    defer repeated.deinit();
    try std.testing.expectEqualDeep(recorded, images.atlasIdentity());

    var changed = value;
    changed.source.id.revision += 1;
    pixels.rgba[0] = 0;
    changed.source.rgba = pixels.rgba;
    try images.syncResources(&.{changed.source});
    try std.testing.expect(!std.meta.eql(recorded, images.atlasIdentity()));
    try std.testing.expectEqual(@as(usize, 1), images.resourceCount());
    var replaced = try images.prepareImage(std.testing.allocator, changed);
    defer replaced.deinit();

    const replacement_identity = images.atlasIdentity();
    try images.syncResources(&.{changed.source});
    try std.testing.expectEqualDeep(replacement_identity, images.atlasIdentity());

    try images.syncResources(&.{});
    try std.testing.expect(!std.meta.eql(replacement_identity, images.atlasIdentity()));
    try std.testing.expectEqual(@as(usize, 0), images.resourceCount());
}

test "ordered faces select a fallback face per text cluster" {
    const primary = @embedFile("test_primary_font");
    const arabic = @embedFile("test_arabic_font");
    var engine = try adapter.TextEngine.initFaces(std.testing.allocator, &.{
        .{ .bytes = primary },
        .{ .bytes = arabic },
    }, .{});
    defer engine.deinit();

    var prepared = try engine.prepareText(
        std.testing.allocator,
        "A\xd8\xb9",
        .{
            .baseline = .{ .x = 0, .y = 14 },
            .world_to_pixel = .identity,
        },
        14,
        .rgb(255, 255, 255),
    );
    defer prepared.deinit();
    var saw_primary = false;
    var saw_fallback = false;
    for (prepared.shapes) |shape| {
        saw_primary = saw_primary or shape.key.a == 0;
        saw_fallback = saw_fallback or shape.key.a == 1;
    }
    try std.testing.expect(saw_primary);
    try std.testing.expect(saw_fallback);
}

test "text placement snaps origins to the caller's device grid and uses device ppem records" {
    const primary = @embedFile("test_primary_font");
    var engine = try adapter.TextEngine.init(std.testing.allocator, primary, .{});
    defer engine.deinit();

    const world_to_pixel = adapter.Transform2D.scale(2, 2);
    var prepared = try engine.prepareText(
        std.testing.allocator,
        "Grid fit",
        .{
            .baseline = .{ .x = 3.25, .y = 17.75 },
            .world_to_pixel = world_to_pixel,
        },
        13.25,
        .rgb(255, 255, 255),
    );
    defer prepared.deinit();

    const expected_ppem: u32 = 26 * 64 + 32;
    try std.testing.expect(prepared.shapes.len > 0);
    for (prepared.shapes) |shape| {
        try std.testing.expectEqual(snail.record_key.ns.tt_hinted_glyph, shape.key.namespace);
        try std.testing.expectEqual(expected_ppem, shape.key.c);
        const device_origin = world_to_pixel.applyPoint(.{
            .x = shape.local_transform.tx,
            .y = shape.local_transform.ty,
        });
        try std.testing.expectEqual(@round(device_origin.x), device_origin.x);
        try std.testing.expectEqual(@round(device_origin.y), device_origin.y);
        try std.testing.expect(engine.atlas().contains(shape.key));
    }
}

test "TT shaping matches Snail's hinted-advance sequence" {
    const primary = @embedFile("test_primary_font");
    const text = "AVATAR iiiiiiiiiiii Wavy";

    var font = try snail.Font.init(primary);
    var faces = try snail.Faces.build(std.testing.allocator, &.{.{
        .font = &font,
        .font_id = 0,
    }});
    defer faces.deinit();
    var source = snail.FontSource{
        .font_id = 0,
        .font = &font,
        .cache_key = [_]u8{0x5a} ** 16,
    };

    var pool = try snail.PagePool.init(std.testing.allocator, .{
        .max_pages = 2,
        .curve_words_per_page = 1024,
        .band_words_per_page = 256,
    });
    defer pool.deinit();
    var atlas = try snail.Atlas.init(std.testing.allocator, pool);
    defer atlas.deinit();
    var native = try snail.shape(std.testing.allocator, &faces, text, .{});
    defer native.deinit();

    // Find a small ppem where this font's hinted advances materially change
    // placement. The font is a test input, not a policy constant, so the test
    // discovers a discriminating size instead of baking in one rasterizer's
    // expected metric.
    var ppem_26_6: u32 = 6 * 64;
    while (ppem_26_6 <= 32 * 64) : (ppem_26_6 += 8) {
        const ppem = snail.TtHintPpem.uniform(ppem_26_6);
        var plan = try snail.planTtAdvances(
            &atlas,
            std.testing.allocator,
            (&source)[0..1],
            &.{&native},
            ppem,
        );
        defer plan.deinit();
        try applyTtPlan(&atlas, &source, ppem, &plan);

        var advance_source = snail.TtAdvanceSource{
            .atlas = &atlas,
            .sources = (&source)[0..1],
        };
        var hinted = try snail.shape(std.testing.allocator, &faces, text, .{
            .advance_provider = advance_source.advanceProvider(),
            .target_ppem = ppem,
        });
        defer hinted.deinit();
        const font_size = @as(f32, @floatFromInt(ppem_26_6)) / 64.0;
        const placement = snail.RunPlacement{
            .baseline = .{ .x = 3.25, .y = 17.75 },
            .em = font_size,
            .color = adapter.linearColor(.rgb(255, 255, 255)),
            .mode = .{ .tt_hint = .{ .ppem_26_6 = ppem_26_6 } },
            .snap = .origins,
            .world_to_pixel = .identity,
            .y_axis = .down,
        };
        const expected = try snail.placeRunAlloc(std.testing.allocator, &hinted, null, placement);
        defer std.testing.allocator.free(expected);
        const native_placed = try snail.placeRunAlloc(std.testing.allocator, &native, null, placement);
        defer std.testing.allocator.free(native_placed);

        var differs_from_native = false;
        for (expected, native_placed) |hinted_shape, native_shape| {
            differs_from_native = differs_from_native or
                hinted_shape.local_transform.tx != native_shape.local_transform.tx;
        }
        if (!differs_from_native) continue;

        var engine = try adapter.TextEngine.init(std.testing.allocator, primary, .{});
        defer engine.deinit();
        const device_metrics = try engine.prepareMetrics(text, font_size, .identity);
        try std.testing.expectApproxEqAbs(
            hinted.advanceX() * font_size,
            device_metrics.width,
            0.0001,
        );
        var actual = try engine.prepareText(
            std.testing.allocator,
            text,
            .{
                .baseline = placement.baseline,
                .world_to_pixel = placement.world_to_pixel.?,
            },
            font_size,
            .rgb(255, 255, 255),
        );
        defer actual.deinit();

        try std.testing.expectEqual(expected.len, actual.shapes.len);
        for (expected, actual.shapes) |expected_shape, actual_shape| {
            try std.testing.expectEqualDeep(expected_shape.key, actual_shape.key);
            try std.testing.expectEqualDeep(expected_shape.local_transform, actual_shape.local_transform);
        }
        return;
    }
    return error.TestExpectedHintedAdvanceDifference;
}

test "TT shape cache keys identical text by exact device ppem" {
    const primary = @embedFile("test_primary_font");
    var engine = try adapter.TextEngine.init(std.testing.allocator, primary, .{});
    defer engine.deinit();

    var first = try engine.prepareText(
        std.testing.allocator,
        "same text",
        .{ .baseline = .{ .x = 0, .y = 14 }, .world_to_pixel = .identity },
        14,
        .rgb(255, 255, 255),
    );
    first.deinit();
    const after_first = engine.shapeCacheSize();

    var repeated = try engine.prepareText(
        std.testing.allocator,
        "same text",
        .{ .baseline = .{ .x = 12, .y = 40 }, .world_to_pixel = .identity },
        14,
        .rgb(255, 255, 255),
    );
    repeated.deinit();
    try std.testing.expectEqual(after_first, engine.shapeCacheSize());

    var scaled = try engine.prepareText(
        std.testing.allocator,
        "same text",
        .{
            .baseline = .{ .x = 0, .y = 14 },
            .world_to_pixel = adapter.Transform2D.scale(2, 2),
        },
        14,
        .rgb(255, 255, 255),
    );
    scaled.deinit();
    try std.testing.expectEqual(after_first + 1, engine.shapeCacheSize());
}

test "renderer-independent measurement does not populate the atlas" {
    const primary = @embedFile("test_primary_font");
    var engine = try adapter.TextEngine.init(std.testing.allocator, primary, .{});
    defer engine.deinit();

    const atlas_before = engine.atlasIdentity();
    const metrics = try engine.measure("layout only", 14);
    try std.testing.expect(metrics.width > 0);
    try std.testing.expectEqualDeep(atlas_before, engine.atlasIdentity());
}

test "unsupported TT transforms fall back and extreme ppem clamps" {
    const primary = @embedFile("test_primary_font");
    var engine = try adapter.TextEngine.init(std.testing.allocator, primary, .{});
    defer engine.deinit();

    const unsupported = [_]adapter.Transform2D{
        adapter.Transform2D.scale(2, 1),
        .{ .xx = 1, .xy = 0.25, .yy = 1 },
    };
    for (unsupported) |world_to_pixel| {
        var prepared = try engine.prepareText(
            std.testing.allocator,
            "natural outline",
            .{ .baseline = .{ .x = 0, .y = 14 }, .world_to_pixel = world_to_pixel },
            14,
            .rgb(255, 255, 255),
        );
        defer prepared.deinit();
        try std.testing.expect(prepared.shapes.len > 0);
        for (prepared.shapes) |shape| {
            try std.testing.expectEqual(snail.record_key.ns.unhinted_glyph, shape.key.namespace);
        }
    }

    var tiny = try engine.prepareText(
        std.testing.allocator,
        "tiny",
        .{ .baseline = .{ .x = 0, .y = 1 }, .world_to_pixel = .identity },
        0.5,
        .rgb(255, 255, 255),
    );
    defer tiny.deinit();
    for (tiny.shapes) |shape| {
        try std.testing.expectEqual(snail.record_key.ns.unhinted_glyph, shape.key.namespace);
    }

    var extreme = try engine.prepareText(
        std.testing.allocator,
        "extreme",
        .{ .baseline = .{ .x = 0, .y = 2000 }, .world_to_pixel = .identity },
        2000,
        .rgb(255, 255, 255),
    );
    defer extreme.deinit();
    try std.testing.expect(extreme.shapes.len > 0);
    for (extreme.shapes) |shape| {
        try std.testing.expectEqual(snail.record_key.ns.tt_hinted_glyph, shape.key.namespace);
        try std.testing.expectEqual(snail.TtHintPpem.max_26_6, shape.key.c);
    }
}

fn applyTtPlan(
    atlas: *snail.Atlas,
    source: *const snail.FontSource,
    ppem: snail.TtHintPpem,
    plan: *const snail.PreparePlan,
) !void {
    const requests = plan.requests();
    const owned = try std.testing.allocator.alloc(?snail.prepared.OwnedRecord, requests.len);
    defer std.testing.allocator.free(owned);
    @memset(owned, null);
    defer for (owned) |*record| if (record.*) |*value| value.deinit();
    const results = try std.testing.allocator.alloc(?snail.prepared.RecordView, requests.len);
    defer std.testing.allocator.free(results);
    @memset(results, null);

    var context = try snail.TtHintContext.init(
        std.testing.allocator,
        std.testing.allocator,
        source,
    );
    defer context.deinit();
    var size = try context.prepareSize(ppem);
    defer size.deinit();
    for (requests, 0..) |request, index| {
        owned[index] = try context.prepare(&size, request);
        results[index] = owned[index].?.view();
    }
    try plan.applyInPlace(std.testing.allocator, atlas, results);
}
