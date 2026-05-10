const std = @import("std");
const goop = @import("goop");

const fm = @import("../file_manager_main.zig");
const State = fm.State;
const allocator = fm.allocator;

const BrowserEntry = fm.BrowserEntry;
const fileManagerThemeForScale = fm.fileManagerThemeForScale;
const refreshAssetViewportIfNeeded = fm.refreshAssetViewportIfNeeded;
const buildWidgetTree = fm.buildWidgetTree;
const formatSizeText = fm.formatSizeText;
const deinitBrowserState = fm.deinitBrowserState;
const bytesLookLikeTextPreview = fm.bytesLookLikeTextPreview;
const appendFileUri = fm.appendFileUri;
const clearTrackedPaths = fm.clearTrackedPaths;
const browserListWindow = fm.browserListWindow;
const browserGridWindow = fm.browserGridWindow;
const browserEntryLessThan = fm.browserEntryLessThan;
const appendDirectoryPreviewSummary = fm.appendDirectoryPreviewSummary;
const allocSelectionPreview = fm.allocSelectionPreview;
const allocUiDetailWrappedUtf8Lossy = fm.allocUiDetailWrappedUtf8Lossy;
const wrapTextOwnedForWidth = fm.wrapTextOwnedForWidth;
const appendSelectedPathIfMissing = fm.appendSelectedPathIfMissing;
const pointInRect = fm.pointInRect;
const syncSelectedPathsFromTable = fm.syncSelectedPathsFromTable;
const FolderTreeExpansion = fm.FolderTreeExpansion;
const preserveFolderTreeContextForNavigation = fm.preserveFolderTreeContextForNavigation;
const browserListRowHeight = fm.browserListRowHeight;
const browserVirtualGap = fm.browserVirtualGap;
const setSelectedPath = fm.setSelectedPath;
const pointInFilePanelBlankSpace = fm.pointInFilePanelBlankSpace;
const clearSelectedPaths = fm.clearSelectedPaths;
const folderTreeExpansion = fm.folderTreeExpansion;
const isFolderTreePathExpanded = fm.isFolderTreePathExpanded;
const browserVisibleCount = fm.browserVisibleCount;
const detailTitleFontSizePx = fm.detailTitleFontSizePx;
const browser_grid_item_height = fm.browser_grid_item_height;
const entryNameTextRect = fm.entryNameTextRect;
const clearSelectionState = fm.clearSelectionState;
const syncSelectedPathsFromGrid = fm.syncSelectedPathsFromGrid;
const shouldRenderFolderTreeChildForExpansion = fm.shouldRenderFolderTreeChildForExpansion;
const browserVirtualRange = fm.browserVirtualRange;
const browser_grid_row_gap = fm.browser_grid_row_gap;
const browserVirtualChunkRows = fm.browserVirtualChunkRows;
const pointHitsEntryNameText = fm.pointHitsEntryNameText;
const setFolderTreePathExpanded = fm.setFolderTreePathExpanded;
const browser_grid_padding_v = fm.browser_grid_padding_v;
const browser_overscan_rows = fm.browser_overscan_rows;
const beginRenameEntry = fm.beginRenameEntry;

fn browserTestMeasureText(text: []const u8, font_size: f32, _: ?*anyopaque) goop.TextDimensions {
    if (std.mem.eql(u8, text, "Mg")) {
        return .{
            .width = font_size,
            .height = 20,
            .ascent = 14,
            .descent = 6,
        };
    }

    var line_count: usize = 1;
    var current_line_len: usize = 0;
    var max_line_len: usize = 0;
    for (text) |byte| {
        if (byte == '\n') {
            max_line_len = @max(max_line_len, current_line_len);
            current_line_len = 0;
            line_count += 1;
            continue;
        }
        current_line_len += 1;
    }
    max_line_len = @max(max_line_len, current_line_len);

    return .{
        .width = @as(f32, @floatFromInt(max_line_len)) * font_size * 0.5,
        .height = @as(f32, @floatFromInt(line_count)) * 20,
        .ascent = 14,
        .descent = 6,
    };
}

fn browserTestTheme() goop.Theme {
    return fileManagerThemeForScale(1);
}

fn appendBrowserTestEntries(state: *State, count: usize) !void {
    for (0..count) |index| {
        try state.entries.append(allocator, .{
            .name = try std.fmt.allocPrint(allocator, "entry-{d:03}.txt", .{index}),
            .path = try std.fmt.allocPrint(allocator, "/tmp/entry-{d:03}.txt", .{index}),
            .kind = .file,
            .size_bytes = @intCast(index * 1024),
            .modified_unix = 0,
        });
    }
}

fn syncBrowserTestScrollFrame(state: *State, ctx: *goop.Context, text_measure_ctx: *const goop.TextMeasureCtx) !bool {
    ctx.invalidate();
    ctx.doLayout(text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(state)) {
        ctx.doLayout(text_measure_ctx);
        return true;
    }
    return false;
}

fn initBrowserListTestState(state: *State, ctx: *goop.Context, text_measure_ctx: *const goop.TextMeasureCtx) !void {
    state.current_dir = try allocator.dupe(u8, "/tmp");
    state.text_measure_ctx = text_measure_ctx;
    state.ctx = ctx;
    try appendBrowserTestEntries(state, 256);
    try buildWidgetTree(state);
    ctx.doLayout(text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(state)) {
        ctx.doLayout(text_measure_ctx);
    }
}

test "file browser formats file sizes with correct units" {
    var buf: [24]u8 = undefined;

    try std.testing.expectEqualStrings("0 B", formatSizeText(buf[0..], .file, 0, null));
    try std.testing.expectEqualStrings("1023 B", formatSizeText(buf[0..], .file, 1023, null));
    try std.testing.expectEqualStrings("1.0 KB", formatSizeText(buf[0..], .file, 1024, null));
    try std.testing.expectEqualStrings("1.5 KB", formatSizeText(buf[0..], .file, 1536, null));
    try std.testing.expectEqualStrings("1.0 MB", formatSizeText(buf[0..], .file, 1024 * 1024, null));
    try std.testing.expectEqualStrings("", formatSizeText(buf[0..], .directory, 4096, null));
    try std.testing.expectEqualStrings("", formatSizeText(buf[0..], .symlink, 4096, .directory));
}

test "file browser can sort directories with the active field" {
    var state = State{
        .sort_column = .modified,
        .sort_direction = .descending,
        .sort_directories_together = false,
    };
    const older_dir_name = try allocator.dupe(u8, "older-dir");
    defer allocator.free(older_dir_name);
    const older_dir_path = try allocator.dupe(u8, "/tmp/older-dir");
    defer allocator.free(older_dir_path);
    const newer_file_name = try allocator.dupe(u8, "newer.txt");
    defer allocator.free(newer_file_name);
    const newer_file_path = try allocator.dupe(u8, "/tmp/newer.txt");
    defer allocator.free(newer_file_path);
    const older_dir = BrowserEntry{
        .name = older_dir_name,
        .path = older_dir_path,
        .kind = .directory,
        .size_bytes = 0,
        .modified_unix = 10,
    };
    const newer_file = BrowserEntry{
        .name = newer_file_name,
        .path = newer_file_path,
        .kind = .file,
        .size_bytes = 0,
        .modified_unix = 20,
    };

    try std.testing.expect(browserEntryLessThan(&state, newer_file, older_dir));

    state.sort_directories_together = true;
    try std.testing.expect(browserEntryLessThan(&state, older_dir, newer_file));
}

test "file browser directory preview separates contents onto new lines" {
    var state = State{};
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);

    const folder_name = try allocator.dupe(u8, "folder");
    defer allocator.free(folder_name);
    const folder_path = try allocator.dupe(u8, "/tmp/folder");
    defer allocator.free(folder_path);
    const file_name = try allocator.dupe(u8, "file.txt");
    defer allocator.free(file_name);
    const file_path = try allocator.dupe(u8, "/tmp/file.txt");
    defer allocator.free(file_path);
    const entries = [_]BrowserEntry{
        .{
            .name = folder_name,
            .path = folder_path,
            .kind = .directory,
            .size_bytes = 0,
            .modified_unix = 0,
        },
        .{
            .name = file_name,
            .path = file_path,
            .kind = .file,
            .size_bytes = 0,
            .modified_unix = 0,
        },
    };

    try appendDirectoryPreviewSummary(&state, &buffer, "/tmp", entries[0..]);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Contents:\n- folder/") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\n- file.txt") != null);
}

test "file browser directory preview is not framed like file content" {
    var state = State{};
    defer deinitBrowserState(&state);

    state.current_dir = try allocator.dupe(u8, "/tmp");
    const preview = try allocSelectionPreview(&state);
    try std.testing.expect(!preview.framed);
}

test "file browser detects text preview content without an extension" {
    try std.testing.expect(bytesLookLikeTextPreview("KEY=value\n  indented\n"));
    try std.testing.expect(!bytesLookLikeTextPreview("prefix\x00suffix"));
}

test "file browser formats drag paths as file URIs" {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);

    try appendFileUri(&buffer, "/tmp/a file#1.txt", "\r\n");
    try std.testing.expectEqualStrings("file:///tmp/a%20file%231.txt\r\n", buffer.items);
}

test "file browser detail wrapper inserts line breaks for long names" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    state.ui_scale = 2;
    state.logical_width = 800;
    state.text_measure_ctx = &text_measure_ctx;

    const wrapped = try allocUiDetailWrappedUtf8Lossy(
        &state,
        "this-is-a-very-long-file-name-without-natural-break-points-to-force-detail-panel-overflow.txt",
        detailTitleFontSizePx(&state),
    );
    try std.testing.expect(std.mem.indexOfScalar(u8, wrapped, '\n') != null);
}

test "file browser detail wrapper preserves leading whitespace" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };
    state.text_measure_ctx = &text_measure_ctx;

    const wrapped = try wrapTextOwnedForWidth(
        &state,
        try allocator.dupe(u8, "first\n    second"),
        14,
        400,
    );
    defer allocator.free(wrapped);

    try std.testing.expect(std.mem.indexOf(u8, wrapped, "\n    second") != null);
}

test "file browser selected name text click starts inline rename" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 960,
        .height = 720,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    state.logical_width = 960;
    state.logical_height = 720;
    state.current_dir = try allocator.dupe(u8, "/tmp");
    state.text_measure_ctx = &text_measure_ctx;
    state.ctx = &ctx;
    try state.entries.append(allocator, .{
        .name = try allocator.dupe(u8, "rename-me"),
        .path = try allocator.dupe(u8, "/tmp/rename-me"),
        .kind = .file,
        .size_bytes = 12,
        .modified_unix = 0,
    });
    try appendSelectedPathIfMissing(&state, state.entries.items[0].path);
    try setSelectedPath(&state, state.entries.items[0].path);

    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(&state)) ctx.doLayout(&text_measure_ctx);

    const name_rect = entryNameTextRect(&state, &ctx, 0, state.entries.items[0]).?;
    try std.testing.expect(pointHitsEntryNameText(&state, &ctx, 0, state.entries.items[0], name_rect.x + 1, name_rect.y + name_rect.h * 0.5));
    try beginRenameEntry(&state, &ctx, state.entries.items[0]);
    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);

    const input = state.rename_input_handle orelse return error.TestUnexpectedResult;
    try std.testing.expect(ctx.tree.getConst(input).interaction.focused);
    try std.testing.expectEqualStrings("rename-me", ctx.tree.getConst(input).kind.text_input.content());
}

test "file browser blank asset space can clear selection" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 960,
        .height = 720,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    state.logical_width = 960;
    state.logical_height = 720;
    state.current_dir = try allocator.dupe(u8, "/tmp");
    state.text_measure_ctx = &text_measure_ctx;
    state.ctx = &ctx;
    try state.entries.append(allocator, .{
        .name = try allocator.dupe(u8, "only-file"),
        .path = try allocator.dupe(u8, "/tmp/only-file"),
        .kind = .file,
        .size_bytes = 12,
        .modified_unix = 0,
    });
    try appendSelectedPathIfMissing(&state, state.entries.items[0].path);
    try setSelectedPath(&state, state.entries.items[0].path);

    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(&state)) ctx.doLayout(&text_measure_ctx);

    const scroll_rect = ctx.tree.getConst(state.file_panel_scroll.?).layout_rect;
    const row_rect = ctx.tree.getConst(state.row_handles.items[0]).layout_rect;
    const blank_x = scroll_rect.x + 24;
    const blank_y = row_rect.y + row_rect.h + 24;

    const body_rect = ctx.tree.getConst(state.asset_table_body.?).layout_rect;
    try std.testing.expect(pointInRect(blank_x, blank_y, body_rect));
    try std.testing.expect(pointInFilePanelBlankSpace(&state, &ctx, blank_x, blank_y));
    try std.testing.expect(clearSelectionState(&state));
    try std.testing.expectEqual(@as(usize, 0), state.selected_paths.items.len);
}

test "file browser blank asset space starts marquee before any selection" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 960,
        .height = 720,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    state.logical_width = 960;
    state.logical_height = 720;
    state.current_dir = try allocator.dupe(u8, "/tmp");
    state.text_measure_ctx = &text_measure_ctx;
    state.ctx = &ctx;
    try state.entries.append(allocator, .{
        .name = try allocator.dupe(u8, "only-file"),
        .path = try allocator.dupe(u8, "/tmp/only-file"),
        .kind = .file,
        .size_bytes = 12,
        .modified_unix = 0,
    });

    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(&state)) ctx.doLayout(&text_measure_ctx);

    const scroll_rect = ctx.tree.getConst(state.file_panel_scroll.?).layout_rect;
    const row_rect = ctx.tree.getConst(state.row_handles.items[0]).layout_rect;
    const blank_x = scroll_rect.x + 24;
    const blank_y = row_rect.y + row_rect.h + 24;
    const row_x = row_rect.x + 24;
    const row_y = row_rect.y + row_rect.h * 0.5;

    const body_rect = ctx.tree.getConst(state.asset_table_body.?).layout_rect;
    try std.testing.expect(pointInRect(blank_x, blank_y, body_rect));
    try std.testing.expect(pointInFilePanelBlankSpace(&state, &ctx, blank_x, blank_y));

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = blank_x, .y = blank_y } });
    try ctx.pushEvent(.{ .mouse_move = .{ .x = row_x, .y = row_y } });
    ctx.processEvents();

    try std.testing.expect(ctx.tree.getConst(state.asset_table_body.?).kind.table.marquee_active);
    try std.testing.expect(ctx.tree.getConst(state.row_handles.items[0]).kind.table_row.selected);
}

test "file browser list refresh grows blank marquee hit area with viewport" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 960,
        .height = 360,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    state.logical_width = 960;
    state.logical_height = 360;
    state.current_dir = try allocator.dupe(u8, "/tmp");
    state.text_measure_ctx = &text_measure_ctx;
    state.ctx = &ctx;
    try state.entries.append(allocator, .{
        .name = try allocator.dupe(u8, "only-file"),
        .path = try allocator.dupe(u8, "/tmp/only-file"),
        .kind = .file,
        .size_bytes = 12,
        .modified_unix = 0,
    });

    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(&state)) ctx.doLayout(&text_measure_ctx);

    state.logical_height = 720;
    ctx.setDimensions(960, 720);
    ctx.doLayout(&text_measure_ctx);

    try std.testing.expect(try refreshAssetViewportIfNeeded(&state));
    ctx.doLayout(&text_measure_ctx);

    const scroll_rect = ctx.tree.getConst(state.file_panel_scroll.?).layout_rect;
    const body_rect = ctx.tree.getConst(state.asset_table_body.?).layout_rect;
    const blank_x = scroll_rect.x + 24;
    const blank_y = scroll_rect.y + scroll_rect.h - 48;
    try std.testing.expect(pointInRect(blank_x, blank_y, body_rect));
    try std.testing.expect(pointInFilePanelBlankSpace(&state, &ctx, blank_x, blank_y));
}

test "file browser syncs toolkit selection from visible entry window" {
    var state = State{};
    defer deinitBrowserState(&state);
    try appendBrowserTestEntries(&state, 8);
    state.asset_visible_start = 3;

    var ctx = try goop.Context.init(allocator, .{
        .width = 640,
        .height = 480,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    const table = try ctx.tree.addChild(root, .{ .table = .{ .selection_mode = .multiple } });
    _ = try ctx.tree.addChild(table, .{ .table_row = .{} });
    _ = try ctx.tree.addChild(table, .{ .table_row = .{ .selected = true } });
    try syncSelectedPathsFromTable(&state, &ctx, table);
    try std.testing.expectEqual(@as(usize, 1), state.selected_paths.items.len);
    try std.testing.expectEqualStrings("/tmp/entry-004.txt", state.selected_paths.items[0]);

    clearSelectedPaths(&state);
    const grid = try ctx.tree.addChild(root, .{ .grid_selector = .{ .selection_mode = .multiple } });
    _ = try ctx.tree.addChild(grid, .{ .grid_item = .{ .label = "a" } });
    _ = try ctx.tree.addChild(grid, .{ .grid_item = .{ .label = "b", .selected = true } });
    try syncSelectedPathsFromGrid(&state, &ctx, grid);
    try std.testing.expectEqual(@as(usize, 1), state.selected_paths.items.len);
    try std.testing.expectEqualStrings("/tmp/entry-004.txt", state.selected_paths.items[0]);
}

test "file browser selection detail does not resize the list at ui scale 2" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 1600,
        .height = 960,
        .theme = fileManagerThemeForScale(2),
    });
    defer ctx.deinit();

    state.ui_scale = 2;
    state.current_dir = try allocator.dupe(u8, "/tmp");
    state.text_measure_ctx = &text_measure_ctx;
    state.ctx = &ctx;

    const long_name = "this-is-a-very-long-file-name-without-natural-break-points-to-force-detail-panel-overflow.txt";
    const long_path = "/tmp/this-is-a-very-long-file-name-without-natural-break-points-to-force-detail-panel-overflow.txt";
    try state.entries.append(allocator, .{
        .name = try allocator.dupe(u8, long_name),
        .path = try allocator.dupe(u8, long_path),
        .kind = .file,
        .size_bytes = 1024,
        .modified_unix = 0,
    });
    try appendBrowserTestEntries(&state, 48);

    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(&state)) {
        ctx.doLayout(&text_measure_ctx);
    }
    const width_before = ctx.tree.getConst(state.asset_table.?).layout_rect.w;
    try appendSelectedPathIfMissing(&state, state.entries.items[0].path);
    try setSelectedPath(&state, state.entries.items[0].path);
    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(&state)) {
        ctx.doLayout(&text_measure_ctx);
    }
    const width_after = ctx.tree.getConst(state.asset_table.?).layout_rect.w;
    try std.testing.expect(@abs(width_before - width_after) < 4);
}

test "folder tree derives partial ancestors and expanded current directory" {
    var state = State{};
    state.current_dir = try allocator.dupe(u8, "/home/user/project");
    defer {
        allocator.free(state.current_dir);
        clearTrackedPaths(&state.folder_tree_expanded_paths);
        state.folder_tree_expanded_paths.deinit(allocator);
    }

    try std.testing.expectEqual(FolderTreeExpansion.partial, folderTreeExpansion(&state, "/"));
    try std.testing.expectEqual(FolderTreeExpansion.partial, folderTreeExpansion(&state, "/home"));
    try std.testing.expectEqual(FolderTreeExpansion.partial, folderTreeExpansion(&state, "/home/user"));
    try std.testing.expectEqual(FolderTreeExpansion.expanded, folderTreeExpansion(&state, "/home/user/project"));
    try std.testing.expectEqual(FolderTreeExpansion.collapsed, folderTreeExpansion(&state, "/tmp"));

    try std.testing.expect(shouldRenderFolderTreeChildForExpansion(&state, .partial, 900, "/home"));
    try std.testing.expect(!shouldRenderFolderTreeChildForExpansion(&state, .partial, 0, "/tmp"));

    try std.testing.expect(try setFolderTreePathExpanded(&state, "/tmp", true));
    try std.testing.expectEqual(FolderTreeExpansion.expanded, folderTreeExpansion(&state, "/tmp"));
    try std.testing.expect(shouldRenderFolderTreeChildForExpansion(&state, .expanded, 900, "/tmp"));
}

test "folder tree preserves previous current branch when navigating to ancestor" {
    var state = State{};
    state.current_dir = try allocator.dupe(u8, "/home/user/project/goop");
    defer {
        allocator.free(state.current_dir);
        clearTrackedPaths(&state.folder_tree_expanded_paths);
        state.folder_tree_expanded_paths.deinit(allocator);
    }

    try preserveFolderTreeContextForNavigation(&state, "/home/user/project");
    try std.testing.expect(isFolderTreePathExpanded(&state, "/home/user/project/goop"));

    allocator.free(state.current_dir);
    state.current_dir = try allocator.dupe(u8, "/home/user/project");

    try std.testing.expectEqual(FolderTreeExpansion.expanded, folderTreeExpansion(&state, "/home/user/project"));
    try std.testing.expectEqual(FolderTreeExpansion.expanded, folderTreeExpansion(&state, "/home/user/project/goop"));
    try std.testing.expect(shouldRenderFolderTreeChildForExpansion(&state, .expanded, 900, "/home/user/project/goop"));
}

test "sidebar scroll survives widget tree rebuild" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 960,
        .height = 720,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    state.current_dir = try allocator.dupe(u8, "/tmp");
    state.text_measure_ctx = &text_measure_ctx;
    state.ctx = &ctx;

    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);
    const first_scroll = state.sidebar_scroll.?;
    if (ctx.runtime.mutateKind(&ctx.tree, first_scroll)) |__k| { __k.scroll_area.scroll_y = 73; }

    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);
    const second_scroll = state.sidebar_scroll.?;
    try std.testing.expectApproxEqAbs(@as(f32, 73), ctx.tree.getConst(second_scroll).kind.scroll_area.scroll_y, 0.01);
}

test "browser list window keeps rendered body aligned with logical row offset" {
    var state = State{};
    defer state.entries.deinit(allocator);

    for (0..64) |_| {
        try state.entries.append(allocator, .{
            .name = @constCast(""[0..]),
            .path = @constCast(""[0..]),
            .kind = .file,
            .size_bytes = 0,
            .modified_unix = 0,
        });
    }

    state.file_panel_scroll_y = 104;
    const window = browserListWindow(&state, 120);
    const row_height = browserListRowHeight(&state);
    const gap = browserVirtualGap(&state);
    const visible_start = @as(usize, @intFromFloat(@floor(window.scroll_y / row_height)));
    const visible_count = browserVisibleCount(120, row_height);
    const expected_range = browserVirtualRange(state.entries.items.len, visible_start, visible_count);
    const body_y = if (window.top_spacer > 0) window.top_spacer + gap else 0;
    const visible_height = row_height * @as(f32, @floatFromInt(window.end - window.start));
    const trailing = if (window.bottom_spacer > 0) window.bottom_spacer + gap else 0;
    const total_height = row_height * @as(f32, @floatFromInt(state.entries.items.len));

    try std.testing.expectEqual(expected_range.start, window.start);
    try std.testing.expectEqual(expected_range.end, window.end);
    try std.testing.expectApproxEqAbs(row_height * @as(f32, @floatFromInt(window.start)), body_y, 0.01);
    try std.testing.expectApproxEqAbs(total_height, body_y + visible_height + trailing, 0.01);
}

test "browser grid window keeps rendered body aligned with logical row offset" {
    var state = State{};
    defer state.entries.deinit(allocator);

    for (0..80) |_| {
        try state.entries.append(allocator, .{
            .name = @constCast(""[0..]),
            .path = @constCast(""[0..]),
            .kind = .file,
            .size_bytes = 0,
            .modified_unix = 0,
        });
    }

    state.logical_width = 800;
    state.file_panel_scroll_y = 640;
    const viewport_width: f32 = 480;
    const viewport_height: f32 = 220;
    const window = browserGridWindow(&state, viewport_width, viewport_height);
    const gap = browserVirtualGap(&state);
    const slot_height = browser_grid_item_height + browser_grid_row_gap;
    const content_scroll_y = @max(window.scroll_y - browser_grid_padding_v, 0);
    const visible_start_row = @as(usize, @intFromFloat(@floor(content_scroll_y / slot_height)));
    const visible_row_count = browserVisibleCount(@max(viewport_height - browser_grid_padding_v * 2, browser_grid_item_height) + browser_grid_row_gap, slot_height);
    const total_rows = std.math.divCeil(usize, state.entries.items.len, window.columns) catch unreachable;
    const expected_range = browserVirtualRange(total_rows, visible_start_row, visible_row_count);
    const start_row = window.start / window.columns;
    const desired_body_y = browser_grid_padding_v + @as(f32, @floatFromInt(start_row)) * slot_height;
    const body_y = if (window.top_spacer > 0) window.top_spacer + gap else 0;
    const visible_rows = std.math.divCeil(usize, window.end - window.start, window.columns) catch unreachable;
    const visible_height = browser_grid_item_height * @as(f32, @floatFromInt(visible_rows)) +
        browser_grid_row_gap * @as(f32, @floatFromInt(if (visible_rows > 0) visible_rows - 1 else 0));
    const trailing = if (window.bottom_spacer > 0) window.bottom_spacer + gap else 0;
    const total_height = browser_grid_padding_v * 2 +
        browser_grid_item_height * @as(f32, @floatFromInt(total_rows)) +
        browser_grid_row_gap * @as(f32, @floatFromInt(total_rows - 1));

    try std.testing.expectEqual(expected_range.start * window.columns, window.start);
    try std.testing.expectApproxEqAbs(desired_body_y, body_y, 0.01);
    try std.testing.expectApproxEqAbs(total_height, body_y + visible_height + trailing, 0.01);
}

test "file browser list scroll keeps existing window until the render range changes" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 960,
        .height = 720,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    try initBrowserListTestState(&state, &ctx, &text_measure_ctx);

    const scroll_handle = state.file_panel_scroll.?;
    const row_height = browserListRowHeight(&state);
    const visible_count = browserVisibleCount(state.file_panel_viewport_height, row_height);
    const chunk_rows = browserVirtualChunkRows(visible_count);
    const target_scroll = row_height * @as(f32, @floatFromInt(chunk_rows - 1)) + row_height * 0.5;
    const start_before = state.asset_visible_start;
    const end_before = state.asset_visible_end;

    if (ctx.runtime.mutateKind(&ctx.tree, scroll_handle)) |__k| { __k.scroll_area.scroll_y = target_scroll; }
    const rebuilt = try syncBrowserTestScrollFrame(&state, &ctx, &text_measure_ctx);

    try std.testing.expect(!rebuilt);
    try std.testing.expectEqual(start_before, state.asset_visible_start);
    try std.testing.expectEqual(end_before, state.asset_visible_end);
    try std.testing.expectApproxEqAbs(target_scroll, ctx.tree.getConst(scroll_handle).kind.scroll_area.scroll_y, 0.01);
}

test "file browser list preserves row continuity across virtualization boundaries" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 960,
        .height = 720,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    try initBrowserListTestState(&state, &ctx, &text_measure_ctx);

    const scroll_handle = state.file_panel_scroll.?;
    const row_height = browserListRowHeight(&state);
    const visible_count = browserVisibleCount(state.file_panel_viewport_height, row_height);
    const chunk_rows = browserVirtualChunkRows(visible_count);
    const boundary_scroll = row_height * @as(f32, @floatFromInt(chunk_rows));
    const logical_entry_index = chunk_rows + browser_overscan_rows;

    if (ctx.runtime.mutateKind(&ctx.tree, scroll_handle)) |__k| { __k.scroll_area.scroll_y = boundary_scroll - 1; }
    _ = try syncBrowserTestScrollFrame(&state, &ctx, &text_measure_ctx);
    const first_row = state.row_handles.items[logical_entry_index - state.asset_visible_start];
    const first_y = ctx.tree.getConst(first_row).layout_rect.y;

    if (ctx.runtime.mutateKind(&ctx.tree, scroll_handle)) |__k| { __k.scroll_area.scroll_y = boundary_scroll; }
    const rebuilt = try syncBrowserTestScrollFrame(&state, &ctx, &text_measure_ctx);
    const second_row = state.row_handles.items[logical_entry_index - state.asset_visible_start];
    const second_y = ctx.tree.getConst(second_row).layout_rect.y;

    try std.testing.expect(rebuilt);
    try std.testing.expectEqual(chunk_rows - browser_overscan_rows, state.asset_visible_start);
    try std.testing.expectApproxEqAbs(first_y - 1, second_y, 0.01);
}

test "file browser list covers the viewport after a large scroll jump" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 960,
        .height = 720,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    try initBrowserListTestState(&state, &ctx, &text_measure_ctx);

    const scroll_handle = state.file_panel_scroll.?;
    const row_height = browserListRowHeight(&state);
    const target_row: usize = 120;
    const target_scroll = row_height * @as(f32, @floatFromInt(target_row)) + row_height * 0.25;
    const visible_count = browserVisibleCount(state.file_panel_viewport_height, row_height);

    if (ctx.runtime.mutateKind(&ctx.tree, scroll_handle)) |__k| { __k.scroll_area.scroll_y = target_scroll; }
    const rebuilt = try syncBrowserTestScrollFrame(&state, &ctx, &text_measure_ctx);

    try std.testing.expect(rebuilt);
    try std.testing.expect(state.asset_visible_start <= target_row);
    try std.testing.expect(state.asset_visible_end >= target_row + visible_count);
}

