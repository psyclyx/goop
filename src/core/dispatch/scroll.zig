const std = @import("std");
const widget = @import("../widget.zig");
const hittest = @import("../hittest.zig");
const paint = @import("../paint.zig");
const style = @import("../style.zig");
const types = @import("types.zig");

const MouseState = types.MouseState;
const ScrollbarAxis = types.ScrollbarAxis;

pub const ScrollbarMetrics = struct {
    axis: ScrollbarAxis,
    track: paint.Rect,
    thumb: paint.Rect,
    max_scroll: f32,
};

pub const ScrollbarHit = struct {
    handle: widget.NodeHandle,
    metrics: ScrollbarMetrics,
};

pub fn verticalScrollbarMetrics(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    theme: style.Theme,
) ?ScrollbarMetrics {
    const node = tree.getConst(handle);
    if (node.kind != .scroll_area) return null;
    const scroll = node.kind.scroll_area;
    if (scroll.disable_vertical_scroll) return null;

    const viewport = node.layout_rect;
    const extent = contentExtentForAppliedScroll(tree, handle, scroll.effectiveScrollX(), scroll.effectiveScrollY());
    if (extent.h <= viewport.h + 0.01) return null;
    const has_horizontal_scrollbar = !scroll.disable_horizontal_scroll and extent.w > viewport.w + 0.01;

    const resolved = node.style_override.resolve(theme);
    const scrollbar_inset: f32 = 2;
    const track_w = @max(resolved.thumb_width * 0.5, 6);
    const horizontal_reserve = if (has_horizontal_scrollbar) track_w + scrollbar_inset else 0;
    const track = paint.Rect{
        .x = viewport.x + viewport.w - track_w - scrollbar_inset,
        .y = viewport.y + scrollbar_inset,
        .w = track_w,
        .h = @max(viewport.h - scrollbar_inset * 2 - horizontal_reserve, 0),
    };
    const max_scroll_y = @max(extent.h - viewport.h, 0);
    const thumb_h = @max(track.h * (viewport.h / extent.h), @min(resolved.thumb_width * 1.5, track.h));
    const thumb_t = if (max_scroll_y > 0)
        std.math.clamp(scroll.scroll_y / max_scroll_y, 0, 1)
    else
        0;
    const thumb_y = track.y + (track.h - thumb_h) * thumb_t;

    return .{
        .axis = .vertical,
        .track = track,
        .thumb = .{ .x = track.x, .y = thumb_y, .w = track.w, .h = thumb_h },
        .max_scroll = max_scroll_y,
    };
}

pub fn horizontalScrollbarMetrics(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    theme: style.Theme,
) ?ScrollbarMetrics {
    const node = tree.getConst(handle);
    if (node.kind != .scroll_area) return null;
    const scroll = node.kind.scroll_area;
    if (scroll.disable_horizontal_scroll) return null;

    const viewport = node.layout_rect;
    const extent = contentExtentForAppliedScroll(tree, handle, scroll.effectiveScrollX(), scroll.effectiveScrollY());
    if (extent.w <= viewport.w + 0.01) return null;
    const has_vertical_scrollbar = !scroll.disable_vertical_scroll and extent.h > viewport.h + 0.01;

    const resolved = node.style_override.resolve(theme);
    const scrollbar_inset: f32 = 2;
    const track_h = @max(resolved.thumb_width * 0.5, 6);
    const vertical_reserve = if (has_vertical_scrollbar) track_h + scrollbar_inset else 0;
    const track = paint.Rect{
        .x = viewport.x + scrollbar_inset,
        .y = viewport.y + viewport.h - track_h - scrollbar_inset,
        .w = @max(viewport.w - scrollbar_inset * 2 - vertical_reserve, 0),
        .h = track_h,
    };
    const max_scroll_x = @max(extent.w - viewport.w, 0);
    const thumb_w = @max(track.w * (viewport.w / extent.w), @min(resolved.thumb_width * 1.5, track.w));
    const thumb_t = if (max_scroll_x > 0)
        std.math.clamp(scroll.scroll_x / max_scroll_x, 0, 1)
    else
        0;
    const thumb_x = track.x + (track.w - thumb_w) * thumb_t;

    return .{
        .axis = .horizontal,
        .track = track,
        .thumb = .{ .x = thumb_x, .y = track.y, .w = thumb_w, .h = track.h },
        .max_scroll = max_scroll_x,
    };
}

pub fn scrollbarMetricsForAxis(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    axis: ScrollbarAxis,
    theme: style.Theme,
) ?ScrollbarMetrics {
    return switch (axis) {
        .vertical => verticalScrollbarMetrics(tree, handle, theme),
        .horizontal => horizontalScrollbarMetrics(tree, handle, theme),
    };
}

pub fn scrollbarHitAtPoint(
    tree: *const widget.Tree,
    x: f32,
    y: f32,
    theme: style.Theme,
) ?ScrollbarHit {
    const target = hittest.hitTestKind(tree, x, y, .scroll_area) orelse return null;
    if (verticalScrollbarMetrics(tree, target, theme)) |metrics| {
        if (hittest.pointInRect(x, y, metrics.track)) return .{ .handle = target, .metrics = metrics };
    }
    if (horizontalScrollbarMetrics(tree, target, theme)) |metrics| {
        if (hittest.pointInRect(x, y, metrics.track)) return .{ .handle = target, .metrics = metrics };
    }
    return null;
}

pub fn scrollbarTargetAtPoint(
    tree: *const widget.Tree,
    x: f32,
    y: f32,
    theme: style.Theme,
) ?widget.NodeHandle {
    return if (scrollbarHitAtPoint(tree, x, y, theme)) |hit| hit.handle else null;
}

pub fn scrollPositionForTrackPoint(metrics: ScrollbarMetrics, x: f32, y: f32) f32 {
    const usable = switch (metrics.axis) {
        .vertical => metrics.track.h - metrics.thumb.h,
        .horizontal => metrics.track.w - metrics.thumb.w,
    };
    if (usable <= 0 or metrics.max_scroll <= 0) return 0;
    const t = switch (metrics.axis) {
        .vertical => std.math.clamp((y - metrics.track.y - metrics.thumb.h * 0.5) / usable, 0, 1),
        .horizontal => std.math.clamp((x - metrics.track.x - metrics.thumb.w * 0.5) / usable, 0, 1),
    };
    return metrics.max_scroll * t;
}

pub fn updateScrollAreaDrag(
    tree: *widget.Tree,
    handle: widget.NodeHandle,
    mouse: *const MouseState,
    theme: style.Theme,
) bool {
    const metrics = scrollbarMetricsForAxis(tree, handle, mouse.scroll_drag_axis, theme) orelse return false;
    const usable = switch (metrics.axis) {
        .vertical => metrics.track.h - metrics.thumb.h,
        .horizontal => metrics.track.w - metrics.thumb.w,
    };
    if (usable <= 0 or metrics.max_scroll <= 0) return false;

    const delta_px = switch (metrics.axis) {
        .vertical => mouse.y - mouse.drag_origin_y,
        .horizontal => mouse.x - mouse.drag_origin_x,
    };
    const delta_scroll = delta_px * (metrics.max_scroll / usable);
    const next = std.math.clamp(mouse.drag_origin_value + delta_scroll, 0, metrics.max_scroll);
    const node = tree.get(handle);
    const current = switch (metrics.axis) {
        .vertical => node.kind.scroll_area.scroll_y,
        .horizontal => node.kind.scroll_area.scroll_x,
    };
    if (@abs(next - current) <= 0.01) return false;
    switch (metrics.axis) {
        .vertical => node.kind.scroll_area.scroll_y = next,
        .horizontal => node.kind.scroll_area.scroll_x = next,
    }
    return true;
}

pub fn clampScroll(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    const scroll = node.kind.scroll_area;
    const viewport = node.layout_rect;
    const extent = contentExtentForAppliedScroll(tree, handle, scroll.effectiveScrollX(), scroll.effectiveScrollY());

    const max_x = if (scroll.disable_horizontal_scroll) 0 else @max(extent.w - viewport.w, 0);
    const max_y = if (scroll.disable_vertical_scroll) 0 else @max(extent.h - viewport.h, 0);

    node.kind.scroll_area.scroll_x = std.math.clamp(node.kind.scroll_area.scroll_x, 0, max_x);
    node.kind.scroll_area.scroll_y = std.math.clamp(node.kind.scroll_area.scroll_y, 0, max_y);
}

pub fn contentExtent(tree: *const widget.Tree, parent: widget.NodeHandle) struct { w: f32, h: f32 } {
    const parent_node = tree.getConst(parent);
    const scroll = if (parent_node.kind == .scroll_area)
        parent_node.kind.scroll_area
    else
        widget.WidgetKind.ScrollArea{};
    return contentExtentForAppliedScroll(tree, parent, scroll.effectiveScrollX(), scroll.effectiveScrollY());
}

pub fn contentExtentForAppliedScroll(
    tree: *const widget.Tree,
    parent: widget.NodeHandle,
    applied_scroll_x: f32,
    applied_scroll_y: f32,
) struct { w: f32, h: f32 } {
    const parent_node = tree.getConst(parent);
    const parent_rect = parent_node.layout_rect;
    var max_x: f32 = parent_rect.x;
    var max_y: f32 = parent_rect.y;

    var iter = tree.children(parent);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .popup or tree.getConst(child).kind == .tooltip) continue;
        const r = tree.getConst(child).layout_rect;
        max_x = @max(max_x, r.x + applied_scroll_x + r.w);
        max_y = @max(max_y, r.y + applied_scroll_y + r.h);
    }

    return .{
        .w = max_x - parent_rect.x,
        .h = max_y - parent_rect.y,
    };
}
