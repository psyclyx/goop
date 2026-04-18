const std = @import("std");
const widget = @import("widget.zig");
const draw = @import("draw.zig");

/// Find the topmost (last in tree order) interactive widget at (x, y).
/// Skips text widgets (they don't receive interaction).
pub fn hitTest(tree: *const widget.Tree, x: f32, y: f32) ?widget.NodeHandle {
    var result: ?widget.NodeHandle = null;
    for (tree.nodes.items, 0..) |node, i| {
        if (!isInteractive(node.kind)) continue;
        if (pointInRect(x, y, node.layout_rect)) {
            result = @enumFromInt(@as(u32, @intCast(i)));
        }
    }
    return result;
}

/// Find the topmost widget of a specific kind at (x, y).
pub fn hitTestKind(tree: *const widget.Tree, x: f32, y: f32, kind_tag: std.meta.Tag(widget.WidgetKind)) ?widget.NodeHandle {
    var result: ?widget.NodeHandle = null;
    for (tree.nodes.items, 0..) |node, i| {
        if (node.kind != kind_tag) continue;
        if (pointInRect(x, y, node.layout_rect)) {
            result = @enumFromInt(@as(u32, @intCast(i)));
        }
    }
    return result;
}

pub fn isInteractive(kind: widget.WidgetKind) bool {
    return switch (kind) {
        .button, .checkbox, .radio_button, .slider, .scroll_area, .container, .text_input => true,
        .text => false,
    };
}

pub fn pointInRect(x: f32, y: f32, rect: draw.Rect) bool {
    return x >= rect.x and x < rect.x + rect.w and
        y >= rect.y and y < rect.y + rect.h;
}
