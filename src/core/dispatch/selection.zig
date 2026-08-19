const std = @import("std");
const widget = @import("../widget.zig");
const types = @import("types.zig");

const MouseState = types.MouseState;

const SelectedFn = *const fn (*const widget.Node) bool;
const SetSelectedFn = *const fn (*widget.Node, bool) void;
const GetAnchorFn = *const fn (*const widget.Node) ?u16;
const SetAnchorFn = *const fn (*widget.Node, ?u16) void;
const ItemEligibleFn = *const fn (*const widget.Tree, widget.NodeHandle, *const widget.Node) bool;

const SelectionCollectionOps = struct {
    selected: SelectedFn,
    set_selected: SetSelectedFn,
    get_anchor: GetAnchorFn,
    set_anchor: SetAnchorFn,
    item_eligible: ItemEligibleFn,
};

fn itemIndexInContainer(
    tree: *const widget.Tree,
    container: widget.NodeHandle,
    item: widget.NodeHandle,
    ops: SelectionCollectionOps,
) ?u16 {
    var index: u16 = 0;
    var iter = tree.children(container);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (!ops.item_eligible(tree, child, child_node)) continue;
        if (child.eql(item)) return index;
        index += 1;
    }
    return null;
}

fn selectSingleInContainer(
    tree: *widget.Tree,
    container: widget.NodeHandle,
    item: widget.NodeHandle,
    ops: SelectionCollectionOps,
) bool {
    var changed = false;
    var selected_index: ?u16 = null;
    var index: u16 = 0;
    var iter = tree.children(container);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (!ops.item_eligible(tree, child, child_node)) continue;
        const should_select = child.eql(item);
        if (ops.selected(child_node) != should_select) {
            ops.set_selected(tree.get(child), should_select);
            changed = true;
        }
        if (should_select) selected_index = index;
        index += 1;
    }

    ops.set_anchor(tree.get(container), selected_index);
    return changed;
}

fn selectRangeInContainer(
    tree: *widget.Tree,
    container: widget.NodeHandle,
    start_index: u16,
    end_index: u16,
    additive: bool,
    ops: SelectionCollectionOps,
) bool {
    var changed = false;
    var index: u16 = 0;
    var iter = tree.children(container);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (!ops.item_eligible(tree, child, child_node)) continue;
        const in_range = index >= start_index and index <= end_index;
        const should_select = in_range or (additive and ops.selected(child_node));
        if (ops.selected(child_node) != should_select) {
            ops.set_selected(tree.get(child), should_select);
            changed = true;
        }
        index += 1;
    }
    return changed;
}

fn toggleInContainer(
    tree: *widget.Tree,
    container: widget.NodeHandle,
    item: widget.NodeHandle,
    ops: SelectionCollectionOps,
) bool {
    _ = container;
    const current = ops.selected(tree.getConst(item));
    ops.set_selected(tree.get(item), !current);
    return true;
}

fn clearSelectionInContainer(
    tree: *widget.Tree,
    container: widget.NodeHandle,
    ops: SelectionCollectionOps,
) bool {
    var changed = false;
    var iter = tree.children(container);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (!ops.item_eligible(tree, child, child_node)) continue;
        if (ops.selected(child_node)) {
            ops.set_selected(tree.get(child), false);
            changed = true;
        }
    }

    ops.set_anchor(tree.get(container), null);
    return changed;
}

fn selectAllInContainer(
    tree: *widget.Tree,
    container: widget.NodeHandle,
    ops: SelectionCollectionOps,
) bool {
    var changed = false;
    var last_index: ?u16 = null;
    var index: u16 = 0;
    var iter = tree.children(container);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (!ops.item_eligible(tree, child, child_node)) continue;
        if (!ops.selected(child_node)) {
            ops.set_selected(tree.get(child), true);
            changed = true;
        }
        last_index = index;
        index += 1;
    }
    if (changed) {
        ops.set_anchor(tree.get(container), last_index);
    }
    return changed;
}

fn selectMultiInContainer(
    tree: *widget.Tree,
    container: widget.NodeHandle,
    item: widget.NodeHandle,
    mouse: *const MouseState,
    ops: SelectionCollectionOps,
) bool {
    const clicked_index = itemIndexInContainer(tree, container, item, ops) orelse return false;
    const container_node = tree.get(container);

    if (mouse.shift_down) {
        const anchor = ops.get_anchor(container_node) orelse clicked_index;
        const changed = selectRangeInContainer(tree, container, @min(anchor, clicked_index), @max(anchor, clicked_index), mouse.ctrl_down, ops);
        ops.set_anchor(tree.get(container), anchor);
        return changed;
    }

    ops.set_anchor(container_node, clicked_index);
    if (mouse.ctrl_down) {
        return toggleInContainer(tree, container, item, ops);
    }

    return selectSingleInContainer(tree, container, item, ops);
}

const listSelectionOps = SelectionCollectionOps{
    .selected = selectableSelected,
    .set_selected = setSelectableSelected,
    .get_anchor = listSelectionAnchor,
    .set_anchor = setListSelectionAnchor,
    .item_eligible = selectableSelectionItem,
};

const gridSelectionOps = SelectionCollectionOps{
    .selected = gridItemSelected,
    .set_selected = setGridItemSelected,
    .get_anchor = gridSelectionAnchor,
    .set_anchor = setGridSelectionAnchor,
    .item_eligible = gridSelectionItem,
};

const tableSelectionOps = SelectionCollectionOps{
    .selected = tableRowSelected,
    .set_selected = setTableRowSelected,
    .get_anchor = tableSelectionAnchor,
    .set_anchor = setTableSelectionAnchor,
    .item_eligible = tableSelectionItem,
};

fn selectableSelected(node: *const widget.Node) bool {
    return node.kind.selectable.selected;
}

fn setSelectableSelected(node: *widget.Node, selected: bool) void {
    node.kind.selectable.selected = selected;
}

fn listSelectionAnchor(node: *const widget.Node) ?u16 {
    return node.kind.list_box.internal.anchor_index;
}

fn setListSelectionAnchor(node: *widget.Node, anchor: ?u16) void {
    node.kind.list_box.internal.anchor_index = anchor;
}

fn selectableSelectionItem(_: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node) bool {
    return node.kind == .selectable;
}

fn gridItemSelected(node: *const widget.Node) bool {
    return node.kind.grid_item.selected;
}

fn setGridItemSelected(node: *widget.Node, selected: bool) void {
    node.kind.grid_item.selected = selected;
}

fn gridSelectionAnchor(node: *const widget.Node) ?u16 {
    return node.kind.grid_selector.internal.anchor_index;
}

fn setGridSelectionAnchor(node: *widget.Node, anchor: ?u16) void {
    node.kind.grid_selector.internal.anchor_index = anchor;
}

fn gridSelectionItem(_: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node) bool {
    return node.kind == .grid_item;
}

fn tableRowSelected(node: *const widget.Node) bool {
    return node.kind.table_row.selected;
}

fn setTableRowSelected(node: *widget.Node, selected: bool) void {
    node.kind.table_row.selected = selected;
}

fn tableSelectionAnchor(node: *const widget.Node) ?u16 {
    return node.kind.table.internal.anchor_row;
}

fn setTableSelectionAnchor(node: *widget.Node, anchor: ?u16) void {
    node.kind.table.internal.anchor_row = anchor;
}

fn tableSelectionItem(_: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node) bool {
    return node.kind == .table_row and !node.kind.table_row.header;
}

pub fn selectSelectable(tree: *widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.get(handle);
    if (node.kind != .selectable) return false;

    var changed = false;
    const group = node.kind.selectable.group;

    if (group != 0) {
        for (tree.nodes.items, 0..) |*candidate, i| {
            if (!candidate.alive or candidate.kind != .selectable or candidate.kind.selectable.group != group) continue;
            const candidate_handle = tree.handleFromIndex(@intCast(i));
            const should_select = candidate_handle.eql(handle);
            if (candidate.kind.selectable.selected != should_select) {
                candidate.kind.selectable.selected = should_select;
                changed = true;
            }
        }
        return changed;
    }

    if (node.parent) |parent_handle| {
        if (tree.getConst(parent_handle).kind == .list_box) {
            return selectSingleInContainer(tree, parent_handle, handle, listSelectionOps);
        }

        var iter = tree.children(parent_handle);
        while (iter.next()) |child| {
            if (tree.getConst(child).kind != .selectable) continue;
            const should_select = child.eql(handle);
            if (tree.getConst(child).kind.selectable.selected != should_select) {
                tree.get(child).kind.selectable.selected = should_select;
                changed = true;
            }
        }
        return changed;
    }

    if (!node.kind.selectable.selected) {
        node.kind.selectable.selected = true;
        changed = true;
    }
    return changed;
}

pub fn selectGridItem(tree: *widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.get(handle);
    if (node.kind != .grid_item) return false;

    const selector = widget.gridItemParentSelector(tree, handle) orelse {
        if (!node.kind.grid_item.selected) {
            node.kind.grid_item.selected = true;
            return true;
        }
        return false;
    };

    return selectSingleInContainer(tree, selector, handle, gridSelectionOps);
}

pub fn selectGridItemsMulti(
    tree: *widget.Tree,
    selector: widget.NodeHandle,
    handle: widget.NodeHandle,
    mouse: *const MouseState,
) bool {
    return selectMultiInContainer(tree, selector, handle, mouse, gridSelectionOps);
}

pub fn selectGridRange(
    tree: *widget.Tree,
    selector: widget.NodeHandle,
    start_index: u16,
    end_index: u16,
    additive: bool,
) bool {
    return selectRangeInContainer(tree, selector, start_index, end_index, additive, gridSelectionOps);
}

pub fn toggleGridItem(tree: *widget.Tree, selector: widget.NodeHandle, handle: widget.NodeHandle) bool {
    return toggleInContainer(tree, selector, handle, gridSelectionOps);
}

pub fn clearGridSelectorSelection(tree: *widget.Tree, selector: widget.NodeHandle) bool {
    const node = tree.get(selector);
    if (node.kind != .grid_selector) return false;

    return clearSelectionInContainer(tree, selector, gridSelectionOps);
}

pub fn clearTableSelection(tree: *widget.Tree, table: widget.NodeHandle) bool {
    if (tree.getConst(table).kind != .table) return false;
    return clearSelectionInContainer(tree, table, tableSelectionOps);
}

pub fn clearListBoxSelection(tree: *widget.Tree, list_box: widget.NodeHandle) bool {
    if (tree.getConst(list_box).kind != .list_box) return false;
    return clearSelectionInContainer(tree, list_box, listSelectionOps);
}

pub fn selectAllGridSelector(tree: *widget.Tree, selector: widget.NodeHandle) bool {
    return selectAllInContainer(tree, selector, gridSelectionOps);
}

pub fn selectTableRow(tree: *widget.Tree, handle: widget.NodeHandle) bool {
    if (!widget.tableRowSelectable(tree, handle)) return false;

    const table_handle = tree.getConst(handle).parent orelse return false;
    return selectSingleInContainer(tree, table_handle, handle, tableSelectionOps);
}

pub fn selectTableRowsMulti(
    tree: *widget.Tree,
    table_handle: widget.NodeHandle,
    row_handle: widget.NodeHandle,
    mouse: *const MouseState,
) bool {
    if (!widget.tableRowSelectable(tree, row_handle)) return false;
    return selectMultiInContainer(tree, table_handle, row_handle, mouse, tableSelectionOps);
}

pub fn selectTableRowRange(
    tree: *widget.Tree,
    table_handle: widget.NodeHandle,
    start_index: u16,
    end_index: u16,
    additive: bool,
) bool {
    return selectRangeInContainer(tree, table_handle, start_index, end_index, additive, tableSelectionOps);
}

pub fn toggleTableRow(tree: *widget.Tree, table_handle: widget.NodeHandle, row_handle: widget.NodeHandle) bool {
    if (!widget.tableRowSelectable(tree, row_handle)) return false;
    return toggleInContainer(tree, table_handle, row_handle, tableSelectionOps);
}

pub fn selectListBoxMulti(
    tree: *widget.Tree,
    list_box: widget.NodeHandle,
    handle: widget.NodeHandle,
    mouse: *const MouseState,
) bool {
    const list_box_node = tree.get(list_box);
    std.debug.assert(list_box_node.kind == .list_box);
    return selectMultiInContainer(tree, list_box, handle, mouse, listSelectionOps);
}

pub fn selectListBoxRange(
    tree: *widget.Tree,
    list_box: widget.NodeHandle,
    start_index: u16,
    end_index: u16,
    additive: bool,
) bool {
    return selectRangeInContainer(tree, list_box, start_index, end_index, additive, listSelectionOps);
}

pub fn toggleListBoxSelectable(tree: *widget.Tree, list_box: widget.NodeHandle, handle: widget.NodeHandle) bool {
    return toggleInContainer(tree, list_box, handle, listSelectionOps);
}

pub fn selectableParentListBox(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    const parent_handle = tree.getConst(handle).parent orelse return null;
    if (tree.getConst(parent_handle).kind != .list_box) return null;
    return parent_handle;
}

pub fn selectableIndexInParent(tree: *const widget.Tree, handle: widget.NodeHandle) ?u16 {
    const parent_handle = tree.getConst(handle).parent orelse return null;
    return itemIndexInContainer(tree, parent_handle, handle, listSelectionOps);
}

pub fn applySelectableKeyboardNavigation(tree: *widget.Tree, target: widget.NodeHandle, mouse: *const MouseState) bool {
    if (selectableParentListBox(tree, target)) |list_box| {
        if (tree.getConst(list_box).kind.list_box.selection_mode == .multiple and mouse.shift_down) {
            return selectListBoxMulti(tree, list_box, target, mouse);
        }
    }
    return selectSelectable(tree, target);
}

pub fn applyGridItemKeyboardNavigation(tree: *widget.Tree, target: widget.NodeHandle, mouse: *const MouseState) bool {
    if (widget.gridItemParentSelector(tree, target)) |selector| {
        if (tree.getConst(selector).kind.grid_selector.selection_mode == .multiple and mouse.shift_down) {
            return selectGridItemsMulti(tree, selector, target, mouse);
        }
    }
    return selectGridItem(tree, target);
}

pub fn applyTableRowKeyboardNavigation(tree: *widget.Tree, target: widget.NodeHandle, mouse: *const MouseState) bool {
    if (!widget.tableRowSelectable(tree, target)) return false;
    const table_handle = tree.getConst(target).parent orelse return false;
    if (tree.getConst(table_handle).kind.table.selection_mode == .multiple and mouse.shift_down) {
        return selectTableRowsMulti(tree, table_handle, target, mouse);
    }
    return selectTableRow(tree, target);
}
