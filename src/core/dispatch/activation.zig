const widget = @import("../widget.zig");
const types = @import("types.zig");
const menu = @import("menu.zig");
const navigation = @import("navigation.zig");
const selection = @import("selection.zig");

const MouseState = types.MouseState;

pub fn activateTable(tree: *widget.Tree, handle: widget.NodeHandle, x: f32, y: f32) void {
    const column = widget.tableHeaderCellIndexAtPoint(tree, handle, x, y) orelse return;
    const node = tree.get(handle);
    node.interaction.primary_clicked = true;
    _ = node.kind.table.toggleSort(column);
}

pub fn activateSelectable(tree: *widget.Tree, handle: widget.NodeHandle, mouse: ?*const MouseState) void {
    const node = tree.get(handle);
    if (node.kind != .selectable) return;

    node.interaction.primary_clicked = true;

    if (mouse) |state| {
        if (selection.selectableParentListBox(tree, handle)) |list_box| {
            if (tree.getConst(list_box).kind.list_box.selection_mode == .multiple) {
                _ = selection.selectListBoxMulti(tree, list_box, handle, state);
                return;
            }
        }
    }

    _ = selection.selectSelectable(tree, handle);
}

pub fn activateGridSelector(tree: *widget.Tree, handle: widget.NodeHandle, mouse: ?*const MouseState) void {
    const node = tree.get(handle);
    if (node.kind != .grid_selector) return;

    node.interaction.primary_clicked = true;
    if (mouse) |state| {
        if (state.ctrl_down or state.shift_down) return;
    }
    _ = selection.clearGridSelectorSelection(tree, handle);
}

pub fn activateGridItem(tree: *widget.Tree, handle: widget.NodeHandle, mouse: ?*const MouseState) void {
    const node = tree.get(handle);
    if (node.kind != .grid_item) return;

    node.interaction.primary_clicked = true;

    if (mouse) |state| {
        if (widget.gridItemParentSelector(tree, handle)) |selector| {
            if (tree.getConst(selector).kind.grid_selector.selection_mode == .multiple) {
                _ = selection.selectGridItemsMulti(tree, selector, handle, state);
                return;
            }
        }
    }

    _ = selection.selectGridItem(tree, handle);
}

pub fn activateTableRow(tree: *widget.Tree, handle: widget.NodeHandle, mouse: ?*const MouseState) void {
    if (!widget.tableRowSelectable(tree, handle)) return;

    const node = tree.get(handle);
    node.interaction.primary_clicked = true;

    if (mouse) |state| {
        const table_handle = node.parent orelse return;
        if (tree.getConst(table_handle).kind.table.selection_mode == .multiple) {
            _ = selection.selectTableRowsMulti(tree, table_handle, handle, state);
            return;
        }
    }

    _ = selection.selectTableRow(tree, handle);
}

pub fn fireClick(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    switch (node.kind) {
        .button => {
            node.interaction.primary_clicked = true;
        },
        .checkbox => {
            node.interaction.primary_clicked = true;
            node.kind.checkbox.checked = !node.kind.checkbox.checked;
        },
        .radio_button => {
            node.interaction.primary_clicked = true;
            const group = node.kind.radio_button.group;
            // Deselect all other radio buttons in the same group
            for (tree.nodes.items) |*n| {
                if (n.kind == .radio_button and n.kind.radio_button.group == group) {
                    n.kind.radio_button.selected = false;
                }
            }
            node.kind.radio_button.selected = true;
        },
        .tree_item => {
            if (node.kind.tree_item.editing) return;
            node.interaction.primary_clicked = true;
            const group = node.kind.tree_item.group;
            for (tree.nodes.items) |*n| {
                if (n.alive and n.kind == .tree_item and n.kind.tree_item.group == group) {
                    n.kind.tree_item.selected = false;
                }
            }
            node.kind.tree_item.selected = true;
        },
        .dropdown => {
            node.interaction.primary_clicked = true;
            node.kind.dropdown.open = !node.kind.dropdown.open;
        },
        .selectable => {
            activateSelectable(tree, handle, null);
        },
        .grid_item => {
            activateGridItem(tree, handle, null);
        },
        .drag_value => {
            if (!node.kind.drag_value.editing) node.kind.drag_value.beginEdit();
        },
        .spinbox => {
            if (!node.kind.spinbox.editing) node.kind.spinbox.beginEdit();
        },
        .table_row => {
            activateTableRow(tree, handle, null);
        },
        .menu => {
            node.interaction.primary_clicked = true;
            menu.toggleOwnedPopup(tree, handle, null);
        },
        .menu_item => {
            if (node.kind.menu_item.disabled) return;
            node.interaction.primary_clicked = true;
            if (menu.directPopupChild(tree, handle) != null) {
                menu.toggleOwnedPopup(tree, handle, null);
            } else {
                menu.applyMenuSelection(tree, handle);
            }
        },
        .tab_item => {
            node.interaction.primary_clicked = true;
            navigation.selectTabItem(tree, handle);
        },
        .custom => {
            node.interaction.primary_clicked = true;
        },
        else => {},
    }
}

pub fn fireSecondaryClick(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    const node = tree.get(handle);
    node.interaction.secondary_clicked = true;
    mouse.last_secondary_click = .{
        .target = handle,
        .x = mouse.x,
        .y = mouse.y,
    };
}

pub fn commitTreeItemRename(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    if (node.kind != .tree_item or !node.kind.tree_item.editing) return;
    node.kind.tree_item.commitRename();
}

pub fn cancelTreeItemRename(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    if (node.kind != .tree_item or !node.kind.tree_item.editing) return;
    node.kind.tree_item.cancelRename();
}

pub fn shouldBeginTreeRename(item: widget.WidgetKind.TreeItem, clicked_label: bool, is_double_click: bool) bool {
    if (!clicked_label) return false;
    return switch (item.rename_trigger) {
        .none => false,
        .selected_click => item.selected,
        .double_click => is_double_click,
    };
}
