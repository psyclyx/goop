const std = @import("std");
const goop = @import("goop");

const fm = @import("controller.zig");
const types = @import("types.zig");
const State = fm.State;
const allocator = fm.allocator;

const style = @import("style.zig");
const preview = @import("preview.zig");
const fs = @import("fs.zig");

// ── Type aliases ──
const BrowserEntry = types.BrowserEntry;
const BrowserEntryKind = types.BrowserEntryKind;
const BrowserPlace = types.BrowserPlace;
const FolderTreeChild = types.FolderTreeChild;
const BrowserSortColumn = types.BrowserSortColumn;
const BrowserSortDirection = types.BrowserSortDirection;
const BrowserViewMode = types.BrowserViewMode;
const BrowserCommand = types.BrowserCommand;
const WidgetUserKind = types.WidgetUserKind;
const FolderTreeExpansion = types.FolderTreeExpansion;
const ListVirtualWindow = types.ListVirtualWindow;
const GridVirtualWindow = types.GridVirtualWindow;

// ── Constants from fm ──
const browser_overscan_rows = types.browser_overscan_rows;
const browser_virtual_chunk_rows_min = types.browser_virtual_chunk_rows_min;
const browser_table_divider_width = types.browser_table_divider_width;
const browser_name_icon_inset_left = types.browser_name_icon_inset_left;
const browser_name_text_inset_left = types.browser_name_text_inset_left;
const browser_grid_item_width = types.browser_grid_item_width;
const browser_grid_item_height = types.browser_grid_item_height;
const browser_grid_column_gap = types.browser_grid_column_gap;
const browser_grid_row_gap = types.browser_grid_row_gap;
const browser_grid_padding_h = types.browser_grid_padding_h;
const browser_grid_padding_v = types.browser_grid_padding_v;
const folder_tree_max_visible_children = types.folder_tree_max_visible_children;

// ── Style helpers (from style.zig) ──
const uiPx = style.uiPx;
const uiEdgesAll = style.uiEdgesAll;
const uiEdgesSymmetric = style.uiEdgesSymmetric;
const fileManagerToolbarButtonStyle = style.fileManagerToolbarButtonStyle;
const fileManagerTextInputStyle = style.fileManagerTextInputStyle;
const fileManagerRenameInputStyle = style.fileManagerRenameInputStyle;
const fileManagerMenuBarStyle = style.fileManagerMenuBarStyle;
const fileManagerMenuStyle = style.fileManagerMenuStyle;
const fileManagerMenuPopupStyle = style.fileManagerMenuPopupStyle;
const fileManagerMenuItemStyle = style.fileManagerMenuItemStyle;
const fileManagerSectionLabelStyle = style.fileManagerSectionLabelStyle;
const fileManagerFolderTreeStyle = style.fileManagerFolderTreeStyle;
const fileManagerFolderTreeItemStyle = style.fileManagerFolderTreeItemStyle;
const fileManagerPlaceItemStyle = style.fileManagerPlaceItemStyle;
const fileManagerStatusTextStyle = style.fileManagerStatusTextStyle;
const fileManagerShellStyle = style.fileManagerShellStyle;
const fileManagerToolbarStyle = style.fileManagerToolbarStyle;
const fileManagerPaneStyle = style.fileManagerPaneStyle;
const fileManagerPaneHeaderStyle = style.fileManagerPaneHeaderStyle;
const fileManagerDetailContentStyle = style.fileManagerDetailContentStyle;
const fileManagerPreviewFrameStyle = style.fileManagerPreviewFrameStyle;
const fileManagerDetailTitleStyle = style.fileManagerDetailTitleStyle;
const fileManagerDetailMetaStyle = style.fileManagerDetailMetaStyle;
const fileManagerDetailHintStyle = style.fileManagerDetailHintStyle;
const fileManagerPreviewBodyStyle = style.fileManagerPreviewBodyStyle;
const fileManagerGutterStyle = style.fileManagerGutterStyle;
const fileManagerSidebarColor = style.fileManagerSidebarColor;
const fileManagerSurfaceColor = style.fileManagerSurfaceColor;

// ── Callbacks back into fm ──
const widgetUserId = types.widgetUserId;
const isPathSelected = fm.isPathSelected;
const selectedPathCount = fm.selectedPathCount;
const selectedEntry = fm.selectedEntry;
const isRenamingPath = fm.isRenamingPath;
const browserCommandChecked = fm.browserCommandChecked;
const browserCommandEnabled = fm.browserCommandEnabled;
const contextOpenEnabled = fm.contextOpenEnabled;
const contextCopyPathEnabled = fm.contextCopyPathEnabled;
const contextOpenLinkTargetEnabled = fm.contextOpenLinkTargetEnabled;
const contextSelectionCommandEnabled = fm.contextSelectionCommandEnabled;
const contextRenameEnabled = fm.contextRenameEnabled;
const contextMoveParentEnabled = fm.contextMoveParentEnabled;
const contextPasteEnabled = fm.contextPasteEnabled;
const browserViewModeLabel = fm.browserViewModeLabel;

// fs callbacks
const isFolderTreePathExpanded = fm.isFolderTreePathExpanded;
const folderTreeExpansion = fm.folderTreeExpansion;
const shouldRenderFolderTreeChildForExpansion = fm.shouldRenderFolderTreeChildForExpansion;
const clearFolderTreeChildren = fs.clearFolderTreeChildren;
const collectFolderTreeChildren = fs.collectFolderTreeChildren;
const folderTreeDirectoryHasChildren = fs.folderTreeDirectoryHasChildren;
const allocAssetEntryNameText = fs.allocAssetEntryNameText;
const allocAssetFormattedTimestamp = fs.allocAssetFormattedTimestamp;
const allocAssetFormattedSize = fs.allocAssetFormattedSize;
const allocFormattedTimestampDetail = fs.allocFormattedTimestampDetail;
const allocFormattedSize = fs.allocFormattedSize;
const sortColumnLabel = fs.sortColumnLabel;
const sortDirectionLabel = fs.sortDirectionLabel;

// preview
const allocSelectionPreview = preview.allocSelectionPreview;

// allocation/string helpers
const allocUtf8LossyOwned = fm.allocUtf8LossyOwned;
const allocUiString = fm.allocUiString;
const allocAssetUiEllipsizedUtf8Lossy = fm.allocAssetUiEllipsizedUtf8Lossy;
const allocUiUtf8Lossy = fm.allocUiUtf8Lossy;
const trackUiString = fm.trackUiString;
const clearAssetBodyTracking = fm.clearAssetBodyTracking;
const clearUiTracking = fm.clearUiTracking;
const scrollDebug = fm.scrollDebug;
const layoutDebug = fm.layoutDebug;

// ── Local helpers wrapping the px-constant helpers ──
fn browserGridItemWidthPx(state: *const State) f32 {
    return uiPx(state, browser_grid_item_width);
}

fn browserGridItemHeightPx(state: *const State) f32 {
    return uiPx(state, browser_grid_item_height);
}

fn browserGridColumnGapPx(state: *const State) f32 {
    return uiPx(state, browser_grid_column_gap);
}

fn browserGridRowGapPx(state: *const State) f32 {
    return uiPx(state, browser_grid_row_gap);
}

fn browserGridPaddingHPx(state: *const State) f32 {
    return uiPx(state, browser_grid_padding_h);
}

fn browserGridPaddingVPx(state: *const State) f32 {
    return uiPx(state, browser_grid_padding_v);
}

fn browserTableDividerWidthPx(state: *const State) f32 {
    _ = state;
    return browser_table_divider_width;
}

fn browserNameIconInsetLeftPx(state: *const State) f32 {
    return uiPx(state, browser_name_icon_inset_left);
}

fn browserNameTextInsetLeftPx(state: *const State) f32 {
    return uiPx(state, browser_name_text_inset_left);
}

// ── Viewport / virtualization ──

pub fn captureFilePanelViewport(state: *State, ctx: *goop.Context) void {
    const handle = state.view.chrome.file_panel_scroll orelse return;
    if (!ctx.tree.isAlive(handle)) return;
    const node = ctx.tree.getConst(handle);
    state.model.file_panel_scroll_y = node.kind.scroll_area.scroll_y;
    state.view.layout.file_panel_viewport_width = node.layout_rect.w;
    state.view.layout.file_panel_viewport_height = node.layout_rect.h;
}

pub fn captureSidebarScroll(state: *State, ctx: *goop.Context) void {
    const handle = state.view.chrome.sidebar_scroll orelse return;
    if (!ctx.tree.isAlive(handle)) return;
    const node = ctx.tree.getConst(handle);
    if (node.kind != .scroll_area) return;
    state.model.sidebar_scroll_x = node.kind.scroll_area.scroll_x;
    state.model.sidebar_scroll_y = node.kind.scroll_area.scroll_y;
}

pub fn browserViewportWidthEstimate(state: *const State) f32 {
    if (state.view.layout.file_panel_viewport_width > 0) return state.view.layout.file_panel_viewport_width;
    return @as(f32, @floatFromInt(state.runtime.logical_width));
}

pub fn browserViewportHeightEstimate(state: *const State) f32 {
    if (state.view.layout.file_panel_viewport_height > 0) return state.view.layout.file_panel_viewport_height;
    return @as(f32, @floatFromInt(state.runtime.logical_height));
}

pub fn browserVirtualGap(state: *const State) f32 {
    if (state.runtime.ctx) |ctx| return ctx.theme.spacing;
    return goop.Theme.default.spacing;
}

pub fn browserListRowHeight(state: *const State) f32 {
    const ctx = state.runtime.ctx orelse return uiPx(state, 26);
    const text_metrics = goop.layout.textMetrics(ctx.theme.font_size, state.runtime.text_measure_ctx);
    return text_metrics.height + ctx.theme.padding.top + ctx.theme.padding.bottom;
}

pub fn browserGridColumnsForViewport(state: *const State, viewport_width: f32) usize {
    const grid_padding_h = browserGridPaddingHPx(state);
    const grid_item_width = browserGridItemWidthPx(state);
    const grid_column_gap = browserGridColumnGapPx(state);
    const inner_width = @max(viewport_width - grid_padding_h * 2, grid_item_width);
    const slot_width = grid_item_width + grid_column_gap;
    return @max(@as(usize, @intFromFloat(@floor((inner_width + grid_column_gap) / slot_width))), 1);
}

pub fn browserVisibleCount(viewport_extent: f32, slot_extent: f32) usize {
    return @max(@as(usize, @intFromFloat(@ceil(viewport_extent / slot_extent))), 1);
}

pub fn browserVirtualChunkRows(visible_count: usize) usize {
    return @max(visible_count, browser_virtual_chunk_rows_min);
}

pub fn browserVirtualRange(total_items: usize, visible_start: usize, visible_count: usize) struct { start: usize, end: usize } {
    if (total_items == 0) return .{ .start = 0, .end = 0 };

    const chunk_rows = browserVirtualChunkRows(visible_count);
    const render_count = @min(total_items, visible_count + chunk_rows + browser_overscan_rows * 2);
    if (render_count >= total_items) return .{ .start = 0, .end = total_items };

    const chunk_origin = (visible_start / chunk_rows) * chunk_rows;
    var start = chunk_origin -| browser_overscan_rows;
    if (start + render_count > total_items) start = total_items - render_count;
    return .{
        .start = start,
        .end = start + render_count,
    };
}

pub fn browserListWindow(state: *const State, viewport_height: f32) ListVirtualWindow {
    const total_entries = state.model.entries.items.len;
    if (total_entries == 0) return .{};

    const row_height = browserListRowHeight(state);
    const virtual_gap = browserVirtualGap(state);
    const total_height = row_height * @as(f32, @floatFromInt(total_entries));
    const scroll_y = std.math.clamp(state.model.file_panel_scroll_y, 0, @max(total_height - viewport_height, 0));
    const visible_start = @min(total_entries, @as(usize, @intFromFloat(@floor(scroll_y / row_height))));
    const visible_count = browserVisibleCount(viewport_height, row_height);
    const range = browserVirtualRange(total_entries, visible_start, visible_count);
    const start = range.start;
    const end = range.end;
    const top_spacer = if (start > 0)
        @max(row_height * @as(f32, @floatFromInt(start)) - virtual_gap, 0)
    else
        0;
    const bottom_spacer = if (end < total_entries)
        @max(row_height * @as(f32, @floatFromInt(total_entries - end)) - virtual_gap, 0)
    else
        0;

    return .{
        .start = start,
        .end = end,
        .top_spacer = top_spacer,
        .bottom_spacer = bottom_spacer,
        .scroll_y = scroll_y,
    };
}

pub fn browserGridWindow(state: *const State, viewport_width: f32, viewport_height: f32) GridVirtualWindow {
    const columns = browserGridColumnsForViewport(state, viewport_width);
    const total_entries = state.model.entries.items.len;
    if (total_entries == 0) return .{ .columns = columns };

    const virtual_gap = browserVirtualGap(state);
    const grid_padding_v = browserGridPaddingVPx(state);
    const grid_item_height = browserGridItemHeightPx(state);
    const grid_row_gap = browserGridRowGapPx(state);
    const total_rows = std.math.divCeil(usize, total_entries, columns) catch unreachable;
    const total_height = grid_padding_v * 2 +
        grid_item_height * @as(f32, @floatFromInt(total_rows)) +
        grid_row_gap * @as(f32, @floatFromInt(total_rows - 1));
    const scroll_y = std.math.clamp(state.model.file_panel_scroll_y, 0, @max(total_height - viewport_height, 0));
    const slot_height = grid_item_height + grid_row_gap;
    const content_scroll_y = @max(scroll_y - grid_padding_v, 0);
    const visible_start_row = @min(total_rows, @as(usize, @intFromFloat(@floor(content_scroll_y / slot_height))));
    const inner_viewport_height = @max(viewport_height - grid_padding_v * 2, grid_item_height);
    const visible_row_count = browserVisibleCount(inner_viewport_height + grid_row_gap, slot_height);
    const row_range = browserVirtualRange(total_rows, visible_start_row, visible_row_count);
    const start_row = row_range.start;
    const end_row = row_range.end;
    const start = @min(total_entries, start_row * columns);
    const end = @min(total_entries, end_row * columns);
    const rendered_rows = end_row - start_row;
    const visible_height = grid_item_height * @as(f32, @floatFromInt(rendered_rows)) +
        grid_row_gap * @as(f32, @floatFromInt(if (rendered_rows > 0) rendered_rows - 1 else 0));
    const body_y = grid_padding_v + @as(f32, @floatFromInt(start_row)) * slot_height;
    const remaining_height = @max(total_height - body_y - visible_height, 0);
    const top_spacer = if (body_y > 0)
        @max(body_y - virtual_gap, 0)
    else
        0;
    const bottom_spacer = if (remaining_height > 0)
        @max(remaining_height - virtual_gap, 0)
    else
        0;

    return .{
        .start = start,
        .end = end,
        .columns = columns,
        .top_spacer = top_spacer,
        .bottom_spacer = bottom_spacer,
        .scroll_y = scroll_y,
    };
}

// ── Table cells ──

pub fn addTextCell(state: *const State, ctx: *goop.Context, row: goop.NodeHandle, text: []const u8) !void {
    const cell = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    _ = ctx.setStyle(cell, .{
        .border_width = browserTableDividerWidthPx(state),
    });
    _ = try ctx.tree.addChild(cell, .{ .text = .{ .content = text, .overflow = .ellipsis } });
}

pub fn addNameHeaderCell(state: *const State, ctx: *goop.Context, row: goop.NodeHandle, text: []const u8) !void {
    const cell = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    _ = ctx.setStyle(cell, .{
        .border_width = browserTableDividerWidthPx(state),
        .padding = .{
            .top = uiPx(state, 6),
            .right = uiPx(state, 8),
            .bottom = uiPx(state, 6),
            .left = browserNameIconInsetLeftPx(state),
        },
    });
    _ = try ctx.tree.addChild(cell, .{ .text = .{ .content = text, .overflow = .ellipsis } });
}

pub fn addNameCell(state: *State, ctx: *goop.Context, row: goop.NodeHandle, entry: BrowserEntry) !goop.NodeHandle {
    const cell = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    _ = ctx.setStyle(cell, .{
        .border_width = browserTableDividerWidthPx(state),
        .padding = .{
            .top = uiPx(state, 6),
            .right = uiPx(state, 8),
            .bottom = uiPx(state, 6),
            .left = browserNameTextInsetLeftPx(state),
        },
    });
    _ = ctx.setCustomPaint(cell, true);
    if (isRenamingPath(state, entry.path)) {
        const input = try ctx.tree.addChild(cell, .{ .text_input = .{ .placeholder = state.interaction.rename_input.placeholder } });
        if (ctx.mutateKind(input)) |kind| {
            kind.text_input = state.interaction.rename_input;
        }
        _ = ctx.setStyle(input, fileManagerRenameInputStyle(state));
        state.interaction.rename_input_handle = input;
        _ = ctx.focusWidget(input);
    } else {
        _ = try ctx.tree.addChild(cell, .{ .text = .{
            .content = try allocAssetEntryNameText(state, entry),
            .overflow = .ellipsis,
        } });
    }
    return cell;
}

// ── Detail-pane sizing & wrapping ──

pub fn detailTitleFontSizePx(state: *const State) f32 {
    return uiPx(state, 16);
}

pub fn detailCaptionFontSizePx(state: *const State) f32 {
    return uiPx(state, 13);
}

pub fn previewBodyFontSizePx(state: *const State) f32 {
    return uiPx(state, 13);
}

pub fn clampDetailSplitterRatio(raw: f32, available: f32, min_first: f32, min_second: f32) f32 {
    const clamped = std.math.clamp(raw, 0, 1);
    if (available <= 0) return clamped;

    const min_ratio = std.math.clamp(min_first / available, 0, 1);
    const max_ratio = std.math.clamp(1 - min_second / available, 0, 1);
    if (min_ratio > max_ratio) return clamped;
    return std.math.clamp(clamped, min_ratio, max_ratio);
}

pub fn browserBodyWidthPx(state: *const State) f32 {
    var width = @max(@as(f32, @floatFromInt(@max(state.runtime.logical_width, @as(u32, 1)))) - 1, 1);
    if (state.model.show_sidebar) {
        const nav_ratio = clampDetailSplitterRatio(state.model.nav_ratio, width, uiPx(state, 220), uiPx(state, 420));
        width *= 1 - nav_ratio;
    }
    return @max(width, 1);
}

pub fn inspectorPanelWidthPx(state: *const State) f32 {
    var width = browserBodyWidthPx(state);
    if (state.model.show_preview or state.model.show_info) {
        const detail_ratio = clampDetailSplitterRatio(state.model.detail_ratio, width, uiPx(state, 360), uiPx(state, 300));
        width *= 1 - detail_ratio;
    }
    return @max(width, uiPx(state, 200));
}

pub fn detailTextWrapWidthPx(state: *const State) f32 {
    // Reserve the scroll + panel padding so wrapped inspector text stays inside the pane body.
    return @max(inspectorPanelWidthPx(state) - uiPx(state, 44), uiPx(state, 156));
}

pub fn measureDetailTextWidth(text: []const u8, font_size: f32, text_ctx: *const goop.TextMeasureCtx) f32 {
    return goop.layout.measureTextDimensions(text, font_size, text_ctx).width;
}

pub fn isDetailWrapBoundary(codepoint: u21) bool {
    return switch (codepoint) {
        ' ', '\t', '/', '\\', '-', '_', '.' => true,
        else => false,
    };
}

pub fn flushDetailWrappedLine(out: *std.ArrayListUnmanaged(u8), line: *std.ArrayListUnmanaged(u8)) !void {
    if (line.items.len == 0) return;
    if (out.items.len > 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, line.items);
    line.clearRetainingCapacity();
}

pub fn appendDetailForcedWrappedToken(
    out: *std.ArrayListUnmanaged(u8),
    line: *std.ArrayListUnmanaged(u8),
    token: []const u8,
    max_width: f32,
    font_size: f32,
    text_ctx: *const goop.TextMeasureCtx,
) !void {
    var view = std.unicode.Utf8View.init(token) catch unreachable;
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const previous_len = line.items.len;
        try line.appendSlice(allocator, slice);
        if (previous_len == 0 or measureDetailTextWidth(line.items, font_size, text_ctx) <= max_width) continue;

        line.items.len = previous_len;
        try flushDetailWrappedLine(out, line);
        try line.appendSlice(allocator, slice);
    }
}

pub fn appendDetailWrappedToken(
    out: *std.ArrayListUnmanaged(u8),
    line: *std.ArrayListUnmanaged(u8),
    token: []const u8,
    max_width: f32,
    font_size: f32,
    text_ctx: *const goop.TextMeasureCtx,
) !void {
    if (token.len == 0) return;

    const previous_len = line.items.len;
    try line.appendSlice(allocator, token);
    if (measureDetailTextWidth(line.items, font_size, text_ctx) <= max_width) return;

    line.items.len = previous_len;
    if (previous_len > 0) {
        try flushDetailWrappedLine(out, line);
    }

    try appendDetailForcedWrappedToken(out, line, token, max_width, font_size, text_ctx);
}

pub fn wrapTextOwnedForWidth(state: *const State, text: []u8, font_size: f32, max_width: f32) ![]u8 {
    const text_ctx = state.runtime.text_measure_ctx orelse return text;
    if (std.mem.indexOfScalar(u8, text, '\n') == null and measureDetailTextWidth(text, font_size, text_ctx) <= max_width) {
        return text;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(allocator);
    var token: std.ArrayListUnmanaged(u8) = .empty;
    defer token.deinit(allocator);

    var view = std.unicode.Utf8View.init(text) catch unreachable;
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const codepoint = std.unicode.utf8Decode(slice) catch unreachable;
        if (codepoint == '\n') {
            try appendDetailWrappedToken(&out, &line, token.items, max_width, font_size, text_ctx);
            token.clearRetainingCapacity();
            try flushDetailWrappedLine(&out, &line);
            continue;
        }

        try token.appendSlice(allocator, slice);
        if (isDetailWrapBoundary(codepoint)) {
            try appendDetailWrappedToken(&out, &line, token.items, max_width, font_size, text_ctx);
            token.clearRetainingCapacity();
        }
    }

    try appendDetailWrappedToken(&out, &line, token.items, max_width, font_size, text_ctx);
    try flushDetailWrappedLine(&out, &line);

    if (out.items.len == 0 or std.mem.eql(u8, out.items, text)) return text;

    const wrapped = try allocator.dupe(u8, out.items);
    allocator.free(text);
    return wrapped;
}

pub fn wrapDetailTextOwned(state: *const State, text: []u8, font_size: f32) ![]u8 {
    return wrapTextOwnedForWidth(state, text, font_size, detailTextWrapWidthPx(state));
}

pub fn allocUiDetailWrappedUtf8Lossy(state: *State, bytes: []const u8, font_size: f32) ![]const u8 {
    return trackUiString(state, try wrapDetailTextOwned(state, try allocUtf8LossyOwned(bytes), font_size));
}

pub fn allocUiWrappedOwnedText(state: *State, text: []u8, font_size: f32) ![]const u8 {
    return trackUiString(state, try wrapTextOwnedForWidth(state, text, font_size, detailTextWrapWidthPx(state)));
}

pub fn addDetailText(
    ctx: *goop.Context,
    parent: goop.NodeHandle,
    text: []const u8,
    overflow: goop.TextOverflow,
) !goop.NodeHandle {
    return ctx.tree.addChild(parent, .{ .text = .{
        .content = text,
        .overflow = overflow,
    } });
}

pub fn addStyledDetailText(
    ctx: *goop.Context,
    parent: goop.NodeHandle,
    text: []const u8,
    overflow: goop.TextOverflow,
    style_override: goop.Style,
) !goop.NodeHandle {
    const handle = try addDetailText(ctx, parent, text, overflow);
    _ = ctx.setStyle(handle, style_override);
    return handle;
}

// ── Asset view builders ──

pub fn applyAssetTableColumns(table: *goop.widget.WidgetKind.Table, state: *const State) void {
    table.internal.column_weights[0] = state.model.table_column_weights[0];
    table.internal.column_weights[1] = state.model.table_column_weights[1];
    table.internal.column_weights[2] = state.model.table_column_weights[2];
    table.internal.column_weights[3] = state.model.table_column_weights[3];
}

pub fn buildListHeaderTable(state: *State, ctx: *goop.Context, parent: goop.NodeHandle) !void {
    state.view.assets.asset_table = try ctx.tree.addChild(parent, .{ .table = .{
        .columns = 4,
        .striped = false,
        .resizable = true,
        .sortable = true,
        .selection_mode = .none,
        .min_column_width = uiPx(state, 96),
    } });
    _ = ctx.setStyle(state.view.assets.asset_table.?, .{
        .bg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .border = .{ .r = 214, .g = 220, .b = 228, .a = 255 },
        .border_width = 0,
        .padding = goop.style.Edges.all(0),
        .border_radius = 0,
    });
    {
        const table = &ctx.mutateKind(state.view.assets.asset_table.?).?.table;
        applyAssetTableColumns(table, state);
        table.sorted_column = @intFromEnum(state.model.sort_column);
        table.sort_direction = switch (state.model.sort_direction) {
            .ascending => .ascending,
            .descending => .descending,
        };
    }

    const header_row = try ctx.tree.addChild(state.view.assets.asset_table.?, .{ .table_row = .{ .header = true } });
    _ = ctx.setStyle(header_row, .{
        .border_width = browserTableDividerWidthPx(state),
    });
    try addNameHeaderCell(state, ctx, header_row, "Name");
    try addTextCell(state, ctx, header_row, "Modified");
    try addTextCell(state, ctx, header_row, "Type");
    try addTextCell(state, ctx, header_row, "Size");
}

pub fn buildListAssetView(state: *State, ctx: *goop.Context, scroll_handle: goop.NodeHandle, viewport_height: f32) !void {
    const window = browserListWindow(state, viewport_height);
    state.model.file_panel_scroll_y = window.scroll_y;
    if (ctx.mutateKind(scroll_handle)) |__k| {
        __k.scroll_area.scroll_y = window.scroll_y;
    }
    state.view.assets.asset_visible_start = window.start;
    state.view.assets.asset_visible_end = window.end;
    state.view.assets.asset_visible_columns = 0;

    state.view.assets.asset_table_body = try ctx.tree.addChild(scroll_handle, .{ .table = .{
        .columns = 4,
        .striped = false,
        .selection_mode = .multiple,
        .min_column_width = uiPx(state, 96),
    } });
    state.view.assets.asset_view_root = state.view.assets.asset_table_body;
    _ = ctx.setStyle(state.view.assets.asset_table_body.?, .{
        .bg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .border_width = 0,
        .padding = blk: {
            const gap = ctx.theme.spacing;
            const top = if (window.top_spacer > 0) window.top_spacer + gap else 0;
            const bottom = if (window.bottom_spacer > 0) window.bottom_spacer + gap else 0;
            const rendered_height = browserListRowHeight(state) * @as(f32, @floatFromInt(window.end - window.start));
            const filler = @max(viewport_height - top - rendered_height - bottom, 0);
            break :blk goop.style.Edges{
                .top = top,
                .right = 0,
                .bottom = bottom + filler,
                .left = 0,
            };
        },
        .border_radius = 0,
    });
    applyAssetTableColumns(&ctx.mutateKind(state.view.assets.asset_table_body.?).?.table, state);

    for (state.model.entries.items[window.start..window.end], window.start..) |entry, entry_index| {
        const row = try ctx.tree.addChild(state.view.assets.asset_table_body.?, .{ .table_row = .{
            .selected = isPathSelected(state, entry.path),
        } });
        ctx.tree.setUserId(row, widgetUserId(.asset_entry, entry_index));
        _ = ctx.setStyle(row, .{
            .border_width = browserTableDividerWidthPx(state),
        });
        try state.view.assets.row_handles.append(allocator, row);
        try state.view.assets.name_cell_handles.append(allocator, try addNameCell(state, ctx, row, entry));
        try addTextCell(state, ctx, row, try allocAssetFormattedTimestamp(state, entry.modified_unix));
        try addTextCell(state, ctx, row, entry.typeLabel());
        try addTextCell(state, ctx, row, try allocAssetFormattedSize(state, entry.kind, entry.size_bytes, entry.target_kind));
    }

    scrollDebug(state, "build list scroll={d:.2} viewport_h={d:.2} window=[{}..{}) rows={} spacers=({d:.2},{d:.2})", .{
        window.scroll_y,
        viewport_height,
        window.start,
        window.end,
        window.end - window.start,
        window.top_spacer,
        window.bottom_spacer,
    });
}

pub fn buildGridAssetView(state: *State, ctx: *goop.Context, scroll_handle: goop.NodeHandle, viewport_width: f32, viewport_height: f32) !void {
    const window = browserGridWindow(state, viewport_width, viewport_height);
    state.model.file_panel_scroll_y = window.scroll_y;
    if (ctx.mutateKind(scroll_handle)) |__k| {
        __k.scroll_area.scroll_y = window.scroll_y;
    }
    state.view.assets.asset_visible_start = window.start;
    state.view.assets.asset_visible_end = window.end;
    state.view.assets.asset_visible_columns = window.columns;

    state.view.assets.asset_view_root = try ctx.tree.addChild(scroll_handle, .{ .container = .{ .direction = .column } });
    _ = ctx.setStyle(state.view.assets.asset_view_root.?, .{
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border_width = 0,
        .padding = goop.style.Edges.all(0),
        .spacing = 0,
        .border_radius = 0,
    });

    state.view.assets.asset_grid = try ctx.tree.addChild(state.view.assets.asset_view_root.?, .{ .grid_selector = .{
        .selection_mode = .multiple,
        .item_width = browserGridItemWidthPx(state),
        .item_height = browserGridItemHeightPx(state),
        .column_gap = browserGridColumnGapPx(state),
        .row_gap = browserGridRowGapPx(state),
    } });
    _ = ctx.setStyle(state.view.assets.asset_grid.?, .{
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border_width = 0,
        .padding = .{
            .top = blk: {
                const gap = ctx.theme.spacing;
                break :blk if (window.top_spacer > 0) window.top_spacer + gap else 0;
            },
            .right = browserGridPaddingHPx(state),
            .bottom = blk: {
                const gap = ctx.theme.spacing;
                const bottom = if (window.bottom_spacer > 0) window.bottom_spacer + gap else 0;
                const rendered_count = window.end - window.start;
                const rendered_rows = if (rendered_count == 0)
                    @as(usize, 0)
                else
                    (rendered_count + window.columns - 1) / window.columns;
                const rendered_height = if (rendered_rows == 0)
                    @as(f32, 0)
                else
                    browserGridItemHeightPx(state) * @as(f32, @floatFromInt(rendered_rows)) +
                        browserGridRowGapPx(state) * @as(f32, @floatFromInt(rendered_rows - 1));
                const top = if (window.top_spacer > 0) window.top_spacer + gap else 0;
                const filler = @max(viewport_height - top - rendered_height - bottom, 0);
                break :blk bottom + filler;
            },
            .left = browserGridPaddingHPx(state),
        },
        .border_radius = 0,
    });

    for (state.model.entries.items[window.start..window.end], window.start..) |entry, entry_index| {
        const item = try ctx.tree.addChild(state.view.assets.asset_grid.?, .{ .grid_item = .{
            .label = try allocAssetUiEllipsizedUtf8Lossy(state, entry.name, uiPx(state, 104), ctx.theme.font_size),
            .selected = isPathSelected(state, entry.path),
        } });
        ctx.tree.setUserId(item, widgetUserId(.asset_entry, entry_index));
        _ = ctx.setCustomPaint(item, true);
        _ = ctx.setStyle(item, .{
            .bg = if (entry.isDirectory())
                .{ .r = 243, .g = 247, .b = 255, .a = 255 }
            else
                .{ .r = 252, .g = 252, .b = 253, .a = 255 },
            .border = if (entry.isDirectory())
                .{ .r = 184, .g = 204, .b = 233, .a = 255 }
            else
                .{ .r = 214, .g = 220, .b = 228, .a = 255 },
            .border_width = 0,
            .padding = uiEdgesSymmetric(state, 10, 10),
            .border_radius = uiPx(state, 10),
        });
        try state.view.assets.grid_handles.append(allocator, item);
    }

    scrollDebug(state, "build grid scroll={d:.2} viewport=({d:.2},{d:.2}) window=[{}..{}) cols={} spacers=({d:.2},{d:.2})", .{
        window.scroll_y,
        viewport_width,
        viewport_height,
        window.start,
        window.end,
        window.columns,
        window.top_spacer,
        window.bottom_spacer,
    });
}

pub fn buildAssetView(state: *State, ctx: *goop.Context, scroll_handle: goop.NodeHandle) !void {
    const viewport_width = browserViewportWidthEstimate(state);
    const viewport_height = browserViewportHeightEstimate(state);

    if (state.model.entries.items.len == 0) {
        state.model.file_panel_scroll_y = 0;
        if (ctx.mutateKind(scroll_handle)) |__k| {
            __k.scroll_area.scroll_y = 0;
        }
        state.view.assets.asset_visible_start = 0;
        state.view.assets.asset_visible_end = 0;
        state.view.assets.asset_visible_columns = 0;
        state.view.assets.asset_view_root = try ctx.tree.addChild(scroll_handle, .{ .text = .{ .content = "This directory is empty." } });
        return;
    }

    switch (state.model.view_mode) {
        .list => try buildListAssetView(state, ctx, scroll_handle, viewport_height),
        .grid => try buildGridAssetView(state, ctx, scroll_handle, viewport_width, viewport_height),
    }
}

pub fn rebuildAssetView(state: *State) !void {
    const ctx = state.runtime.ctx orelse return error.NoContext;
    const scroll_handle = state.view.chrome.file_panel_scroll orelse return error.NoContext;

    scrollDebug(state, "rebuild begin mode={s} prev_window=[{}..{}) scroll={d:.2}", .{
        browserViewModeLabel(state.model.view_mode),
        state.view.assets.asset_visible_start,
        state.view.assets.asset_visible_end,
        state.model.file_panel_scroll_y,
    });

    while (ctx.tree.getConst(scroll_handle).first_child) |child| {
        try ctx.tree.remove(child);
    }
    clearAssetBodyTracking(state);
    try buildAssetView(state, ctx, scroll_handle);

    scrollDebug(state, "rebuild end mode={s} next_window=[{}..{})", .{
        browserViewModeLabel(state.model.view_mode),
        state.view.assets.asset_visible_start,
        state.view.assets.asset_visible_end,
    });
}

pub fn refreshAssetViewportIfNeeded(state: *State) !bool {
    const ctx = state.runtime.ctx orelse return false;
    const scroll_handle = state.view.chrome.file_panel_scroll orelse return false;
    if (!ctx.tree.isAlive(scroll_handle)) return false;

    const previous_scroll_y = state.model.file_panel_scroll_y;
    const previous_viewport_height = state.view.layout.file_panel_viewport_height;
    const previous_visible_start = state.view.assets.asset_visible_start;
    const previous_visible_end = state.view.assets.asset_visible_end;
    const previous_visible_columns = state.view.assets.asset_visible_columns;
    const scroll_node = ctx.tree.getConst(scroll_handle);
    const viewport_width = scroll_node.layout_rect.w;
    const viewport_height = scroll_node.layout_rect.h;
    const current_scroll_y = scroll_node.kind.scroll_area.scroll_y;
    state.view.layout.file_panel_viewport_width = viewport_width;
    state.view.layout.file_panel_viewport_height = viewport_height;
    state.model.file_panel_scroll_y = current_scroll_y;

    if (state.model.entries.items.len == 0) {
        return false;
    }

    switch (state.model.view_mode) {
        .list => {
            const asset_alive = if (state.view.assets.asset_table_body) |body| ctx.tree.isAlive(body) else false;
            const window = browserListWindow(state, viewport_height);
            const viewport_height_changed = @abs(previous_viewport_height - viewport_height) > 0.01;
            const scroll_clamped = @abs(current_scroll_y - window.scroll_y) > 0.01;
            if (scroll_clamped) {
                if (ctx.mutateKind(scroll_handle)) |__k| {
                    __k.scroll_area.scroll_y = window.scroll_y;
                }
                state.model.file_panel_scroll_y = window.scroll_y;
            }
            const needs_rebuild = !asset_alive or viewport_height_changed or state.view.assets.asset_visible_start != window.start or state.view.assets.asset_visible_end != window.end;
            if (needs_rebuild or scroll_clamped or @abs(previous_scroll_y - current_scroll_y) > 0.01) {
                scrollDebug(state, "refresh list viewport_h={d:.2}->{d:.2} scroll={d:.2}->{d:.2} prev_window=[{}..{}) next_window=[{}..{}) alive={} rebuild={} clamp={}", .{
                    previous_viewport_height,
                    viewport_height,
                    previous_scroll_y,
                    current_scroll_y,
                    previous_visible_start,
                    previous_visible_end,
                    window.start,
                    window.end,
                    asset_alive,
                    needs_rebuild,
                    scroll_clamped,
                });
            }
            if (needs_rebuild) {
                try rebuildAssetView(state);
                return true;
            }
            return scroll_clamped;
        },
        .grid => {
            const asset_alive = if (state.view.assets.asset_view_root) |root| ctx.tree.isAlive(root) else false;
            const window = browserGridWindow(state, viewport_width, viewport_height);
            const viewport_height_changed = @abs(previous_viewport_height - viewport_height) > 0.01;
            const scroll_clamped = @abs(current_scroll_y - window.scroll_y) > 0.01;
            if (scroll_clamped) {
                if (ctx.mutateKind(scroll_handle)) |__k| {
                    __k.scroll_area.scroll_y = window.scroll_y;
                }
                state.model.file_panel_scroll_y = window.scroll_y;
            }
            const needs_rebuild = !asset_alive or viewport_height_changed or state.view.assets.asset_visible_start != window.start or state.view.assets.asset_visible_end != window.end or state.view.assets.asset_visible_columns != window.columns;
            if (needs_rebuild or scroll_clamped or @abs(previous_scroll_y - current_scroll_y) > 0.01) {
                scrollDebug(state, "refresh grid viewport=({d:.2},{d:.2}->{d:.2}) scroll={d:.2}->{d:.2} prev_window=[{}..{})/{} next_window=[{}..{})/{} alive={} rebuild={} clamp={}", .{
                    viewport_width,
                    previous_viewport_height,
                    viewport_height,
                    previous_scroll_y,
                    current_scroll_y,
                    previous_visible_start,
                    previous_visible_end,
                    previous_visible_columns,
                    window.start,
                    window.end,
                    window.columns,
                    asset_alive,
                    needs_rebuild,
                    scroll_clamped,
                });
            }
            if (needs_rebuild) {
                try rebuildAssetView(state);
                return true;
            }
            return scroll_clamped;
        },
    }

    return false;
}

// ── Icons + paint composition ──

pub fn browserEntryIconKind(entry: BrowserEntry) u32 {
    const id: types.DemoIcon = switch (entry.kind) {
        .directory => .folder,
        .symlink => if (entry.target_kind == .directory) .folder else .file,
        else => .file,
    };
    return @intFromEnum(id);
}

pub fn browserEntryIconColor(theme: goop.Theme, entry: BrowserEntry, selected: bool) goop.Color {
    if (selected) return theme.accent;
    return switch (entry.kind) {
        .directory => .rgb(74, 120, 201),
        .symlink => if (entry.target_kind == .directory) .rgb(74, 120, 201) else .rgb(118, 127, 141),
        else => .rgb(118, 127, 141),
    };
}

pub fn browserEntryLinkBadgeColor(theme: goop.Theme, selected: bool) goop.Color {
    return if (selected) theme.accent else .rgb(44, 140, 134);
}

pub fn iconRectInTableCell(state: *const State, cell_rect: goop.paint.Rect) goop.paint.Rect {
    const size = @min(@max(cell_rect.h - uiPx(state, 10), uiPx(state, 14)), uiPx(state, 18));
    return .{
        .x = cell_rect.x + browserNameIconInsetLeftPx(state),
        .y = cell_rect.y + (cell_rect.h - size) * 0.5,
        .w = size,
        .h = size,
    };
}

pub fn iconRectInGridItem(ctx: *goop.Context, handle: goop.NodeHandle) goop.paint.Rect {
    const node = ctx.tree.getConst(handle);
    const resolved = node.style_override.resolve(ctx.theme);
    const rect = node.layout_rect;
    const inner = goop.paint.Rect{
        .x = rect.x + resolved.padding.left,
        .y = rect.y + resolved.padding.top,
        .w = @max(rect.w - resolved.padding.left - resolved.padding.right, 0),
        .h = @max(rect.h - resolved.padding.top - resolved.padding.bottom, 0),
    };
    const icon_size = @max(@min(inner.w, inner.h - resolved.font_size - ctx.theme.spacing), 0);
    return .{
        .x = inner.x + (inner.w - icon_size) * 0.5,
        .y = inner.y,
        .w = icon_size,
        .h = @min(icon_size, inner.h - resolved.font_size - ctx.theme.spacing),
    };
}

pub fn symlinkBadgeRect(base: goop.paint.Rect) goop.paint.Rect {
    const size = @max(@min(base.w, base.h) * 0.42, 7);
    return .{
        .x = base.x + base.w - size * 0.82,
        .y = base.y + base.h - size * 0.82,
        .w = size,
        .h = size,
    };
}

pub fn appendEntryIconCommands(
    state: *State,
    ctx: *goop.Context,
    entry: BrowserEntry,
    bounds: goop.paint.Rect,
) !void {
    const selected = isPathSelected(state, entry.path);
    try state.view.composed_paint_commands.append(allocator, .{ .icon = .{
        .bounds = bounds,
        .kind = browserEntryIconKind(entry),
        .color = browserEntryIconColor(ctx.theme, entry, selected),
    } });
    if (entry.kind == .symlink) {
        try state.view.composed_paint_commands.append(allocator, .{ .icon = .{
            .bounds = symlinkBadgeRect(bounds),
            .kind = @intFromEnum(types.DemoIcon.symlink),
            .color = browserEntryLinkBadgeColor(ctx.theme, selected),
        } });
    }
}

pub fn composeFileBrowserPaintList(state: *State, base: goop.PaintList) !goop.PaintList {
    const ctx = state.runtime.ctx orelse return base;

    state.view.composed_paint_commands.clearRetainingCapacity();
    try state.view.composed_paint_commands.ensureTotalCapacity(allocator, base.commands.len + state.view.assets.name_cell_handles.items.len * 2 + state.view.assets.grid_handles.items.len * 2);

    for (base.commands) |command| {
        switch (command) {
            .custom => |custom| {
                var matched_index: ?usize = null;
                for (state.view.assets.name_cell_handles.items, 0..) |handle, index| {
                    if (handle.eql(custom.handle)) {
                        matched_index = index;
                        break;
                    }
                }
                if (matched_index) |index| {
                    const entry_index = state.view.assets.asset_visible_start + index;
                    if (entry_index < state.model.entries.items.len) {
                        const entry = state.model.entries.items[entry_index];
                        try appendEntryIconCommands(state, ctx, entry, iconRectInTableCell(state, custom.bounds));
                    }
                    continue;
                }

                matched_index = null;
                for (state.view.assets.grid_handles.items, 0..) |handle, index| {
                    if (handle.eql(custom.handle)) {
                        matched_index = index;
                        break;
                    }
                }
                if (matched_index) |index| {
                    const entry_index = state.view.assets.asset_visible_start + index;
                    if (entry_index < state.model.entries.items.len) {
                        const entry = state.model.entries.items[entry_index];
                        try appendEntryIconCommands(state, ctx, entry, iconRectInGridItem(ctx, custom.handle));
                    }
                    continue;
                }
            },
            else => {},
        }
        try state.view.composed_paint_commands.append(allocator, command);
    }

    return .{ .commands = state.view.composed_paint_commands.items };
}

pub fn debugWidgetKindName(kind: goop.widget.WidgetKind) []const u8 {
    return switch (kind) {
        .container => "container",
        .text => "text",
        .button => "button",
        .checkbox => "checkbox",
        .radio_button => "radio_button",
        .tree_item => "tree_item",
        .dropdown => "dropdown",
        .list_box => "list_box",
        .selectable => "selectable",
        .grid_selector => "grid_selector",
        .grid_item => "grid_item",
        .table => "table",
        .table_row => "table_row",
        .table_cell => "table_cell",
        .toolbar => "toolbar",
        .status_bar => "status_bar",
        .menu_bar => "menu_bar",
        .menu => "menu",
        .popup => "popup",
        .tooltip => "tooltip",
        .menu_item => "menu_item",
        .drag_value => "drag_value",
        .spinbox => "spinbox",
        .tab_bar => "tab_bar",
        .tab_item => "tab_item",
        .splitter => "splitter",
        .slider => "slider",
        .spacer => "spacer",
        .scroll_area => "scroll_area",
        .text_input => "text_input",
        .custom => "custom",
    };
}

pub fn entryNameTextRect(state: *const State, ctx: *const goop.Context, visible_index: usize, entry: BrowserEntry) ?goop.paint.Rect {
    if (visible_index >= state.view.assets.name_cell_handles.items.len) return null;
    const cell = state.view.assets.name_cell_handles.items[visible_index];
    if (!ctx.tree.isAlive(cell)) return null;

    const node = ctx.tree.getConst(cell);
    const resolved = node.style_override.resolve(ctx.theme);
    const rect = node.layout_rect;
    const x = rect.x + resolved.padding.left;
    const available_w = @max(rect.w - resolved.padding.left - resolved.padding.right, 0);
    const measured_w = goop.layout.measureTextDimensions(entry.name, ctx.theme.font_size, state.runtime.text_measure_ctx).width;
    return .{
        .x = x,
        .y = rect.y + resolved.padding.top,
        .w = @min(measured_w, available_w),
        .h = @max(rect.h - resolved.padding.top - resolved.padding.bottom, 0),
    };
}

pub fn pointInRect(x: f32, y: f32, rect: goop.paint.Rect) bool {
    return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h;
}

pub fn pointHitsEntryNameText(state: *const State, ctx: *const goop.Context, visible_index: usize, entry: BrowserEntry, x: f32, y: f32) bool {
    const rect = entryNameTextRect(state, ctx, visible_index, entry) orelse return false;
    return pointInRect(x, y, rect);
}

pub fn pointHitsVisibleAssetItem(state: *const State, ctx: *const goop.Context, x: f32, y: f32) bool {
    for (state.view.assets.row_handles.items) |handle| {
        if (!ctx.tree.isAlive(handle)) continue;
        if (pointInRect(x, y, ctx.tree.getConst(handle).layout_rect)) return true;
    }
    for (state.view.assets.grid_handles.items) |handle| {
        if (!ctx.tree.isAlive(handle)) continue;
        if (pointInRect(x, y, ctx.tree.getConst(handle).layout_rect)) return true;
    }
    return false;
}

pub fn pointInFilePanelBlankSpace(state: *const State, ctx: *const goop.Context, x: f32, y: f32) bool {
    const scroll_handle = state.view.chrome.file_panel_scroll orelse return false;
    if (!ctx.tree.isAlive(scroll_handle)) return false;
    const rect = ctx.tree.getConst(scroll_handle).layout_rect;
    if (!pointInRect(x, y, rect)) return false;

    const scrollbar_reserve = @max(ctx.theme.thumb_width, uiPx(state, 16));
    if (x >= rect.x + rect.w - scrollbar_reserve) return false;
    if (y >= rect.y + rect.h - scrollbar_reserve) return false;
    return !pointHitsVisibleAssetItem(state, ctx, x, y);
}

pub fn collectRowCellWidths(ctx: *const goop.Context, row_handle: ?goop.NodeHandle) [4]f32 {
    var widths: [4]f32 = .{ -1, -1, -1, -1 };
    const row = row_handle orelse return widths;
    if (!ctx.tree.isAlive(row)) return widths;

    var cell_index: usize = 0;
    var iter = ctx.tree.children(row);
    while (iter.next()) |child| {
        if (ctx.tree.getConst(child).kind != .table_cell) continue;
        if (cell_index >= widths.len) break;
        widths[cell_index] = ctx.tree.getConst(child).layout_rect.w;
        cell_index += 1;
    }
    return widths;
}

pub fn sameWidths(a: [4]f32, b: [4]f32) bool {
    for (a, b) |left, right| {
        if (@abs(left - right) > 0.01) return false;
    }
    return true;
}

pub fn debugLogFilePanelLayout(state: *State) void {
    if (!state.view.layout.scroll_debug_enabled and !state.view.layout.layout_debug_enabled) return;

    const ctx = state.runtime.ctx orelse return;
    const root_handle = state.view.chrome.ui_root orelse return;
    const scroll_handle = state.view.chrome.file_panel_scroll orelse return;
    if (!ctx.tree.isAlive(root_handle) or !ctx.tree.isAlive(scroll_handle)) return;

    const root_rect = ctx.tree.getConst(root_handle).layout_rect;
    const scroll_node = ctx.tree.getConst(scroll_handle);
    const scroll_y = scroll_node.kind.scroll_area.scroll_y;
    const scroll_state_unchanged = @abs(scroll_y - state.view.layout.scroll_debug_last_scroll_y) <= 0.01 and
        state.view.layout.scroll_debug_last_visible_start == state.view.assets.asset_visible_start and
        state.view.layout.scroll_debug_last_visible_end == state.view.assets.asset_visible_end;

    const scroll_rect = scroll_node.layout_rect;
    const body_handle = switch (state.model.view_mode) {
        .list => state.view.assets.asset_table_body,
        .grid => state.view.assets.asset_view_root,
    };
    const body_alive = if (body_handle) |handle| ctx.tree.isAlive(handle) else false;
    const body_y = if (body_alive) ctx.tree.getConst(body_handle.?).layout_rect.y else -1.0;
    const body_h = if (body_alive) ctx.tree.getConst(body_handle.?).layout_rect.h else -1.0;
    const first_row_alive = switch (state.model.view_mode) {
        .list => state.view.assets.row_handles.items.len > 0 and ctx.tree.isAlive(state.view.assets.row_handles.items[0]),
        .grid => state.view.assets.grid_handles.items.len > 0 and ctx.tree.isAlive(state.view.assets.grid_handles.items[0]),
    };
    const first_row_y = switch (state.model.view_mode) {
        .list => if (first_row_alive) ctx.tree.getConst(state.view.assets.row_handles.items[0]).layout_rect.y else -1.0,
        .grid => if (first_row_alive) ctx.tree.getConst(state.view.assets.grid_handles.items[0]).layout_rect.y else -1.0,
    };

    if (!scroll_state_unchanged) {
        state.view.layout.scroll_debug_last_scroll_y = scroll_y;
        state.view.layout.scroll_debug_last_visible_start = state.view.assets.asset_visible_start;
        state.view.layout.scroll_debug_last_visible_end = state.view.assets.asset_visible_end;

        scrollDebug(state, "layout mode={s} scroll={d:.2} scroll_rect=({d:.1},{d:.1},{d:.1},{d:.1}) body_alive={} body_y={d:.1} body_h={d:.1} first_row_y={d:.1} window=[{}..{})", .{
            browserViewModeLabel(state.model.view_mode),
            scroll_y,
            scroll_rect.x,
            scroll_rect.y,
            scroll_rect.w,
            scroll_rect.h,
            body_alive,
            body_y,
            body_h,
            first_row_y,
            state.view.assets.asset_visible_start,
            state.view.assets.asset_visible_end,
        });
        scrollDebug(state, "layout root logical={}x{} root_rect=({d:.1},{d:.1},{d:.1},{d:.1})", .{
            state.runtime.logical_width,
            state.runtime.logical_height,
            root_rect.x,
            root_rect.y,
            root_rect.w,
            root_rect.h,
        });
    }

    if (state.view.layout.layout_debug_enabled and state.model.view_mode == .list) {
        const header_table_handle = state.view.assets.asset_table;
        const body_table_handle = state.view.assets.asset_table_body;
        const header_alive = if (header_table_handle) |handle| ctx.tree.isAlive(handle) else false;
        const body_table_alive = if (body_table_handle) |handle| ctx.tree.isAlive(handle) else false;
        const header_rect = if (header_alive) ctx.tree.getConst(header_table_handle.?).layout_rect else goop.paint.Rect{ .x = -1, .y = -1, .w = -1, .h = -1 };
        const body_rect = if (body_table_alive) ctx.tree.getConst(body_table_handle.?).layout_rect else goop.paint.Rect{ .x = -1, .y = -1, .w = -1, .h = -1 };
        const header_row = if (header_alive) goop.widget.tableHeaderRow(&ctx.tree, header_table_handle.?) else null;
        const body_row = if (state.view.assets.row_handles.items.len > 0) state.view.assets.row_handles.items[0] else null;
        const header_widths = collectRowCellWidths(ctx, header_row);
        const body_widths = collectRowCellWidths(ctx, body_row);
        const focused_handle = ctx.frame().focused;
        const focused_index = if (focused_handle) |handle| handle.index else std.math.maxInt(u32);

        const layout_state_unchanged = focused_index == state.view.layout.layout_debug_last_focus_index and
            @abs(header_rect.x - state.view.layout.layout_debug_last_header_x) <= 0.01 and
            @abs(header_rect.w - state.view.layout.layout_debug_last_header_w) <= 0.01 and
            @abs(body_rect.x - state.view.layout.layout_debug_last_body_x) <= 0.01 and
            @abs(body_rect.w - state.view.layout.layout_debug_last_body_w) <= 0.01 and
            sameWidths(header_widths, state.view.layout.layout_debug_last_header_widths) and
            sameWidths(body_widths, state.view.layout.layout_debug_last_body_widths);

        if (!layout_state_unchanged) {
            state.view.layout.layout_debug_last_focus_index = focused_index;
            state.view.layout.layout_debug_last_header_x = header_rect.x;
            state.view.layout.layout_debug_last_header_w = header_rect.w;
            state.view.layout.layout_debug_last_body_x = body_rect.x;
            state.view.layout.layout_debug_last_body_w = body_rect.w;
            state.view.layout.layout_debug_last_header_widths = header_widths;
            state.view.layout.layout_debug_last_body_widths = body_widths;

            const focused_kind = if (focused_handle) |handle|
                debugWidgetKindName(ctx.tree.getConst(handle).kind)
            else
                "none";
            layoutDebug(state, "list columns focus={s}#{} header_rect=({d:.1},{d:.1}) body_rect=({d:.1},{d:.1}) weights=({d:.3},{d:.3},{d:.3},{d:.3}) header=({d:.1},{d:.1},{d:.1},{d:.1}) body=({d:.1},{d:.1},{d:.1},{d:.1})", .{
                focused_kind,
                focused_index,
                header_rect.x,
                header_rect.w,
                body_rect.x,
                body_rect.w,
                state.model.table_column_weights[0],
                state.model.table_column_weights[1],
                state.model.table_column_weights[2],
                state.model.table_column_weights[3],
                header_widths[0],
                header_widths[1],
                header_widths[2],
                header_widths[3],
                body_widths[0],
                body_widths[1],
                body_widths[2],
                body_widths[3],
            });
        }
    }
}

// ── Toolbar / menu builders ──

pub fn addToolbarButton(state: *const State, ctx: *goop.Context, parent: goop.NodeHandle, label: []const u8, active: bool, enabled: bool) !goop.NodeHandle {
    const handle = try ctx.tree.addChild(parent, .{ .button = .{ .label = label } });
    _ = ctx.setStyle(handle, fileManagerToolbarButtonStyle(state, active, enabled));
    return handle;
}

pub fn addToolbarCommandButton(state: *const State, ctx: *goop.Context, parent: goop.NodeHandle, label: []const u8, command: BrowserCommand) !goop.NodeHandle {
    return addToolbarButton(state, ctx, parent, label, browserCommandChecked(state, command), browserCommandEnabled(state, command));
}

pub fn addMenuCommandItem(
    state: *const State,
    ctx: *goop.Context,
    parent: goop.NodeHandle,
    label: []const u8,
    command: BrowserCommand,
    shortcut: []const u8,
) !goop.NodeHandle {
    const handle = try ctx.tree.addChild(parent, .{ .menu_item = .{
        .label = label,
        .shortcut = shortcut,
        .checked = browserCommandChecked(state, command),
        .disabled = !browserCommandEnabled(state, command),
    } });
    _ = ctx.setStyle(handle, fileManagerMenuItemStyle(state));
    return handle;
}

pub fn addContextMenuItem(
    state: *const State,
    ctx: *goop.Context,
    parent: goop.NodeHandle,
    label: []const u8,
    enabled: bool,
) !goop.NodeHandle {
    const handle = try ctx.tree.addChild(parent, .{ .menu_item = .{
        .label = label,
        .disabled = !enabled,
    } });
    _ = ctx.setStyle(handle, fileManagerMenuItemStyle(state));
    return handle;
}

pub fn buildContextPopup(state: *State, ctx: *goop.Context) !void {
    if (!state.interaction.context_visible) return;

    const popup = try ctx.tree.addRoot(.{ .popup = .{
        .placement = .absolute,
        .x = state.interaction.context_x,
        .y = state.interaction.context_y,
        .visible = true,
        .close_on_outside_click = true,
        .z_index = 140,
    } });
    state.view.context_menu.context_popup = popup;
    _ = ctx.setStyle(popup, fileManagerMenuPopupStyle(state));

    state.view.context_menu.context_open = try addContextMenuItem(state, ctx, popup, "Open", contextOpenEnabled(state));
    state.view.context_menu.context_copy = try addContextMenuItem(state, ctx, popup, "Copy", contextSelectionCommandEnabled(state));
    state.view.context_menu.context_cut = try addContextMenuItem(state, ctx, popup, "Cut", contextSelectionCommandEnabled(state));
    state.view.context_menu.context_paste = try addContextMenuItem(state, ctx, popup, "Paste", contextPasteEnabled(state));
    state.view.context_menu.context_delete = try addContextMenuItem(state, ctx, popup, "Delete", contextSelectionCommandEnabled(state));
    state.view.context_menu.context_rename = try addContextMenuItem(state, ctx, popup, "Rename", contextRenameEnabled(state));
    state.view.context_menu.context_move_parent = try addContextMenuItem(state, ctx, popup, "Move to Parent Directory", contextMoveParentEnabled(state));
    state.view.context_menu.context_copy_path = try addContextMenuItem(state, ctx, popup, "Copy Path", contextCopyPathEnabled(state));
    state.view.context_menu.context_open_link_target = try addContextMenuItem(state, ctx, popup, "Open Link Target", contextOpenLinkTargetEnabled(state));
}

// ── Folder tree (UI side) ──

pub fn folderTreeLabel(state: *State, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "/")) return "/";
    return allocUiUtf8Lossy(state, std.fs.path.basename(path));
}

pub fn addFolderTreeItem(
    state: *State,
    ctx: *goop.Context,
    parent: goop.NodeHandle,
    path: []const u8,
    label: []const u8,
    expanded: bool,
    selected: bool,
    has_children: bool,
) !goop.NodeHandle {
    const handle = try ctx.tree.addChild(parent, .{ .tree_item = .{
        .label = label,
        .group = 91,
        .icon = @intFromEnum(types.DemoIcon.folder),
        .icon_color = .rgb(74, 120, 201),
        .has_children = has_children,
        .expanded = expanded,
        .selected = selected,
    } });
    _ = ctx.setStyle(handle, fileManagerFolderTreeItemStyle(state));
    ctx.tree.setDropTarget(handle, true);
    ctx.tree.setUserId(handle, widgetUserId(.folder_tree, state.view.assets.folder_tree_paths.items.len));
    try state.view.assets.folder_tree_handles.append(allocator, handle);
    try state.view.assets.folder_tree_paths.append(allocator, try allocator.dupe(u8, path));
    return handle;
}

pub fn buildFolderTreeBranch(
    state: *State,
    ctx: *goop.Context,
    parent: goop.NodeHandle,
    dir_path: []const u8,
    parent_expansion: FolderTreeExpansion,
) !void {
    var children: std.ArrayListUnmanaged(FolderTreeChild) = .empty;
    defer {
        clearFolderTreeChildren(&children);
        children.deinit(allocator);
    }

    const io = state.runtime.io orelse return;
    try collectFolderTreeChildren(io, dir_path, &children);

    for (children.items, 0..) |child, index| {
        if (!shouldRenderFolderTreeChildForExpansion(state, parent_expansion, index, child.path)) continue;

        const selected = std.mem.eql(u8, child.path, state.model.current_dir);
        const expansion = folderTreeExpansion(state, child.path);
        const expanded = expansion != .collapsed;
        const has_children = folderTreeDirectoryHasChildren(io, child.path);
        const handle = try addFolderTreeItem(
            state,
            ctx,
            parent,
            child.path,
            try allocUiUtf8Lossy(state, child.name),
            expanded,
            selected,
            has_children,
        );
        if (expanded) try buildFolderTreeBranch(state, ctx, handle, child.path, expansion);
    }
}

pub fn buildFolderTree(state: *State, ctx: *goop.Context, parent: goop.NodeHandle) !void {
    const tree_root = try ctx.tree.addChild(parent, .{ .container = .{ .direction = .column } });
    _ = ctx.setStyle(tree_root, fileManagerFolderTreeStyle(state));

    const root_expansion = folderTreeExpansion(state, "/");
    const root = try addFolderTreeItem(
        state,
        ctx,
        tree_root,
        "/",
        try folderTreeLabel(state, "/"),
        root_expansion != .collapsed,
        std.mem.eql(u8, state.model.current_dir, "/"),
        if (state.runtime.io) |io| folderTreeDirectoryHasChildren(io, "/") else false,
    );
    if (root_expansion != .collapsed) try buildFolderTreeBranch(state, ctx, root, "/", root_expansion);
}

const BrowserSummary = struct {
    directory_count: usize = 0,
    file_count: usize = 0,
    selected_directory_count: usize = 0,
    selected_file_count: usize = 0,
    selected_file_bytes: u64 = 0,
    selected_count: usize = 0,
};

const InspectorPanels = struct {
    file_panel: goop.NodeHandle,
    preview_panel: ?goop.NodeHandle = null,
    detail_panel: ?goop.NodeHandle = null,
};

fn summarizeBrowser(state: *const State) BrowserSummary {
    var summary = BrowserSummary{ .selected_count = selectedPathCount(state) };
    for (state.model.entries.items) |entry| {
        if (entry.isDirectory()) {
            summary.directory_count += 1;
        } else {
            summary.file_count += 1;
        }

        if (!isPathSelected(state, entry.path)) continue;
        if (entry.isDirectory()) {
            summary.selected_directory_count += 1;
        } else {
            summary.selected_file_count += 1;
            summary.selected_file_bytes += entry.size_bytes;
        }
    }
    return summary;
}

fn buildTopMenu(state: *State, ctx: *goop.Context, root: goop.NodeHandle) !void {
    const menu_bar = try ctx.tree.addChild(root, .{ .menu_bar = .{} });
    _ = ctx.setStyle(menu_bar, fileManagerMenuBarStyle(state));

    state.view.menus.file.button = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "File" } });
    _ = ctx.setStyle(state.view.menus.file.button.?, fileManagerMenuStyle(state));
    var popup = try ctx.tree.addChild(state.view.menus.file.button.?, .{ .popup = .{ .placement = .below_start, .visible = false } });
    state.view.menus.file.popup = popup;
    _ = ctx.setStyle(popup, fileManagerMenuPopupStyle(state));
    state.view.menus.file.refresh = try addMenuCommandItem(state, ctx, popup, "Refresh", .refresh, "");
    state.view.menus.file.copy_path = try addMenuCommandItem(state, ctx, popup, "Copy Path", .copy_path, "");
    state.view.menus.file.open_target = try addMenuCommandItem(state, ctx, popup, "Open Link Target", .open_link_target, "");
    state.view.menus.file.quit = try addMenuCommandItem(state, ctx, popup, "Quit", .quit, "");

    state.view.menus.edit.button = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "Edit" } });
    _ = ctx.setStyle(state.view.menus.edit.button.?, fileManagerMenuStyle(state));
    popup = try ctx.tree.addChild(state.view.menus.edit.button.?, .{ .popup = .{ .placement = .below_start, .visible = false } });
    state.view.menus.edit.popup = popup;
    _ = ctx.setStyle(popup, fileManagerMenuPopupStyle(state));
    state.view.menus.edit.copy = try addMenuCommandItem(state, ctx, popup, "Copy", .copy, "Ctrl+C");
    state.view.menus.edit.cut = try addMenuCommandItem(state, ctx, popup, "Cut", .cut, "Ctrl+X");
    state.view.menus.edit.paste = try addMenuCommandItem(state, ctx, popup, "Paste", .paste, "Ctrl+V");
    state.view.menus.edit.delete = try addMenuCommandItem(state, ctx, popup, "Delete", .delete, "Del");
    state.view.menus.edit.rename = try addMenuCommandItem(state, ctx, popup, "Rename", .rename, "");
    state.view.menus.edit.move_parent = try addMenuCommandItem(state, ctx, popup, "Move to Parent Directory", .move_parent, "Ctrl+Shift+Up");
    state.view.menus.edit.select_all = try addMenuCommandItem(state, ctx, popup, "Select All", .select_all, "Ctrl+A");
    state.view.menus.edit.clear_selection = try addMenuCommandItem(state, ctx, popup, "Clear Selection", .clear_selection, "Esc");

    state.view.menus.view.button = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "View" } });
    _ = ctx.setStyle(state.view.menus.view.button.?, fileManagerMenuStyle(state));
    popup = try ctx.tree.addChild(state.view.menus.view.button.?, .{ .popup = .{ .placement = .below_start, .visible = false } });
    state.view.menus.view.popup = popup;
    _ = ctx.setStyle(popup, fileManagerMenuPopupStyle(state));
    state.view.menus.view.sidebar = try addMenuCommandItem(state, ctx, popup, "Sidebar", .toggle_sidebar, "");
    state.view.menus.view.preview = try addMenuCommandItem(state, ctx, popup, "Preview", .toggle_preview, "");
    state.view.menus.view.info = try addMenuCommandItem(state, ctx, popup, "Details", .toggle_info, "");
    state.view.menus.view.status_bar = try addMenuCommandItem(state, ctx, popup, "Status Bar", .toggle_status_bar, "");
    state.view.menus.view.list = try addMenuCommandItem(state, ctx, popup, "List View", .view_list, "");
    state.view.menus.view.grid = try addMenuCommandItem(state, ctx, popup, "Grid View", .view_grid, "");
    state.view.menus.view.sort_directories = try addMenuCommandItem(state, ctx, popup, "Sort Directories Together", .toggle_sort_directories, "");

    state.view.menus.go.button = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "Go" } });
    _ = ctx.setStyle(state.view.menus.go.button.?, fileManagerMenuStyle(state));
    popup = try ctx.tree.addChild(state.view.menus.go.button.?, .{ .popup = .{ .placement = .below_start, .visible = false } });
    state.view.menus.go.popup = popup;
    _ = ctx.setStyle(popup, fileManagerMenuPopupStyle(state));
    state.view.menus.go.back = try addMenuCommandItem(state, ctx, popup, "Back", .back, "");
    state.view.menus.go.forward = try addMenuCommandItem(state, ctx, popup, "Forward", .forward, "");
    state.view.menus.go.up = try addMenuCommandItem(state, ctx, popup, "Up", .up, "");
    state.view.menus.go.home = try addMenuCommandItem(state, ctx, popup, "Home", .home, "");

    state.view.menus.help.button = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "Help" } });
    _ = ctx.setStyle(state.view.menus.help.button.?, fileManagerMenuStyle(state));
    popup = try ctx.tree.addChild(state.view.menus.help.button.?, .{ .popup = .{ .placement = .below_start, .visible = false } });
    state.view.menus.help.popup = popup;
    _ = ctx.setStyle(popup, fileManagerMenuPopupStyle(state));
    state.view.menus.help.about = try addMenuCommandItem(state, ctx, popup, "About goop files", .about, "");
}

fn buildToolbar(state: *State, ctx: *goop.Context, root: goop.NodeHandle) !void {
    const toolbar = try ctx.tree.addChild(root, .{ .toolbar = .{} });
    _ = ctx.setStyle(toolbar, fileManagerToolbarStyle(state));
    state.view.chrome.btn_back = try addToolbarCommandButton(state, ctx, toolbar, "Back", .back);
    state.view.chrome.btn_forward = try addToolbarCommandButton(state, ctx, toolbar, "Forward", .forward);
    state.view.chrome.btn_up = try addToolbarCommandButton(state, ctx, toolbar, "Up", .up);
    ctx.tree.setUserId(state.view.chrome.btn_up.?, widgetUserId(.toolbar_up, 0));
    if (browserCommandEnabled(state, .up)) ctx.tree.setDropTarget(state.view.chrome.btn_up.?, true);
    state.view.chrome.btn_home = try addToolbarCommandButton(state, ctx, toolbar, "Home", .home);
    state.view.chrome.btn_refresh = try addToolbarCommandButton(state, ctx, toolbar, "Refresh", .refresh);
    _ = try ctx.tree.addChild(toolbar, .{ .spacer = .{ .width = uiPx(state, 6) } });
    state.view.chrome.btn_toggle_sidebar = try addToolbarCommandButton(state, ctx, toolbar, "Sidebar", .toggle_sidebar);
    state.view.chrome.btn_toggle_preview = try addToolbarCommandButton(state, ctx, toolbar, "Preview", .toggle_preview);
    state.view.chrome.btn_toggle_info = try addToolbarCommandButton(state, ctx, toolbar, "Details", .toggle_info);
    _ = try ctx.tree.addChild(toolbar, .{ .spacer = .{ .width = uiPx(state, 8) } });
    state.view.chrome.address_input_handle = try ctx.tree.addChild(toolbar, .{ .text_input = .{ .placeholder = state.view.address_input.placeholder } });
    if (ctx.mutateKind(state.view.chrome.address_input_handle.?)) |kind| {
        kind.text_input = state.view.address_input;
    }
    _ = ctx.setStyle(state.view.chrome.address_input_handle.?, fileManagerTextInputStyle(state));
    state.view.chrome.btn_address_go = try addToolbarButton(state, ctx, toolbar, "Go", false, true);
    _ = try ctx.tree.addChild(toolbar, .{ .spacer = .{ .width = uiPx(state, 8) } });
    state.view.chrome.btn_list_view = try addToolbarCommandButton(state, ctx, toolbar, "List", .view_list);
    state.view.chrome.btn_grid_view = try addToolbarCommandButton(state, ctx, toolbar, "Grid", .view_grid);
}

fn buildContentHost(state: *State, ctx: *goop.Context, root: goop.NodeHandle, transparent: goop.Color) !goop.NodeHandle {
    if (!state.model.show_sidebar) {
        const content_host = try ctx.tree.addChild(root, .{ .container = .{ .direction = .column } });
        _ = ctx.setStyle(content_host, fileManagerPaneStyle(state, transparent));
        return content_host;
    }

    state.view.chrome.nav_splitter = try ctx.tree.addChild(root, .{ .splitter = .{
        .direction = .row,
        .ratio = state.model.nav_ratio,
        .min_first = uiPx(state, 220),
        .min_second = uiPx(state, 420),
        .thickness = uiPx(state, 8),
        .gap_thickness = 1,
    } });
    _ = ctx.setStyle(state.view.chrome.nav_splitter.?, fileManagerGutterStyle(state));

    const sidebar = try ctx.tree.addChild(state.view.chrome.nav_splitter.?, .{ .container = .{ .direction = .column } });
    _ = ctx.setStyle(sidebar, fileManagerPaneStyle(state, fileManagerSidebarColor()));
    const sidebar_header = try ctx.tree.addChild(sidebar, .{ .toolbar = .{} });
    _ = ctx.setStyle(sidebar_header, fileManagerPaneHeaderStyle(state));
    _ = try ctx.tree.addChild(sidebar_header, .{ .text = .{ .content = "Browse" } });

    const sidebar_scroll = try ctx.tree.addChild(sidebar, .{ .scroll_area = .{
        .scroll_x = state.model.sidebar_scroll_x,
        .scroll_y = state.model.sidebar_scroll_y,
    } });
    state.view.chrome.sidebar_scroll = sidebar_scroll;
    _ = ctx.setStyle(sidebar_scroll, .{
        .bg = transparent,
        .border_width = 0,
        .padding = uiEdgesSymmetric(state, 12, 12),
        .border_radius = 0,
    });
    const sidebar_content = try ctx.tree.addChild(sidebar_scroll, .{ .container = .{ .direction = .column } });
    _ = ctx.setStyle(sidebar_content, .{
        .bg = transparent,
        .border_width = 0,
        .padding = uiEdgesAll(state, 0),
        .spacing = uiPx(state, 14),
        .border_radius = 0,
    });

    const places_label = try ctx.tree.addChild(sidebar_content, .{ .text = .{ .content = "Places" } });
    _ = ctx.setStyle(places_label, fileManagerSectionLabelStyle(state));
    const places_list = try ctx.tree.addChild(sidebar_content, .{ .list_box = .{ .selection_mode = .single } });
    for (state.model.places.items, 0..) |place, place_index| {
        const handle = try ctx.tree.addChild(places_list, .{ .selectable = .{
            .label = place.label,
            .selected = std.mem.eql(u8, place.path, state.model.current_dir),
        } });
        _ = ctx.setStyle(handle, fileManagerPlaceItemStyle(state));
        ctx.tree.setDropTarget(handle, true);
        ctx.tree.setUserId(handle, widgetUserId(.place, place_index));
        try state.view.assets.place_handles.append(allocator, handle);
    }

    const folders_label = try ctx.tree.addChild(sidebar_content, .{ .text = .{ .content = "Folders" } });
    _ = ctx.setStyle(folders_label, fileManagerSectionLabelStyle(state));
    try buildFolderTree(state, ctx, sidebar_content);

    const content_host = try ctx.tree.addChild(state.view.chrome.nav_splitter.?, .{ .container = .{ .direction = .column } });
    _ = ctx.setStyle(content_host, fileManagerPaneStyle(state, transparent));
    return content_host;
}

fn buildInspectorPanels(state: *State, ctx: *goop.Context, content_host: goop.NodeHandle) !InspectorPanels {
    if (!state.model.show_preview and !state.model.show_info) {
        const file_panel = try ctx.tree.addChild(content_host, .{ .container = .{ .direction = .column } });
        _ = ctx.setStyle(file_panel, fileManagerPaneStyle(state, fileManagerSurfaceColor()));
        return .{ .file_panel = file_panel };
    }

    state.view.chrome.detail_splitter = try ctx.tree.addChild(content_host, .{ .splitter = .{
        .direction = .row,
        .ratio = state.model.detail_ratio,
        .min_first = uiPx(state, 360),
        .min_second = uiPx(state, 300),
        .thickness = uiPx(state, 8),
        .gap_thickness = 1,
    } });
    _ = ctx.setStyle(state.view.chrome.detail_splitter.?, fileManagerGutterStyle(state));

    const file_panel = try ctx.tree.addChild(state.view.chrome.detail_splitter.?, .{ .container = .{ .direction = .column } });
    _ = ctx.setStyle(file_panel, fileManagerPaneStyle(state, fileManagerSurfaceColor()));
    const inspector_host = try ctx.tree.addChild(state.view.chrome.detail_splitter.?, .{ .container = .{ .direction = .column } });
    _ = ctx.setStyle(inspector_host, fileManagerPaneStyle(state, fileManagerSidebarColor()));

    if (state.model.show_preview and state.model.show_info) {
        state.view.chrome.preview_splitter = try ctx.tree.addChild(inspector_host, .{ .splitter = .{
            .direction = .column,
            .ratio = state.model.preview_ratio,
            .min_first = uiPx(state, 180),
            .min_second = uiPx(state, 180),
            .thickness = uiPx(state, 8),
            .gap_thickness = 1,
        } });
        _ = ctx.setStyle(state.view.chrome.preview_splitter.?, fileManagerGutterStyle(state));
        const preview_panel = try ctx.tree.addChild(state.view.chrome.preview_splitter.?, .{ .container = .{ .direction = .column } });
        _ = ctx.setStyle(preview_panel, fileManagerPaneStyle(state, fileManagerSidebarColor()));
        const detail_panel = try ctx.tree.addChild(state.view.chrome.preview_splitter.?, .{ .container = .{ .direction = .column } });
        _ = ctx.setStyle(detail_panel, fileManagerPaneStyle(state, fileManagerSidebarColor()));
        return .{ .file_panel = file_panel, .preview_panel = preview_panel, .detail_panel = detail_panel };
    }

    return .{
        .file_panel = file_panel,
        .preview_panel = if (state.model.show_preview) inspector_host else null,
        .detail_panel = if (state.model.show_info) inspector_host else null,
    };
}

fn buildBreadcrumbBar(state: *State, ctx: *goop.Context, file_panel: goop.NodeHandle) !void {
    const breadcrumb_bar = try ctx.tree.addChild(file_panel, .{ .toolbar = .{} });
    _ = ctx.setStyle(breadcrumb_bar, fileManagerPaneHeaderStyle(state));
    const root_button = try ctx.tree.addChild(breadcrumb_bar, .{ .button = .{ .label = "/" } });
    _ = ctx.setStyle(root_button, fileManagerToolbarButtonStyle(state, false, true));
    ctx.tree.setDropTarget(root_button, true);
    ctx.tree.setUserId(root_button, widgetUserId(.breadcrumb, state.view.assets.breadcrumb_paths.items.len));
    try state.view.assets.breadcrumb_handles.append(allocator, root_button);
    try state.view.assets.breadcrumb_paths.append(allocator, try allocator.dupe(u8, "/"));
    if (std.mem.eql(u8, state.model.current_dir, "/")) return;

    var start: usize = 1;
    while (start < state.model.current_dir.len) {
        const end = std.mem.indexOfScalarPos(u8, state.model.current_dir, start, '/') orelse state.model.current_dir.len;
        _ = try ctx.tree.addChild(breadcrumb_bar, .{ .text = .{ .content = "/" } });
        const segment = state.model.current_dir[start..end];
        const handle = try ctx.tree.addChild(breadcrumb_bar, .{ .button = .{ .label = try allocUiUtf8Lossy(state, segment) } });
        _ = ctx.setStyle(handle, fileManagerToolbarButtonStyle(state, false, true));
        ctx.tree.setDropTarget(handle, true);
        ctx.tree.setUserId(handle, widgetUserId(.breadcrumb, state.view.assets.breadcrumb_paths.items.len));
        try state.view.assets.breadcrumb_handles.append(allocator, handle);
        try state.view.assets.breadcrumb_paths.append(allocator, try allocator.dupe(u8, state.model.current_dir[0..end]));
        start = end + 1;
    }
}

fn buildPreviewPanel(state: *State, ctx: *goop.Context, panel: goop.NodeHandle, transparent: goop.Color) !void {
    const preview_header = try ctx.tree.addChild(panel, .{ .toolbar = .{} });
    _ = ctx.setStyle(preview_header, fileManagerPaneHeaderStyle(state));
    _ = try ctx.tree.addChild(preview_header, .{ .text = .{ .content = "Preview" } });

    const preview_scroll = try ctx.tree.addChild(panel, .{ .scroll_area = .{ .disable_horizontal_scroll = true } });
    _ = ctx.setStyle(preview_scroll, .{
        .bg = transparent,
        .border_width = 0,
        .padding = uiEdgesSymmetric(state, 12, 12),
        .border_radius = 0,
    });
    const preview_content = try ctx.tree.addChild(preview_scroll, .{ .container = .{ .direction = .column } });
    _ = ctx.setStyle(preview_content, fileManagerDetailContentStyle(state));
    const selection_preview = try allocSelectionPreview(state);
    const preview_text_parent = if (selection_preview.framed) blk: {
        const preview_frame = try ctx.tree.addChild(preview_content, .{ .container = .{ .direction = .column } });
        _ = ctx.setStyle(preview_frame, fileManagerPreviewFrameStyle(state));
        break :blk preview_frame;
    } else preview_content;
    _ = try addStyledDetailText(
        ctx,
        preview_text_parent,
        selection_preview.text,
        .wrap,
        fileManagerPreviewBodyStyle(state),
    );
}

fn addSingleSelectionDetails(state: *State, ctx: *goop.Context, detail_content: goop.NodeHandle) !void {
    const entry = selectedEntry(state).?;
    const modified_text = try allocFormattedTimestampDetail(state, entry.modified_unix);
    const size_text = try allocFormattedSize(state, entry.kind, entry.size_bytes, entry.target_kind);
    const meta_text = if (size_text.len > 0)
        try allocUiString(state, "{s} · {s} · {s}", .{
            entry.typeLabel(),
            size_text,
            modified_text,
        })
    else
        try allocUiString(state, "{s} · {s}", .{
            entry.typeLabel(),
            modified_text,
        });
    _ = try addStyledDetailText(
        ctx,
        detail_content,
        try allocUiDetailWrappedUtf8Lossy(state, entry.name, detailTitleFontSizePx(state)),
        .wrap,
        fileManagerDetailTitleStyle(state),
    );
    _ = try addStyledDetailText(ctx, detail_content, meta_text, .wrap, fileManagerDetailMetaStyle(state));

    const path_line = try std.fmt.allocPrint(allocator, "Path: {f}", .{std.unicode.fmtUtf8(entry.path)});
    defer allocator.free(path_line);
    _ = try addStyledDetailText(
        ctx,
        detail_content,
        try allocUiDetailWrappedUtf8Lossy(state, path_line, detailCaptionFontSizePx(state)),
        .wrap,
        fileManagerDetailMetaStyle(state),
    );
    if (entry.target_path) |target_path| {
        const target_line = try std.fmt.allocPrint(allocator, "Target: {f}", .{std.unicode.fmtUtf8(target_path)});
        defer allocator.free(target_line);
        _ = try addStyledDetailText(
            ctx,
            detail_content,
            try allocUiDetailWrappedUtf8Lossy(state, target_line, detailCaptionFontSizePx(state)),
            .wrap,
            fileManagerDetailMetaStyle(state),
        );
    }
    _ = try addStyledDetailText(
        ctx,
        detail_content,
        if (entry.canEnter())
            "Double-click to enter this folder."
        else if (entry.kind == .symlink)
            "Use Go or Open Link Target to follow this symbolic link."
        else
            "Text files preview inline here; other file types show a summary.",
        .wrap,
        fileManagerDetailHintStyle(state),
    );
}

fn addMultiSelectionDetails(state: *State, ctx: *goop.Context, detail_content: goop.NodeHandle, summary: BrowserSummary) !void {
    const selected_size_text = try allocFormattedSize(state, .file, summary.selected_file_bytes, null);
    _ = try addStyledDetailText(
        ctx,
        detail_content,
        try allocUiString(state, "{d} items selected", .{summary.selected_count}),
        .wrap,
        fileManagerDetailTitleStyle(state),
    );
    const summary_text = if (summary.selected_file_count > 0)
        try allocUiString(state, "{d} directories · {d} files · {s}", .{
            summary.selected_directory_count,
            summary.selected_file_count,
            selected_size_text,
        })
    else
        try allocUiString(state, "{d} directories · {d} files", .{
            summary.selected_directory_count,
            summary.selected_file_count,
        });
    _ = try addStyledDetailText(ctx, detail_content, summary_text, .wrap, fileManagerDetailMetaStyle(state));

    if (state.model.selected_path) |selected_path| {
        const active_line = try std.fmt.allocPrint(allocator, "Active: {f}", .{
            std.unicode.fmtUtf8(std.fs.path.basename(selected_path)),
        });
        defer allocator.free(active_line);
        _ = try addStyledDetailText(
            ctx,
            detail_content,
            try allocUiDetailWrappedUtf8Lossy(state, active_line, detailCaptionFontSizePx(state)),
            .wrap,
            fileManagerDetailMetaStyle(state),
        );
    }

    _ = try addStyledDetailText(
        ctx,
        detail_content,
        "Ctrl-click and Shift-click extend the current selection.",
        .wrap,
        fileManagerDetailHintStyle(state),
    );
}

fn addDirectoryDetails(state: *State, ctx: *goop.Context, detail_content: goop.NodeHandle, summary: BrowserSummary) !void {
    const directory_name = if (std.mem.eql(u8, state.model.current_dir, "/")) "/" else std.fs.path.basename(state.model.current_dir);
    _ = try addStyledDetailText(
        ctx,
        detail_content,
        try allocUiDetailWrappedUtf8Lossy(state, directory_name, detailTitleFontSizePx(state)),
        .wrap,
        fileManagerDetailTitleStyle(state),
    );
    _ = try addStyledDetailText(
        ctx,
        detail_content,
        try allocUiString(state, "{d} items · {d} directories · {d} files", .{
            state.model.entries.items.len,
            summary.directory_count,
            summary.file_count,
        }),
        .wrap,
        fileManagerDetailMetaStyle(state),
    );
    _ = try addStyledDetailText(
        ctx,
        detail_content,
        try allocUiString(state, "Sort: {s}, {s}{s} · View: {s}", .{
            sortColumnLabel(state.model.sort_column),
            sortDirectionLabel(state.model.sort_direction),
            if (state.model.sort_directories_together) ", directories together" else "",
            browserViewModeLabel(state.model.view_mode),
        }),
        .wrap,
        fileManagerDetailMetaStyle(state),
    );
    const current_path_line = try std.fmt.allocPrint(allocator, "Path: {f}", .{std.unicode.fmtUtf8(state.model.current_dir)});
    defer allocator.free(current_path_line);
    _ = try addStyledDetailText(
        ctx,
        detail_content,
        try allocUiDetailWrappedUtf8Lossy(state, current_path_line, detailCaptionFontSizePx(state)),
        .wrap,
        fileManagerDetailMetaStyle(state),
    );
    _ = try addStyledDetailText(
        ctx,
        detail_content,
        "Select a file to inspect it, or use Preview to skim folders and text files inline.",
        .wrap,
        fileManagerDetailHintStyle(state),
    );
}

fn buildDetailPanel(state: *State, ctx: *goop.Context, panel: goop.NodeHandle, transparent: goop.Color, summary: BrowserSummary) !void {
    const detail_header = try ctx.tree.addChild(panel, .{ .toolbar = .{} });
    _ = ctx.setStyle(detail_header, fileManagerPaneHeaderStyle(state));
    _ = try ctx.tree.addChild(detail_header, .{ .text = .{ .content = "Details" } });
    const detail_scroll = try ctx.tree.addChild(panel, .{ .scroll_area = .{ .disable_horizontal_scroll = true } });
    _ = ctx.setStyle(detail_scroll, .{
        .bg = transparent,
        .border_width = 0,
        .padding = uiEdgesSymmetric(state, 12, 12),
        .border_radius = 0,
    });
    const detail_content = try ctx.tree.addChild(detail_scroll, .{ .container = .{ .direction = .column } });
    _ = ctx.setStyle(detail_content, fileManagerDetailContentStyle(state));

    if (summary.selected_count == 1 and selectedEntry(state) != null) {
        try addSingleSelectionDetails(state, ctx, detail_content);
    } else if (summary.selected_count > 1) {
        try addMultiSelectionDetails(state, ctx, detail_content, summary);
    } else {
        try addDirectoryDetails(state, ctx, detail_content, summary);
    }
}

fn buildStatusBar(state: *State, ctx: *goop.Context, root: goop.NodeHandle, summary: BrowserSummary) !void {
    if (!state.model.show_status_bar) return;

    const status_bar = try ctx.tree.addChild(root, .{ .status_bar = .{} });
    _ = ctx.setStyle(status_bar, fileManagerToolbarStyle(state));
    if (state.interaction.status_note) |note| {
        const handle = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = note } });
        _ = ctx.setStyle(handle, fileManagerStatusTextStyle(state));
    }
    {
        const handle = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "{d} items", .{state.model.entries.items.len}) } });
        _ = ctx.setStyle(handle, fileManagerStatusTextStyle(state));
    }
    {
        const handle = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "{d} selected", .{summary.selected_count}) } });
        _ = ctx.setStyle(handle, fileManagerStatusTextStyle(state));
    }
    {
        const handle = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "View: {s}", .{browserViewModeLabel(state.model.view_mode)}) } });
        _ = ctx.setStyle(handle, fileManagerStatusTextStyle(state));
    }
    {
        const handle = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "Path: {f}", .{std.unicode.fmtUtf8(state.model.current_dir)}) } });
        _ = ctx.setStyle(handle, fileManagerStatusTextStyle(state));
    }
}

// -- Widget tree composition --

pub fn buildWidgetTree(state: *State) !void {
    const ctx = state.runtime.ctx orelse return error.NoContext;
    const transparent = goop.Color.rgba(0, 0, 0, 0);

    captureFilePanelViewport(state, ctx);
    captureSidebarScroll(state, ctx);
    if (state.view.chrome.ui_root) |root| {
        if (ctx.tree.isAlive(root)) try ctx.tree.remove(root);
    }
    if (state.view.context_menu.context_popup) |popup| {
        if (ctx.tree.isAlive(popup)) try ctx.tree.remove(popup);
    }
    clearUiTracking(state);

    state.view.chrome.ui_root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const root = state.view.chrome.ui_root.?;
    _ = ctx.setStyle(root, fileManagerShellStyle(state));

    const summary = summarizeBrowser(state);
    try buildTopMenu(state, ctx, root);
    try buildToolbar(state, ctx, root);

    const content_host = try buildContentHost(state, ctx, root, transparent);
    const panels = try buildInspectorPanels(state, ctx, content_host);

    try buildBreadcrumbBar(state, ctx, panels.file_panel);
    if (state.model.view_mode == .list) {
        try buildListHeaderTable(state, ctx, panels.file_panel);
    }

    state.view.chrome.file_panel_scroll = try ctx.tree.addChild(panels.file_panel, .{ .scroll_area = .{ .scroll_y = state.model.file_panel_scroll_y } });
    _ = ctx.setStyle(state.view.chrome.file_panel_scroll.?, .{
        .bg = transparent,
        .border_width = 0,
        .padding = uiEdgesAll(state, 0),
        .border_radius = 0,
    });
    try buildAssetView(state, ctx, state.view.chrome.file_panel_scroll.?);

    if (panels.preview_panel) |panel| {
        try buildPreviewPanel(state, ctx, panel, transparent);
    }
    if (panels.detail_panel) |panel| {
        try buildDetailPanel(state, ctx, panel, transparent, summary);
    }
    try buildStatusBar(state, ctx, root, summary);
    try buildContextPopup(state, ctx);
}
