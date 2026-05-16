const std = @import("std");
const widget = @import("../widget.zig");
const hittest = @import("../hittest.zig");
const style = @import("../style.zig");
const scrollbar = @import("../scrollbar.zig");
const types = @import("types.zig");

const MouseState = types.MouseState;
const ScrollbarAxis = scrollbar.Axis;

pub const ScrollbarMetrics = scrollbar.Metrics;
pub const ContentExtent = scrollbar.ContentExtent;

pub const ScrollbarHit = struct {
    handle: widget.NodeHandle,
    metrics: ScrollbarMetrics,
};

pub fn verticalScrollbarMetrics(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    theme: style.Theme,
) ?ScrollbarMetrics {
    return scrollbar.verticalMetrics(tree, handle, theme);
}

pub fn horizontalScrollbarMetrics(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    theme: style.Theme,
) ?ScrollbarMetrics {
    return scrollbar.horizontalMetrics(tree, handle, theme);
}

pub fn scrollbarMetricsForAxis(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    axis: ScrollbarAxis,
    theme: style.Theme,
) ?ScrollbarMetrics {
    return scrollbar.metricsForAxis(tree, handle, axis, theme);
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
    return scrollbar.scrollPositionForTrackPoint(metrics, x, y);
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

pub fn contentExtent(tree: *const widget.Tree, parent: widget.NodeHandle) ContentExtent {
    return scrollbar.contentExtent(tree, parent);
}

pub fn contentExtentForAppliedScroll(
    tree: *const widget.Tree,
    parent: widget.NodeHandle,
    applied_scroll_x: f32,
    applied_scroll_y: f32,
) ContentExtent {
    return scrollbar.contentExtentForAppliedScroll(tree, parent, applied_scroll_x, applied_scroll_y);
}
