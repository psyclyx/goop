const std = @import("std");
const widget = @import("../widget.zig");
const types = @import("types.zig");

const MouseState = types.MouseState;

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
                markSelectableListBoxChanged(tree, candidate_handle);
            }
        }
        return changed;
    }

    if (node.parent) |parent_handle| {
        var iter = tree.children(parent_handle);
        var selected_index: ?u16 = null;
        var index: u16 = 0;
        while (iter.next()) |child| {
            if (tree.getConst(child).kind != .selectable) continue;
            const should_select = child.eql(handle);
            if (tree.getConst(child).kind.selectable.selected != should_select) {
                tree.get(child).kind.selectable.selected = should_select;
                changed = true;
                markSelectableListBoxChanged(tree, child);
            }
            if (should_select) selected_index = index;
            index += 1;
        }
        if (tree.getConst(parent_handle).kind == .list_box) {
            tree.get(parent_handle).kind.list_box.internal.anchor_index = selected_index;
        }
        return changed;
    }

    if (!node.kind.selectable.selected) {
        node.kind.selectable.selected = true;
        changed = true;
        markSelectableListBoxChanged(tree, handle);
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

    var changed = false;
    var selected_index: ?u16 = null;
    var index: u16 = 0;
    var iter = tree.children(selector);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .grid_item) continue;
        const should_select = child.eql(handle);
        if (tree.getConst(child).kind.grid_item.selected != should_select) {
            tree.get(child).kind.grid_item.selected = should_select;
            changed = true;
        }
        if (should_select) selected_index = index;
        index += 1;
    }

    const selector_node = tree.get(selector);
    selector_node.kind.grid_selector.internal.anchor_index = selected_index;
    if (changed) selector_node.interaction.changed = true;
    return changed;
}

pub fn selectGridItemsMulti(
    tree: *widget.Tree,
    selector: widget.NodeHandle,
    handle: widget.NodeHandle,
    mouse: *const MouseState,
) bool {
    const clicked_index = widget.gridItemIndex(tree, handle) orelse return false;
    const grid_selector = &tree.get(selector).kind.grid_selector;

    if (mouse.shift_down) {
        const anchor = grid_selector.internal.anchor_index orelse clicked_index;
        const changed = selectGridRange(tree, selector, @min(anchor, clicked_index), @max(anchor, clicked_index), mouse.ctrl_down);
        grid_selector.internal.anchor_index = anchor;
        return changed;
    }

    grid_selector.internal.anchor_index = clicked_index;
    if (mouse.ctrl_down) {
        return toggleGridItem(tree, selector, handle);
    }

    return selectGridItem(tree, handle);
}

pub fn selectGridRange(
    tree: *widget.Tree,
    selector: widget.NodeHandle,
    start_index: u16,
    end_index: u16,
    additive: bool,
) bool {
    var changed = false;
    var index: u16 = 0;
    var iter = tree.children(selector);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .grid_item) continue;
        const in_range = index >= start_index and index <= end_index;
        const should_select = in_range or (additive and tree.getConst(child).kind.grid_item.selected);
        if (tree.getConst(child).kind.grid_item.selected != should_select) {
            tree.get(child).kind.grid_item.selected = should_select;
            changed = true;
        }
        index += 1;
    }
    if (changed) tree.get(selector).interaction.changed = true;
    return changed;
}

pub fn toggleGridItem(tree: *widget.Tree, selector: widget.NodeHandle, handle: widget.NodeHandle) bool {
    const current = tree.getConst(handle).kind.grid_item.selected;
    tree.get(handle).kind.grid_item.selected = !current;
    if (current == tree.getConst(handle).kind.grid_item.selected) return false;
    tree.get(selector).interaction.changed = true;
    return true;
}

pub fn clearGridSelectorSelection(tree: *widget.Tree, selector: widget.NodeHandle) bool {
    const node = tree.get(selector);
    if (node.kind != .grid_selector) return false;

    var changed = false;
    var iter = tree.children(selector);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .grid_item) continue;
        if (tree.getConst(child).kind.grid_item.selected) {
            tree.get(child).kind.grid_item.selected = false;
            changed = true;
        }
    }

    node.kind.grid_selector.internal.anchor_index = null;
    if (changed) node.interaction.changed = true;
    return changed;
}

pub fn selectAllGridSelector(tree: *widget.Tree, selector: widget.NodeHandle) bool {
    var changed = false;
    var last_index: ?u16 = null;
    var index: u16 = 0;
    var iter = tree.children(selector);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .grid_item) continue;
        if (!tree.getConst(child).kind.grid_item.selected) {
            tree.get(child).kind.grid_item.selected = true;
            changed = true;
        }
        last_index = index;
        index += 1;
    }
    if (changed) {
        tree.get(selector).kind.grid_selector.internal.anchor_index = last_index;
        tree.get(selector).interaction.changed = true;
    }
    return changed;
}

pub fn selectTableRow(tree: *widget.Tree, handle: widget.NodeHandle) bool {
    if (!widget.tableRowSelectable(tree, handle)) return false;

    const table_handle = tree.getConst(handle).parent orelse return false;
    var changed = false;
    const selected_index = widget.tableDataRowIndex(tree, handle);

    var iter = tree.children(table_handle);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (child_node.kind != .table_row or child_node.kind.table_row.header) continue;
        const should_select = child.eql(handle);
        if (child_node.kind.table_row.selected != should_select) {
            tree.get(child).kind.table_row.selected = should_select;
            changed = true;
        }
    }

    const table = &tree.get(table_handle).kind.table;
    table.internal.anchor_row = selected_index;
    if (changed) table.selection_changed = true;
    return changed;
}

pub fn selectTableRowsMulti(
    tree: *widget.Tree,
    table_handle: widget.NodeHandle,
    row_handle: widget.NodeHandle,
    mouse: *const MouseState,
) bool {
    const row_index = widget.tableDataRowIndex(tree, row_handle) orelse return false;
    const table = &tree.get(table_handle).kind.table;

    if (mouse.shift_down) {
        const anchor = table.internal.anchor_row orelse row_index;
        const changed = selectTableRowRange(tree, table_handle, @min(anchor, row_index), @max(anchor, row_index), mouse.ctrl_down);
        table.internal.anchor_row = anchor;
        return changed;
    }

    table.internal.anchor_row = row_index;
    if (mouse.ctrl_down) {
        return toggleTableRow(tree, table_handle, row_handle);
    }

    return selectTableRow(tree, row_handle);
}

pub fn selectTableRowRange(
    tree: *widget.Tree,
    table_handle: widget.NodeHandle,
    start_index: u16,
    end_index: u16,
    additive: bool,
) bool {
    var changed = false;
    var index: u16 = 0;
    var iter = tree.children(table_handle);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (child_node.kind != .table_row or child_node.kind.table_row.header) continue;
        const in_range = index >= start_index and index <= end_index;
        const should_select = in_range or (additive and child_node.kind.table_row.selected);
        if (child_node.kind.table_row.selected != should_select) {
            tree.get(child).kind.table_row.selected = should_select;
            changed = true;
        }
        index += 1;
    }
    if (changed) tree.get(table_handle).kind.table.selection_changed = true;
    return changed;
}

pub fn toggleTableRow(tree: *widget.Tree, table_handle: widget.NodeHandle, row_handle: widget.NodeHandle) bool {
    const current = tree.getConst(row_handle).kind.table_row.selected;
    tree.get(row_handle).kind.table_row.selected = !current;
    if (current == tree.getConst(row_handle).kind.table_row.selected) return false;
    tree.get(table_handle).kind.table.selection_changed = true;
    return true;
}

pub fn selectListBoxMulti(
    tree: *widget.Tree,
    list_box: widget.NodeHandle,
    handle: widget.NodeHandle,
    mouse: *const MouseState,
) bool {
    const clicked_index = selectableIndexInParent(tree, handle) orelse return false;
    const list_box_node = tree.get(list_box);
    std.debug.assert(list_box_node.kind == .list_box);

    if (mouse.shift_down) {
        const anchor = list_box_node.kind.list_box.internal.anchor_index orelse clicked_index;
        const changed = selectListBoxRange(tree, list_box, @min(anchor, clicked_index), @max(anchor, clicked_index), mouse.ctrl_down);
        list_box_node.kind.list_box.internal.anchor_index = anchor;
        return changed;
    }

    list_box_node.kind.list_box.internal.anchor_index = clicked_index;
    if (mouse.ctrl_down) {
        return toggleListBoxSelectable(tree, list_box, handle);
    }

    return selectSelectable(tree, handle);
}

pub fn selectListBoxRange(
    tree: *widget.Tree,
    list_box: widget.NodeHandle,
    start_index: u16,
    end_index: u16,
    additive: bool,
) bool {
    var changed = false;
    var index: u16 = 0;
    var iter = tree.children(list_box);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .selectable) continue;
        const in_range = index >= start_index and index <= end_index;
        const should_select = in_range or (additive and tree.getConst(child).kind.selectable.selected);
        if (tree.getConst(child).kind.selectable.selected != should_select) {
            tree.get(child).kind.selectable.selected = should_select;
            changed = true;
        }
        index += 1;
    }
    if (changed) tree.get(list_box).interaction.changed = true;
    return changed;
}

pub fn toggleListBoxSelectable(tree: *widget.Tree, list_box: widget.NodeHandle, handle: widget.NodeHandle) bool {
    const current = tree.getConst(handle).kind.selectable.selected;
    tree.get(handle).kind.selectable.selected = !current;
    if (current == tree.getConst(handle).kind.selectable.selected) return false;
    tree.get(list_box).interaction.changed = true;
    return true;
}

pub fn markSelectableListBoxChanged(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const parent_handle = tree.getConst(handle).parent orelse return;
    if (tree.getConst(parent_handle).kind == .list_box) {
        tree.get(parent_handle).interaction.changed = true;
    }
}

pub fn selectableParentListBox(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    const parent_handle = tree.getConst(handle).parent orelse return null;
    if (tree.getConst(parent_handle).kind != .list_box) return null;
    return parent_handle;
}

pub fn selectableIndexInParent(tree: *const widget.Tree, handle: widget.NodeHandle) ?u16 {
    const parent_handle = tree.getConst(handle).parent orelse return null;
    var index: u16 = 0;
    var iter = tree.children(parent_handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .selectable) continue;
        if (child.eql(handle)) return index;
        index += 1;
    }
    return null;
}

pub fn applySelectableKeyboardNavigation(tree: *widget.Tree, target: widget.NodeHandle, mouse: *const MouseState) void {
    if (selectableParentListBox(tree, target)) |list_box| {
        if (tree.getConst(list_box).kind.list_box.selection_mode == .multiple and mouse.shift_down) {
            _ = selectListBoxMulti(tree, list_box, target, mouse);
            return;
        }
    }
    _ = selectSelectable(tree, target);
}

pub fn applyGridItemKeyboardNavigation(tree: *widget.Tree, target: widget.NodeHandle, mouse: *const MouseState) void {
    if (widget.gridItemParentSelector(tree, target)) |selector| {
        if (tree.getConst(selector).kind.grid_selector.selection_mode == .multiple and mouse.shift_down) {
            _ = selectGridItemsMulti(tree, selector, target, mouse);
            return;
        }
    }
    _ = selectGridItem(tree, target);
}

pub fn applyTableRowKeyboardNavigation(tree: *widget.Tree, target: widget.NodeHandle, mouse: *const MouseState) void {
    if (!widget.tableRowSelectable(tree, target)) return;
    const table_handle = tree.getConst(target).parent orelse return;
    if (tree.getConst(table_handle).kind.table.selection_mode == .multiple and mouse.shift_down) {
        _ = selectTableRowsMulti(tree, table_handle, target, mouse);
        return;
    }
    _ = selectTableRow(tree, target);
}
