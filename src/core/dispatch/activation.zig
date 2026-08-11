const std = @import("std");
const widget = @import("../widget.zig");
const types = @import("types.zig");
const menu = @import("menu.zig");
const navigation = @import("navigation.zig");
const selection = @import("selection.zig");

const MouseState = types.MouseState;

pub fn activateTable(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, x: f32, y: f32) void {
    const column = widget.tableHeaderCellIndexAtPoint(tree, handle, x, y) orelse return;
    const node = tree.get(handle);
    mouse.emitActivation(tree, handle);
    if (node.kind.table.toggleSort(column)) {
        mouse.emitSort(tree, handle, column, node.kind.table.sort_direction);
    }
}

pub fn activateSelectable(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    const node = tree.get(handle);
    if (node.kind != .selectable) return;

    mouse.emitActivation(tree, handle);

    if (selection.selectableParentListBox(tree, handle)) |list_box| {
        if (tree.getConst(list_box).kind.list_box.selection_mode == .multiple) {
            if (selection.selectListBoxMulti(tree, list_box, handle, mouse)) mouse.emitSelection(tree, list_box);
            return;
        }
    }

    if (selection.selectSelectable(tree, handle)) emitSelectionForItem(tree, handle, mouse);
}

pub fn activateGridSelector(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    const node = tree.get(handle);
    if (node.kind != .grid_selector) return;

    mouse.emitActivation(tree, handle);
    if (mouse.ctrl_down or mouse.shift_down) return;
    if (selection.clearGridSelectorSelection(tree, handle)) mouse.emitSelection(tree, handle);
}

pub fn activateGridItem(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    const node = tree.get(handle);
    if (node.kind != .grid_item) return;

    mouse.emitActivation(tree, handle);

    if (widget.gridItemParentSelector(tree, handle)) |selector| {
        if (tree.getConst(selector).kind.grid_selector.selection_mode == .multiple) {
            if (selection.selectGridItemsMulti(tree, selector, handle, mouse)) mouse.emitSelection(tree, selector);
            return;
        }
    }

    if (selection.selectGridItem(tree, handle)) emitSelectionForItem(tree, handle, mouse);
}

pub fn activateTableRow(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    if (!widget.tableRowSelectable(tree, handle)) return;

    const node = tree.get(handle);
    mouse.emitActivation(tree, handle);

    const table_handle = node.parent orelse return;
    if (tree.getConst(table_handle).kind.table.selection_mode == .multiple) {
        if (selection.selectTableRowsMulti(tree, table_handle, handle, mouse)) mouse.emitSelection(tree, table_handle);
        return;
    }

    if (selection.selectTableRow(tree, handle)) mouse.emitSelection(tree, table_handle);
}

pub fn fireClick(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    activateBuiltin(tree.getConst(handle).kind)(tree, handle, mouse);
}

const BuiltinActivate = *const fn (*widget.Tree, widget.NodeHandle, *MouseState) void;

fn activateBuiltin(kind: widget.WidgetKind) BuiltinActivate {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return builtin_activators[@intFromEnum(tag)];
}

const builtin_activators = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var activators: [std.meta.fields(Tag).len]BuiltinActivate = undefined;
    activators[@intFromEnum(Tag.container)] = activateNoop;
    activators[@intFromEnum(Tag.text)] = activateNoop;
    activators[@intFromEnum(Tag.icon)] = activateNoop;
    activators[@intFromEnum(Tag.button)] = activateButton;
    activators[@intFromEnum(Tag.checkbox)] = activateCheckbox;
    activators[@intFromEnum(Tag.radio_button)] = activateRadioButton;
    activators[@intFromEnum(Tag.tree_item)] = activateTreeItem;
    activators[@intFromEnum(Tag.dropdown)] = activateDropdown;
    activators[@intFromEnum(Tag.list_box)] = activateNoop;
    activators[@intFromEnum(Tag.selectable)] = activateSelectableNoMouse;
    activators[@intFromEnum(Tag.grid_selector)] = activateNoop;
    activators[@intFromEnum(Tag.grid_item)] = activateGridItemNoMouse;
    activators[@intFromEnum(Tag.table)] = activateNoop;
    activators[@intFromEnum(Tag.table_row)] = activateTableRowNoMouse;
    activators[@intFromEnum(Tag.table_cell)] = activateNoop;
    activators[@intFromEnum(Tag.toolbar)] = activateNoop;
    activators[@intFromEnum(Tag.status_bar)] = activateNoop;
    activators[@intFromEnum(Tag.menu_bar)] = activateNoop;
    activators[@intFromEnum(Tag.menu)] = activateMenu;
    activators[@intFromEnum(Tag.popup)] = activateNoop;
    activators[@intFromEnum(Tag.tooltip)] = activateNoop;
    activators[@intFromEnum(Tag.menu_item)] = activateMenuItem;
    activators[@intFromEnum(Tag.drag_value)] = activateDragValue;
    activators[@intFromEnum(Tag.spinbox)] = activateSpinBox;
    activators[@intFromEnum(Tag.tab_bar)] = activateNoop;
    activators[@intFromEnum(Tag.tab_item)] = activateTabItem;
    activators[@intFromEnum(Tag.splitter)] = activateNoop;
    activators[@intFromEnum(Tag.slider)] = activateNoop;
    activators[@intFromEnum(Tag.spacer)] = activateNoop;
    activators[@intFromEnum(Tag.scroll_area)] = activateNoop;
    activators[@intFromEnum(Tag.text_input)] = activateNoop;
    activators[@intFromEnum(Tag.custom)] = activateButton;
    break :blk activators;
};

fn activateNoop(_: *widget.Tree, _: widget.NodeHandle, _: *MouseState) void {}

fn activateButton(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    mouse.emitActivation(tree, handle);
}

fn activateCheckbox(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    const node = tree.get(handle);
    node.kind.checkbox.checked = !node.kind.checkbox.checked;
    mouse.emitActivation(tree, handle);
    mouse.emitToggle(tree, handle, node.kind.checkbox.checked);
}

fn activateRadioButton(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    const node = tree.get(handle);
    const group = node.kind.radio_button.group;
    for (tree.nodes.items) |*n| {
        if (n.kind == .radio_button and n.kind.radio_button.group == group) {
            n.kind.radio_button.selected = false;
        }
    }
    node.kind.radio_button.selected = true;
    mouse.emitActivation(tree, handle);
    mouse.emitItemSelection(tree, handle, true);
}

fn activateTreeItem(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    const node = tree.get(handle);
    if (node.kind.tree_item.editing) return;
    const group = node.kind.tree_item.group;
    for (tree.nodes.items) |*n| {
        if (n.alive and n.kind == .tree_item and n.kind.tree_item.group == group) {
            n.kind.tree_item.selected = false;
        }
    }
    node.kind.tree_item.selected = true;
    mouse.emitActivation(tree, handle);
    mouse.emitItemSelection(tree, handle, true);
}

fn activateDropdown(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    const node = tree.get(handle);
    node.kind.dropdown.open = !node.kind.dropdown.open;
    mouse.emitActivation(tree, handle);
}

fn activateSelectableNoMouse(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    activateSelectable(tree, handle, mouse);
}

fn activateGridItemNoMouse(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    activateGridItem(tree, handle, mouse);
}

fn activateTableRowNoMouse(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    activateTableRow(tree, handle, mouse);
}

fn activateDragValue(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    const node = tree.get(handle);
    if (!node.kind.drag_value.editing) node.kind.drag_value.beginEdit();
    mouse.emitActivation(tree, handle);
}

fn activateSpinBox(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    const node = tree.get(handle);
    if (!node.kind.spinbox.editing) node.kind.spinbox.beginEdit();
    mouse.emitActivation(tree, handle);
}

fn activateMenu(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    menu.toggleOwnedPopup(tree, handle, null);
    mouse.emitActivation(tree, handle);
}

fn activateMenuItem(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    const node = tree.get(handle);
    if (node.kind.menu_item.disabled) return;
    if (menu.directPopupChild(tree, handle) != null) {
        menu.toggleOwnedPopup(tree, handle, null);
    } else {
        menu.applyMenuSelection(tree, handle, mouse);
    }
    mouse.emitActivation(tree, handle);
}

fn activateTabItem(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    navigation.selectTabItem(tree, handle);
    mouse.emitActivation(tree, handle);
    mouse.emitItemSelection(tree, handle, true);
}

pub fn fireSecondaryClick(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    mouse.emitSecondaryActivation(tree, handle);
}

fn emitSelectionForItem(tree: *const widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    const node = tree.getConst(handle);
    if (node.parent) |parent| {
        switch (tree.getConst(parent).kind) {
            .list_box, .grid_selector, .table => {
                mouse.emitSelection(tree, parent);
                return;
            },
            else => {},
        }
    }
    const selected = switch (node.kind) {
        .selectable => |item| item.selected,
        .grid_item => |item| item.selected,
        .table_row => |item| item.selected,
        else => false,
    };
    mouse.emitItemSelection(tree, handle, selected);
}

pub fn commitTreeItemRename(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    const node = tree.get(handle);
    if (node.kind != .tree_item or !node.kind.tree_item.editing) return;
    node.kind.tree_item.commitRename();
    mouse.emitText(tree, handle, node.kind.tree_item.label, true);
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
