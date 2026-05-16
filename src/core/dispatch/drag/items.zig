const std = @import("std");
const widget = @import("../../widget.zig");
const hittest = @import("../../hittest.zig");
const paint = @import("../../paint.zig");
const types = @import("../types.zig");
const selection = @import("../selection.zig");
const tree_util = @import("../tree.zig");

const MouseState = types.MouseState;

fn beginDragState(tree: *const widget.Tree, source: widget.NodeHandle, mouse: *MouseState, drag: *widget.DragState) void {
    const source_rect = tree.getConst(source).layout_rect;
    mouse.press_can_defer_drag = false;
    mouse.drag_target = source;
    drag.active = true;
    drag.offset_x = mouse.press_origin_x - source_rect.x;
    drag.offset_y = mouse.press_origin_y - source_rect.y;
}

fn clearDragState(drag: *widget.DragState) void {
    drag.active = false;
    drag.rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}

fn updateDragGhostRect(tree: *const widget.Tree, source: widget.NodeHandle, mouse: *const MouseState, drag: *widget.DragState) void {
    const source_rect = tree.getConst(source).layout_rect;
    drag.rect = .{
        .x = mouse.x - drag.offset_x,
        .y = mouse.y - drag.offset_y,
        .w = source_rect.w,
        .h = source_rect.h,
    };
}

pub fn beginTreeDrag(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    if (!tree.isAlive(source) or tree.getConst(source).kind != .tree_item) return;
    clearTreeDragPreview(tree);
    beginDragState(tree, source, mouse, &tree.get(source).kind.tree_item.internal.drag);
    updateTreeDragPreview(tree, source, mouse);
}

pub fn updateTreeDragPreview(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    clearTreeDragPreview(tree);
    mouse.tree_drop_preview = null;

    if (!tree.isAlive(source) or tree.getConst(source).kind != .tree_item) return;
    updateTreeDragGhostRect(tree, source, mouse);
    const source_item = tree.getConst(source).kind.tree_item;
    const target = hittest.hitTestKind(tree, mouse.x, mouse.y, .tree_item) orelse return;
    if (!tree.isAlive(target) or target.eql(source) or tree_util.isDescendantOf(tree, target, source)) return;

    const target_item = tree.getConst(target).kind.tree_item;
    if (target_item.group != source_item.group) return;

    const position = treeDropPositionAtY(tree.getConst(target).layout_rect, mouse.y);
    tree.get(target).kind.tree_item.internal.drop_preview = position;
    mouse.tree_drop_preview = .{
        .source = source,
        .target = target,
        .position = position,
    };
}

pub fn finalizeTreeDrag(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    if (tree.isAlive(source) and tree.getConst(source).kind == .tree_item) {
        clearDragState(&tree.get(source).kind.tree_item.internal.drag);
    }
    if (mouse.tree_drop_preview) |preview| {
        mouse.last_drop = .{ .tree = preview };
        if (tree.isAlive(preview.target) and tree.getConst(preview.target).kind == .tree_item) {
            tree.get(preview.target).interaction.drop_received = true;
        }
    }
    clearTreeDragPreview(tree);
    mouse.tree_drop_preview = null;
}

pub fn clearTreeDragPreview(tree: *widget.Tree) void {
    for (tree.nodes.items) |*node| {
        if (!node.alive or node.kind != .tree_item) continue;
        node.kind.tree_item.internal.drop_preview = null;
    }
}

pub fn updateTreeDragGhostRect(tree: *widget.Tree, source: widget.NodeHandle, mouse: *const MouseState) void {
    updateDragGhostRect(tree, source, mouse, &tree.get(source).kind.tree_item.internal.drag);
}

pub fn beginSelectableDrag(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    if (!tree.isAlive(source) or tree.getConst(source).kind != .selectable) return;
    if (selection.selectableParentListBox(tree, source) == null) return;
    clearListDragPreview(tree);
    beginDragState(tree, source, mouse, &tree.get(source).kind.selectable.internal.drag);
    updateSelectableDragPreview(tree, source, mouse);
}

pub fn updateSelectableDragPreview(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    clearListDragPreview(tree);
    mouse.list_drop_preview = null;
    if (!tree.isAlive(source) or tree.getConst(source).kind != .selectable) return;
    updateSelectableDragGhostRect(tree, source, mouse);

    const list_box = selection.selectableParentListBox(tree, source) orelse return;
    const hovered_item = hittest.hitTestKind(tree, mouse.x, mouse.y, .selectable);
    if (hovered_item) |target| {
        if (target.eql(source)) return;
        if (selection.selectableParentListBox(tree, target)) |target_list_box| {
            if (target_list_box.eql(list_box)) {
                tree.get(target).kind.selectable.internal.drop_preview = true;
                mouse.list_drop_preview = .{
                    .source = source,
                    .target = target,
                    .position = .item,
                };
                return;
            }
        }
    }

    if (hittest.pointInRect(mouse.x, mouse.y, tree.getConst(list_box).layout_rect)) {
        tree.get(list_box).kind.list_box.internal.drop_preview_background = true;
        mouse.list_drop_preview = .{
            .source = source,
            .target = list_box,
            .position = .background,
        };
    }
}

pub fn finalizeSelectableDrag(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    if (tree.isAlive(source) and tree.getConst(source).kind == .selectable) {
        clearDragState(&tree.get(source).kind.selectable.internal.drag);
    }
    if (mouse.list_drop_preview) |preview| {
        mouse.last_drop = .{ .list = preview };
    }
    clearListDragPreview(tree);
    mouse.list_drop_preview = null;
}

pub fn clearListDragPreview(tree: *widget.Tree) void {
    for (tree.nodes.items) |*node| {
        if (!node.alive) continue;
        listPreviewClearer(node.kind)(node);
    }
}

pub fn updateSelectableDragGhostRect(tree: *widget.Tree, source: widget.NodeHandle, mouse: *const MouseState) void {
    updateDragGhostRect(tree, source, mouse, &tree.get(source).kind.selectable.internal.drag);
}

pub fn beginGridItemDrag(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    if (!tree.isAlive(source) or tree.getConst(source).kind != .grid_item) return;
    clearGridDragPreview(tree);
    beginDragState(tree, source, mouse, &tree.get(source).kind.grid_item.internal.drag);
    updateGridItemDragPreview(tree, source, mouse);
}

pub fn updateGridItemDragPreview(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    clearGridDragPreview(tree);
    mouse.grid_drop_preview = null;
    if (!tree.isAlive(source) or tree.getConst(source).kind != .grid_item) return;
    updateGridItemDragGhostRect(tree, source, mouse);

    const selector = widget.gridItemParentSelector(tree, source) orelse return;
    const hovered_item = hittest.hitTestKind(tree, mouse.x, mouse.y, .grid_item);
    if (hovered_item) |target| {
        if (target.eql(source)) return;
        if (widget.gridItemParentSelector(tree, target)) |target_selector| {
            if (target_selector.eql(selector)) {
                tree.get(target).kind.grid_item.internal.drop_preview = true;
                mouse.grid_drop_preview = .{
                    .source = source,
                    .target = target,
                    .position = .item,
                };
                return;
            }
        }
    }

    if (hittest.pointInRect(mouse.x, mouse.y, tree.getConst(selector).layout_rect)) {
        tree.get(selector).kind.grid_selector.internal.drop_preview_background = true;
        mouse.grid_drop_preview = .{
            .source = source,
            .target = selector,
            .position = .background,
        };
    }
}

pub fn finalizeGridItemDrag(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    if (tree.isAlive(source) and tree.getConst(source).kind == .grid_item) {
        clearDragState(&tree.get(source).kind.grid_item.internal.drag);
    }
    if (mouse.grid_drop_preview) |preview| {
        mouse.last_drop = .{ .grid = preview };
    }
    clearGridDragPreview(tree);
    mouse.grid_drop_preview = null;
}

pub fn clearGridDragPreview(tree: *widget.Tree) void {
    for (tree.nodes.items) |*node| {
        if (!node.alive) continue;
        gridPreviewClearer(node.kind)(node);
    }
}

pub fn updateGridItemDragGhostRect(tree: *widget.Tree, source: widget.NodeHandle, mouse: *const MouseState) void {
    updateDragGhostRect(tree, source, mouse, &tree.get(source).kind.grid_item.internal.drag);
}

pub fn beginTableRowDrag(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    if (!tree.isAlive(source) or tree.getConst(source).kind != .table_row) return;
    if (!widget.tableRowSelectable(tree, source)) return;
    clearTableDragPreview(tree);
    beginDragState(tree, source, mouse, &tree.get(source).kind.table_row.internal.drag);
    updateTableRowDragPreview(tree, source, mouse);
}

pub fn updateTableRowDragPreview(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    clearTableDragPreview(tree);
    mouse.table_drop_preview = null;
    if (!tree.isAlive(source) or tree.getConst(source).kind != .table_row) return;
    updateTableRowDragGhostRect(tree, source, mouse);

    const table_handle = tree.getConst(source).parent orelse return;
    if (tree.getConst(table_handle).kind != .table) return;

    const hovered_row = hittest.hitTestKind(tree, mouse.x, mouse.y, .table_row);
    if (hovered_row) |target| {
        if (tableRowDropTarget(tree, table_handle, source, target)) {
            tree.get(target).kind.table_row.internal.drop_preview = true;
            mouse.table_drop_preview = .{
                .source = source,
                .target = target,
                .position = .item,
            };
            return;
        }
    }

    if (hittest.pointInRect(mouse.x, mouse.y, tree.getConst(table_handle).layout_rect)) {
        tree.get(table_handle).kind.table.internal.drop_preview_background = true;
        mouse.table_drop_preview = .{
            .source = source,
            .target = table_handle,
            .position = .background,
        };
    }
}

pub fn finalizeTableRowDrag(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    if (tree.isAlive(source) and tree.getConst(source).kind == .table_row) {
        clearDragState(&tree.get(source).kind.table_row.internal.drag);
    }
    if (mouse.table_drop_preview) |preview| {
        mouse.last_drop = .{ .table = preview };
    }
    clearTableDragPreview(tree);
    mouse.table_drop_preview = null;
}

pub fn clearTableDragPreview(tree: *widget.Tree) void {
    for (tree.nodes.items) |*node| {
        if (!node.alive) continue;
        tablePreviewClearer(node.kind)(node);
    }
}

const PreviewClearer = *const fn (*widget.Node) void;

fn listPreviewClearer(kind: widget.WidgetKind) PreviewClearer {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return list_preview_clearers[@intFromEnum(tag)];
}

fn gridPreviewClearer(kind: widget.WidgetKind) PreviewClearer {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return grid_preview_clearers[@intFromEnum(tag)];
}

fn tablePreviewClearer(kind: widget.WidgetKind) PreviewClearer {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return table_preview_clearers[@intFromEnum(tag)];
}

const list_preview_clearers = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var clearers: [std.meta.fields(Tag).len]PreviewClearer = undefined;
    for (&clearers) |*clearer| clearer.* = clearPreviewNoop;
    clearers[@intFromEnum(Tag.list_box)] = clearListBoxPreview;
    clearers[@intFromEnum(Tag.selectable)] = clearSelectablePreview;
    break :blk clearers;
};

const grid_preview_clearers = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var clearers: [std.meta.fields(Tag).len]PreviewClearer = undefined;
    for (&clearers) |*clearer| clearer.* = clearPreviewNoop;
    clearers[@intFromEnum(Tag.grid_selector)] = clearGridSelectorPreview;
    clearers[@intFromEnum(Tag.grid_item)] = clearGridItemPreview;
    break :blk clearers;
};

const table_preview_clearers = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var clearers: [std.meta.fields(Tag).len]PreviewClearer = undefined;
    for (&clearers) |*clearer| clearer.* = clearPreviewNoop;
    clearers[@intFromEnum(Tag.table)] = clearTablePreview;
    clearers[@intFromEnum(Tag.table_row)] = clearTableRowPreview;
    break :blk clearers;
};

fn clearPreviewNoop(_: *widget.Node) void {}

fn clearListBoxPreview(node: *widget.Node) void {
    node.kind.list_box.internal.drop_preview_background = false;
}

fn clearSelectablePreview(node: *widget.Node) void {
    node.kind.selectable.internal.drop_preview = false;
}

fn clearGridSelectorPreview(node: *widget.Node) void {
    node.kind.grid_selector.internal.drop_preview_background = false;
}

fn clearGridItemPreview(node: *widget.Node) void {
    node.kind.grid_item.internal.drop_preview = false;
}

fn clearTablePreview(node: *widget.Node) void {
    node.kind.table.internal.drop_preview_background = false;
}

fn clearTableRowPreview(node: *widget.Node) void {
    node.kind.table_row.internal.drop_preview = false;
}

pub fn updateTableRowDragGhostRect(tree: *widget.Tree, source: widget.NodeHandle, mouse: *const MouseState) void {
    updateDragGhostRect(tree, source, mouse, &tree.get(source).kind.table_row.internal.drag);
}

fn tableRowDropTarget(
    tree: *const widget.Tree,
    table_handle: widget.NodeHandle,
    source: widget.NodeHandle,
    target: widget.NodeHandle,
) bool {
    if (target.eql(source)) return false;
    const target_node = tree.getConst(target);
    if (target_node.kind != .table_row or target_node.kind.table_row.header) return false;
    const target_parent = target_node.parent orelse return false;
    return target_parent.eql(table_handle);
}

pub fn treeDropPositionAtY(rect: paint.Rect, y: f32) widget.WidgetKind.TreeItem.DropPosition {
    if (rect.h <= 0) return .into;
    const rel = (y - rect.y) / rect.h;
    if (rel <= 0.25) return .before;
    if (rel >= 0.75) return .after;
    return .into;
}
