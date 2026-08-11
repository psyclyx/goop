const std = @import("std");
const widget = @import("../widget.zig");
const hittest = @import("../hittest.zig");
const types = @import("types.zig");
const tree_util = @import("tree.zig");
const items = @import("drag/items.zig");
const marquee = @import("drag/marquee.zig");

const MouseState = types.MouseState;

pub const beginTreeDrag = items.beginTreeDrag;
pub const updateTreeDragPreview = items.updateTreeDragPreview;
pub const finalizeTreeDrag = items.finalizeTreeDrag;
pub const clearTreeDragPreview = items.clearTreeDragPreview;
pub const updateTreeDragGhostRect = items.updateTreeDragGhostRect;
pub const beginSelectableDrag = items.beginSelectableDrag;
pub const updateSelectableDragPreview = items.updateSelectableDragPreview;
pub const finalizeSelectableDrag = items.finalizeSelectableDrag;
pub const clearListDragPreview = items.clearListDragPreview;
pub const updateSelectableDragGhostRect = items.updateSelectableDragGhostRect;
pub const beginGridItemDrag = items.beginGridItemDrag;
pub const updateGridItemDragPreview = items.updateGridItemDragPreview;
pub const finalizeGridItemDrag = items.finalizeGridItemDrag;
pub const clearGridDragPreview = items.clearGridDragPreview;
pub const updateGridItemDragGhostRect = items.updateGridItemDragGhostRect;
pub const beginTableRowDrag = items.beginTableRowDrag;
pub const updateTableRowDragPreview = items.updateTableRowDragPreview;
pub const finalizeTableRowDrag = items.finalizeTableRowDrag;
pub const clearTableDragPreview = items.clearTableDragPreview;
pub const updateTableRowDragGhostRect = items.updateTableRowDragGhostRect;
pub const treeDropPositionAtY = items.treeDropPositionAtY;

pub const beginListBoxMarquee = marquee.beginListBoxMarquee;
pub const updateListBoxMarquee = marquee.updateListBoxMarquee;
pub const cancelListBoxMarquee = marquee.cancelListBoxMarquee;
pub const finalizeListBoxMarquee = marquee.finalizeListBoxMarquee;
pub const snapshotListBoxSelection = marquee.snapshotListBoxSelection;
pub const beginGridSelectorMarquee = marquee.beginGridSelectorMarquee;
pub const updateGridSelectorMarquee = marquee.updateGridSelectorMarquee;
pub const cancelGridSelectorMarquee = marquee.cancelGridSelectorMarquee;
pub const finalizeGridSelectorMarquee = marquee.finalizeGridSelectorMarquee;
pub const snapshotGridSelectorSelection = marquee.snapshotGridSelectorSelection;
pub const beginTableMarquee = marquee.beginTableMarquee;
pub const updateTableMarquee = marquee.updateTableMarquee;
pub const cancelTableMarquee = marquee.cancelTableMarquee;
pub const finalizeTableMarquee = marquee.finalizeTableMarquee;
pub const snapshotTableSelection = marquee.snapshotTableSelection;

pub fn maybeBeginDeferredDrag(tree: *widget.Tree, mouse: *MouseState) void {
    if (!mouse.left_down or mouse.drag_target != null or !mouse.press_can_defer_drag) return;
    const target = mouse.press_target orelse return;
    if (!tree.isAlive(target)) return;

    const dx = mouse.x - mouse.press_origin_x;
    const dy = mouse.y - mouse.press_origin_y;
    if (dx * dx + dy * dy < MouseState.drag_threshold * MouseState.drag_threshold) return;

    dragKindOps(tree.getConst(target).kind).begin_deferred(tree, target, mouse);
}

pub fn beginDragValueScrub(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    if (!tree.isAlive(handle) or tree.getConst(handle).kind != .drag_value) return;
    mouse.press_can_defer_drag = false;
    mouse.drag_target = handle;
    mouse.drag_origin_x = mouse.press_origin_x;
    mouse.drag_origin_y = mouse.press_origin_y;
    mouse.drag_origin_value = tree.getConst(handle).kind.drag_value.value;
}

pub fn dragSourceCanDrop(kind: widget.WidgetKind) bool {
    return dragKindOps(kind).can_drop;
}

const DragKindOps = struct {
    begin_deferred: BeginDeferredDragFn = beginDeferredDragNoop,
    can_drop: bool = false,
};

const BeginDeferredDragFn = *const fn (*widget.Tree, widget.NodeHandle, *MouseState) void;

fn dragKindOps(kind: widget.WidgetKind) DragKindOps {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return drag_kind_ops[@intFromEnum(tag)];
}

const drag_kind_ops = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var ops: [std.meta.fields(Tag).len]DragKindOps = undefined;
    for (&ops) |*op| op.* = .{};
    ops[@intFromEnum(Tag.tree_item)] = .{
        .begin_deferred = beginTreeDrag,
        .can_drop = true,
    };
    ops[@intFromEnum(Tag.selectable)] = .{
        .begin_deferred = beginSelectableDrag,
        .can_drop = true,
    };
    ops[@intFromEnum(Tag.list_box)] = .{ .begin_deferred = beginListBoxMarquee };
    ops[@intFromEnum(Tag.grid_item)] = .{
        .begin_deferred = beginGridItemDrag,
        .can_drop = true,
    };
    ops[@intFromEnum(Tag.drag_value)] = .{ .begin_deferred = beginDragValueScrub };
    ops[@intFromEnum(Tag.grid_selector)] = .{ .begin_deferred = beginGridSelectorMarquee };
    ops[@intFromEnum(Tag.table_row)] = .{
        .begin_deferred = beginTableRowDrag,
        .can_drop = true,
    };
    ops[@intFromEnum(Tag.table)] = .{ .begin_deferred = beginTableMarquee };
    break :blk ops;
};

fn beginDeferredDragNoop(_: *widget.Tree, _: widget.NodeHandle, _: *MouseState) void {}

pub fn updateWidgetDropPreview(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    clearWidgetDropPreview(tree);
    mouse.widget_drop_preview = null;

    if (!tree.isAlive(source) or !dragSourceCanDrop(tree.getConst(source).kind)) return;
    const target = dropTargetAtPoint(tree, source, mouse.x, mouse.y) orelse return;
    tree.get(target).interaction.drop_hovered = true;
    mouse.widget_drop_preview = .{
        .source = source,
        .target = target,
        .x = mouse.x,
        .y = mouse.y,
        .ctrl_down = mouse.ctrl_down,
        .shift_down = mouse.shift_down,
    };
}

pub fn finalizeWidgetDrop(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    if (mouse.widget_drop_preview) |preview| {
        if (preview.source.eql(source)) {
            mouse.commitDrop(tree, .{ .widget = preview });
        }
    }
    clearWidgetDropPreview(tree);
    mouse.widget_drop_preview = null;
}

pub fn clearWidgetDropPreview(tree: *widget.Tree) void {
    for (tree.nodes.items) |*node| {
        if (!node.alive) continue;
        node.interaction.drop_hovered = false;
    }
}

pub fn dropTargetAtPoint(tree: *const widget.Tree, source: widget.NodeHandle, x: f32, y: f32) ?widget.NodeHandle {
    if (hittest.hitTest(tree, x, y)) |hit| {
        var current: ?widget.NodeHandle = hit;
        while (current) |handle| {
            if (validDropTarget(tree, source, handle)) return handle;
            current = tree.getConst(handle).parent;
        }
    }

    var index = tree.nodes.items.len;
    while (index > 0) {
        index -= 1;
        const node = tree.nodes.items[index];
        if (!node.alive) continue;
        const handle = tree.handleFromIndex(@intCast(index));
        if (!validDropTarget(tree, source, handle)) continue;
        if (hittest.pointInRect(x, y, node.layout_rect)) return handle;
    }

    return null;
}

pub fn validDropTarget(tree: *const widget.Tree, source: widget.NodeHandle, target: widget.NodeHandle) bool {
    if (!tree.isAlive(target) or target.eql(source) or tree_util.isDescendantOf(tree, target, source)) return false;
    return tree.getConst(target).interaction.accepts_drop;
}
