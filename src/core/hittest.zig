const std = @import("std");
const widget = @import("widget.zig");
const paint = @import("paint.zig");
const style = @import("style.zig");
const geometry = @import("geometry.zig");

const HitState = struct {
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    clip: ?paint.Rect = null,
};

/// Find the topmost interactive widget at (x, y), giving floating popup
/// subtrees precedence over the regular layout tree.
pub fn hitTest(tree: *const widget.Tree, x: f32, y: f32) ?widget.NodeHandle {
    var result: ?widget.NodeHandle = null;

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive or node.parent != null or node.kind == .popup or node.kind == .tooltip) continue;
        if (hitTestSubtree(tree, tree.handleFromIndex(@intCast(i)), x, y, null, false, .{})) |found| {
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
        if (!node.alive or node.parent != null or node.kind == .popup or node.kind == .tooltip) continue;
        if (hitTestSubtree(tree, tree.handleFromIndex(@intCast(i)), x, y, kind_tag, false, .{})) |found| {
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
        .list_box,
        .selectable,
        .grid_selector,
        .grid_item,
        .table,
        .table_row,
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
        .custom,
        => true,
        .text, .table_cell, .toolbar, .status_bar, .menu_bar, .tooltip, .tab_bar, .spacer => false,
    };
}

pub fn pointInRect(x: f32, y: f32, rect: paint.Rect) bool {
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
        return hitTestSubtree(tree, handle, x, y, kind_tag, true, .{});
    }
    if (node.kind == .tooltip) return null;

    var result: ?widget.NodeHandle = null;
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (node.kind == .tree_item and !node.kind.tree_item.expanded and tree.getConst(child).kind != .popup and tree.getConst(child).kind != .tooltip) continue;
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
    state: HitState,
) ?widget.NodeHandle {
    if (!isVisible(tree, handle)) return null;
    const node = tree.getConst(handle);
    if (!in_floating_subtree and (node.kind == .popup or node.kind == .tooltip)) return null;
    if (state.clip) |clip| {
        if (!pointInRect(x, y, clip)) return null;
    }

    var result: ?widget.NodeHandle = null;
    if ((kind_tag == null or node.kind == kind_tag.?) and isInteractive(node.kind) and pointHitsWidget(tree, handle, x, y, state)) {
        result = handle;
    }

    const child_state = childHitState(node, state);
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (!in_floating_subtree and (tree.getConst(child).kind == .popup or tree.getConst(child).kind == .tooltip)) continue;
        if (node.kind == .tree_item and !node.kind.tree_item.expanded and tree.getConst(child).kind != .popup and tree.getConst(child).kind != .tooltip) continue;
        if (node.kind == .tab_item and !node.kind.tab_item.selected) continue;
        if (hitTestSubtree(tree, child, x, y, kind_tag, in_floating_subtree, child_state)) |found| {
            result = found;
        }
    }
    return result;
}

fn isVisible(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    return switch (node.kind) {
        .popup => popupVisible(tree, handle),
        .tooltip => tooltipVisible(tree, handle),
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

fn tooltipVisible(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    const owner_handle = node.parent orelse return false;
    const owner = tree.getConst(owner_handle);
    return (owner.interaction.hovered or owner.interaction.focused) and node.layout_rect.w > 0 and node.layout_rect.h > 0;
}

fn pointHitsWidget(tree: *const widget.Tree, handle: widget.NodeHandle, x: f32, y: f32, state: HitState) bool {
    const node = tree.getConst(handle);
    const local_x = x - state.offset_x;
    const local_y = y - state.offset_y;
    return switch (node.kind) {
        .table => pointInRect(local_x, local_y, node.layout_rect),
        .table_row => widget.tableRowSelectable(tree, handle) and pointInRect(local_x, local_y, node.layout_rect),
        .splitter => {
            const resolved = node.style_override.resolve(style.Theme.default);
            const divider = geometry.splitterDividerRect(node.layout_rect, node.kind.splitter, resolved);
            return pointInRect(local_x, local_y, geometry.splitterHandleRect(divider, node.kind.splitter));
        },
        else => pointInRect(local_x, local_y, node.layout_rect),
    };
}

fn childHitState(node: *const widget.Node, state: HitState) HitState {
    if (node.kind != .scroll_area) return state;

    const scroll = node.kind.scroll_area;
    const node_rect = translatedRect(node.layout_rect, state);
    return .{
        .offset_x = state.offset_x - scroll.effectiveScrollX(),
        .offset_y = state.offset_y - scroll.effectiveScrollY(),
        .clip = if (state.clip) |clip| intersectRects(clip, node_rect) else node_rect,
    };
}

fn translatedRect(rect: paint.Rect, state: HitState) paint.Rect {
    return .{
        .x = rect.x + state.offset_x,
        .y = rect.y + state.offset_y,
        .w = rect.w,
        .h = rect.h,
    };
}

fn intersectRects(a: paint.Rect, b: paint.Rect) paint.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{
        .x = x0,
        .y = y0,
        .w = @max(x1 - x0, 0),
        .h = @max(y1 - y0, 0),
    };
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

test "scroll area hit testing follows visual child offset" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{ .scroll_y = 40 } });
    const button = try tree.addChild(scroll, .{ .button = .{ .label = "Scrolled" } });

    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 200, .h = 80 };
    tree.get(button).layout_rect = .{ .x = 10, .y = 60, .w = 100, .h = 24 };

    try std.testing.expect(hitTest(&tree, 20, 30).?.eql(button));
    try std.testing.expect(hitTestKind(&tree, 20, 30, .button).?.eql(button));
    try std.testing.expect(hitTestKind(&tree, 20, 70, .button) == null);
}

test "scroll area clips hit testing to viewport" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{ .scroll_y = 40 } });
    const button = try tree.addChild(scroll, .{ .button = .{ .label = "Clipped" } });

    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 200, .h = 40 };
    tree.get(button).layout_rect = .{ .x = 10, .y = 70, .w = 100, .h = 24 };

    try std.testing.expect(hitTestKind(&tree, 20, 35, .button).?.eql(button));
    try std.testing.expect(hitTestKind(&tree, 20, 45, .button) == null);
}
