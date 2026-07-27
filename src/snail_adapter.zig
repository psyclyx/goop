//! Backend-neutral Snail integration.
//!
//! This module owns CPU font/shaping/atlas state and emitted draw records.
//! It deliberately owns no graphics objects and submits no commands.

const std = @import("std");
const display = @import("goop_display");
const snail = @import("snail");

pub const Binding = snail.render.records.Binding;
pub const Instance = snail.render.records.Instance;
pub const DrawBatch = snail.render.records.DrawBatch;
pub const DrawRecords = snail.render.records.DrawRecords;
pub const Atlas = snail.Atlas;
pub const PagePool = snail.PagePool;

const unit_rect_key = snail.record_key.RecordKey{
    .namespace = snail.record_key.ns.path_fill,
    .a = 0x676f_6f70,
};

pub const Metrics = struct {
    width: f32,
    ascent: f32,
    descent: f32,
    line_gap: f32,

    pub fn height(self: Metrics) f32 {
        return self.ascent - self.descent + self.line_gap;
    }
};

pub const PreparedText = struct {
    allocator: std.mem.Allocator,
    shapes: []snail.Shape,

    pub fn deinit(self: *PreparedText) void {
        self.allocator.free(self.shapes);
        self.* = undefined;
    }
};

/// Stable heap-owned state is required because `snail.Faces` borrows the
/// address of `font`. Moving a `TextEngine` handle never moves that pointee.
pub const TextEngine = struct {
    state: *State,

    /// Cap on cached shaped runs. Distinct UI strings are bounded in practice
    /// (chrome + the visible file listing); if a long session accumulates more
    /// than this the whole cache is dropped and warms again, which is rare and
    /// cheap relative to re-shaping every label every frame.
    const max_cached_shapes = 4096;

    const State = struct {
        allocator: std.mem.Allocator,
        font: snail.Font,
        faces: snail.Faces,
        pool: *snail.PagePool,
        atlas: snail.Atlas,
        unit_rect_design_to_source: snail.Transform2D,
        /// Harfbuzz shaping is position- and size-independent, so a run can be
        /// shaped once and re-placed cheaply every frame. Keyed by a content
        /// hash of the text; serves both `measure` (layout) and `prepareText`
        /// (paint) so a hover/scroll doesn't re-shape unchanged labels.
        shape_cache: std.AutoHashMapUnmanaged(u64, snail.ShapedText) = .empty,
    };

    pub const Options = struct {
        max_layers: u16 = 32,
        curve_words_per_page: u32 = 1 << 18,
        band_words_per_page: u32 = 1 << 16,
        font_id: u32 = 0,
    };

    /// `font_bytes` are borrowed and must outlive the engine.
    pub fn init(
        allocator: std.mem.Allocator,
        font_bytes: []const u8,
        options: Options,
    ) !TextEngine {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = undefined;
        state.allocator = allocator;
        state.shape_cache = .empty;
        state.font = try snail.Font.init(font_bytes);

        state.pool = try snail.PagePool.init(allocator, .{
            .max_layers = options.max_layers,
            .curve_words_per_page = options.curve_words_per_page,
            .band_words_per_page = options.band_words_per_page,
        });
        errdefer state.pool.deinit();

        state.atlas = try snail.Atlas.init(allocator, state.pool);
        errdefer state.atlas.deinit();

        state.faces = try snail.Faces.build(allocator, &.{
            .{ .font = &state.font, .font_id = options.font_id },
        });
        errdefer state.faces.deinit();
        state.unit_rect_design_to_source = try recordUnitRect(state);
        return .{ .state = state };
    }

    pub fn deinit(self: *TextEngine) void {
        const state = self.state;
        const allocator = state.allocator;
        self.clearShapeCache();
        state.shape_cache.deinit(allocator);
        state.faces.deinit();
        state.atlas.deinit();
        state.pool.deinit();
        allocator.destroy(state);
        self.* = undefined;
    }

    fn clearShapeCache(self: *TextEngine) void {
        var it = self.state.shape_cache.valueIterator();
        while (it.next()) |shaped| shaped.deinit();
        self.state.shape_cache.clearRetainingCapacity();
    }

    /// Shape `text` once and cache it. Missing glyphs are recorded into the
    /// atlas at shape time so later placement of a cached run always finds
    /// them. The returned pointer is valid until the next `shapedFor` call.
    fn shapedFor(self: *TextEngine, text: []const u8) !*const snail.ShapedText {
        const state = self.state;
        var hasher = std.hash.Wyhash.init(0x676f_6f70_7368_6170);
        hasher.update(text);
        const key = hasher.final();
        if (state.shape_cache.getPtr(key)) |existing| return existing;

        if (state.shape_cache.count() >= max_cached_shapes) self.clearShapeCache();

        var shaped = try snail.shape(state.allocator, &state.faces, text, .{});
        errdefer shaped.deinit();
        try snail.recordUnhintedRun(&state.atlas, state.allocator, &state.faces, &shaped, .{});
        try state.shape_cache.put(state.allocator, key, shaped);
        return state.shape_cache.getPtr(key).?;
    }

    pub fn atlas(self: *const TextEngine) *const snail.Atlas {
        return &self.state.atlas;
    }

    pub fn pool(self: *const TextEngine) *snail.PagePool {
        return self.state.pool;
    }

    /// Number of distinct runs currently shaped-and-cached. Exposed for tests
    /// and diagnostics that want to confirm repeated frames reuse shaping.
    pub fn shapeCacheSize(self: *const TextEngine) usize {
        return self.state.shape_cache.count();
    }

    pub fn measure(self: *TextEngine, text: []const u8, font_size: f32) !Metrics {
        const shaped = try self.shapedFor(text);

        const units_per_em: f32 = @floatFromInt(self.state.font.unitsPerEm());
        const line = try self.state.font.lineMetrics();
        return .{
            .width = shaped.advanceX() * font_size,
            .ascent = @as(f32, @floatFromInt(line.ascent)) / units_per_em * font_size,
            .descent = @as(f32, @floatFromInt(line.descent)) / units_per_em * font_size,
            .line_gap = @as(f32, @floatFromInt(line.line_gap)) / units_per_em * font_size,
        };
    }

    /// Shape, record any missing glyphs, and return backend-neutral placed
    /// shapes. Repeated calls reuse the persistent atlas.
    pub fn prepareText(
        self: *TextEngine,
        allocator: std.mem.Allocator,
        text: []const u8,
        baseline: struct { x: f32, y: f32 },
        font_size: f32,
        color: display.Color,
    ) !PreparedText {
        const shaped = try self.shapedFor(text);

        return .{
            .allocator = allocator,
            .shapes = try snail.placeRunAlloc(allocator, shaped, null, .{
                .baseline = .{ .x = baseline.x, .y = baseline.y },
                .em = font_size,
                .color = linearColor(color),
                .y_axis = .down,
            }),
        };
    }

    /// Prepare a solid rectangle through the same backend-neutral shape
    /// stream as text. Render backends can therefore use their normal blend
    /// pipeline for translucent UI surfaces instead of replacing attachment
    /// pixels with a clear operation.
    pub fn prepareRect(
        self: *const TextEngine,
        allocator: std.mem.Allocator,
        bounds: display.Rect,
        color: display.Color,
    ) !PreparedText {
        const shapes = try allocator.alloc(snail.Shape, 1);
        shapes[0] = .{
            .key = unit_rect_key,
            .local_transform = snail.Transform2D.multiply(.{
                .xx = bounds.w,
                .yy = bounds.h,
                .tx = bounds.x,
                .ty = bounds.y,
            }, self.state.unit_rect_design_to_source),
            .local_color = linearColor(color),
        };
        return .{ .allocator = allocator, .shapes = shapes };
    }

    /// Emit one prepared run into caller-owned buffers. Vulkan, software, and
    /// future backends all consume this same record stream.
    pub fn emit(
        self: *const TextEngine,
        binding: Binding,
        prepared: *const PreparedText,
        instances: []Instance,
        batches: []DrawBatch,
        instance_len: *usize,
        batch_len: *usize,
    ) !snail.emit.EmitResult {
        return snail.emit.emit(
            instances,
            batches,
            instance_len,
            batch_len,
            binding,
            &self.state.atlas,
            prepared.shapes,
            .identity,
            .{ 1, 1, 1, 1 },
        );
    }
};

fn recordUnitRect(state: *TextEngine.State) !snail.Transform2D {
    var scratch = std.heap.ArenaAllocator.init(state.allocator);
    defer scratch.deinit();

    var path = snail.Path.init(state.allocator);
    defer path.deinit();
    try path.addRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 });

    var prepared = try path.prepare(state.allocator);
    defer prepared.deinit();
    var curves = try prepared.fillCurves(state.allocator, scratch.allocator());
    defer curves.deinit();

    // Register the unit rect as a coverage mask (no baked paint) so it renders
    // in the atlas's `.regular` mode and is tinted by each instance's
    // `local_color`. Baking a solid paint instead makes it a `.colr_solid`
    // record whose color comes from the atlas, ignoring the per-instance color —
    // which silently drops the tint on every translucent surface fill.
    try state.atlas.extendInPlace(state.allocator, &.{.{
        .key = unit_rect_key,
        .curves = curves,
    }});
    return prepared.design_to_source;
}

pub fn linearColor(color: display.Color) [4]f32 {
    const scale = 1.0 / 255.0;
    return snail.color.srgbToLinearColor(.{
        @as(f32, @floatFromInt(color.r)) * scale,
        @as(f32, @floatFromInt(color.g)) * scale,
        @as(f32, @floatFromInt(color.b)) * scale,
        @as(f32, @floatFromInt(color.a)) * scale,
    });
}

test "display colors cross the Snail boundary once" {
    const linear = linearColor(.rgba(128, 64, 0, 128));
    try std.testing.expectApproxEqAbs(@as(f32, 0.21586), linear[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05127), linear[1], 0.0001);
    try std.testing.expectEqual(@as(f32, 0), linear[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), linear[3], 0.0001);
}
