const widget = @import("widget.zig");

/// Whether a widget kind can receive keyboard focus.
pub fn isFocusable(kind: widget.WidgetKind) bool {
    return switch (kind) {
        .button,
        .checkbox,
        .radio_button,
        .tree_item,
        .dropdown,
        .selectable,
        .grid_item,
        .table_row,
        .menu,
        .menu_item,
        .drag_value,
        .spinbox,
        .tab_item,
        .splitter,
        .slider,
        .text_input,
        => true,
        .text, .container, .list_box, .grid_selector, .table, .table_cell, .toolbar, .status_bar, .menu_bar, .popup, .tooltip, .tab_bar, .spacer, .scroll_area => false,
    };
}

/// Find the next focusable widget in tree order after `current`.
/// Wraps around to the first focusable widget.
pub fn focusNext(tree: *const widget.Tree, current: ?widget.NodeHandle) ?widget.NodeHandle {
    const nodes = tree.nodes.items;
    if (nodes.len == 0) return null;

    const start: u32 = if (current) |c| c.index + 1 else 0;

    // Search from start to end, then wrap from 0 to start
    var i: u32 = start;
    var wrapped = false;
    while (true) {
        if (i >= nodes.len) {
            if (wrapped) return current;
            i = 0;
            wrapped = true;
        }
        if (wrapped and current != null and i >= current.?.index + 1) return current;
        if (canFocusNode(tree, i)) return tree.handleFromIndex(i);
        i += 1;
    }
}

/// Find the previous focusable widget in tree order before `current`.
/// Wraps around to the last focusable widget.
pub fn focusPrev(tree: *const widget.Tree, current: ?widget.NodeHandle) ?widget.NodeHandle {
    const nodes = tree.nodes.items;
    if (nodes.len == 0) return null;

    const len: u32 = @intCast(nodes.len);
    const start: u32 = if (current) |c| c.index else len;

    // Search backwards from start-1, wrapping at 0 to end
    if (start == 0) {
        // Wrap to end
        var i: u32 = len;
        while (i > 0) {
            i -= 1;
            if (canFocusNode(tree, i)) return tree.handleFromIndex(i);
        }
        return current;
    }

    var i: u32 = start - 1;
    while (true) {
        if (canFocusNode(tree, i)) return tree.handleFromIndex(i);
        if (i == 0) break;
        i -= 1;
    }
    // Wrap: search from end backwards to start
    i = len;
    while (i > start) {
        i -= 1;
        if (canFocusNode(tree, i)) return tree.handleFromIndex(i);
    }
    return current;
}

/// Update the `.focused` flag on all nodes to match the current focus target.
pub fn syncFocusFlags(tree: *widget.Tree, focused: ?widget.NodeHandle) void {
    for (tree.nodes.items) |*node| {
        node.interaction.focused = false;
    }
    if (focused) |f| {
        tree.get(f).interaction.focused = true;
    }
}

fn canFocusNode(tree: *const widget.Tree, index: u32) bool {
    const node = tree.nodes.items[index];
    if (!node.alive or !isFocusable(node.kind) or node.layout_rect.w <= 0 or node.layout_rect.h <= 0) return false;
    if (node.kind == .table_row) {
        return widget.tableRowSelectable(tree, tree.handleFromIndex(index));
    }
    return true;
}
