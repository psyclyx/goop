const widget = @import("../../widget.zig");
const geometry = @import("../../geometry.zig");
const types = @import("../types.zig");

const MouseState = types.MouseState;
const Rect = geometry.Rect;

const ContainerPredicate = *const fn (*const widget.Node) bool;
const ContainerBoolSetter = *const fn (*widget.Node, bool) void;
const ContainerRectSetter = *const fn (*widget.Node, Rect) void;
const ItemPredicate = *const fn (*const widget.Node) bool;
const ItemBoolGetter = *const fn (*const widget.Node) bool;
const ItemBoolSetter = *const fn (*widget.Node, bool) void;
const MarkChangedFn = *const fn (*widget.Tree, widget.NodeHandle) void;

const MarqueeOps = struct {
    is_container: ContainerPredicate,
    can_begin: ContainerPredicate,
    active: ContainerPredicate,
    set_active: ContainerBoolSetter,
    set_rect: ContainerRectSetter,
    item_eligible: ItemPredicate,
    selected: ItemBoolGetter,
    set_selected: ItemBoolSetter,
    base_selected: ItemBoolGetter,
    set_base_selected: ItemBoolSetter,
    mark_changed: MarkChangedFn,
};

const listMarqueeOps = MarqueeOps{
    .is_container = isListBox,
    .can_begin = canBeginListBoxMarquee,
    .active = listBoxMarqueeActive,
    .set_active = setListBoxMarqueeActive,
    .set_rect = setListBoxMarqueeRect,
    .item_eligible = selectableMarqueeItem,
    .selected = selectableSelected,
    .set_selected = setSelectableSelected,
    .base_selected = selectableBaseSelected,
    .set_base_selected = setSelectableBaseSelected,
    .mark_changed = markInteractionChanged,
};

const gridMarqueeOps = MarqueeOps{
    .is_container = isGridSelector,
    .can_begin = isGridSelector,
    .active = gridSelectorMarqueeActive,
    .set_active = setGridSelectorMarqueeActive,
    .set_rect = setGridSelectorMarqueeRect,
    .item_eligible = gridItemMarqueeItem,
    .selected = gridItemSelected,
    .set_selected = setGridItemSelected,
    .base_selected = gridItemBaseSelected,
    .set_base_selected = setGridItemBaseSelected,
    .mark_changed = markInteractionChanged,
};

const tableMarqueeOps = MarqueeOps{
    .is_container = isTable,
    .can_begin = canBeginTableMarquee,
    .active = tableMarqueeActive,
    .set_active = setTableMarqueeActive,
    .set_rect = setTableMarqueeRect,
    .item_eligible = tableRowMarqueeItem,
    .selected = tableRowSelected,
    .set_selected = setTableRowSelected,
    .base_selected = tableRowBaseSelected,
    .set_base_selected = setTableRowBaseSelected,
    .mark_changed = markTableSelectionChanged,
};

pub fn beginListBoxMarquee(tree: *widget.Tree, list_box: widget.NodeHandle, mouse: *MouseState) void {
    beginMarquee(tree, list_box, mouse, listMarqueeOps);
}

pub fn updateListBoxMarquee(tree: *widget.Tree, list_box: widget.NodeHandle, mouse: *const MouseState) void {
    updateMarquee(tree, list_box, mouse, listMarqueeOps);
}

pub fn finalizeListBoxMarquee(tree: *widget.Tree, list_box: widget.NodeHandle) void {
    finalizeMarquee(tree, list_box, listMarqueeOps);
}

pub fn snapshotListBoxSelection(tree: *widget.Tree, list_box: widget.NodeHandle) void {
    snapshotMarqueeSelection(tree, list_box, listMarqueeOps);
}

pub fn beginGridSelectorMarquee(tree: *widget.Tree, selector: widget.NodeHandle, mouse: *MouseState) void {
    beginMarquee(tree, selector, mouse, gridMarqueeOps);
}

pub fn updateGridSelectorMarquee(tree: *widget.Tree, selector: widget.NodeHandle, mouse: *const MouseState) void {
    updateMarquee(tree, selector, mouse, gridMarqueeOps);
}

pub fn finalizeGridSelectorMarquee(tree: *widget.Tree, selector: widget.NodeHandle) void {
    finalizeMarquee(tree, selector, gridMarqueeOps);
}

pub fn snapshotGridSelectorSelection(tree: *widget.Tree, selector: widget.NodeHandle) void {
    snapshotMarqueeSelection(tree, selector, gridMarqueeOps);
}

pub fn beginTableMarquee(tree: *widget.Tree, table: widget.NodeHandle, mouse: *MouseState) void {
    beginMarquee(tree, table, mouse, tableMarqueeOps);
}

pub fn updateTableMarquee(tree: *widget.Tree, table: widget.NodeHandle, mouse: *const MouseState) void {
    updateMarquee(tree, table, mouse, tableMarqueeOps);
}

pub fn finalizeTableMarquee(tree: *widget.Tree, table: widget.NodeHandle) void {
    finalizeMarquee(tree, table, tableMarqueeOps);
}

pub fn snapshotTableSelection(tree: *widget.Tree, table: widget.NodeHandle) void {
    snapshotMarqueeSelection(tree, table, tableMarqueeOps);
}

fn beginMarquee(tree: *widget.Tree, container: widget.NodeHandle, mouse: *MouseState, ops: MarqueeOps) void {
    if (!tree.isAlive(container)) return;
    if (!ops.can_begin(tree.getConst(container))) return;

    mouse.press_can_defer_drag = false;
    mouse.drag_target = container;
    mouse.drag_origin_x = mouse.press_origin_x;
    mouse.drag_origin_y = mouse.press_origin_y;
    snapshotMarqueeSelection(tree, container, ops);
    ops.set_active(tree.get(container), true);
    updateMarquee(tree, container, mouse, ops);
}

fn updateMarquee(tree: *widget.Tree, container: widget.NodeHandle, mouse: *const MouseState, ops: MarqueeOps) void {
    if (!tree.isAlive(container)) return;

    const container_node = tree.getConst(container);
    if (!ops.is_container(container_node) or !ops.active(container_node)) return;

    const marquee_rect = geometry.clampRectToBounds(
        geometry.normalizedRect(mouse.drag_origin_x, mouse.drag_origin_y, mouse.x, mouse.y),
        container_node.layout_rect,
    );
    ops.set_rect(tree.get(container), marquee_rect);

    var changed = false;
    var iter = tree.children(container);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (!ops.item_eligible(child_node)) continue;
        const should_select = geometry.rectsIntersectIncludingDegenerate(marquee_rect, child_node.layout_rect) or
            (mouse.ctrl_down and ops.base_selected(child_node));
        if (ops.selected(child_node) != should_select) {
            ops.set_selected(tree.get(child), should_select);
            changed = true;
        }
    }
    if (changed) ops.mark_changed(tree, container);
}

fn finalizeMarquee(tree: *widget.Tree, container: widget.NodeHandle, ops: MarqueeOps) void {
    if (!tree.isAlive(container)) return;
    if (!ops.is_container(tree.getConst(container))) return;

    ops.set_active(tree.get(container), false);
    ops.set_rect(tree.get(container), .{ .x = 0, .y = 0, .w = 0, .h = 0 });

    var iter = tree.children(container);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (!ops.item_eligible(child_node)) continue;
        ops.set_base_selected(tree.get(child), false);
    }
}

fn snapshotMarqueeSelection(tree: *widget.Tree, container: widget.NodeHandle, ops: MarqueeOps) void {
    if (!tree.isAlive(container)) return;
    if (!ops.is_container(tree.getConst(container))) return;

    var iter = tree.children(container);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (!ops.item_eligible(child_node)) continue;
        ops.set_base_selected(tree.get(child), ops.selected(child_node));
    }
}

fn isListBox(node: *const widget.Node) bool {
    return node.kind == .list_box;
}

fn canBeginListBoxMarquee(node: *const widget.Node) bool {
    return node.kind == .list_box and node.kind.list_box.selection_mode == .multiple;
}

fn listBoxMarqueeActive(node: *const widget.Node) bool {
    return node.kind.list_box.internal.marquee_active;
}

fn setListBoxMarqueeActive(node: *widget.Node, active: bool) void {
    node.kind.list_box.internal.marquee_active = active;
}

fn setListBoxMarqueeRect(node: *widget.Node, rect: Rect) void {
    node.kind.list_box.internal.marquee_rect = rect;
}

fn selectableMarqueeItem(node: *const widget.Node) bool {
    return node.kind == .selectable;
}

fn selectableSelected(node: *const widget.Node) bool {
    return node.kind.selectable.selected;
}

fn setSelectableSelected(node: *widget.Node, selected: bool) void {
    node.kind.selectable.selected = selected;
}

fn selectableBaseSelected(node: *const widget.Node) bool {
    return node.kind.selectable.internal.marquee_base_selected;
}

fn setSelectableBaseSelected(node: *widget.Node, selected: bool) void {
    node.kind.selectable.internal.marquee_base_selected = selected;
}

fn isGridSelector(node: *const widget.Node) bool {
    return node.kind == .grid_selector;
}

fn gridSelectorMarqueeActive(node: *const widget.Node) bool {
    return node.kind.grid_selector.internal.marquee_active;
}

fn setGridSelectorMarqueeActive(node: *widget.Node, active: bool) void {
    node.kind.grid_selector.internal.marquee_active = active;
}

fn setGridSelectorMarqueeRect(node: *widget.Node, rect: Rect) void {
    node.kind.grid_selector.internal.marquee_rect = rect;
}

fn gridItemMarqueeItem(node: *const widget.Node) bool {
    return node.kind == .grid_item;
}

fn gridItemSelected(node: *const widget.Node) bool {
    return node.kind.grid_item.selected;
}

fn setGridItemSelected(node: *widget.Node, selected: bool) void {
    node.kind.grid_item.selected = selected;
}

fn gridItemBaseSelected(node: *const widget.Node) bool {
    return node.kind.grid_item.internal.marquee_base_selected;
}

fn setGridItemBaseSelected(node: *widget.Node, selected: bool) void {
    node.kind.grid_item.internal.marquee_base_selected = selected;
}

fn isTable(node: *const widget.Node) bool {
    return node.kind == .table;
}

fn canBeginTableMarquee(node: *const widget.Node) bool {
    return node.kind == .table and node.kind.table.selection_mode == .multiple;
}

fn tableMarqueeActive(node: *const widget.Node) bool {
    return node.kind.table.internal.marquee_active;
}

fn setTableMarqueeActive(node: *widget.Node, active: bool) void {
    node.kind.table.internal.marquee_active = active;
}

fn setTableMarqueeRect(node: *widget.Node, rect: Rect) void {
    node.kind.table.internal.marquee_rect = rect;
}

fn tableRowMarqueeItem(node: *const widget.Node) bool {
    return node.kind == .table_row and !node.kind.table_row.header;
}

fn tableRowSelected(node: *const widget.Node) bool {
    return node.kind.table_row.selected;
}

fn setTableRowSelected(node: *widget.Node, selected: bool) void {
    node.kind.table_row.selected = selected;
}

fn tableRowBaseSelected(node: *const widget.Node) bool {
    return node.kind.table_row.internal.marquee_base_selected;
}

fn setTableRowBaseSelected(node: *widget.Node, selected: bool) void {
    node.kind.table_row.internal.marquee_base_selected = selected;
}

fn markInteractionChanged(tree: *widget.Tree, container: widget.NodeHandle) void {
    tree.get(container).interaction.changed = true;
}

fn markTableSelectionChanged(tree: *widget.Tree, table: widget.NodeHandle) void {
    tree.get(table).kind.table.selection_changed = true;
}
