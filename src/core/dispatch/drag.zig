const widget = @import("../widget.zig");
const hittest = @import("../hittest.zig");
const paint = @import("../paint.zig");
const types = @import("types.zig");
const selection = @import("selection.zig");
const tree_util = @import("tree.zig");
const marquee = @import("drag/marquee.zig");

const MouseState = types.MouseState;

pub const beginListBoxMarquee = marquee.beginListBoxMarquee;
pub const updateListBoxMarquee = marquee.updateListBoxMarquee;
pub const finalizeListBoxMarquee = marquee.finalizeListBoxMarquee;
pub const snapshotListBoxSelection = marquee.snapshotListBoxSelection;
pub const beginGridSelectorMarquee = marquee.beginGridSelectorMarquee;
pub const updateGridSelectorMarquee = marquee.updateGridSelectorMarquee;
pub const finalizeGridSelectorMarquee = marquee.finalizeGridSelectorMarquee;
pub const snapshotGridSelectorSelection = marquee.snapshotGridSelectorSelection;
pub const beginTableMarquee = marquee.beginTableMarquee;
pub const updateTableMarquee = marquee.updateTableMarquee;
pub const finalizeTableMarquee = marquee.finalizeTableMarquee;
pub const snapshotTableSelection = marquee.snapshotTableSelection;

pub fn maybeBeginDeferredDrag(tree: *widget.Tree, mouse: *MouseState) void {
    if (!mouse.left_down or mouse.drag_target != null or !mouse.press_can_defer_drag) return;
    const target = mouse.press_target orelse return;
    if (!tree.isAlive(target)) return;

    const dx = mouse.x - mouse.press_origin_x;
    const dy = mouse.y - mouse.press_origin_y;
    if (dx * dx + dy * dy < MouseState.drag_threshold * MouseState.drag_threshold) return;

    switch (tree.getConst(target).kind) {
        .tree_item => beginTreeDrag(tree, target, mouse),
        .selectable => beginSelectableDrag(tree, target, mouse),
        .list_box => beginListBoxMarquee(tree, target, mouse),
        .grid_item => beginGridItemDrag(tree, target, mouse),
        .drag_value => beginDragValueScrub(tree, target, mouse),
        .grid_selector => beginGridSelectorMarquee(tree, target, mouse),
        .table_row => beginTableRowDrag(tree, target, mouse),
        .table => beginTableMarquee(tree, target, mouse),
        else => {},
    }
}

pub fn beginTreeDrag(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    if (!tree.isAlive(source) or tree.getConst(source).kind != .tree_item) return;
    mouse.press_can_defer_drag = false;
    clearTreeDragPreview(tree);
    mouse.drag_target = source;
    {
        const item = &tree.get(source).kind.tree_item;
        item.internal.drag.active = true;
        item.internal.drag.offset_x = mouse.press_origin_x - tree.getConst(source).layout_rect.x;
        item.internal.drag.offset_y = mouse.press_origin_y - tree.getConst(source).layout_rect.y;
    }
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
        const item = &tree.get(source).kind.tree_item;
        item.internal.drag.active = false;
        item.internal.drag.rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
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
    const source_rect = tree.getConst(source).layout_rect;
    const item = &tree.get(source).kind.tree_item;
    item.internal.drag.rect = .{
        .x = mouse.x - item.internal.drag.offset_x,
        .y = mouse.y - item.internal.drag.offset_y,
        .w = source_rect.w,
        .h = source_rect.h,
    };
}

pub fn beginSelectableDrag(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    if (!tree.isAlive(source) or tree.getConst(source).kind != .selectable) return;
    if (selection.selectableParentListBox(tree, source) == null) return;
    mouse.press_can_defer_drag = false;
    clearListDragPreview(tree);
    mouse.drag_target = source;
    {
        const item = &tree.get(source).kind.selectable;
        item.internal.drag.active = true;
        item.internal.drag.offset_x = mouse.press_origin_x - tree.getConst(source).layout_rect.x;
        item.internal.drag.offset_y = mouse.press_origin_y - tree.getConst(source).layout_rect.y;
    }
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
        const item = &tree.get(source).kind.selectable;
        item.internal.drag.active = false;
        item.internal.drag.rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
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
        switch (node.kind) {
            .list_box => node.kind.list_box.internal.drop_preview_background = false,
            .selectable => node.kind.selectable.internal.drop_preview = false,
            else => {},
        }
    }
}

pub fn updateSelectableDragGhostRect(tree: *widget.Tree, source: widget.NodeHandle, mouse: *const MouseState) void {
    const source_rect = tree.getConst(source).layout_rect;
    const item = &tree.get(source).kind.selectable;
    item.internal.drag.rect = .{
        .x = mouse.x - item.internal.drag.offset_x,
        .y = mouse.y - item.internal.drag.offset_y,
        .w = source_rect.w,
        .h = source_rect.h,
    };
}

pub fn beginGridItemDrag(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    if (!tree.isAlive(source) or tree.getConst(source).kind != .grid_item) return;
    mouse.press_can_defer_drag = false;
    clearGridDragPreview(tree);
    mouse.drag_target = source;
    {
        const item = &tree.get(source).kind.grid_item;
        item.internal.drag.active = true;
        item.internal.drag.offset_x = mouse.press_origin_x - tree.getConst(source).layout_rect.x;
        item.internal.drag.offset_y = mouse.press_origin_y - tree.getConst(source).layout_rect.y;
    }
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
        const item = &tree.get(source).kind.grid_item;
        item.internal.drag.active = false;
        item.internal.drag.rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
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
        switch (node.kind) {
            .grid_selector => node.kind.grid_selector.internal.drop_preview_background = false,
            .grid_item => node.kind.grid_item.internal.drop_preview = false,
            else => {},
        }
    }
}

pub fn updateGridItemDragGhostRect(tree: *widget.Tree, source: widget.NodeHandle, mouse: *const MouseState) void {
    const source_rect = tree.getConst(source).layout_rect;
    const item = &tree.get(source).kind.grid_item;
    item.internal.drag.rect = .{
        .x = mouse.x - item.internal.drag.offset_x,
        .y = mouse.y - item.internal.drag.offset_y,
        .w = source_rect.w,
        .h = source_rect.h,
    };
}

pub fn beginDragValueScrub(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    if (!tree.isAlive(handle) or tree.getConst(handle).kind != .drag_value) return;
    mouse.press_can_defer_drag = false;
    mouse.drag_target = handle;
    mouse.drag_origin_x = mouse.press_origin_x;
    mouse.drag_origin_y = mouse.press_origin_y;
    mouse.drag_origin_value = tree.getConst(handle).kind.drag_value.value;
}

pub fn beginTableRowDrag(tree: *widget.Tree, source: widget.NodeHandle, mouse: *MouseState) void {
    if (!tree.isAlive(source) or tree.getConst(source).kind != .table_row) return;
    if (!widget.tableRowSelectable(tree, source)) return;
    mouse.press_can_defer_drag = false;
    clearTableDragPreview(tree);
    mouse.drag_target = source;
    {
        const row = &tree.get(source).kind.table_row;
        row.internal.drag.active = true;
        row.internal.drag.offset_x = mouse.press_origin_x - tree.getConst(source).layout_rect.x;
        row.internal.drag.offset_y = mouse.press_origin_y - tree.getConst(source).layout_rect.y;
    }
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
        if (!target.eql(source) and tree.getConst(target).parent != null and tree.getConst(target).parent.?.eql(table_handle) and
            tree.getConst(target).kind == .table_row and !tree.getConst(target).kind.table_row.header)
        {
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
        const row = &tree.get(source).kind.table_row;
        row.internal.drag.active = false;
        row.internal.drag.rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
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
        switch (node.kind) {
            .table => node.kind.table.internal.drop_preview_background = false,
            .table_row => node.kind.table_row.internal.drop_preview = false,
            else => {},
        }
    }
}

pub fn updateTableRowDragGhostRect(tree: *widget.Tree, source: widget.NodeHandle, mouse: *const MouseState) void {
    const source_rect = tree.getConst(source).layout_rect;
    const row = &tree.get(source).kind.table_row;
    row.internal.drag.rect = .{
        .x = mouse.x - row.internal.drag.offset_x,
        .y = mouse.y - row.internal.drag.offset_y,
        .w = source_rect.w,
        .h = source_rect.h,
    };
}

pub fn dragSourceCanDrop(kind: widget.WidgetKind) bool {
    return switch (kind) {
        .tree_item, .selectable, .grid_item, .table_row => true,
        else => false,
    };
}

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
            mouse.last_drop = .{ .widget = preview };
            if (tree.isAlive(preview.target)) tree.get(preview.target).interaction.drop_received = true;
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

pub fn treeDropPositionAtY(rect: paint.Rect, y: f32) widget.WidgetKind.TreeItem.DropPosition {
    if (rect.h <= 0) return .into;
    const rel = (y - rect.y) / rect.h;
    if (rel <= 0.25) return .before;
    if (rel >= 0.75) return .after;
    return .into;
}
