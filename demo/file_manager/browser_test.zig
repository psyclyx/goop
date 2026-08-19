const std = @import("std");
const goop = @import("goop");
const image = @import("goop_image");

const fm = @import("controller.zig");
const ids = @import("ids.zig");
const state = @import("state.zig");
const capabilities = @import("capabilities.zig");
const types = @import("types.zig");
const view = @import("view.zig");
const preview = @import("preview.zig");
const style = @import("style.zig");
const transfer = @import("transfer.zig");
const fs = @import("fs.zig");
const format = @import("format.zig");
const model_ops = @import("model.zig");
const virtualization = @import("virtualization.zig");
const detail_text = @import("detail_text.zig");

const allocator = std.heap.smp_allocator;

fn behavior(browser: *state.Browser) capabilities.Behavior {
    return capabilities.behavior(&browser.session, &browser.viewport, &browser.domain, &browser.effects);
}

fn deinitBrowser(browser: *state.Browser) void {
    var behavior_scope = behavior(browser);
    fm.deinit(&behavior_scope);
    browser.domain.identities.deinit();
    @import("projection.zig").deinit(&browser.projection);
}

fn appendEntry(browser: *state.Browser, name: []const u8, path: []const u8) !void {
    try appendEntryOfKind(browser, name, path, .file);
}

fn appendEntryOfKind(browser: *state.Browser, name: []const u8, path: []const u8, kind: types.BrowserEntryKind) !void {
    try browser.domain.model.entries.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .path = try allocator.dupe(u8, path),
        .kind = kind,
        .size_bytes = 1,
        .modified_unix = 0,
    });
}

fn appendEntries(browser: *state.Browser, count: usize) !void {
    for (0..count) |index| {
        const name = try std.fmt.allocPrint(allocator, "entry-{d:03}.txt", .{index});
        errdefer allocator.free(name);
        const path = try std.fmt.allocPrint(allocator, "/tmp/entry-{d:03}.txt", .{index});
        try browser.domain.model.entries.append(allocator, .{
            .name = name,
            .path = path,
            .kind = .file,
            .size_bytes = @intCast(index * 1024),
            .modified_unix = 0,
        });
    }
}

fn metrics(browser: *const state.Browser) virtualization.Metrics {
    return .{
        .ui_scale = browser.viewport.ui_scale,
        .text_measure_ctx = browser.projection.text_measure_ctx,
    };
}

fn emptyEvents(items: []const goop.ControlEvent) goop.ControlEvents {
    return .{ .items = items, .text_bytes = &.{}, .selection_ids = &.{} };
}

fn testMeasureText(text: []const u8, font_size: f32, _: ?*anyopaque) goop.TextDimensions {
    return .{
        .width = @as(f32, @floatFromInt(text.len)) * font_size * 0.5,
        .height = font_size,
        .ascent = font_size * 0.75,
        .descent = font_size * 0.25,
    };
}

test "browser owners retain no GUI context or node handles" {
    try std.testing.expect(!@hasField(state.Session, "ctx"));
    try std.testing.expect(!@hasField(state.Session, "renderer"));
    try std.testing.expect(!@hasField(state.Model, "root_handle"));
    try std.testing.expect(!@hasField(state.Interaction, "rename_input_handle"));
    try std.testing.expect(!@hasField(state.View, "chrome"));
    try std.testing.expect(!@hasField(state.AssetProjection, "row_handles"));
    try std.testing.expect(!@hasField(state.AssetProjection, "grid_handles"));
}

test "visual projection and pure presentation queries have no effect capabilities" {
    const sources = [_][]const u8{
        @embedFile("view.zig"),
        @embedFile("presentation.zig"),
    };
    const forbidden = [_][]const u8{
        "@im" ++ "port(\"fs.zig\")",
        "@im" ++ "port(\"preview.zig\")",
        "std." ++ "Io",
        "Clock" ++ ".",
        "open" ++ "Dir(",
        "open" ++ "File(",
        "stat" ++ "File(",
        "read" ++ "Slice",
        ".reader" ++ "(",
    };
    for (sources) |source| {
        for (forbidden) |name| try std.testing.expect(std.mem.indexOf(u8, source, name) == null);
    }
}

test "command activation reduces without tree access" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);

    const event = goop.ControlEvent{ .activated = .{
        .element = ids.commandElement(.toolbar, .toggle_preview),
        .action = ids.commandAction(.toggle_preview),
    } };
    try std.testing.expect(browser.domain.model.show_preview);
    var scope = behavior(&browser);
    try std.testing.expect(try fm.update(&scope, emptyEvents(&.{event}), std.testing.io));
    try std.testing.expect(!browser.domain.model.show_preview);
}

test "popup dismissal output clears retained context-menu visibility" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.domain.interaction.context_visible = true;

    const event = goop.ControlEvent{ .popup_visibility_changed = .{
        .element = ids.fixed(.context_popup),
        .visible = false,
    } };
    var scope = behavior(&browser);
    try std.testing.expect(try fm.update(&scope, emptyEvents(&.{event}), std.testing.io));
    try std.testing.expect(!browser.domain.interaction.context_visible);
}

test "list and grid backgrounds target the current directory context menu" {
    inline for (.{ ids.Fixed.asset_body_table, ids.Fixed.asset_grid }) |background| {
        var browser: state.Browser = .{};
        defer deinitBrowser(&browser);
        browser.domain.model.current_dir = try allocator.dupe(u8, "/tmp");
        const event = goop.ControlEvent{ .secondary_activated = .{
            .element = ids.fixed(background),
            .action = null,
            .x = 120,
            .y = 220,
        } };
        var scope = behavior(&browser);
        try std.testing.expect(try fm.update(&scope, emptyEvents(&.{event}), std.testing.io));
        try std.testing.expect(browser.domain.interaction.context_visible);
        try std.testing.expectEqualStrings("/tmp", browser.domain.interaction.context_target_path.?);
    }
}

test "journal order is preserved by reducer" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);

    const events = [_]goop.ControlEvent{
        .{ .activated = .{
            .element = ids.commandElement(.toolbar, .toggle_sidebar),
            .action = ids.commandAction(.toggle_sidebar),
        } },
        .{ .activated = .{
            .element = ids.commandElement(.toolbar, .toggle_sidebar),
            .action = ids.commandAction(.toggle_sidebar),
        } },
    };
    const original = browser.domain.model.show_sidebar;
    var scope = behavior(&browser);
    _ = try fm.update(&scope, emptyEvents(&events), std.testing.io);
    try std.testing.expectEqual(original, browser.domain.model.show_sidebar);
}

test "durable asset activation survives model reorder" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    try appendEntry(&browser, "a", "/a");
    try appendEntry(&browser, "b", "/b");

    const a_id = try browser.domain.identities.idForPath(.asset, "/a");
    std.mem.swap(types.BrowserEntry, &browser.domain.model.entries.items[0], &browser.domain.model.entries.items[1]);

    const event = goop.ControlEvent{ .activated = .{ .element = a_id, .action = null } };
    var scope = behavior(&browser);
    try std.testing.expect(try fm.update(&scope, emptyEvents(&.{event}), std.testing.io));
    try std.testing.expectEqualStrings("/a", browser.domain.model.selected_path.?);
}

test "selection output resolves semantic IDs to current paths" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    try appendEntry(&browser, "a", "/a");
    try appendEntry(&browser, "b", "/b");

    const a_id = try browser.domain.identities.idForPath(.asset, "/a");
    const b_id = try browser.domain.identities.idForPath(.asset, "/b");
    const selected = [_]goop.ElementId{ b_id, a_id };
    const event = goop.ControlEvent{ .selection_changed = .{
        .element = ids.fixed(.asset_body_table),
        .selected = .{ .start = 0, .len = selected.len },
    } };
    const output = goop.ControlEvents{
        .items = &.{event},
        .text_bytes = &.{},
        .selection_ids = &selected,
    };
    var scope = behavior(&browser);
    try std.testing.expect(try fm.update(&scope, output, std.testing.io));
    try std.testing.expectEqual(@as(usize, 2), browser.domain.model.selected_paths.items.len);
    try std.testing.expectEqualStrings("/b", browser.domain.model.selected_paths.items[0]);
    try std.testing.expectEqualStrings("/a", browser.domain.model.selected_paths.items[1]);
    const preview_text = browser.domain.presentation.preview.text orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, preview_text, "2 items selected") != null);
}

test "controller reads selected file preview before visual projection" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "note.txt",
        .data = "prepared by behavior",
    });

    const root_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root_path);
    const file_path = try fs.joinPath(allocator, root_path, "note.txt");
    defer allocator.free(file_path);

    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.session.io = std.testing.io;
    browser.domain.model.current_dir = try allocator.dupe(u8, root_path);
    try appendEntryOfKind(&browser, "note.txt", file_path, .file);
    const file_id = try browser.domain.identities.idForPath(.asset, file_path);
    const event = goop.ControlEvent{ .selection_changed = .{
        .element = ids.fixed(.asset_body_table),
        .selected = .{ .start = 0, .len = 1 },
    } };
    const output = goop.ControlEvents{
        .items = &.{event},
        .text_bytes = &.{},
        .selection_ids = &.{file_id},
    };

    var scope = behavior(&browser);
    try std.testing.expect(try fm.update(&scope, output, std.testing.io));
    const prepared = browser.domain.presentation.preview.text orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, prepared, "prepared by behavior") != null);
    try std.testing.expect(browser.domain.presentation.preview.framed);
}

test "controller decodes selected image into renderer-neutral presentation" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var encoded = [_]u8{0} ** 9000;
    @memcpy(encoded[0..8], "\x89PNG\r\n\x1a\n");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "probe.png",
        .data = &encoded,
    });

    const root_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root_path);
    const file_path = try fs.joinPath(allocator, root_path, "probe.png");
    defer allocator.free(file_path);

    const DecoderContext = struct { expected_len: usize };
    const Decoder = struct {
        fn decode(
            context_ptr: *anyopaque,
            format_value: image.EncodedFormat,
            bytes: []const u8,
            alloc: std.mem.Allocator,
        ) image.DecodeError!image.Pixels {
            const context: *DecoderContext = @ptrCast(@alignCast(context_ptr));
            if (format_value != .png) return error.UnsupportedFormat;
            if (bytes.len != context.expected_len) return error.InvalidData;
            return image.Pixels.init(alloc, 2, 1, &.{
                255, 0,   0, 255,
                0,   255, 0, 255,
            });
        }
    };
    var decoder_context = DecoderContext{ .expected_len = encoded.len };
    const decoder = image.Decoder{ .context = &decoder_context, .decode_fn = Decoder.decode };

    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.session.io = std.testing.io;
    browser.domain.model.current_dir = try allocator.dupe(u8, root_path);
    try appendEntryOfKind(&browser, "probe.png", file_path, .file);
    browser.domain.model.entries.items[0].size_bytes = encoded.len;
    const file_id = try browser.domain.identities.idForPath(.asset, file_path);
    const event = goop.ControlEvent{ .selection_changed = .{
        .element = ids.fixed(.asset_body_table),
        .selected = .{ .start = 0, .len = 1 },
    } };
    const output = goop.ControlEvents{
        .items = &.{event},
        .text_bytes = &.{},
        .selection_ids = &.{file_id},
    };

    var scope = capabilities.behaviorWithImages(
        &browser.session,
        &browser.viewport,
        &browser.domain,
        &browser.effects,
        decoder,
    );
    try std.testing.expect(try fm.update(&scope, output, std.testing.io));
    const pixels = browser.domain.presentation.preview.image orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2), pixels.width);
    try std.testing.expectEqual(@as(u32, 1), pixels.height);
    try std.testing.expectEqual(@as(usize, 8), pixels.rgba.len);
    const first_resource = browser.domain.presentation.preview.image_id;
    try std.testing.expect(try fm.update(&scope, output, std.testing.io));
    try std.testing.expectEqual(first_resource, browser.domain.presentation.preview.image_id);
}

test "text output updates caller-owned address editor" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    const event = goop.ControlEvent{ .text_changed = .{
        .element = ids.fixed(.address_input),
        .text = .{ .start = 0, .len = 4 },
    } };
    const output = goop.ControlEvents{
        .items = &.{event},
        .text_bytes = "/tmp",
        .selection_ids = &.{},
    };
    var scope = behavior(&browser);
    try std.testing.expect(!(try fm.update(&scope, output, std.testing.io)));
    try std.testing.expectEqualStrings("/tmp", browser.domain.interaction.address_input.content());
}

test "rename command starts caller-owned inline editor state" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    try appendEntry(&browser, "rename-me", "/tmp/rename-me");
    try model_ops.appendSelectedPathIfMissing(&browser.domain.model, "/tmp/rename-me");
    try model_ops.setSelectedPath(&browser.domain.model, "/tmp/rename-me");
    const event = goop.ControlEvent{ .activated = .{
        .element = ids.commandElement(.toolbar, .rename),
        .action = ids.commandAction(.rename),
    } };
    var scope = behavior(&browser);
    try std.testing.expect(try fm.update(&scope, emptyEvents(&.{event}), std.testing.io));
    try std.testing.expectEqualStrings("/tmp/rename-me", browser.domain.interaction.rename_path.?);
    try std.testing.expectEqualStrings("rename-me", browser.domain.interaction.rename_input.content());
}

test "clear selection command reduces semantic selection state" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    try appendEntry(&browser, "only-file", "/tmp/only-file");
    try model_ops.appendSelectedPathIfMissing(&browser.domain.model, "/tmp/only-file");
    try model_ops.setSelectedPath(&browser.domain.model, "/tmp/only-file");
    const event = goop.ControlEvent{ .activated = .{
        .element = ids.commandElement(.toolbar, .clear_selection),
        .action = ids.commandAction(.clear_selection),
    } };
    var scope = behavior(&browser);
    try std.testing.expect(try fm.update(&scope, emptyEvents(&.{event}), std.testing.io));
    try std.testing.expectEqual(@as(usize, 0), browser.domain.model.selected_paths.items.len);
    try std.testing.expect(browser.domain.model.selected_path == null);
}

test "zoom commands change content without rescaling application chrome" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    var scope = behavior(&browser);
    const zoom_in = goop.ControlEvent{ .activated = .{
        .element = ids.commandElement(.toolbar, .zoom_in),
        .action = ids.commandAction(.zoom_in),
    } };
    for (0..20) |_| _ = try fm.update(&scope, emptyEvents(&.{zoom_in}), std.testing.io);
    try std.testing.expectEqual(@as(f32, 3), browser.domain.model.content_zoom);
    try std.testing.expectEqual(@as(f32, 1), browser.viewport.ui_scale);
    const reset = goop.ControlEvent{ .activated = .{
        .element = ids.commandElement(.toolbar, .zoom_reset),
        .action = ids.commandAction(.zoom_reset),
    } };
    _ = try fm.update(&scope, emptyEvents(&.{reset}), std.testing.io);
    try std.testing.expectEqual(@as(f32, 1), browser.domain.model.content_zoom);
}

test "splitter and table resize outputs persist in browser layout state" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    var scope = behavior(&browser);
    const events = [_]goop.ControlEvent{
        .{ .value_changed = .{ .element = ids.fixed(.nav_splitter), .value = .{ .scalar = 0.31 } } },
        .{ .value_changed = .{ .element = ids.fixed(.detail_splitter), .value = .{ .scalar = 0.66 } } },
        .{ .value_changed = .{ .element = ids.fixed(.preview_splitter), .value = .{ .scalar = 0.42 } } },
        .{ .value_changed = .{ .element = ids.fixed(.asset_header_table), .value = .{ .column_fraction = .{ .column = 1, .fraction = 0.27 } } } },
    };
    try std.testing.expect(try fm.update(&scope, emptyEvents(&events), std.testing.io));
    try std.testing.expectEqual(@as(f32, 0.31), browser.domain.model.nav_ratio);
    try std.testing.expectEqual(@as(f32, 0.66), browser.domain.model.detail_ratio);
    try std.testing.expectEqual(@as(f32, 0.42), browser.domain.model.preview_ratio);
    try std.testing.expectEqual(@as(f32, 0.27), browser.domain.model.table_column_weights[1]);
}

test "hidden entries follow the model visibility policy" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "visible.txt", .data = "v" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".hidden.txt", .data = "h" });
    const root_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root_path);

    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.session.io = std.testing.io;
    browser.domain.model.current_dir = try allocator.dupe(u8, root_path);
    const filesystem = capabilities.filesystem(&browser.session, &browser.domain.model, &browser.domain.interaction);
    try fs.loadDirectoryEntries(filesystem);
    try std.testing.expectEqual(@as(usize, 1), browser.domain.model.entries.items.len);
    try std.testing.expectEqualStrings("visible.txt", browser.domain.model.entries.items[0].name);

    browser.domain.model.show_hidden = true;
    try fs.loadDirectoryEntries(filesystem);
    try std.testing.expectEqual(@as(usize, 2), browser.domain.model.entries.items.len);
}

test "projection assigns stable identities to every application control" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.domain.model.current_dir = try allocator.dupe(u8, "/");
    try appendEntry(&browser, "a", "/a");

    const text_measure = goop.TextMeasureCtx{ .measureFn = &testMeasureText };
    browser.projection.text_measure_ctx = &text_measure;
    var ctx = try goop.Context.init(allocator, .{
        .width = 900,
        .height = 650,
        .theme = style.fileManagerThemeForScale(1),
    });
    defer ctx.deinit();

    try view.buildWidgetTree(
        capabilities.viewInput(
            &browser.viewport,
            &browser.domain.model,
            &browser.domain.interaction,
            &browser.domain.presentation,
        ),
        capabilities.viewOutput(&browser.projection, &browser.domain.identities),
        &ctx,
    );
    try std.testing.expect(ctx.tree.findByElementId(ids.fixed(.root)) != null);
    try std.testing.expect(ctx.tree.findByElementId(ids.fixed(.address_input)) != null);
    try std.testing.expect(ctx.tree.findByElementId(ids.fixed(.file_panel_scroll)) != null);
    try std.testing.expect(ctx.tree.findByElementId(ids.fixed(.asset_header_table)) != null);
    try std.testing.expect(ctx.tree.findByElementId(ids.fixed(.asset_body_table)) != null);
    try std.testing.expect(ctx.tree.findByElementId(ids.commandElement(.toolbar, .refresh)) != null);
    const asset_id = browser.domain.identities.existingIdForPath(.asset, "/a").?;
    try std.testing.expect(ctx.tree.findByElementId(asset_id) != null);
}

test "permission editor projects a compact uniquely identified bit matrix" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.domain.model.current_dir = try allocator.dupe(u8, "/");
    try appendEntryOfKind(&browser, "a", "/a", .file);
    browser.domain.model.entries.items[0].permissions = 0o754;
    try model_ops.setSelectedPath(&browser.domain.model, "/a");
    try model_ops.appendSelectedPathIfMissing(&browser.domain.model, "/a");
    browser.domain.interaction.permission_path = try allocator.dupe(u8, "/a");
    browser.domain.interaction.permission_draft = 0o754;

    const text_measure = goop.TextMeasureCtx{ .measureFn = &testMeasureText };
    browser.projection.text_measure_ctx = &text_measure;
    var ctx = try goop.Context.init(allocator, .{ .width = 1000, .height = 700, .theme = style.fileManagerThemeForScale(1) });
    defer ctx.deinit();
    try view.buildWidgetTree(
        capabilities.viewInput(&browser.viewport, &browser.domain.model, &browser.domain.interaction, &browser.domain.presentation),
        capabilities.viewOutput(&browser.projection, &browser.domain.identities),
        &ctx,
    );
    ctx.doLayout(&text_measure);
    for (@import("permissions.zig").bits) |bit| {
        const handle = ctx.tree.findByElementId(ids.fixed(bit.element)) orelse return error.TestUnexpectedResult;
        try std.testing.expect(ctx.tree.getConst(handle).layout_rect.w > 0);
    }
    try std.testing.expect(ctx.tree.findByElementId(ids.fixed(.permission_apply)) != null);
    try std.testing.expect(ctx.tree.findByElementId(ids.fixed(.permission_cancel)) != null);
}

test "file browser projects semantic entry icons in list and grid views" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.domain.model.current_dir = try allocator.dupe(u8, "/tmp");
    try appendEntryOfKind(&browser, "folder", "/tmp/folder", .directory);
    try appendEntryOfKind(&browser, "file.txt", "/tmp/file.txt", .file);
    try appendEntryOfKind(&browser, "folder-link", "/tmp/folder-link", .symlink);
    browser.domain.model.entries.items[2].target_kind = .directory;
    try appendEntryOfKind(&browser, "file-link", "/tmp/file-link", .symlink);
    browser.domain.model.entries.items[3].target_kind = .file;
    try appendEntryOfKind(&browser, "broken-link", "/tmp/broken-link", .symlink);

    const expected = [_]struct {
        path: []const u8,
        icon: goop.IconId,
    }{
        .{ .path = "/tmp/folder", .icon = @intFromEnum(goop.StockIcon.folder) },
        .{ .path = "/tmp/file.txt", .icon = @intFromEnum(goop.StockIcon.file) },
        .{ .path = "/tmp/folder-link", .icon = @intFromEnum(goop.StockIcon.folder_symlink) },
        .{ .path = "/tmp/file-link", .icon = @intFromEnum(goop.StockIcon.file_symlink) },
        .{ .path = "/tmp/broken-link", .icon = @intFromEnum(goop.StockIcon.symlink) },
    };

    const text_measure = goop.TextMeasureCtx{ .measureFn = &testMeasureText };
    browser.projection.text_measure_ctx = &text_measure;
    var ctx = try goop.Context.init(allocator, .{
        .width = 900,
        .height = 650,
        .theme = style.fileManagerThemeForScale(1),
    });
    defer ctx.deinit();
    const input = capabilities.viewInput(&browser.viewport, &browser.domain.model, &browser.domain.interaction, &browser.domain.presentation);
    const output = capabilities.viewOutput(&browser.projection, &browser.domain.identities);

    try view.buildWidgetTree(input, output, &ctx);
    for (expected) |entry| {
        const asset_id = browser.domain.identities.existingIdForPath(.asset, entry.path) orelse return error.TestUnexpectedResult;
        const row = ctx.tree.findByElementId(asset_id) orelse return error.TestUnexpectedResult;
        try std.testing.expect(ctx.tree.getConst(row).kind == .table_row);
        var row_children = ctx.tree.children(row);
        const name_cell = row_children.next() orelse return error.TestUnexpectedResult;
        try std.testing.expect(ctx.tree.getConst(name_cell).kind == .table_cell);
        var name_children = ctx.tree.children(name_cell);
        const icon = name_children.next() orelse return error.TestUnexpectedResult;
        try std.testing.expect(ctx.tree.getConst(icon).kind == .icon);
        try std.testing.expectEqual(entry.icon, ctx.tree.getConst(icon).kind.icon.kind);
    }

    browser.domain.model.view_mode = .grid;
    try view.buildWidgetTree(input, output, &ctx);
    for (expected) |entry| {
        const asset_id = browser.domain.identities.existingIdForPath(.asset, entry.path) orelse return error.TestUnexpectedResult;
        const item = ctx.tree.findByElementId(asset_id) orelse return error.TestUnexpectedResult;
        try std.testing.expect(ctx.tree.getConst(item).kind == .grid_item);
        try std.testing.expectEqual(entry.icon, ctx.tree.getConst(item).kind.grid_item.icon.?);
    }
}

test "file browser table marquee commits multiple rows after crossing child hits" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.viewport.logical_width = 900;
    browser.viewport.logical_height = 650;
    browser.domain.model.current_dir = try allocator.dupe(u8, "/tmp");
    try appendEntry(&browser, "a", "/tmp/a");
    try appendEntry(&browser, "b", "/tmp/b");
    try appendEntry(&browser, "c", "/tmp/c");

    const text_measure = goop.TextMeasureCtx{ .measureFn = &testMeasureText };
    browser.projection.text_measure_ctx = &text_measure;
    var ctx = try goop.Context.init(allocator, .{
        .width = browser.viewport.logical_width,
        .height = browser.viewport.logical_height,
        .theme = style.fileManagerThemeForScale(1),
    });
    defer ctx.deinit();
    const input = capabilities.viewInput(&browser.viewport, &browser.domain.model, &browser.domain.interaction, &browser.domain.presentation);
    const output = capabilities.viewOutput(&browser.projection, &browser.domain.identities);
    try view.buildWidgetTree(input, output, &ctx);
    ctx.doLayout(&text_measure);
    if (try view.refreshAssetViewportIfNeeded(input, output, &ctx)) ctx.doLayout(&text_measure);

    const table = ctx.tree.findByElementId(ids.fixed(.asset_body_table)) orelse return error.TestUnexpectedResult;
    const scroll = ctx.tree.findByElementId(ids.fixed(.file_panel_scroll)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(goop.scrollbar.verticalMetrics(&ctx.tree, scroll, ctx.theme) == null);
    const second_id = browser.domain.identities.existingIdForPath(.asset, "/tmp/b") orelse return error.TestUnexpectedResult;
    const third_id = browser.domain.identities.existingIdForPath(.asset, "/tmp/c") orelse return error.TestUnexpectedResult;
    const second = ctx.tree.findByElementId(second_id) orelse return error.TestUnexpectedResult;
    const third = ctx.tree.findByElementId(third_id) orelse return error.TestUnexpectedResult;
    const table_rect = ctx.tree.getConst(table).layout_rect;
    const second_rect = ctx.tree.getConst(second).layout_rect;
    const third_rect = ctx.tree.getConst(third).layout_rect;
    const scroll_rect = ctx.tree.getConst(scroll).layout_rect;
    const x = table_rect.x + table_rect.w * 0.5;
    const origin_y = @min(table_rect.y + table_rect.h, scroll_rect.y + scroll_rect.h) - 2;
    try std.testing.expect(goop.hittest.hitTestWithTheme(&ctx.tree, x, origin_y, ctx.theme).?.eql(table));

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = x, .y = origin_y } });
    try std.testing.expectEqual(@as(usize, 0), (try ctx.processEvents()).items.len);

    try ctx.pushEvent(.{ .mouse_move = .{ .x = x, .y = third_rect.y + third_rect.h * 0.5 } });
    const first_move = try ctx.processEvents();
    try std.testing.expectEqual(@as(usize, 0), first_move.items.len);
    try std.testing.expect(ctx.tree.getConst(table).kind.table.internal.marquee_active);
    try std.testing.expect(ctx.tree.getConst(third).kind.table_row.selected);

    try ctx.pushEvent(.{ .mouse_move = .{ .x = x, .y = second_rect.y + second_rect.h * 0.5 } });
    const second_move = try ctx.processEvents();
    try std.testing.expectEqual(@as(usize, 0), second_move.items.len);
    try std.testing.expect(ctx.tree.getConst(table).kind.table.internal.marquee_active);
    try std.testing.expect(ctx.tree.getConst(second).kind.table_row.selected);
    try std.testing.expect(ctx.tree.getConst(third).kind.table_row.selected);

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .released, .x = x, .y = second_rect.y + second_rect.h * 0.5 } });
    const release = try ctx.processEvents();
    try std.testing.expectEqual(@as(usize, 1), release.items.len);
    var behavior_scope = behavior(&browser);
    try std.testing.expect(try fm.update(&behavior_scope, release, std.testing.io));
    try std.testing.expectEqual(@as(usize, 2), browser.domain.model.selected_paths.items.len);
    try std.testing.expect(model_ops.isPathSelected(&browser.domain.model, "/tmp/b"));
    try std.testing.expect(model_ops.isPathSelected(&browser.domain.model, "/tmp/c"));
}

test "wheel scrolling moves the projected file list without pointer motion" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.viewport.logical_width = 900;
    browser.viewport.logical_height = 520;
    browser.domain.model.current_dir = try allocator.dupe(u8, "/tmp");
    browser.domain.model.show_sidebar = false;
    browser.domain.model.show_preview = false;
    browser.domain.model.show_info = false;
    try appendEntries(&browser, 192);

    const text_measure = goop.TextMeasureCtx{ .measureFn = &testMeasureText };
    browser.projection.text_measure_ctx = &text_measure;
    var ctx = try goop.Context.init(allocator, .{
        .width = browser.viewport.logical_width,
        .height = browser.viewport.logical_height,
        .theme = style.fileManagerThemeForScale(1),
    });
    defer ctx.deinit();
    const input = capabilities.viewInput(&browser.viewport, &browser.domain.model, &browser.domain.interaction, &browser.domain.presentation);
    const output = capabilities.viewOutput(&browser.projection, &browser.domain.identities);
    try view.buildWidgetTree(input, output, &ctx);
    ctx.doLayout(&text_measure);
    if (try view.refreshAssetViewportIfNeeded(input, output, &ctx)) ctx.doLayout(&text_measure);

    const scroll = ctx.tree.findByElementId(ids.fixed(.file_panel_scroll)) orelse return error.TestUnexpectedResult;
    const rect = ctx.tree.getConst(scroll).layout_rect;
    try ctx.pushEvent(.{ .mouse_move = .{ .x = rect.x + rect.w * 0.5, .y = rect.y + rect.h * 0.5 } });
    try ctx.pushEvent(.{ .mouse_scroll = .{ .dx = 0, .dy = 900 } });
    const events = try ctx.processEvents();
    var behavior_scope = behavior(&browser);
    _ = try fm.update(&behavior_scope, events, std.testing.io);
    if (try view.refreshAssetViewportIfNeeded(input, output, &ctx)) ctx.doLayout(&text_measure);

    const refreshed = ctx.tree.findByElementId(ids.fixed(.file_panel_scroll)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ctx.tree.getConst(refreshed).kind.scroll_area.scroll_y > 0);
    try std.testing.expect(browser.domain.model.file_panel_scroll_y > 0);
    try std.testing.expect(browser.projection.assets.asset_visible_start > 0);
}

test "selection detail does not resize the asset list at ui scale 2" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.viewport.logical_width = 1600;
    browser.viewport.logical_height = 960;
    browser.viewport.ui_scale = 2;
    browser.domain.model.current_dir = try allocator.dupe(u8, "/tmp");
    const long_name = "this-is-a-very-long-file-name-without-natural-break-points-to-force-detail-panel-overflow.txt";
    const long_path = "/tmp/this-is-a-very-long-file-name-without-natural-break-points-to-force-detail-panel-overflow.txt";
    try appendEntry(&browser, long_name, long_path);
    try appendEntries(&browser, 48);

    const text_measure = goop.TextMeasureCtx{ .measureFn = &testMeasureText };
    browser.projection.text_measure_ctx = &text_measure;
    var ctx = try goop.Context.init(allocator, .{
        .width = 1600,
        .height = 960,
        .theme = style.fileManagerThemeForScale(2),
    });
    defer ctx.deinit();
    const input = capabilities.viewInput(&browser.viewport, &browser.domain.model, &browser.domain.interaction, &browser.domain.presentation);
    const output = capabilities.viewOutput(&browser.projection, &browser.domain.identities);

    try view.buildWidgetTree(input, output, &ctx);
    ctx.doLayout(&text_measure);
    if (try view.refreshAssetViewportIfNeeded(input, output, &ctx)) ctx.doLayout(&text_measure);
    const before_handle = ctx.tree.findByElementId(ids.fixed(.asset_body_table)) orelse return error.TestUnexpectedResult;
    const width_before = ctx.tree.getConst(before_handle).layout_rect.w;

    try model_ops.appendSelectedPathIfMissing(&browser.domain.model, long_path);
    try model_ops.setSelectedPath(&browser.domain.model, long_path);
    try view.buildWidgetTree(input, output, &ctx);
    ctx.doLayout(&text_measure);
    if (try view.refreshAssetViewportIfNeeded(input, output, &ctx)) ctx.doLayout(&text_measure);
    const after_handle = ctx.tree.findByElementId(ids.fixed(.asset_body_table)) orelse return error.TestUnexpectedResult;
    const width_after = ctx.tree.getConst(after_handle).layout_rect.w;
    try std.testing.expect(@abs(width_before - width_after) < 4);
}

test "virtual range remains bounded and overscanned" {
    const range = virtualization.range(1000, 26, 10);
    try std.testing.expect(range.start < range.end);
    try std.testing.expect(range.end <= 1000);
    try std.testing.expect(range.end - range.start >= 24);
}

test "preview byte classifier distinguishes text and binary" {
    try std.testing.expect(preview.bytesLookLikeTextPreview("hello\nworld"));
    try std.testing.expect(!preview.bytesLookLikeTextPreview(&.{ 'a', 0, 'b' }));
}

test "file URI encoding remains explicit" {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);
    try transfer.appendFileUri(allocator, &buffer, "/tmp/a b", "\r\n");
    try std.testing.expectEqualStrings("file:///tmp/a%20b\r\n", buffer.items);
}

test "file sizes use the correct units" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", format.formatSizeText(buf[0..], .file, 0, null));
    try std.testing.expectEqualStrings("1023 B", format.formatSizeText(buf[0..], .file, 1023, null));
    try std.testing.expectEqualStrings("1.0 KB", format.formatSizeText(buf[0..], .file, 1024, null));
    try std.testing.expectEqualStrings("1.5 KB", format.formatSizeText(buf[0..], .file, 1536, null));
    try std.testing.expectEqualStrings("1.0 MB", format.formatSizeText(buf[0..], .file, 1024 * 1024, null));
    try std.testing.expectEqualStrings("", format.formatSizeText(buf[0..], .directory, 4096, null));
    try std.testing.expectEqualStrings("", format.formatSizeText(buf[0..], .symlink, 4096, .directory));
}

test "directory sorting respects the active field and grouping" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.domain.model.sort_column = .modified;
    browser.domain.model.sort_direction = .descending;
    browser.domain.model.sort_directories_together = false;

    const older_dir = types.BrowserEntry{
        .name = @constCast("older-dir"),
        .path = @constCast("/tmp/older-dir"),
        .kind = .directory,
        .size_bytes = 0,
        .modified_unix = 10,
    };
    const newer_file = types.BrowserEntry{
        .name = @constCast("newer.txt"),
        .path = @constCast("/tmp/newer.txt"),
        .kind = .file,
        .size_bytes = 0,
        .modified_unix = 20,
    };
    const scope = capabilities.filesystem(
        &browser.session,
        &browser.domain.model,
        &browser.domain.interaction,
    );
    try std.testing.expect(fs.browserEntryLessThan(scope, newer_file, older_dir));
    browser.domain.model.sort_directories_together = true;
    try std.testing.expect(fs.browserEntryLessThan(scope, older_dir, newer_file));
}

test "directory selection has no synthetic preview content" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    try appendEntryOfKind(&browser, "folder", "/tmp/folder", .directory);
    try model_ops.setSelectedPath(&browser.domain.model, "/tmp/folder");
    try model_ops.appendSelectedPathIfMissing(&browser.domain.model, "/tmp/folder");

    var selection_preview = try preview.allocSelectionPreview(.{
        .io = browser.session.io,
        .model = &browser.domain.model,
    });
    defer if (selection_preview.text) |text| allocator.free(text);
    defer if (selection_preview.image) |*pixels| pixels.deinit();
    try std.testing.expect(selection_preview.text == null);
    try std.testing.expect(selection_preview.image == null);
    try std.testing.expect(!selection_preview.framed);
}

test "directory preview is not framed like file content" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.domain.model.current_dir = try allocator.dupe(u8, "/tmp");
    var selection_preview = try preview.allocSelectionPreview(.{
        .io = browser.session.io,
        .model = &browser.domain.model,
    });
    defer if (selection_preview.text) |text| allocator.free(text);
    defer if (selection_preview.image) |*pixels| pixels.deinit();
    try std.testing.expect(selection_preview.text == null);
    try std.testing.expect(selection_preview.image == null);
    try std.testing.expect(!selection_preview.framed);
}

test "selected directory preview is bounded structured data" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "folder/subdir");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "folder/photo.png", .data = "image" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "folder/readme.md", .data = "text" });
    const root_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root_path);
    const folder_path = try fs.joinPath(allocator, root_path, "folder");
    defer allocator.free(folder_path);

    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.session.io = std.testing.io;
    try appendEntryOfKind(&browser, "folder", folder_path, .directory);
    try model_ops.setSelectedPath(&browser.domain.model, folder_path);
    try model_ops.appendSelectedPathIfMissing(&browser.domain.model, folder_path);
    var selection_preview = try preview.allocSelectionPreview(.{ .io = std.testing.io, .model = &browser.domain.model });
    defer {
        if (selection_preview.text) |text| allocator.free(text);
        if (selection_preview.image) |*pixels| pixels.deinit();
        if (selection_preview.directory) |*directory| {
            for (directory.samples.items) |sample| allocator.free(sample.name);
            directory.samples.deinit(allocator);
        }
    }
    const directory = selection_preview.directory orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), directory.directory_count);
    try std.testing.expectEqual(@as(usize, 1), directory.image_count);
    try std.testing.expectEqual(@as(usize, 1), directory.text_count);
    try std.testing.expect(directory.samples.items.len <= 6);
    try std.testing.expect(!selection_preview.framed);
}

test "details are filesystem metadata rather than display state or instructions" {
    const source = @embedFile("view.zig");
    for ([_][]const u8{
        "Permissions",
        "Inode",
        "Links",
        "Accessed",
        "Modified",
        "Metadata changed",
        "I/O block size",
    }) |field| try std.testing.expect(std.mem.indexOf(u8, source, field) != null);
    for ([_][]const u8{
        "Double-click to enter",
        "Ctrl-click and Shift-click",
        "Select a file to inspect",
        "Sort: {s}, {s}{s} · View:",
    }) |non_detail| try std.testing.expect(std.mem.indexOf(u8, source, non_detail) == null);
}

test "detail wrapping breaks long unspaced names" {
    const text_measure = goop.TextMeasureCtx{ .measureFn = &testMeasureText };
    const wrapped = try detail_text.wrapOwned(
        try allocator.dupe(u8, "this-is-a-very-long-file-name-without-natural-break-points-to-force-detail-panel-overflow.txt"),
        style.detailTitleFontSizePx(2),
        180,
        &text_measure,
    );
    defer allocator.free(wrapped);
    try std.testing.expect(std.mem.indexOfScalar(u8, wrapped, '\n') != null);
}

test "detail wrapping preserves leading whitespace" {
    const text_measure = goop.TextMeasureCtx{ .measureFn = &testMeasureText };
    const wrapped = try detail_text.wrapOwned(
        try allocator.dupe(u8, "first\n    second"),
        14,
        400,
        &text_measure,
    );
    defer allocator.free(wrapped);
    try std.testing.expect(std.mem.indexOf(u8, wrapped, "\n    second") != null);
}

test "folder expansion derives ancestors and the current directory" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.domain.model.current_dir = try allocator.dupe(u8, "/home/user/project");

    try std.testing.expectEqual(types.FolderTreeExpansion.partial, model_ops.folderTreeExpansion(&browser.domain.model, "/"));
    try std.testing.expectEqual(types.FolderTreeExpansion.partial, model_ops.folderTreeExpansion(&browser.domain.model, "/home"));
    try std.testing.expectEqual(types.FolderTreeExpansion.partial, model_ops.folderTreeExpansion(&browser.domain.model, "/home/user"));
    try std.testing.expectEqual(types.FolderTreeExpansion.expanded, model_ops.folderTreeExpansion(&browser.domain.model, "/home/user/project"));
    try std.testing.expectEqual(types.FolderTreeExpansion.collapsed, model_ops.folderTreeExpansion(&browser.domain.model, "/tmp"));
    try std.testing.expect(model_ops.shouldRenderFolderTreeChildForExpansion(&browser.domain.model, .partial, 900, "/home"));
    try std.testing.expect(!model_ops.shouldRenderFolderTreeChildForExpansion(&browser.domain.model, .partial, 0, "/tmp"));
    try std.testing.expect(try model_ops.setFolderTreePathExpanded(&browser.domain.model, "/tmp", true));
    try std.testing.expectEqual(types.FolderTreeExpansion.expanded, model_ops.folderTreeExpansion(&browser.domain.model, "/tmp"));
}

test "folder expansion preserves the previous branch when navigating to an ancestor" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.domain.model.current_dir = try allocator.dupe(u8, "/home/user/project/goop");
    try model_ops.preserveFolderTreeContextForNavigation(&browser.domain.model, "/home/user/project");
    try std.testing.expect(model_ops.isFolderTreePathExpanded(&browser.domain.model, "/home/user/project/goop"));

    allocator.free(browser.domain.model.current_dir);
    browser.domain.model.current_dir = try allocator.dupe(u8, "/home/user/project");
    try std.testing.expectEqual(types.FolderTreeExpansion.expanded, model_ops.folderTreeExpansion(&browser.domain.model, "/home/user/project"));
    try std.testing.expectEqual(types.FolderTreeExpansion.expanded, model_ops.folderTreeExpansion(&browser.domain.model, "/home/user/project/goop"));
}

test "controller refreshes prepared folder data after expansion changes" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "child/grandchild");

    const root_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root_path);
    const child_path = try fs.joinPath(allocator, root_path, "child");
    defer allocator.free(child_path);
    const grandchild_path = try fs.joinPath(allocator, child_path, "grandchild");
    defer allocator.free(grandchild_path);

    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.session.io = std.testing.io;
    browser.domain.model.current_dir = try allocator.dupe(u8, root_path);
    const child_id = try browser.domain.identities.idForPath(.folder, child_path);

    const event = goop.ControlEvent{ .toggle_changed = .{
        .element = child_id,
        .value = true,
    } };
    var scope = behavior(&browser);
    try std.testing.expect(try fm.update(&scope, emptyEvents(&.{event}), std.testing.io));

    var found_child = false;
    var found_grandchild = false;
    for (browser.domain.presentation.folder_tree.items) |item| {
        if (std.mem.eql(u8, item.path, child_path)) {
            found_child = item.expansion != .collapsed;
        } else if (std.mem.eql(u8, item.path, grandchild_path)) {
            found_grandchild = true;
        }
    }
    try std.testing.expect(found_child);
    try std.testing.expect(found_grandchild);
}

test "semantic sidebar scroll survives projection rebuild" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    browser.domain.model.current_dir = try allocator.dupe(u8, "/tmp");
    const text_measure = goop.TextMeasureCtx{ .measureFn = &testMeasureText };
    browser.projection.text_measure_ctx = &text_measure;
    var ctx = try goop.Context.init(allocator, .{ .width = 960, .height = 720, .theme = style.fileManagerThemeForScale(1) });
    defer ctx.deinit();

    const event = goop.ControlEvent{ .scroll_changed = .{ .element = ids.fixed(.sidebar_scroll), .x = 0, .y = 73 } };
    var scope = behavior(&browser);
    _ = try fm.update(&scope, emptyEvents(&.{event}), std.testing.io);
    const input = capabilities.viewInput(&browser.viewport, &browser.domain.model, &browser.domain.interaction, &browser.domain.presentation);
    const output = capabilities.viewOutput(&browser.projection, &browser.domain.identities);
    try view.buildWidgetTree(input, output, &ctx);
    try view.buildWidgetTree(input, output, &ctx);
    const sidebar = ctx.tree.findByElementId(ids.fixed(.sidebar_scroll)) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f32, 73), ctx.tree.getConst(sidebar).kind.scroll_area.scroll_y, 0.01);
}

test "list window body aligns with its logical row offset" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    try appendEntries(&browser, 64);
    const viewport_height: f32 = 120;
    const window = virtualization.listWindow(&browser.domain.model, metrics(&browser), viewport_height, 104);
    const row_height = virtualization.listRowHeight(metrics(&browser));
    const virtual_gap = virtualization.gap(metrics(&browser));
    const visible_start = @as(usize, @intFromFloat(@floor(window.scroll_y / row_height)));
    const visible_count = virtualization.visibleCount(viewport_height, row_height);
    const expected = virtualization.range(browser.domain.model.entries.items.len, visible_start, visible_count);
    const body_y = if (window.top_spacer > 0) window.top_spacer + virtual_gap else 0;
    const visible_height = row_height * @as(f32, @floatFromInt(window.end - window.start));
    const trailing = if (window.bottom_spacer > 0) window.bottom_spacer + virtual_gap else 0;
    const total_height = row_height * @as(f32, @floatFromInt(browser.domain.model.entries.items.len));
    try std.testing.expectEqual(expected.start, window.start);
    try std.testing.expectEqual(expected.end, window.end);
    try std.testing.expectApproxEqAbs(row_height * @as(f32, @floatFromInt(window.start)), body_y, 0.01);
    try std.testing.expectApproxEqAbs(total_height, body_y + visible_height + trailing, 0.01);
}

test "grid window body aligns with its logical row offset" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    try appendEntries(&browser, 80);
    const viewport_width: f32 = 480;
    const viewport_height: f32 = 220;
    const window = virtualization.gridWindow(&browser.domain.model, metrics(&browser), viewport_width, viewport_height, 640);
    const virtual_gap = virtualization.gap(metrics(&browser));
    const item_height = style.uiPx(1, types.browser_grid_item_height);
    const row_gap = style.uiPx(1, types.browser_grid_row_gap);
    const padding_v = style.uiPx(1, types.browser_grid_padding_v);
    const slot_height = item_height + row_gap;
    const content_scroll_y = @max(window.scroll_y - padding_v, 0);
    const visible_start_row = @as(usize, @intFromFloat(@floor(content_scroll_y / slot_height)));
    const visible_count = virtualization.visibleCount(@max(viewport_height - padding_v * 2, item_height) + row_gap, slot_height);
    const total_rows = std.math.divCeil(usize, browser.domain.model.entries.items.len, window.columns) catch unreachable;
    const expected = virtualization.range(total_rows, visible_start_row, visible_count);
    const start_row = window.start / window.columns;
    const desired_body_y = padding_v + @as(f32, @floatFromInt(start_row)) * slot_height;
    const body_y = if (window.top_spacer > 0) window.top_spacer + virtual_gap else 0;
    const visible_rows = std.math.divCeil(usize, window.end - window.start, window.columns) catch unreachable;
    const visible_height = item_height * @as(f32, @floatFromInt(visible_rows)) + row_gap * @as(f32, @floatFromInt(visible_rows - 1));
    const trailing = if (window.bottom_spacer > 0) window.bottom_spacer + virtual_gap else 0;
    const total_height = padding_v * 2 + item_height * @as(f32, @floatFromInt(total_rows)) + row_gap * @as(f32, @floatFromInt(total_rows - 1));
    try std.testing.expectEqual(expected.start * window.columns, window.start);
    try std.testing.expectApproxEqAbs(desired_body_y, body_y, 0.01);
    try std.testing.expectApproxEqAbs(total_height, body_y + visible_height + trailing, 0.01);
}

test "list virtualization keeps its range inside a chunk" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    try appendEntries(&browser, 256);
    const viewport_height: f32 = 300;
    const row_height = virtualization.listRowHeight(metrics(&browser));
    const visible_count = virtualization.visibleCount(viewport_height, row_height);
    const chunk_rows = virtualization.chunkRows(visible_count);
    const before = virtualization.listWindow(&browser.domain.model, metrics(&browser), viewport_height, 0);
    const inside = virtualization.listWindow(
        &browser.domain.model,
        metrics(&browser),
        viewport_height,
        row_height * @as(f32, @floatFromInt(chunk_rows - 1)) + row_height * 0.5,
    );
    try std.testing.expectEqual(before.start, inside.start);
    try std.testing.expectEqual(before.end, inside.end);
}

test "list virtualization changes continuously at a chunk boundary" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    try appendEntries(&browser, 256);
    const viewport_height: f32 = 300;
    const row_height = virtualization.listRowHeight(metrics(&browser));
    const visible_count = virtualization.visibleCount(viewport_height, row_height);
    const chunk_rows = virtualization.chunkRows(visible_count);
    const boundary = row_height * @as(f32, @floatFromInt(chunk_rows));
    const before = virtualization.listWindow(&browser.domain.model, metrics(&browser), viewport_height, boundary - 1);
    const after = virtualization.listWindow(&browser.domain.model, metrics(&browser), viewport_height, boundary);
    try std.testing.expect(after.start > before.start);
    try std.testing.expectEqual(chunk_rows - types.browser_overscan_rows, after.start);
    const before_logical_y = row_height * @as(f32, @floatFromInt(before.start)) - (boundary - 1);
    const after_logical_y = row_height * @as(f32, @floatFromInt(after.start)) - boundary;
    try std.testing.expect(after_logical_y <= before_logical_y + row_height * @as(f32, @floatFromInt(after.start - before.start)));
}

test "list virtualization covers the viewport after a large jump" {
    var browser: state.Browser = .{};
    defer deinitBrowser(&browser);
    try appendEntries(&browser, 256);
    const viewport_height: f32 = 300;
    const row_height = virtualization.listRowHeight(metrics(&browser));
    const target_row: usize = 120;
    const window = virtualization.listWindow(
        &browser.domain.model,
        metrics(&browser),
        viewport_height,
        row_height * @as(f32, @floatFromInt(target_row)) + row_height * 0.25,
    );
    const visible_count = virtualization.visibleCount(viewport_height, row_height);
    try std.testing.expect(window.start <= target_row);
    try std.testing.expect(window.end >= target_row + visible_count);
}
