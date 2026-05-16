const std = @import("std");
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
    if (node.widget_type) |widget_type| {
        if (widget_type.activate) |activate_fn| {
            if (activate_fn(.{
                .widget = .{
                    .tree = tree,
                    .handle = handle,
                    .node = node,
                    .state = node.widget_state,
                    .theme = .{},
                },
            })) return;
        }
        node.interaction.primary_clicked = true;
        return;
    }
    activateBuiltin(node.kind)(tree, handle);
}

const BuiltinActivate = *const fn (*widget.Tree, widget.NodeHandle) void;

fn activateBuiltin(kind: widget.WidgetKind) BuiltinActivate {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return builtin_activators[@intFromEnum(tag)];
}

const builtin_activators = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var activators: [std.meta.fields(Tag).len]BuiltinActivate = undefined;
    activators[@intFromEnum(Tag.container)] = activateNoop;
    activators[@intFromEnum(Tag.text)] = activateNoop;
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

fn activateNoop(_: *widget.Tree, _: widget.NodeHandle) void {}

fn activateButton(tree: *widget.Tree, handle: widget.NodeHandle) void {
    tree.get(handle).interaction.primary_clicked = true;
}

fn activateCheckbox(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    node.interaction.primary_clicked = true;
    node.kind.checkbox.checked = !node.kind.checkbox.checked;
}

fn activateRadioButton(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    node.interaction.primary_clicked = true;
    const group = node.kind.radio_button.group;
    for (tree.nodes.items) |*n| {
        if (n.kind == .radio_button and n.kind.radio_button.group == group) {
            n.kind.radio_button.selected = false;
        }
    }
    node.kind.radio_button.selected = true;
}

fn activateTreeItem(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    if (node.kind.tree_item.editing) return;
    node.interaction.primary_clicked = true;
    const group = node.kind.tree_item.group;
    for (tree.nodes.items) |*n| {
        if (n.alive and n.kind == .tree_item and n.kind.tree_item.group == group) {
            n.kind.tree_item.selected = false;
        }
    }
    node.kind.tree_item.selected = true;
}

fn activateDropdown(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    node.interaction.primary_clicked = true;
    node.kind.dropdown.open = !node.kind.dropdown.open;
}

fn activateSelectableNoMouse(tree: *widget.Tree, handle: widget.NodeHandle) void {
    activateSelectable(tree, handle, null);
}

fn activateGridItemNoMouse(tree: *widget.Tree, handle: widget.NodeHandle) void {
    activateGridItem(tree, handle, null);
}

fn activateTableRowNoMouse(tree: *widget.Tree, handle: widget.NodeHandle) void {
    activateTableRow(tree, handle, null);
}

fn activateDragValue(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    if (!node.kind.drag_value.editing) node.kind.drag_value.beginEdit();
}

fn activateSpinBox(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    if (!node.kind.spinbox.editing) node.kind.spinbox.beginEdit();
}

fn activateMenu(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    node.interaction.primary_clicked = true;
    menu.toggleOwnedPopup(tree, handle, null);
}

fn activateMenuItem(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    if (node.kind.menu_item.disabled) return;
    node.interaction.primary_clicked = true;
    if (menu.directPopupChild(tree, handle) != null) {
        menu.toggleOwnedPopup(tree, handle, null);
    } else {
        menu.applyMenuSelection(tree, handle);
    }
}

fn activateTabItem(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    node.interaction.primary_clicked = true;
    navigation.selectTabItem(tree, handle);
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
