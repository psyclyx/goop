const std = @import("std");
const widget = @import("widget.zig");

/// Whether a widget kind can receive keyboard focus.
pub fn isFocusable(kind: widget.WidgetKind) bool {
    return focusableKind(kind)(kind);
}

const FocusableKind = *const fn (widget.WidgetKind) bool;

fn focusableKind(kind: widget.WidgetKind) FocusableKind {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return focusable_kinds[@intFromEnum(tag)];
}

const focusable_kinds = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var kinds: [std.meta.fields(Tag).len]FocusableKind = undefined;
    kinds[@intFromEnum(Tag.container)] = neverFocusable;
    kinds[@intFromEnum(Tag.text)] = neverFocusable;
    kinds[@intFromEnum(Tag.button)] = alwaysFocusable;
    kinds[@intFromEnum(Tag.checkbox)] = alwaysFocusable;
    kinds[@intFromEnum(Tag.radio_button)] = alwaysFocusable;
    kinds[@intFromEnum(Tag.tree_item)] = alwaysFocusable;
    kinds[@intFromEnum(Tag.dropdown)] = alwaysFocusable;
    kinds[@intFromEnum(Tag.list_box)] = neverFocusable;
    kinds[@intFromEnum(Tag.selectable)] = alwaysFocusable;
    kinds[@intFromEnum(Tag.grid_selector)] = neverFocusable;
    kinds[@intFromEnum(Tag.grid_item)] = alwaysFocusable;
    kinds[@intFromEnum(Tag.table)] = neverFocusable;
    kinds[@intFromEnum(Tag.table_row)] = alwaysFocusable;
    kinds[@intFromEnum(Tag.table_cell)] = neverFocusable;
    kinds[@intFromEnum(Tag.toolbar)] = neverFocusable;
    kinds[@intFromEnum(Tag.status_bar)] = neverFocusable;
    kinds[@intFromEnum(Tag.menu_bar)] = neverFocusable;
    kinds[@intFromEnum(Tag.menu)] = alwaysFocusable;
    kinds[@intFromEnum(Tag.popup)] = neverFocusable;
    kinds[@intFromEnum(Tag.tooltip)] = neverFocusable;
    kinds[@intFromEnum(Tag.menu_item)] = alwaysFocusable;
    kinds[@intFromEnum(Tag.drag_value)] = alwaysFocusable;
    kinds[@intFromEnum(Tag.spinbox)] = alwaysFocusable;
    kinds[@intFromEnum(Tag.tab_bar)] = neverFocusable;
    kinds[@intFromEnum(Tag.tab_item)] = alwaysFocusable;
    kinds[@intFromEnum(Tag.splitter)] = alwaysFocusable;
    kinds[@intFromEnum(Tag.slider)] = alwaysFocusable;
    kinds[@intFromEnum(Tag.spacer)] = neverFocusable;
    kinds[@intFromEnum(Tag.scroll_area)] = neverFocusable;
    kinds[@intFromEnum(Tag.text_input)] = alwaysFocusable;
    kinds[@intFromEnum(Tag.custom)] = customFocusable;
    break :blk kinds;
};

fn alwaysFocusable(_: widget.WidgetKind) bool {
    return true;
}

fn neverFocusable(_: widget.WidgetKind) bool {
    return false;
}

fn customFocusable(kind: widget.WidgetKind) bool {
    return kind.custom.focusable;
}

pub fn nodeIsFocusable(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    if (node.widget_type) |widget_type| {
        return widget_type.focusable(.{
            .tree = @constCast(tree),
            .handle = handle,
            .node = @constCast(node),
            .state = node.widget_state,
            .theme = .{},
        });
    }
    return isFocusable(node.kind);
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
    if (!node.alive or node.layout_rect.w <= 0 or node.layout_rect.h <= 0) return false;
    const handle = tree.handleFromIndex(index);
    if (!nodeIsFocusable(tree, handle)) return false;
    if (node.kind == .table_row) {
        return widget.tableRowSelectable(tree, handle);
    }
    return true;
}
