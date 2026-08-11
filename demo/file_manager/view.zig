const std = @import("std");
const goop = @import("goop");
const desktop = @import("goop_desktop");

const state_module = @import("state.zig");
const capabilities = @import("capabilities.zig");
const types = @import("types.zig");
const ids = @import("ids.zig");
const ViewDomain = struct {
    model: *const state_module.Model,
    interaction: *const state_module.Interaction,
    presentation: *const state_module.Presentation,
};
const Scope = struct {
    viewport: *const state_module.Viewport,
    domain: ViewDomain,
    projection: *state_module.View,
    identities: *ids.Registry,
};
const allocator = std.heap.smp_allocator;

const style = @import("style.zig");
const format = @import("format.zig");
const model_ops = @import("model.zig");
const presentation = @import("presentation.zig");
const projection = @import("projection.zig");
const virtualization = @import("virtualization.zig");
const detail_text = @import("detail_text.zig");

// ── Type aliases ──
const BrowserEntry = types.BrowserEntry;
const BrowserEntryKind = types.BrowserEntryKind;
const BrowserPlace = types.BrowserPlace;
const BrowserSortColumn = types.BrowserSortColumn;
const BrowserSortDirection = types.BrowserSortDirection;
const BrowserViewMode = types.BrowserViewMode;
const BrowserCommand = types.BrowserCommand;
const ListVirtualWindow = types.ListVirtualWindow;
const GridVirtualWindow = types.GridVirtualWindow;

// ── Constants from fm ──
const browser_table_divider_width = types.browser_table_divider_width;
const browser_name_icon_inset_left = types.browser_name_icon_inset_left;
const browser_name_text_inset_left = types.browser_name_text_inset_left;
const browser_grid_item_width = types.browser_grid_item_width;
const browser_grid_item_height = types.browser_grid_item_height;
const browser_grid_column_gap = types.browser_grid_column_gap;
const browser_grid_row_gap = types.browser_grid_row_gap;
const browser_grid_padding_h = types.browser_grid_padding_h;
const folder_tree_max_visible_children = types.folder_tree_max_visible_children;

// ── Scale-only visual style adapters ──
fn uiPx(s: *const Scope, value: f32) f32 {
    return style.uiPx(s.viewport.ui_scale, value);
}
fn uiEdgesAll(s: *const Scope, value: f32) goop.style.Edges {
    return style.uiEdgesAll(s.viewport.ui_scale, value);
}
fn uiEdgesSymmetric(s: *const Scope, h: f32, v: f32) goop.style.Edges {
    return style.uiEdgesSymmetric(s.viewport.ui_scale, h, v);
}
fn fileManagerToolbarButtonStyle(s: *const Scope, active: bool, enabled: bool) goop.Style {
    return style.fileManagerToolbarButtonStyle(s.viewport.ui_scale, active, enabled);
}
fn fileManagerTextInputStyle(s: *const Scope) goop.Style {
    return style.fileManagerTextInputStyle(s.viewport.ui_scale);
}
fn fileManagerRenameInputStyle(s: *const Scope) goop.Style {
    return style.fileManagerRenameInputStyle(s.viewport.ui_scale);
}
fn fileManagerMenuBarStyle(s: *const Scope) goop.Style {
    return style.fileManagerMenuBarStyle(s.viewport.ui_scale);
}
fn fileManagerMenuStyle(s: *const Scope) goop.Style {
    return style.fileManagerMenuStyle(s.viewport.ui_scale);
}
fn fileManagerMenuPopupStyle(s: *const Scope) goop.Style {
    return style.fileManagerMenuPopupStyle(s.viewport.ui_scale);
}
fn fileManagerMenuItemStyle(s: *const Scope) goop.Style {
    return style.fileManagerMenuItemStyle(s.viewport.ui_scale);
}
fn fileManagerSectionLabelStyle(s: *const Scope) goop.Style {
    return style.fileManagerSectionLabelStyle(s.viewport.ui_scale);
}
fn fileManagerFolderTreeStyle(s: *const Scope) goop.Style {
    return style.fileManagerFolderTreeStyle(s.viewport.ui_scale);
}
fn fileManagerFolderTreeItemStyle(s: *const Scope) goop.Style {
    return style.fileManagerFolderTreeItemStyle(s.viewport.ui_scale);
}
fn fileManagerPlaceItemStyle(s: *const Scope) goop.Style {
    return style.fileManagerPlaceItemStyle(s.viewport.ui_scale);
}
fn fileManagerStatusTextStyle(s: *const Scope) goop.Style {
    return style.fileManagerStatusTextStyle(s.viewport.ui_scale);
}
fn fileManagerShellStyle(s: *const Scope) goop.Style {
    return style.fileManagerShellStyle(s.viewport.ui_scale);
}
fn fileManagerToolbarStyle(s: *const Scope) goop.Style {
    return style.fileManagerToolbarStyle(s.viewport.ui_scale);
}
fn fileManagerPaneStyle(s: *const Scope, bg: goop.Color) goop.Style {
    return style.fileManagerPaneStyle(s.viewport.ui_scale, bg);
}
fn fileManagerPaneHeaderStyle(s: *const Scope) goop.Style {
    return style.fileManagerPaneHeaderStyle(s.viewport.ui_scale);
}
fn fileManagerDetailContentStyle(s: *const Scope) goop.Style {
    return style.fileManagerDetailContentStyle(s.viewport.ui_scale);
}
fn fileManagerPreviewFrameStyle(s: *const Scope) goop.Style {
    return style.fileManagerPreviewFrameStyle(s.viewport.ui_scale);
}
fn fileManagerDetailTitleStyle(s: *const Scope) goop.Style {
    return style.fileManagerDetailTitleStyle(s.viewport.ui_scale);
}
fn fileManagerDetailMetaStyle(s: *const Scope) goop.Style {
    return style.fileManagerDetailMetaStyle(s.viewport.ui_scale);
}
fn fileManagerDetailHintStyle(s: *const Scope) goop.Style {
    return style.fileManagerDetailHintStyle(s.viewport.ui_scale);
}
fn fileManagerPreviewBodyStyle(s: *const Scope) goop.Style {
    return style.fileManagerPreviewBodyStyle(s.viewport.ui_scale);
}
fn fileManagerGutterStyle(s: *const Scope) goop.Style {
    return style.fileManagerGutterStyle(s.viewport.ui_scale);
}
const fileManagerSidebarColor = style.fileManagerSidebarColor;
const fileManagerSurfaceColor = style.fileManagerSurfaceColor;

fn presentationInput(s: *const Scope) presentation.Input {
    return .{
        .model = s.domain.model,
        .interaction = s.domain.interaction,
        .home_available = s.domain.presentation.home_available,
        .file_clipboard_available = s.domain.presentation.file_clipboard_available,
    };
}
fn isPathSelected(s: *const Scope, path: []const u8) bool {
    return model_ops.isPathSelected(s.domain.model, path);
}
fn selectedPathCount(s: *const Scope) usize {
    return model_ops.selectedPathCount(s.domain.model);
}
fn selectedEntry(s: *const Scope) ?*const BrowserEntry {
    return model_ops.selectedEntry(s.domain.model);
}
fn isRenamingPath(s: *const Scope, path: []const u8) bool {
    return presentation.isRenamingPath(presentationInput(s), path);
}
fn browserCommandChecked(s: *const Scope, command: BrowserCommand) bool {
    return presentation.browserCommandChecked(presentationInput(s), command);
}
fn browserCommandEnabled(s: *const Scope, command: BrowserCommand) bool {
    return presentation.browserCommandEnabled(presentationInput(s), command);
}
fn contextOpenEnabled(s: *const Scope) bool {
    return presentation.contextOpenEnabled(presentationInput(s));
}
fn contextCopyPathEnabled(s: *const Scope) bool {
    return presentation.contextCopyPathEnabled(presentationInput(s));
}
fn contextOpenLinkTargetEnabled(s: *const Scope) bool {
    return presentation.contextOpenLinkTargetEnabled(presentationInput(s));
}
fn contextSelectionCommandEnabled(s: *const Scope) bool {
    return presentation.contextSelectionCommandEnabled(presentationInput(s));
}
fn contextRenameEnabled(s: *const Scope) bool {
    return presentation.contextRenameEnabled(presentationInput(s));
}
fn contextMoveParentEnabled(s: *const Scope) bool {
    return presentation.contextMoveParentEnabled(presentationInput(s));
}
fn contextPasteEnabled(s: *const Scope) bool {
    return presentation.contextPasteEnabled(presentationInput(s));
}
const browserViewModeLabel = presentation.browserViewModeLabel;
const sortColumnLabel = format.sortColumnLabel;
const sortDirectionLabel = format.sortDirectionLabel;

// allocation/string helpers
const allocUtf8LossyOwned = projection.allocUtf8LossyOwned;

fn allocUiString(state: *Scope, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return projection.allocUiString(state.projection, fmt, args);
}

fn allocAssetUiString(state: *Scope, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return projection.allocAssetUiString(state.projection, fmt, args);
}

fn allocAssetEntryNameText(state: *Scope, entry: BrowserEntry) ![]const u8 {
    return allocAssetUiString(state, "{f}", .{std.unicode.fmtUtf8(entry.name)});
}

fn allocAssetFormattedTimestamp(state: *Scope, unix_seconds: i64) ![]const u8 {
    var buf: [40]u8 = undefined;
    const text = format.formatTimestampCompactText(buf[0..], unix_seconds, state.domain.presentation.now_unix_seconds);
    return allocAssetUiString(state, "{s}", .{text});
}

fn allocFormattedTimestampDetail(state: *Scope, unix_seconds: i64) ![]const u8 {
    var buf: [48]u8 = undefined;
    return allocUiString(state, "{s}", .{format.formatTimestampDetailText(buf[0..], unix_seconds)});
}

fn allocFormattedSize(state: *Scope, kind: BrowserEntryKind, size_bytes: u64, target_kind: ?BrowserEntryKind) ![]const u8 {
    var buf: [24]u8 = undefined;
    return allocUiString(state, "{s}", .{format.formatSizeText(buf[0..], kind, size_bytes, target_kind)});
}

fn allocAssetFormattedSize(state: *Scope, kind: BrowserEntryKind, size_bytes: u64, target_kind: ?BrowserEntryKind) ![]const u8 {
    var buf: [24]u8 = undefined;
    return allocAssetUiString(state, "{s}", .{format.formatSizeText(buf[0..], kind, size_bytes, target_kind)});
}

fn allocAssetUiEllipsizedUtf8Lossy(state: *Scope, bytes: []const u8, max_width: f32, font_size: f32) ![]const u8 {
    return projection.allocAssetUiEllipsizedUtf8Lossy(state.projection, bytes, max_width, font_size);
}

fn allocUiUtf8Lossy(state: *Scope, bytes: []const u8) ![]const u8 {
    return projection.allocUiUtf8Lossy(state.projection, bytes);
}

fn trackUiString(state: *Scope, text: []u8) ![]const u8 {
    return projection.trackUiString(state.projection, text);
}

fn clearAssetBodyTracking(state: *Scope) void {
    projection.clearAsset(state.projection);
}

fn clearUiTracking(state: *Scope) void {
    projection.clearUi(state.projection);
}

fn scrollDebug(state: *const Scope, comptime fmt: []const u8, args: anytype) void {
    if (state.projection.layout.scroll_debug_enabled) std.debug.print("scroll-debug: " ++ fmt ++ "\n", args);
}

fn layoutDebug(state: *const Scope, comptime fmt: []const u8, args: anytype) void {
    if (state.projection.layout.layout_debug_enabled) std.debug.print("layout-debug: " ++ fmt ++ "\n", args);
}

// ── Local helpers wrapping the px-constant helpers ──
fn browserGridItemWidthPx(state: *const Scope) f32 {
    return uiPx(state, browser_grid_item_width);
}

fn browserGridItemHeightPx(state: *const Scope) f32 {
    return uiPx(state, browser_grid_item_height);
}

fn browserGridColumnGapPx(state: *const Scope) f32 {
    return uiPx(state, browser_grid_column_gap);
}

fn browserGridRowGapPx(state: *const Scope) f32 {
    return uiPx(state, browser_grid_row_gap);
}

fn browserGridPaddingHPx(state: *const Scope) f32 {
    return uiPx(state, browser_grid_padding_h);
}

fn browserTableDividerWidthPx(state: *const Scope) f32 {
    _ = state;
    return browser_table_divider_width;
}

fn browserNameIconInsetLeftPx(state: *const Scope) f32 {
    return uiPx(state, browser_name_icon_inset_left);
}

fn browserNameTextInsetLeftPx(state: *const Scope) f32 {
    return uiPx(state, browser_name_text_inset_left);
}

fn find(ctx: *const goop.Context, id: goop.ElementId) ?goop.NodeHandle {
    return ctx.tree.findByElementId(id);
}

fn identify(ctx: *goop.Context, handle: goop.NodeHandle, id: goop.ElementId, action: ?goop.ActionId) !void {
    try ctx.tree.setControlIdentity(handle, .{ .element_id = id, .action_id = action });
}

fn identifyFixed(ctx: *goop.Context, handle: goop.NodeHandle, id: ids.Fixed) !void {
    try identify(ctx, handle, ids.fixed(id), null);
}

// ── Viewport / virtualization ──

fn captureFilePanelViewport(state: *Scope, ctx: *goop.Context) void {
    const handle = find(ctx, ids.fixed(.file_panel_scroll)) orelse return;
    if (!ctx.tree.isAlive(handle)) return;
    const node = ctx.tree.getConst(handle);
    state.projection.layout.file_panel_viewport_width = node.layout_rect.w;
    state.projection.layout.file_panel_viewport_height = node.layout_rect.h;
}

fn browserViewportWidthEstimate(state: *const Scope) f32 {
    if (state.projection.layout.file_panel_viewport_width > 0) return state.projection.layout.file_panel_viewport_width;
    return @as(f32, @floatFromInt(state.viewport.logical_width));
}

fn browserViewportHeightEstimate(state: *const Scope) f32 {
    if (state.projection.layout.file_panel_viewport_height > 0) return state.projection.layout.file_panel_viewport_height;
    return @as(f32, @floatFromInt(state.viewport.logical_height));
}

fn browserListRowHeight(state: *const Scope) f32 {
    return virtualization.listRowHeight(.{ .ui_scale = state.viewport.ui_scale, .text_measure_ctx = state.projection.text_measure_ctx });
}

fn browserListWindowAt(state: *const Scope, viewport_height: f32, requested_scroll_y: f32) ListVirtualWindow {
    return virtualization.listWindow(
        state.domain.model,
        .{ .ui_scale = state.viewport.ui_scale, .text_measure_ctx = state.projection.text_measure_ctx },
        viewport_height,
        requested_scroll_y,
    );
}

fn browserListWindow(state: *const Scope, viewport_height: f32) ListVirtualWindow {
    return browserListWindowAt(state, viewport_height, state.domain.model.file_panel_scroll_y);
}

fn browserGridWindowAt(state: *const Scope, viewport_width: f32, viewport_height: f32, requested_scroll_y: f32) GridVirtualWindow {
    return virtualization.gridWindow(
        state.domain.model,
        .{ .ui_scale = state.viewport.ui_scale, .text_measure_ctx = state.projection.text_measure_ctx },
        viewport_width,
        viewport_height,
        requested_scroll_y,
    );
}

fn browserGridWindow(state: *const Scope, viewport_width: f32, viewport_height: f32) GridVirtualWindow {
    return browserGridWindowAt(state, viewport_width, viewport_height, state.domain.model.file_panel_scroll_y);
}

// ── Table cells ──

fn addTextCell(state: *const Scope, ctx: *goop.Context, row: goop.NodeHandle, text: []const u8) !void {
    const cell = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    _ = ctx.setStyle(cell, .{
        .border_width = browserTableDividerWidthPx(state),
    });
    _ = try ctx.tree.addChild(cell, .{ .text = .{ .content = text, .overflow = .ellipsis } });
}

fn addNameHeaderCell(state: *const Scope, ctx: *goop.Context, row: goop.NodeHandle, text: []const u8) !void {
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
    _ = try ctx.tree.addChild(cell, .{ .text = .{ .content = text, .overflow = .ellipsis } });
}

fn addNameCell(state: *Scope, ctx: *goop.Context, row: goop.NodeHandle, entry: BrowserEntry) !goop.NodeHandle {
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
    const selected = isPathSelected(state, entry.path);
    const icon = try ctx.tree.addChild(cell, .{ .icon = .{
        .kind = browserEntryIconKind(entry),
        .color = browserEntryIconColor(ctx.theme, entry, selected),
    } });
    _ = ctx.setStyle(icon, .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .padding = goop.style.Edges.all(0),
        .font_size = uiPx(state, 18),
    });
    if (isRenamingPath(state, entry.path)) {
        const input = try ctx.tree.addChild(cell, .{ .text_input = .{ .placeholder = state.domain.interaction.rename_input.placeholder } });
        if (ctx.mutateKind(input)) |kind| {
            kind.text_input = state.domain.interaction.rename_input;
        }
        try identifyFixed(ctx, input, .rename_input);
        _ = ctx.setStyle(input, fileManagerRenameInputStyle(state));
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

fn detailTitleFontSizePx(state: *const Scope) f32 {
    return style.detailTitleFontSizePx(state.viewport.ui_scale);
}
fn detailCaptionFontSizePx(state: *const Scope) f32 {
    return style.detailCaptionFontSizePx(state.viewport.ui_scale);
}
fn previewBodyFontSizePx(state: *const Scope) f32 {
    return style.previewBodyFontSizePx(state.viewport.ui_scale);
}

pub fn clampDetailSplitterRatio(raw: f32, available: f32, min_first: f32, min_second: f32) f32 {
    const clamped = std.math.clamp(raw, 0, 1);
    if (available <= 0) return clamped;

    const min_ratio = std.math.clamp(min_first / available, 0, 1);
    const max_ratio = std.math.clamp(1 - min_second / available, 0, 1);
    if (min_ratio > max_ratio) return clamped;
    return std.math.clamp(clamped, min_ratio, max_ratio);
}

fn browserBodyWidthPx(state: *const Scope) f32 {
    var width = @max(@as(f32, @floatFromInt(@max(state.viewport.logical_width, @as(u32, 1)))) - 1, 1);
    if (state.domain.model.show_sidebar) {
        const nav_ratio = clampDetailSplitterRatio(state.domain.model.nav_ratio, width, uiPx(state, 220), uiPx(state, 420));
        width *= 1 - nav_ratio;
    }
    return @max(width, 1);
}

fn inspectorPanelWidthPx(state: *const Scope) f32 {
    var width = browserBodyWidthPx(state);
    if (state.domain.model.show_preview or state.domain.model.show_info) {
        const detail_ratio = clampDetailSplitterRatio(state.domain.model.detail_ratio, width, uiPx(state, 360), uiPx(state, 300));
        width *= 1 - detail_ratio;
    }
    return @max(width, uiPx(state, 200));
}

fn detailTextWrapWidthPx(state: *const Scope) f32 {
    // Reserve the scroll + panel padding so wrapped inspector text stays inside the pane body.
    return @max(inspectorPanelWidthPx(state) - uiPx(state, 44), uiPx(state, 156));
}

fn wrapTextOwnedForWidth(state: *const Scope, text: []u8, font_size: f32, max_width: f32) ![]u8 {
    return detail_text.wrapOwned(text, font_size, max_width, state.projection.text_measure_ctx);
}

fn wrapDetailTextOwned(state: *const Scope, text: []u8, font_size: f32) ![]u8 {
    return wrapTextOwnedForWidth(state, text, font_size, detailTextWrapWidthPx(state));
}

fn allocUiDetailWrappedUtf8Lossy(state: *Scope, bytes: []const u8, font_size: f32) ![]const u8 {
    return trackUiString(state, try wrapDetailTextOwned(state, try allocUtf8LossyOwned(bytes), font_size));
}

fn allocUiWrappedOwnedText(state: *Scope, text: []u8, font_size: f32) ![]const u8 {
    return trackUiString(state, try wrapTextOwnedForWidth(state, text, font_size, detailTextWrapWidthPx(state)));
}

fn allocUiWrappedText(state: *Scope, text: []const u8, font_size: f32) ![]const u8 {
    return allocUiWrappedOwnedText(state, try allocator.dupe(u8, text), font_size);
}

fn addDetailText(
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

fn addStyledDetailText(
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

fn applyAssetTableColumns(table: *goop.widget.WidgetKind.Table, state: *const Scope) void {
    table.internal.column_weights[0] = state.domain.model.table_column_weights[0];
    table.internal.column_weights[1] = state.domain.model.table_column_weights[1];
    table.internal.column_weights[2] = state.domain.model.table_column_weights[2];
    table.internal.column_weights[3] = state.domain.model.table_column_weights[3];
}

fn buildListHeaderTable(state: *Scope, ctx: *goop.Context, parent: goop.NodeHandle) !void {
    const table_handle = try ctx.tree.addChild(parent, .{ .table = .{
        .columns = 4,
        .striped = false,
        .resizable = true,
        .sortable = true,
        .selection_mode = .none,
        .min_column_width = uiPx(state, 96),
    } });
    try identifyFixed(ctx, table_handle, .asset_header_table);
    _ = ctx.setStyle(table_handle, .{
        .bg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .border = .{ .r = 214, .g = 220, .b = 228, .a = 255 },
        .border_width = 0,
        .padding = goop.style.Edges.all(0),
        .border_radius = 0,
    });
    {
        const table = &ctx.mutateKind(table_handle).?.table;
        applyAssetTableColumns(table, state);
        table.sorted_column = @intFromEnum(state.domain.model.sort_column);
        table.sort_direction = switch (state.domain.model.sort_direction) {
            .ascending => .ascending,
            .descending => .descending,
        };
    }

    const header_row = try ctx.tree.addChild(table_handle, .{ .table_row = .{ .header = true } });
    _ = ctx.setStyle(header_row, .{
        .border_width = browserTableDividerWidthPx(state),
    });
    try addNameHeaderCell(state, ctx, header_row, "Name");
    try addTextCell(state, ctx, header_row, "Modified");
    try addTextCell(state, ctx, header_row, "Type");
    try addTextCell(state, ctx, header_row, "Size");
}

fn buildListAssetView(state: *Scope, ctx: *goop.Context, scroll_handle: goop.NodeHandle, viewport_height: f32) !void {
    const window = browserListWindow(state, viewport_height);
    if (ctx.mutateKind(scroll_handle)) |__k| {
        __k.scroll_area.scroll_y = window.scroll_y;
        __k.scroll_area.content_height = window.content_height;
    }
    state.projection.assets.asset_visible_start = window.start;
    state.projection.assets.asset_visible_end = window.end;
    state.projection.assets.asset_visible_columns = 0;

    const table_body = try ctx.tree.addChild(scroll_handle, .{ .table = .{
        .columns = 4,
        .striped = false,
        .selection_mode = .multiple,
        .min_column_width = uiPx(state, 96),
    } });
    try identifyFixed(ctx, table_body, .asset_body_table);
    _ = ctx.setStyle(table_body, .{
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
    applyAssetTableColumns(&ctx.mutateKind(table_body).?.table, state);

    for (state.domain.model.entries.items[window.start..window.end]) |entry| {
        const row = try ctx.tree.addChild(table_body, .{ .table_row = .{
            .selected = isPathSelected(state, entry.path),
        } });
        try identify(ctx, row, try state.identities.idForPath(.asset, entry.path), null);
        _ = ctx.setStyle(row, .{
            .border_width = browserTableDividerWidthPx(state),
        });
        _ = try addNameCell(state, ctx, row, entry);
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

fn buildGridAssetView(state: *Scope, ctx: *goop.Context, scroll_handle: goop.NodeHandle, viewport_width: f32, viewport_height: f32) !void {
    const window = browserGridWindow(state, viewport_width, viewport_height);
    if (ctx.mutateKind(scroll_handle)) |__k| {
        __k.scroll_area.scroll_y = window.scroll_y;
        __k.scroll_area.content_height = window.content_height;
    }
    state.projection.assets.asset_visible_start = window.start;
    state.projection.assets.asset_visible_end = window.end;
    state.projection.assets.asset_visible_columns = window.columns;

    const asset_root = try ctx.tree.addChild(scroll_handle, .{ .container = .{ .direction = .column } });
    _ = ctx.setStyle(asset_root, .{
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border_width = 0,
        .padding = goop.style.Edges.all(0),
        .spacing = 0,
        .border_radius = 0,
    });

    const grid = try ctx.tree.addChild(asset_root, .{ .grid_selector = .{
        .selection_mode = .multiple,
        .item_width = browserGridItemWidthPx(state),
        .item_height = browserGridItemHeightPx(state),
        .column_gap = browserGridColumnGapPx(state),
        .row_gap = browserGridRowGapPx(state),
    } });
    try identifyFixed(ctx, grid, .asset_grid);
    _ = ctx.setStyle(grid, .{
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

    for (state.domain.model.entries.items[window.start..window.end]) |entry| {
        const item = try ctx.tree.addChild(grid, .{ .grid_item = .{
            .label = try allocAssetUiEllipsizedUtf8Lossy(state, entry.name, uiPx(state, 104), ctx.theme.font_size),
            .icon = browserEntryIconKind(entry),
            .icon_color = browserEntryIconColor(ctx.theme, entry, isPathSelected(state, entry.path)),
            .selected = isPathSelected(state, entry.path),
        } });
        try identify(ctx, item, try state.identities.idForPath(.asset, entry.path), null);
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

fn buildAssetView(state: *Scope, ctx: *goop.Context, scroll_handle: goop.NodeHandle) !void {
    const viewport_width = browserViewportWidthEstimate(state);
    const viewport_height = browserViewportHeightEstimate(state);

    if (state.domain.model.entries.items.len == 0) {
        if (ctx.mutateKind(scroll_handle)) |__k| {
            __k.scroll_area.scroll_y = 0;
            __k.scroll_area.content_height = 0;
        }
        state.projection.assets.asset_visible_start = 0;
        state.projection.assets.asset_visible_end = 0;
        state.projection.assets.asset_visible_columns = 0;
        _ = try ctx.tree.addChild(scroll_handle, .{ .text = .{ .content = "This directory is empty." } });
        return;
    }

    switch (state.domain.model.view_mode) {
        .list => try buildListAssetView(state, ctx, scroll_handle, viewport_height),
        .grid => try buildGridAssetView(state, ctx, scroll_handle, viewport_width, viewport_height),
    }
}

fn rebuildAssetView(state: *Scope, ctx: *goop.Context) !void {
    const scroll_handle = find(ctx, ids.fixed(.file_panel_scroll)) orelse return error.NoContext;

    scrollDebug(state, "rebuild begin mode={s} prev_window=[{}..{}) scroll={d:.2}", .{
        browserViewModeLabel(state.domain.model.view_mode),
        state.projection.assets.asset_visible_start,
        state.projection.assets.asset_visible_end,
        state.domain.model.file_panel_scroll_y,
    });

    while (ctx.tree.getConst(scroll_handle).first_child) |child| {
        try ctx.tree.remove(child);
    }
    clearAssetBodyTracking(state);
    try buildAssetView(state, ctx, scroll_handle);

    scrollDebug(state, "rebuild end mode={s} next_window=[{}..{})", .{
        browserViewModeLabel(state.domain.model.view_mode),
        state.projection.assets.asset_visible_start,
        state.projection.assets.asset_visible_end,
    });
}

fn refreshAssetViewport(state: *Scope, ctx: *goop.Context) !bool {
    const scroll_handle = find(ctx, ids.fixed(.file_panel_scroll)) orelse return false;
    if (!ctx.tree.isAlive(scroll_handle)) return false;

    const previous_scroll_y = state.domain.model.file_panel_scroll_y;
    const previous_viewport_height = state.projection.layout.file_panel_viewport_height;
    const previous_visible_start = state.projection.assets.asset_visible_start;
    const previous_visible_end = state.projection.assets.asset_visible_end;
    const previous_visible_columns = state.projection.assets.asset_visible_columns;
    const scroll_node = ctx.tree.getConst(scroll_handle);
    const viewport_width = scroll_node.layout_rect.w;
    const viewport_height = scroll_node.layout_rect.h;
    const current_scroll_y = scroll_node.kind.scroll_area.scroll_y;
    state.projection.layout.file_panel_viewport_width = viewport_width;
    state.projection.layout.file_panel_viewport_height = viewport_height;

    if (state.domain.model.entries.items.len == 0) {
        return false;
    }

    switch (state.domain.model.view_mode) {
        .list => {
            const asset_alive = find(ctx, ids.fixed(.asset_body_table)) != null;
            const window = browserListWindowAt(state, viewport_height, current_scroll_y);
            const viewport_height_changed = @abs(previous_viewport_height - viewport_height) > 0.01;
            const scroll_clamped = @abs(current_scroll_y - window.scroll_y) > 0.01;
            if (scroll_clamped) {
                if (ctx.mutateKind(scroll_handle)) |__k| {
                    __k.scroll_area.scroll_y = window.scroll_y;
                }
            }
            const needs_rebuild = !asset_alive or viewport_height_changed or state.projection.assets.asset_visible_start != window.start or state.projection.assets.asset_visible_end != window.end;
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
                try rebuildAssetView(state, ctx);
                return true;
            }
            return scroll_clamped;
        },
        .grid => {
            const asset_alive = find(ctx, ids.fixed(.asset_grid)) != null;
            const window = browserGridWindowAt(state, viewport_width, viewport_height, current_scroll_y);
            const viewport_height_changed = @abs(previous_viewport_height - viewport_height) > 0.01;
            const scroll_clamped = @abs(current_scroll_y - window.scroll_y) > 0.01;
            if (scroll_clamped) {
                if (ctx.mutateKind(scroll_handle)) |__k| {
                    __k.scroll_area.scroll_y = window.scroll_y;
                }
            }
            const needs_rebuild = !asset_alive or viewport_height_changed or state.projection.assets.asset_visible_start != window.start or state.projection.assets.asset_visible_end != window.end or state.projection.assets.asset_visible_columns != window.columns;
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
                try rebuildAssetView(state, ctx);
                return true;
            }
            return scroll_clamped;
        },
    }

    return false;
}

// ── Icon geometry and visual metadata ──

pub fn browserEntryIconKind(entry: BrowserEntry) goop.IconId {
    const id: types.DemoIcon = switch (entry.kind) {
        .directory => .folder,
        .symlink => .symlink,
        else => .file,
    };
    return @intFromEnum(id);
}

pub fn browserEntryIconColor(theme: goop.Theme, entry: BrowserEntry, selected: bool) goop.Color {
    if (selected) return theme.accent;
    return switch (entry.kind) {
        .directory => .rgb(74, 120, 201),
        .symlink => .rgb(44, 140, 134),
        else => .rgb(118, 127, 141),
    };
}

fn entryNameTextRect(state: *const Scope, ctx: *const goop.Context, visible_index: usize, entry: BrowserEntry) ?goop.Rect {
    _ = visible_index;
    const element = state.identities.existingIdForPath(.asset, entry.path) orelse return null;
    const row = find(ctx, element) orelse return null;
    var row_children = ctx.tree.children(row);
    const cell = row_children.next() orelse return null;
    var cell_children = ctx.tree.children(cell);
    var text_rect: ?goop.Rect = null;
    while (cell_children.next()) |child| {
        const child_node = ctx.tree.getConst(child);
        if (child_node.kind == .text) {
            text_rect = child_node.layout_rect;
            break;
        }
    }
    const rect = text_rect orelse return null;
    const measured_w = goop.layout.measureTextDimensions(entry.name, ctx.theme.font_size, state.projection.text_measure_ctx).width;
    return .{
        .x = rect.x,
        .y = rect.y,
        .w = @min(measured_w, rect.w),
        .h = rect.h,
    };
}

pub fn pointInRect(x: f32, y: f32, rect: goop.Rect) bool {
    return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h;
}

fn pointHitsEntryNameText(state: *const Scope, ctx: *const goop.Context, visible_index: usize, entry: BrowserEntry, x: f32, y: f32) bool {
    const rect = entryNameTextRect(state, ctx, visible_index, entry) orelse return false;
    return pointInRect(x, y, rect);
}

fn pointHitsVisibleAssetItem(state: *const Scope, ctx: *const goop.Context, x: f32, y: f32) bool {
    for (state.domain.model.entries.items[state.projection.assets.asset_visible_start..state.projection.assets.asset_visible_end]) |entry| {
        const element = state.identities.existingIdForPath(.asset, entry.path) orelse continue;
        const handle = find(ctx, element) orelse continue;
        if (pointInRect(x, y, ctx.tree.getConst(handle).layout_rect)) return true;
    }
    return false;
}

fn pointInFilePanelBlankSpace(state: *const Scope, ctx: *const goop.Context, x: f32, y: f32) bool {
    const scroll_handle = find(ctx, ids.fixed(.file_panel_scroll)) orelse return false;
    const rect = ctx.tree.getConst(scroll_handle).layout_rect;
    if (!pointInRect(x, y, rect)) return false;

    if (goop.scrollbar.verticalMetrics(&ctx.tree, scroll_handle, ctx.theme)) |metrics| {
        if (pointInRect(x, y, metrics.track)) return false;
    }
    if (goop.scrollbar.horizontalMetrics(&ctx.tree, scroll_handle, ctx.theme)) |metrics| {
        if (pointInRect(x, y, metrics.track)) return false;
    }
    return !pointHitsVisibleAssetItem(state, ctx, x, y);
}

fn collectRowCellWidths(ctx: *const goop.Context, row_handle: ?goop.NodeHandle) [4]f32 {
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

fn debugLogFilePanelLayout(state: *Scope, ctx: *goop.Context) void {
    if (!state.projection.layout.scroll_debug_enabled and !state.projection.layout.layout_debug_enabled) return;

    const root_handle = find(ctx, ids.fixed(.root)) orelse return;
    const scroll_handle = find(ctx, ids.fixed(.file_panel_scroll)) orelse return;

    const root_rect = ctx.tree.getConst(root_handle).layout_rect;
    const scroll_node = ctx.tree.getConst(scroll_handle);
    const scroll_y = scroll_node.kind.scroll_area.scroll_y;
    const scroll_state_unchanged = @abs(scroll_y - state.projection.layout.scroll_debug_last_scroll_y) <= 0.01 and
        state.projection.layout.scroll_debug_last_visible_start == state.projection.assets.asset_visible_start and
        state.projection.layout.scroll_debug_last_visible_end == state.projection.assets.asset_visible_end;

    const scroll_rect = scroll_node.layout_rect;
    const body_handle = switch (state.domain.model.view_mode) {
        .list => find(ctx, ids.fixed(.asset_body_table)),
        .grid => find(ctx, ids.fixed(.asset_grid)),
    };
    const body_alive = if (body_handle) |handle| ctx.tree.isAlive(handle) else false;
    const body_y = if (body_alive) ctx.tree.getConst(body_handle.?).layout_rect.y else -1.0;
    const body_h = if (body_alive) ctx.tree.getConst(body_handle.?).layout_rect.h else -1.0;
    const first_row = if (state.projection.assets.asset_visible_start < state.projection.assets.asset_visible_end) blk: {
        const entry = state.domain.model.entries.items[state.projection.assets.asset_visible_start];
        const element = state.identities.existingIdForPath(.asset, entry.path) orelse break :blk null;
        break :blk find(ctx, element);
    } else null;
    const first_row_y = if (first_row) |handle| ctx.tree.getConst(handle).layout_rect.y else -1.0;

    if (!scroll_state_unchanged) {
        state.projection.layout.scroll_debug_last_scroll_y = scroll_y;
        state.projection.layout.scroll_debug_last_visible_start = state.projection.assets.asset_visible_start;
        state.projection.layout.scroll_debug_last_visible_end = state.projection.assets.asset_visible_end;

        scrollDebug(state, "layout mode={s} scroll={d:.2} scroll_rect=({d:.1},{d:.1},{d:.1},{d:.1}) body_alive={} body_y={d:.1} body_h={d:.1} first_row_y={d:.1} window=[{}..{})", .{
            browserViewModeLabel(state.domain.model.view_mode),
            scroll_y,
            scroll_rect.x,
            scroll_rect.y,
            scroll_rect.w,
            scroll_rect.h,
            body_alive,
            body_y,
            body_h,
            first_row_y,
            state.projection.assets.asset_visible_start,
            state.projection.assets.asset_visible_end,
        });
        scrollDebug(state, "layout root logical={}x{} root_rect=({d:.1},{d:.1},{d:.1},{d:.1})", .{
            state.viewport.logical_width,
            state.viewport.logical_height,
            root_rect.x,
            root_rect.y,
            root_rect.w,
            root_rect.h,
        });
    }

    if (state.projection.layout.layout_debug_enabled and state.domain.model.view_mode == .list) {
        const header_table_handle = find(ctx, ids.fixed(.asset_header_table));
        const body_table_handle = find(ctx, ids.fixed(.asset_body_table));
        const header_alive = if (header_table_handle) |handle| ctx.tree.isAlive(handle) else false;
        const body_table_alive = if (body_table_handle) |handle| ctx.tree.isAlive(handle) else false;
        const header_rect = if (header_alive) ctx.tree.getConst(header_table_handle.?).layout_rect else goop.Rect{ .x = -1, .y = -1, .w = -1, .h = -1 };
        const body_rect = if (body_table_alive) ctx.tree.getConst(body_table_handle.?).layout_rect else goop.Rect{ .x = -1, .y = -1, .w = -1, .h = -1 };
        const header_row = if (header_alive) goop.widget.tableHeaderRow(&ctx.tree, header_table_handle.?) else null;
        const body_row = first_row;
        const header_widths = collectRowCellWidths(ctx, header_row);
        const body_widths = collectRowCellWidths(ctx, body_row);
        const layout_state_unchanged = @abs(header_rect.x - state.projection.layout.layout_debug_last_header_x) <= 0.01 and
            @abs(header_rect.w - state.projection.layout.layout_debug_last_header_w) <= 0.01 and
            @abs(body_rect.x - state.projection.layout.layout_debug_last_body_x) <= 0.01 and
            @abs(body_rect.w - state.projection.layout.layout_debug_last_body_w) <= 0.01 and
            sameWidths(header_widths, state.projection.layout.layout_debug_last_header_widths) and
            sameWidths(body_widths, state.projection.layout.layout_debug_last_body_widths);

        if (!layout_state_unchanged) {
            state.projection.layout.layout_debug_last_header_x = header_rect.x;
            state.projection.layout.layout_debug_last_header_w = header_rect.w;
            state.projection.layout.layout_debug_last_body_x = body_rect.x;
            state.projection.layout.layout_debug_last_body_w = body_rect.w;
            state.projection.layout.layout_debug_last_header_widths = header_widths;
            state.projection.layout.layout_debug_last_body_widths = body_widths;

            layoutDebug(state, "list columns header_rect=({d:.1},{d:.1}) body_rect=({d:.1},{d:.1}) weights=({d:.3},{d:.3},{d:.3},{d:.3}) header=({d:.1},{d:.1},{d:.1},{d:.1}) body=({d:.1},{d:.1},{d:.1},{d:.1})", .{
                header_rect.x,
                header_rect.w,
                body_rect.x,
                body_rect.w,
                state.domain.model.table_column_weights[0],
                state.domain.model.table_column_weights[1],
                state.domain.model.table_column_weights[2],
                state.domain.model.table_column_weights[3],
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

fn addToolbarButton(
    state: *const Scope,
    ctx: *goop.Context,
    parent: goop.NodeHandle,
    label: []const u8,
    active: bool,
    enabled: bool,
    element: goop.ElementId,
    action: ?goop.ActionId,
) !goop.NodeHandle {
    const handle = try ctx.tree.addChildControl(parent, desktop.control.button(element, action, .{ .label = label }));
    _ = ctx.setStyle(handle, fileManagerToolbarButtonStyle(state, active, enabled));
    return handle;
}

fn addToolbarCommandButton(state: *const Scope, ctx: *goop.Context, parent: goop.NodeHandle, label: []const u8, command: BrowserCommand) !goop.NodeHandle {
    return addToolbarButton(
        state,
        ctx,
        parent,
        label,
        browserCommandChecked(state, command),
        browserCommandEnabled(state, command),
        ids.commandElement(.toolbar, command),
        ids.commandAction(command),
    );
}

fn addMenuCommandItem(
    state: *const Scope,
    ctx: *goop.Context,
    parent: goop.NodeHandle,
    label: []const u8,
    command: BrowserCommand,
    shortcut: []const u8,
    surface: ids.CommandSurface,
) !goop.NodeHandle {
    const handle = try ctx.tree.addChildControl(parent, desktop.control.menuItem(ids.commandElement(surface, command), ids.commandAction(command), .{
        .label = label,
        .shortcut = shortcut,
        .checked = browserCommandChecked(state, command),
        .disabled = !browserCommandEnabled(state, command),
    }));
    _ = ctx.setStyle(handle, fileManagerMenuItemStyle(state));
    return handle;
}

fn addContextMenuItem(
    state: *const Scope,
    ctx: *goop.Context,
    parent: goop.NodeHandle,
    label: []const u8,
    enabled: bool,
    element: goop.ElementId,
    action: ?goop.ActionId,
) !goop.NodeHandle {
    const handle = try ctx.tree.addChildControl(parent, desktop.control.menuItem(element, action, .{
        .label = label,
        .disabled = !enabled,
    }));
    _ = ctx.setStyle(handle, fileManagerMenuItemStyle(state));
    return handle;
}

fn buildContextPopup(state: *Scope, ctx: *goop.Context) !void {
    if (!state.domain.interaction.context_visible) return;

    const popup = try ctx.tree.addRoot(.{ .popup = .{
        .placement = .absolute,
        .x = state.domain.interaction.context_x,
        .y = state.domain.interaction.context_y,
        .visible = true,
        .close_on_outside_click = true,
        .z_index = 140,
    } });
    try identifyFixed(ctx, popup, .context_popup);
    _ = ctx.setStyle(popup, fileManagerMenuPopupStyle(state));

    _ = try addContextMenuItem(state, ctx, popup, "Open", contextOpenEnabled(state), ids.fixed(.context_open), null);
    _ = try addContextMenuItem(state, ctx, popup, "Copy", contextSelectionCommandEnabled(state), ids.commandElement(.context_menu, .copy), ids.commandAction(.copy));
    _ = try addContextMenuItem(state, ctx, popup, "Cut", contextSelectionCommandEnabled(state), ids.commandElement(.context_menu, .cut), ids.commandAction(.cut));
    _ = try addContextMenuItem(state, ctx, popup, "Paste", contextPasteEnabled(state), ids.fixed(.context_paste), null);
    _ = try addContextMenuItem(state, ctx, popup, "Delete", contextSelectionCommandEnabled(state), ids.commandElement(.context_menu, .delete), ids.commandAction(.delete));
    _ = try addContextMenuItem(state, ctx, popup, "Rename", contextRenameEnabled(state), ids.fixed(.context_rename), null);
    _ = try addContextMenuItem(state, ctx, popup, "Move to Parent Directory", contextMoveParentEnabled(state), ids.commandElement(.context_menu, .move_parent), ids.commandAction(.move_parent));
    _ = try addContextMenuItem(state, ctx, popup, "Copy Path", contextCopyPathEnabled(state), ids.fixed(.context_copy_path), null);
    _ = try addContextMenuItem(state, ctx, popup, "Open Link Target", contextOpenLinkTargetEnabled(state), ids.fixed(.context_open_link_target), null);
}

// ── Folder tree (UI side) ──

fn folderTreeLabel(state: *Scope, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "/")) return "/";
    return allocUiUtf8Lossy(state, std.fs.path.basename(path));
}

fn addFolderTreeItem(
    state: *Scope,
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
    try identify(ctx, handle, try state.identities.idForPath(.folder, path), null);
    try projection.trackPath(&state.projection.assets.folder_tree_paths, path);
    return handle;
}

fn buildFolderTree(state: *Scope, ctx: *goop.Context, parent: goop.NodeHandle) !void {
    const tree_root = try ctx.tree.addChild(parent, .{ .container = .{ .direction = .column } });
    _ = ctx.setStyle(tree_root, fileManagerFolderTreeStyle(state));

    var handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty;
    defer handles.deinit(allocator);
    for (state.domain.presentation.folder_tree.items) |item| {
        const item_parent = if (item.parent_index) |parent_index|
            if (parent_index < handles.items.len) handles.items[parent_index] else return error.InvalidPreparedFolderTree
        else
            tree_root;
        const handle = try addFolderTreeItem(
            state,
            ctx,
            item_parent,
            item.path,
            try folderTreeLabel(state, item.path),
            item.expanded,
            item.selected,
            item.has_children,
        );
        try handles.append(allocator, handle);
    }
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

fn summarizeBrowser(state: *const Scope) BrowserSummary {
    var summary = BrowserSummary{ .selected_count = selectedPathCount(state) };
    for (state.domain.model.entries.items) |entry| {
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

fn addTopMenu(
    state: *const Scope,
    ctx: *goop.Context,
    menu_bar: goop.NodeHandle,
    label: []const u8,
    menu_id: ids.Fixed,
    popup_id: ids.Fixed,
) !goop.NodeHandle {
    const button = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = label } });
    try identifyFixed(ctx, button, menu_id);
    _ = ctx.setStyle(button, fileManagerMenuStyle(state));
    const popup = try ctx.tree.addChild(button, .{ .popup = .{ .placement = .below_start, .visible = false } });
    try identifyFixed(ctx, popup, popup_id);
    _ = ctx.setStyle(popup, fileManagerMenuPopupStyle(state));
    return popup;
}

fn buildTopMenu(state: *Scope, ctx: *goop.Context, root: goop.NodeHandle) !void {
    const menu_bar = try ctx.tree.addChild(root, .{ .menu_bar = .{} });
    _ = ctx.setStyle(menu_bar, fileManagerMenuBarStyle(state));

    var popup = try addTopMenu(state, ctx, menu_bar, "File", .menu_file, .menu_file_popup);
    _ = try addMenuCommandItem(state, ctx, popup, "Refresh", .refresh, "", .file_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Copy Path", .copy_path, "", .file_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Open Link Target", .open_link_target, "", .file_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Quit", .quit, "", .file_menu);

    popup = try addTopMenu(state, ctx, menu_bar, "Edit", .menu_edit, .menu_edit_popup);
    _ = try addMenuCommandItem(state, ctx, popup, "Copy", .copy, "Ctrl+C", .edit_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Cut", .cut, "Ctrl+X", .edit_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Paste", .paste, "Ctrl+V", .edit_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Delete", .delete, "Del", .edit_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Rename", .rename, "", .edit_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Move to Parent Directory", .move_parent, "Ctrl+Shift+Up", .edit_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Select All", .select_all, "Ctrl+A", .edit_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Clear Selection", .clear_selection, "Esc", .edit_menu);

    popup = try addTopMenu(state, ctx, menu_bar, "View", .menu_view, .menu_view_popup);
    _ = try addMenuCommandItem(state, ctx, popup, "Sidebar", .toggle_sidebar, "", .view_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Preview", .toggle_preview, "", .view_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Details", .toggle_info, "", .view_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Status Bar", .toggle_status_bar, "", .view_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "List View", .view_list, "", .view_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Grid View", .view_grid, "", .view_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Sort Directories Together", .toggle_sort_directories, "", .view_menu);

    popup = try addTopMenu(state, ctx, menu_bar, "Go", .menu_go, .menu_go_popup);
    _ = try addMenuCommandItem(state, ctx, popup, "Back", .back, "", .go_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Forward", .forward, "", .go_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Up", .up, "", .go_menu);
    _ = try addMenuCommandItem(state, ctx, popup, "Home", .home, "", .go_menu);

    popup = try addTopMenu(state, ctx, menu_bar, "Help", .menu_help, .menu_help_popup);
    _ = try addMenuCommandItem(state, ctx, popup, "About goop files", .about, "", .help_menu);
}
fn buildToolbar(state: *Scope, ctx: *goop.Context, root: goop.NodeHandle) !void {
    const toolbar = try ctx.tree.addChild(root, .{ .toolbar = .{} });
    _ = ctx.setStyle(toolbar, fileManagerToolbarStyle(state));
    _ = try addToolbarCommandButton(state, ctx, toolbar, "Back", .back);
    _ = try addToolbarCommandButton(state, ctx, toolbar, "Forward", .forward);
    const up = try addToolbarCommandButton(state, ctx, toolbar, "Up", .up);
    if (browserCommandEnabled(state, .up)) ctx.tree.setDropTarget(up, true);
    _ = try addToolbarCommandButton(state, ctx, toolbar, "Home", .home);
    _ = try addToolbarCommandButton(state, ctx, toolbar, "Refresh", .refresh);
    _ = try ctx.tree.addChild(toolbar, .{ .spacer = .{ .width = uiPx(state, 6) } });
    _ = try addToolbarCommandButton(state, ctx, toolbar, "Sidebar", .toggle_sidebar);
    _ = try addToolbarCommandButton(state, ctx, toolbar, "Preview", .toggle_preview);
    _ = try addToolbarCommandButton(state, ctx, toolbar, "Details", .toggle_info);
    _ = try ctx.tree.addChild(toolbar, .{ .spacer = .{ .width = uiPx(state, 8) } });

    const address = try ctx.tree.addChildControl(toolbar, desktop.control.textInput(
        ids.fixed(.address_input),
        null,
        .{ .placeholder = state.domain.interaction.address_input.placeholder },
    ));
    if (ctx.mutateKind(address)) |kind| kind.text_input = state.domain.interaction.address_input;
    _ = ctx.setStyle(address, fileManagerTextInputStyle(state));

    _ = try addToolbarButton(state, ctx, toolbar, "Go", false, true, ids.fixed(.address_go), null);
    _ = try ctx.tree.addChild(toolbar, .{ .spacer = .{ .width = uiPx(state, 8) } });
    _ = try addToolbarCommandButton(state, ctx, toolbar, "List", .view_list);
    _ = try addToolbarCommandButton(state, ctx, toolbar, "Grid", .view_grid);
}
fn buildContentHost(state: *Scope, ctx: *goop.Context, root: goop.NodeHandle, transparent: goop.Color) !goop.NodeHandle {
    if (!state.domain.model.show_sidebar) {
        const content_host = try ctx.tree.addChild(root, .{ .container = .{ .direction = .column } });
        _ = ctx.setStyle(content_host, fileManagerPaneStyle(state, transparent));
        return content_host;
    }

    const nav_splitter = try ctx.tree.addChild(root, .{ .splitter = .{
        .direction = .row,
        .ratio = state.domain.model.nav_ratio,
        .min_first = uiPx(state, 220),
        .min_second = uiPx(state, 420),
        .thickness = uiPx(state, 8),
        .gap_thickness = 1,
    } });
    try identifyFixed(ctx, nav_splitter, .nav_splitter);
    _ = ctx.setStyle(nav_splitter, fileManagerGutterStyle(state));

    const sidebar = try ctx.tree.addChild(nav_splitter, .{ .container = .{ .direction = .column } });
    _ = ctx.setStyle(sidebar, fileManagerPaneStyle(state, fileManagerSidebarColor()));
    const sidebar_header = try ctx.tree.addChild(sidebar, .{ .toolbar = .{} });
    _ = ctx.setStyle(sidebar_header, fileManagerPaneHeaderStyle(state));
    _ = try ctx.tree.addChild(sidebar_header, .{ .text = .{ .content = "Browse" } });

    const sidebar_scroll = try ctx.tree.addChild(sidebar, .{ .scroll_area = .{
        .scroll_x = state.domain.model.sidebar_scroll_x,
        .scroll_y = state.domain.model.sidebar_scroll_y,
    } });
    try identifyFixed(ctx, sidebar_scroll, .sidebar_scroll);
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
    for (state.domain.model.places.items) |place| {
        const handle = try ctx.tree.addChild(places_list, .{ .selectable = .{
            .label = place.label,
            .selected = std.mem.eql(u8, place.path, state.domain.model.current_dir),
        } });
        _ = ctx.setStyle(handle, fileManagerPlaceItemStyle(state));
        ctx.tree.setDropTarget(handle, true);
        try identify(ctx, handle, try state.identities.idForPath(.place, place.path), null);
    }

    const folders_label = try ctx.tree.addChild(sidebar_content, .{ .text = .{ .content = "Folders" } });
    _ = ctx.setStyle(folders_label, fileManagerSectionLabelStyle(state));
    try buildFolderTree(state, ctx, sidebar_content);

    const content_host = try ctx.tree.addChild(nav_splitter, .{ .container = .{ .direction = .column } });
    _ = ctx.setStyle(content_host, fileManagerPaneStyle(state, transparent));
    return content_host;
}

fn buildInspectorPanels(state: *Scope, ctx: *goop.Context, content_host: goop.NodeHandle) !InspectorPanels {
    if (!state.domain.model.show_preview and !state.domain.model.show_info) {
        const file_panel = try ctx.tree.addChild(content_host, .{ .container = .{ .direction = .column } });
        _ = ctx.setStyle(file_panel, fileManagerPaneStyle(state, fileManagerSurfaceColor()));
        return .{ .file_panel = file_panel };
    }

    const detail_splitter = try ctx.tree.addChild(content_host, .{ .splitter = .{
        .direction = .row,
        .ratio = state.domain.model.detail_ratio,
        .min_first = uiPx(state, 360),
        .min_second = uiPx(state, 300),
        .thickness = uiPx(state, 8),
        .gap_thickness = 1,
    } });
    try identifyFixed(ctx, detail_splitter, .detail_splitter);
    _ = ctx.setStyle(detail_splitter, fileManagerGutterStyle(state));

    const file_panel = try ctx.tree.addChild(detail_splitter, .{ .container = .{ .direction = .column } });
    _ = ctx.setStyle(file_panel, fileManagerPaneStyle(state, fileManagerSurfaceColor()));
    const inspector_host = try ctx.tree.addChild(detail_splitter, .{ .container = .{ .direction = .column } });
    _ = ctx.setStyle(inspector_host, fileManagerPaneStyle(state, fileManagerSidebarColor()));

    if (state.domain.model.show_preview and state.domain.model.show_info) {
        const preview_splitter = try ctx.tree.addChild(inspector_host, .{ .splitter = .{
            .direction = .column,
            .ratio = state.domain.model.preview_ratio,
            .min_first = uiPx(state, 180),
            .min_second = uiPx(state, 180),
            .thickness = uiPx(state, 8),
            .gap_thickness = 1,
        } });
        try identifyFixed(ctx, preview_splitter, .preview_splitter);
        _ = ctx.setStyle(preview_splitter, fileManagerGutterStyle(state));
        const preview_panel = try ctx.tree.addChild(preview_splitter, .{ .container = .{ .direction = .column } });
        _ = ctx.setStyle(preview_panel, fileManagerPaneStyle(state, fileManagerSidebarColor()));
        const detail_panel = try ctx.tree.addChild(preview_splitter, .{ .container = .{ .direction = .column } });
        _ = ctx.setStyle(detail_panel, fileManagerPaneStyle(state, fileManagerSidebarColor()));
        return .{ .file_panel = file_panel, .preview_panel = preview_panel, .detail_panel = detail_panel };
    }

    return .{
        .file_panel = file_panel,
        .preview_panel = if (state.domain.model.show_preview) inspector_host else null,
        .detail_panel = if (state.domain.model.show_info) inspector_host else null,
    };
}

fn buildBreadcrumbBar(state: *Scope, ctx: *goop.Context, file_panel: goop.NodeHandle) !void {
    const breadcrumb_bar = try ctx.tree.addChild(file_panel, .{ .toolbar = .{} });
    _ = ctx.setStyle(breadcrumb_bar, fileManagerPaneHeaderStyle(state));
    const root_button = try ctx.tree.addChild(breadcrumb_bar, .{ .button = .{ .label = "/" } });
    _ = ctx.setStyle(root_button, fileManagerToolbarButtonStyle(state, false, true));
    ctx.tree.setDropTarget(root_button, true);
    try identify(ctx, root_button, try state.identities.idForPath(.breadcrumb, "/"), null);
    try projection.trackPath(&state.projection.assets.breadcrumb_paths, "/");
    if (std.mem.eql(u8, state.domain.model.current_dir, "/")) return;

    var start: usize = 1;
    while (start < state.domain.model.current_dir.len) {
        const end = std.mem.indexOfScalarPos(u8, state.domain.model.current_dir, start, '/') orelse state.domain.model.current_dir.len;
        _ = try ctx.tree.addChild(breadcrumb_bar, .{ .text = .{ .content = "/" } });
        const segment = state.domain.model.current_dir[start..end];
        const handle = try ctx.tree.addChild(breadcrumb_bar, .{ .button = .{ .label = try allocUiUtf8Lossy(state, segment) } });
        _ = ctx.setStyle(handle, fileManagerToolbarButtonStyle(state, false, true));
        ctx.tree.setDropTarget(handle, true);
        const path = state.domain.model.current_dir[0..end];
        try identify(ctx, handle, try state.identities.idForPath(.breadcrumb, path), null);
        try projection.trackPath(&state.projection.assets.breadcrumb_paths, path);
        start = end + 1;
    }
}

fn buildPreviewPanel(state: *Scope, ctx: *goop.Context, panel: goop.NodeHandle, transparent: goop.Color) !void {
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
    const prepared = state.domain.presentation.preview;
    if (prepared.image) |pixels| {
        const preview_width = uiPx(state, 260);
        const aspect = @as(f32, @floatFromInt(pixels.height)) /
            @as(f32, @floatFromInt(pixels.width));
        const preview_height = @min(preview_width * aspect, uiPx(state, 320));
        const image_node = try ctx.tree.addChild(preview_content, .{ .custom = .{
            .type_id = @intFromEnum(ids.Fixed.preview_image),
            .width = preview_width,
            .height = preview_height,
            .grow_width = true,
        } });
        try identifyFixed(ctx, image_node, .preview_image);
    }
    const preview_text = try allocUiWrappedText(
        state,
        prepared.text orelse if (prepared.image == null) "Preview unavailable." else "",
        previewBodyFontSizePx(state),
    );
    const preview_text_parent = if (prepared.framed) blk: {
        const preview_frame = try ctx.tree.addChild(preview_content, .{ .container = .{ .direction = .column } });
        _ = ctx.setStyle(preview_frame, fileManagerPreviewFrameStyle(state));
        break :blk preview_frame;
    } else preview_content;
    if (preview_text.len > 0) {
        _ = try addStyledDetailText(
            ctx,
            preview_text_parent,
            preview_text,
            .wrap,
            fileManagerPreviewBodyStyle(state),
        );
    }
}

fn addSingleSelectionDetails(state: *Scope, ctx: *goop.Context, detail_content: goop.NodeHandle) !void {
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

fn addMultiSelectionDetails(state: *Scope, ctx: *goop.Context, detail_content: goop.NodeHandle, summary: BrowserSummary) !void {
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

    if (state.domain.model.selected_path) |selected_path| {
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

fn addDirectoryDetails(state: *Scope, ctx: *goop.Context, detail_content: goop.NodeHandle, summary: BrowserSummary) !void {
    const directory_name = if (std.mem.eql(u8, state.domain.model.current_dir, "/")) "/" else std.fs.path.basename(state.domain.model.current_dir);
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
            state.domain.model.entries.items.len,
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
            sortColumnLabel(state.domain.model.sort_column),
            sortDirectionLabel(state.domain.model.sort_direction),
            if (state.domain.model.sort_directories_together) ", directories together" else "",
            browserViewModeLabel(state.domain.model.view_mode),
        }),
        .wrap,
        fileManagerDetailMetaStyle(state),
    );
    const current_path_line = try std.fmt.allocPrint(allocator, "Path: {f}", .{std.unicode.fmtUtf8(state.domain.model.current_dir)});
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

fn buildDetailPanel(state: *Scope, ctx: *goop.Context, panel: goop.NodeHandle, transparent: goop.Color, summary: BrowserSummary) !void {
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

fn buildStatusBar(state: *Scope, ctx: *goop.Context, root: goop.NodeHandle, summary: BrowserSummary) !void {
    if (!state.domain.model.show_status_bar) return;

    const status_bar = try ctx.tree.addChild(root, .{ .status_bar = .{} });
    _ = ctx.setStyle(status_bar, fileManagerToolbarStyle(state));
    if (state.domain.interaction.status_note) |note| {
        const handle = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = note } });
        _ = ctx.setStyle(handle, fileManagerStatusTextStyle(state));
    }
    {
        const handle = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "{d} items", .{state.domain.model.entries.items.len}) } });
        _ = ctx.setStyle(handle, fileManagerStatusTextStyle(state));
    }
    {
        const handle = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "{d} selected", .{summary.selected_count}) } });
        _ = ctx.setStyle(handle, fileManagerStatusTextStyle(state));
    }
    {
        const handle = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "View: {s}", .{browserViewModeLabel(state.domain.model.view_mode)}) } });
        _ = ctx.setStyle(handle, fileManagerStatusTextStyle(state));
    }
    {
        const handle = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "Path: {f}", .{std.unicode.fmtUtf8(state.domain.model.current_dir)}) } });
        _ = ctx.setStyle(handle, fileManagerStatusTextStyle(state));
    }
}

// -- Widget tree composition --

fn buildTree(state: *Scope, ctx: *goop.Context) !void {
    const transparent = goop.Color.rgba(0, 0, 0, 0);

    captureFilePanelViewport(state, ctx);
    if (find(ctx, ids.fixed(.root))) |root| try ctx.tree.remove(root);
    if (find(ctx, ids.fixed(.context_popup))) |popup| try ctx.tree.remove(popup);
    clearUiTracking(state);

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    try identifyFixed(ctx, root, .root);
    _ = ctx.setStyle(root, fileManagerShellStyle(state));

    const summary = summarizeBrowser(state);
    try buildTopMenu(state, ctx, root);
    try buildToolbar(state, ctx, root);

    const content_host = try buildContentHost(state, ctx, root, transparent);
    const panels = try buildInspectorPanels(state, ctx, content_host);

    try buildBreadcrumbBar(state, ctx, panels.file_panel);
    if (state.domain.model.view_mode == .list) {
        try buildListHeaderTable(state, ctx, panels.file_panel);
    }

    const file_panel_scroll = try ctx.tree.addChild(panels.file_panel, .{ .scroll_area = .{ .scroll_y = state.domain.model.file_panel_scroll_y } });
    try identifyFixed(ctx, file_panel_scroll, .file_panel_scroll);
    _ = ctx.setStyle(file_panel_scroll, .{
        .bg = transparent,
        .border_width = 0,
        .padding = uiEdgesAll(state, 0),
        .border_radius = 0,
    });
    try buildAssetView(state, ctx, file_panel_scroll);

    if (panels.preview_panel) |panel| {
        try buildPreviewPanel(state, ctx, panel, transparent);
    }
    if (panels.detail_panel) |panel| {
        try buildDetailPanel(state, ctx, panel, transparent, summary);
    }
    try buildStatusBar(state, ctx, root, summary);
    try buildContextPopup(state, ctx);
}

fn scope(input: capabilities.ViewInput, output: capabilities.ViewOutput) Scope {
    return .{
        .viewport = input.viewport,
        .domain = .{
            .model = input.model,
            .interaction = input.interaction,
            .presentation = input.presentation,
        },
        .projection = output.projection,
        .identities = output.identities,
    };
}

/// Project borrowed browser data into a goop widget tree.
pub fn buildWidgetTree(
    input: capabilities.ViewInput,
    output: capabilities.ViewOutput,
    ctx: *goop.Context,
) !void {
    var state = scope(input, output);
    try buildTree(&state, ctx);
}

/// Refresh only the virtualized asset projection after layout or scrolling.
pub fn refreshAssetViewportIfNeeded(
    input: capabilities.ViewInput,
    output: capabilities.ViewOutput,
    ctx: *goop.Context,
) !bool {
    var state = scope(input, output);
    return refreshAssetViewport(&state, ctx);
}

pub fn debugLogLayout(
    input: capabilities.ViewInput,
    output: capabilities.ViewOutput,
    ctx: *goop.Context,
) void {
    var state = scope(input, output);
    debugLogFilePanelLayout(&state, ctx);
}
