const std = @import("std");
const widget = @import("widget.zig");
const draw = @import("draw.zig");
const style = @import("style.zig");

/// Find the topmost interactive widget at (x, y), giving floating popup
/// subtrees precedence over the regular layout tree.
pub fn hitTest(tree: *const widget.Tree, x: f32, y: f32) ?widget.NodeHandle {
    var result: ?widget.NodeHandle = null;

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive or node.parent != null or node.kind == .popup) continue;
        if (hitTestSubtree(tree, tree.handleFromIndex(@intCast(i)), x, y, null, false)) |found| {
            result = found;
        }
    }

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive or node.parent != null) continue;
        if (hitTestFloatingSubtrees(tree, tree.handleFromIndex(@intCast(i)), x, y, null)) |found| {
            result = found;
        }
    }

    return result;
}

/// Find the topmost widget of a specific kind at (x, y).
pub fn hitTestKind(tree: *const widget.Tree, x: f32, y: f32, kind_tag: std.meta.Tag(widget.WidgetKind)) ?widget.NodeHandle {
    var result: ?widget.NodeHandle = null;

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive or node.parent != null or node.kind == .popup) continue;
        if (hitTestSubtree(tree, tree.handleFromIndex(@intCast(i)), x, y, kind_tag, false)) |found| {
            result = found;
        }
    }

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive or node.parent != null) continue;
        if (hitTestFloatingSubtrees(tree, tree.handleFromIndex(@intCast(i)), x, y, kind_tag)) |found| {
            result = found;
        }
    }

    return result;
}

pub fn isInteractive(kind: widget.WidgetKind) bool {
    return switch (kind) {
        .button,
        .checkbox,
        .radio_button,
        .tree_item,
        .dropdown,
        .selectable,
        .menu,
        .popup,
        .menu_item,
        .drag_value,
        .spinbox,
        .tab_item,
        .splitter,
        .slider,
        .scroll_area,
        .container,
        .text_input,
        => true,
        .text, .list_box, .menu_bar, .tab_bar => false,
    };
}

pub fn pointInRect(x: f32, y: f32, rect: draw.Rect) bool {
    return x >= rect.x and x < rect.x + rect.w and
        y >= rect.y and y < rect.y + rect.h;
}

fn hitTestFloatingSubtrees(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    x: f32,
    y: f32,
    kind_tag: ?std.meta.Tag(widget.WidgetKind),
) ?widget.NodeHandle {
    if (!isVisible(tree, handle)) return null;
    const node = tree.getConst(handle);
    if (node.kind == .popup) {
        return hitTestSubtree(tree, handle, x, y, kind_tag, true);
    }

    var result: ?widget.NodeHandle = null;
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (node.kind == .tree_item and !node.kind.tree_item.expanded and tree.getConst(child).kind != .popup) continue;
        if (node.kind == .tab_item and !node.kind.tab_item.selected) continue;
        if (hitTestFloatingSubtrees(tree, child, x, y, kind_tag)) |found| {
            result = found;
        }
    }
    return result;
}

fn hitTestSubtree(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    x: f32,
    y: f32,
    kind_tag: ?std.meta.Tag(widget.WidgetKind),
    in_floating_subtree: bool,
) ?widget.NodeHandle {
    if (!isVisible(tree, handle)) return null;
    const node = tree.getConst(handle);
    if (!in_floating_subtree and node.kind == .popup) return null;

    var result: ?widget.NodeHandle = null;
    if ((kind_tag == null or node.kind == kind_tag.?) and isInteractive(node.kind) and pointHitsWidget(tree, handle, x, y)) {
        result = handle;
    }

    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (!in_floating_subtree and tree.getConst(child).kind == .popup) continue;
        if (node.kind == .tree_item and !node.kind.tree_item.expanded and tree.getConst(child).kind != .popup) continue;
        if (node.kind == .tab_item and !node.kind.tab_item.selected) continue;
        if (hitTestSubtree(tree, child, x, y, kind_tag, in_floating_subtree)) |found| {
            result = found;
        }
    }
    return result;
}

fn isVisible(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    return switch (node.kind) {
        .popup => popupVisible(tree, handle),
        else => node.layout_rect.w > 0 and node.layout_rect.h > 0,
    };
}

fn popupVisible(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    if (!node.kind.popup.visible) return false;
    if (node.parent) |parent_handle| {
        const parent = tree.getConst(parent_handle);
        if (parent.kind == .dropdown) {
            return parent.kind.dropdown.open and node.layout_rect.w > 0 and node.layout_rect.h > 0;
        }
    }
    return node.layout_rect.w > 0 and node.layout_rect.h > 0;
}

fn pointHitsWidget(tree: *const widget.Tree, handle: widget.NodeHandle, x: f32, y: f32) bool {
    const node = tree.getConst(handle);
    return switch (node.kind) {
        .splitter => pointInRect(x, y, splitterDividerRect(node.layout_rect, node.kind.splitter, node.style_override.resolve(style.Theme.default))),
        else => pointInRect(x, y, node.layout_rect),
    };
}

fn splitterDividerRect(rect: draw.Rect, splitter: widget.WidgetKind.Splitter, resolved: style.ResolvedStyle) draw.Rect {
    const inner = draw.Rect{
        .x = rect.x + resolved.padding.left,
        .y = rect.y + resolved.padding.top,
        .w = @max(rect.w - resolved.padding.left - resolved.padding.right, 0),
        .h = @max(rect.h - resolved.padding.top - resolved.padding.bottom, 0),
    };
    const ratio = clampedSplitterRatio(splitter, rect, resolved);
    return switch (splitter.direction) {
        .row => .{
            .x = inner.x + (inner.w - splitter.thickness) * ratio,
            .y = inner.y,
            .w = splitter.thickness,
            .h = inner.h,
        },
        .column => .{
            .x = inner.x,
            .y = inner.y + (inner.h - splitter.thickness) * ratio,
            .w = inner.w,
            .h = splitter.thickness,
        },
    };
}

fn clampedSplitterRatio(
    splitter: widget.WidgetKind.Splitter,
    rect: draw.Rect,
    resolved: style.ResolvedStyle,
) f32 {
    const raw = std.math.clamp(splitter.ratio, 0, 1);
    const available = switch (splitter.direction) {
        .row => rect.w - resolved.padding.left - resolved.padding.right - splitter.thickness,
        .column => rect.h - resolved.padding.top - resolved.padding.bottom - splitter.thickness,
    };
    if (available <= 0) return raw;

    const min_ratio = std.math.clamp(splitter.min_first / available, 0, 1);
    const max_ratio = std.math.clamp(1 - splitter.min_second / available, 0, 1);
    if (min_ratio > max_ratio) return raw;
    return std.math.clamp(raw, min_ratio, max_ratio);
}

test "floating popup subtree wins hit testing over regular content" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const button = try tree.addChild(root, .{ .button = .{ .label = "Behind" } });
    const popup = try tree.addRoot(.{ .popup = .{ .placement = .absolute, .x = 20, .y = 20 } });
    const item = try tree.addChild(popup, .{ .menu_item = .{ .label = "Front" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(button).layout_rect = .{ .x = 10, .y = 10, .w = 120, .h = 30 };
    tree.get(popup).layout_rect = .{ .x = 0, .y = 0, .w = 140, .h = 80 };
    tree.get(item).layout_rect = .{ .x = 0, .y = 0, .w = 140, .h = 30 };

    try std.testing.expect(hitTest(&tree, 30, 20).?.eql(item));
}
