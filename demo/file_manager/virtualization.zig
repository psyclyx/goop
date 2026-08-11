//! Pure list/grid virtualization math for the file-browser projection.

const std = @import("std");
const goop = @import("goop");
const state = @import("state.zig");
const style = @import("style.zig");
const types = @import("types.zig");

pub const Metrics = struct {
    ui_scale: f32 = 1,
    text_measure_ctx: ?*const goop.TextMeasureCtx = null,
};

pub fn gap(metrics: Metrics) f32 {
    return style.uiPx(metrics.ui_scale, 6);
}

pub fn listRowHeight(metrics: Metrics) f32 {
    const theme = style.fileManagerThemeForScale(metrics.ui_scale);
    const text_metrics = goop.layout.textMetrics(theme.font_size, metrics.text_measure_ctx);
    return text_metrics.height + theme.padding.top + theme.padding.bottom;
}

pub fn gridColumns(metrics: Metrics, viewport_width: f32) usize {
    const padding = style.uiPx(metrics.ui_scale, types.browser_grid_padding_h);
    const item_width = style.uiPx(metrics.ui_scale, types.browser_grid_item_width);
    const column_gap = style.uiPx(metrics.ui_scale, types.browser_grid_column_gap);
    const inner_width = @max(viewport_width - padding * 2, item_width);
    const slot_width = item_width + column_gap;
    return @max(@as(usize, @intFromFloat(@floor((inner_width + column_gap) / slot_width))), 1);
}

pub fn visibleCount(viewport_extent: f32, slot_extent: f32) usize {
    return @max(@as(usize, @intFromFloat(@ceil(viewport_extent / slot_extent))), 1);
}

pub fn chunkRows(visible_count: usize) usize {
    return @max(visible_count, types.browser_virtual_chunk_rows_min);
}

pub fn range(total_items: usize, visible_start: usize, visible_count: usize) struct { start: usize, end: usize } {
    if (total_items == 0) return .{ .start = 0, .end = 0 };

    const chunk_rows = chunkRows(visible_count);
    const render_count = @min(total_items, visible_count + chunk_rows + types.browser_overscan_rows * 2);
    if (render_count >= total_items) return .{ .start = 0, .end = total_items };

    const chunk_origin = (visible_start / chunk_rows) * chunk_rows;
    var start = chunk_origin -| types.browser_overscan_rows;
    if (start + render_count > total_items) start = total_items - render_count;
    return .{ .start = start, .end = start + render_count };
}

pub fn listWindow(
    model: *const state.Model,
    metrics: Metrics,
    viewport_height: f32,
    requested_scroll_y: f32,
) types.ListVirtualWindow {
    const total_entries = model.entries.items.len;
    if (total_entries == 0) return .{};

    const row_height = listRowHeight(metrics);
    const virtual_gap = gap(metrics);
    const total_height = row_height * @as(f32, @floatFromInt(total_entries));
    const scroll_y = std.math.clamp(requested_scroll_y, 0, @max(total_height - viewport_height, 0));
    const visible_start = @min(total_entries, @as(usize, @intFromFloat(@floor(scroll_y / row_height))));
    const visible_count = visibleCount(viewport_height, row_height);
    const visible_range = range(total_entries, visible_start, visible_count);
    const top_spacer = if (visible_range.start > 0)
        @max(row_height * @as(f32, @floatFromInt(visible_range.start)) - virtual_gap, 0)
    else
        0;
    const bottom_spacer = if (visible_range.end < total_entries)
        @max(row_height * @as(f32, @floatFromInt(total_entries - visible_range.end)) - virtual_gap, 0)
    else
        0;

    return .{
        .start = visible_range.start,
        .end = visible_range.end,
        .top_spacer = top_spacer,
        .bottom_spacer = bottom_spacer,
        .scroll_y = scroll_y,
        .content_height = total_height,
    };
}

pub fn gridWindow(
    model: *const state.Model,
    metrics: Metrics,
    viewport_width: f32,
    viewport_height: f32,
    requested_scroll_y: f32,
) types.GridVirtualWindow {
    const columns = gridColumns(metrics, viewport_width);
    const total_entries = model.entries.items.len;
    if (total_entries == 0) return .{ .columns = columns };

    const virtual_gap = gap(metrics);
    const padding_v = style.uiPx(metrics.ui_scale, types.browser_grid_padding_v);
    const item_height = style.uiPx(metrics.ui_scale, types.browser_grid_item_height);
    const row_gap = style.uiPx(metrics.ui_scale, types.browser_grid_row_gap);
    const total_rows = std.math.divCeil(usize, total_entries, columns) catch unreachable;
    const total_height = padding_v * 2 +
        item_height * @as(f32, @floatFromInt(total_rows)) +
        row_gap * @as(f32, @floatFromInt(total_rows - 1));
    const scroll_y = std.math.clamp(requested_scroll_y, 0, @max(total_height - viewport_height, 0));
    const slot_height = item_height + row_gap;
    const content_scroll_y = @max(scroll_y - padding_v, 0);
    const visible_start_row = @min(total_rows, @as(usize, @intFromFloat(@floor(content_scroll_y / slot_height))));
    const inner_viewport_height = @max(viewport_height - padding_v * 2, item_height);
    const visible_row_count = visibleCount(inner_viewport_height + row_gap, slot_height);
    const row_range = range(total_rows, visible_start_row, visible_row_count);
    const start = @min(total_entries, row_range.start * columns);
    const end = @min(total_entries, row_range.end * columns);
    const rendered_rows = row_range.end - row_range.start;
    const visible_height = item_height * @as(f32, @floatFromInt(rendered_rows)) +
        row_gap * @as(f32, @floatFromInt(if (rendered_rows > 0) rendered_rows - 1 else 0));
    const body_y = padding_v + @as(f32, @floatFromInt(row_range.start)) * slot_height;
    const remaining_height = @max(total_height - body_y - visible_height, 0);

    return .{
        .start = start,
        .end = end,
        .columns = columns,
        .top_spacer = if (body_y > 0) @max(body_y - virtual_gap, 0) else 0,
        .bottom_spacer = if (remaining_height > 0) @max(remaining_height - virtual_gap, 0) else 0,
        .scroll_y = scroll_y,
        .content_height = total_height,
    };
}
