const std = @import("std");
const widget = @import("../widget.zig");
const input = @import("goop_input");
const focus = @import("../focus.zig");
const style = @import("../style.zig");
const geometry = @import("../geometry.zig");
const types = @import("types.zig");
const control = @import("control.zig");
const selection = @import("selection.zig");
const text = @import("text.zig");

const MouseState = types.MouseState;

fn keyPressedOrRepeat(k: input.Event.Key) bool {
    return k.state == .pressed or k.state == .repeat;
}

pub fn handleFocusTraversalKey(tree: *widget.Tree, mouse: *MouseState, k: input.Event.Key) bool {
    if (k.keycode != .tab) return false;
    if (!keyPressedOrRepeat(k)) return true;
    if (mouse.focused) |f| text.commitOrCancelNumericEditorOnBlur(tree, f, mouse);
    mouse.focused = if (mouse.shift_down)
        focus.focusPrev(tree, mouse.focused)
    else
        focus.focusNext(tree, mouse.focused);
    focus.syncFocusFlags(tree, mouse.focused);
    return true;
}

pub fn handleFocusedNavigationKey(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, k: input.Event.Key) bool {
    if (!keyPressedOrRepeat(k)) return false;
    const focused = mouse.focused orelse return false;
    switch (k.keycode) {
        .left => return navigateLeft(tree, mouse, theme, focused),
        .right => return navigateRight(tree, mouse, theme, focused),
        .up => return navigateUp(tree, mouse, theme, focused),
        .down => return navigateDown(tree, mouse, theme, focused),
        .home => return navigateHome(tree, mouse, focused),
        .end => return navigateEnd(tree, mouse, focused),
        else => return false,
    }
}

fn navigateLeft(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, focused: widget.NodeHandle) bool {
    if (tree.getConst(focused).kind == .drag_value) {
        control.stepDragValue(tree, focused, mouse, -1);
    } else if (tree.getConst(focused).kind == .spinbox) {
        control.stepSpinBox(tree, focused, mouse, -1, false);
    } else if (tree.getConst(focused).kind == .splitter and tree.getConst(focused).kind.splitter.direction == .row) {
        control.stepSplitter(tree, focused, mouse, -1, theme);
    } else if (tree.getConst(focused).kind == .tab_item) {
        if (prevTabItem(tree, focused)) |prev| setKeyboardFocusAfterNavigation(tree, mouse, prev, .tab);
    } else if (tree.getConst(focused).kind == .grid_item) {
        if (prevGridItem(tree, focused)) |prev| setKeyboardFocusAfterNavigation(tree, mouse, prev, .grid);
    } else if (tree.getConst(focused).kind == .tree_item) {
        const node = tree.get(focused);
        if (node.kind.tree_item.expanded and hasTreeItemChildren(tree, focused)) {
            toggleTreeItem(tree, focused, mouse);
        } else if (geometry.findTreeParent(tree, focused)) |parent| {
            mouse.focused = parent;
            focus.syncFocusFlags(tree, mouse.focused);
        }
    }
    return true;
}

fn navigateRight(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, focused: widget.NodeHandle) bool {
    if (tree.getConst(focused).kind == .drag_value) {
        control.stepDragValue(tree, focused, mouse, 1);
    } else if (tree.getConst(focused).kind == .spinbox) {
        control.stepSpinBox(tree, focused, mouse, 1, false);
    } else if (tree.getConst(focused).kind == .splitter and tree.getConst(focused).kind.splitter.direction == .row) {
        control.stepSplitter(tree, focused, mouse, 1, theme);
    } else if (tree.getConst(focused).kind == .tab_item) {
        if (nextTabItem(tree, focused)) |next| setKeyboardFocusAfterNavigation(tree, mouse, next, .tab);
    } else if (tree.getConst(focused).kind == .grid_item) {
        if (nextGridItem(tree, focused)) |next| setKeyboardFocusAfterNavigation(tree, mouse, next, .grid);
    } else if (tree.getConst(focused).kind == .tree_item) {
        const node = tree.get(focused);
        if (!node.kind.tree_item.expanded and hasTreeItemChildren(tree, focused)) {
            toggleTreeItem(tree, focused, mouse);
        } else if (node.kind.tree_item.expanded) {
            mouse.focused = firstChildTreeItem(tree, focused) orelse mouse.focused;
            focus.syncFocusFlags(tree, mouse.focused);
        }
    }
    return true;
}

fn navigateUp(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, focused: widget.NodeHandle) bool {
    if (tree.getConst(focused).kind == .spinbox) {
        control.stepSpinBox(tree, focused, mouse, 1, false);
    } else if (tree.getConst(focused).kind == .drag_value) {
        control.stepDragValue(tree, focused, mouse, 1);
    } else if (tree.getConst(focused).kind == .splitter and tree.getConst(focused).kind.splitter.direction == .column) {
        control.stepSplitter(tree, focused, mouse, -1, theme);
    } else if (tree.getConst(focused).kind == .selectable) {
        if (prevSelectableSibling(tree, focused)) |prev| setKeyboardFocusAfterNavigation(tree, mouse, prev, .selectable);
    } else if (tree.getConst(focused).kind == .grid_item) {
        if (gridItemAbove(tree, focused)) |prev| setKeyboardFocusAfterNavigation(tree, mouse, prev, .grid);
    } else if (tree.getConst(focused).kind == .table_row) {
        if (prevTableRowSibling(tree, focused)) |prev| setKeyboardFocusAfterNavigation(tree, mouse, prev, .table);
    } else if (tree.getConst(focused).kind == .tree_item and !text.treeItemEditing(tree, focused)) {
        mouse.focused = prevVisibleTreeItem(tree, focused) orelse mouse.focused;
        focus.syncFocusFlags(tree, mouse.focused);
    }
    return true;
}

fn navigateDown(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, focused: widget.NodeHandle) bool {
    if (tree.getConst(focused).kind == .spinbox) {
        control.stepSpinBox(tree, focused, mouse, -1, false);
    } else if (tree.getConst(focused).kind == .drag_value) {
        control.stepDragValue(tree, focused, mouse, -1);
    } else if (tree.getConst(focused).kind == .splitter and tree.getConst(focused).kind.splitter.direction == .column) {
        control.stepSplitter(tree, focused, mouse, 1, theme);
    } else if (tree.getConst(focused).kind == .selectable) {
        if (nextSelectableSibling(tree, focused)) |next| setKeyboardFocusAfterNavigation(tree, mouse, next, .selectable);
    } else if (tree.getConst(focused).kind == .grid_item) {
        if (gridItemBelow(tree, focused)) |next| setKeyboardFocusAfterNavigation(tree, mouse, next, .grid);
    } else if (tree.getConst(focused).kind == .table_row) {
        if (nextTableRowSibling(tree, focused)) |next| setKeyboardFocusAfterNavigation(tree, mouse, next, .table);
    } else if (tree.getConst(focused).kind == .tree_item and !text.treeItemEditing(tree, focused)) {
        mouse.focused = nextVisibleTreeItem(tree, focused) orelse mouse.focused;
        focus.syncFocusFlags(tree, mouse.focused);
    }
    return true;
}

fn navigateHome(tree: *widget.Tree, mouse: *MouseState, focused: widget.NodeHandle) bool {
    if (tree.getConst(focused).kind == .selectable) {
        if (firstSelectableSibling(tree, focused)) |first| setKeyboardFocusAfterNavigation(tree, mouse, first, .selectable);
    } else if (tree.getConst(focused).kind == .grid_item) {
        if (firstGridItemSibling(tree, focused)) |first| setKeyboardFocusAfterNavigation(tree, mouse, first, .grid);
    } else if (tree.getConst(focused).kind == .table_row) {
        if (firstTableDataRow(tree, focused)) |first| setKeyboardFocusAfterNavigation(tree, mouse, first, .table);
    }
    return true;
}

fn navigateEnd(tree: *widget.Tree, mouse: *MouseState, focused: widget.NodeHandle) bool {
    if (tree.getConst(focused).kind == .selectable) {
        if (lastSelectableSibling(tree, focused)) |last| setKeyboardFocusAfterNavigation(tree, mouse, last, .selectable);
    } else if (tree.getConst(focused).kind == .grid_item) {
        if (lastGridItemSibling(tree, focused)) |last| setKeyboardFocusAfterNavigation(tree, mouse, last, .grid);
    } else if (tree.getConst(focused).kind == .table_row) {
        if (lastTableDataRow(tree, focused)) |last| setKeyboardFocusAfterNavigation(tree, mouse, last, .table);
    }
    return true;
}

const KeyboardNavigationKind = enum { tab, selectable, grid, table };

fn setKeyboardFocusAfterNavigation(tree: *widget.Tree, mouse: *MouseState, target: widget.NodeHandle, kind: KeyboardNavigationKind) void {
    const changed = switch (kind) {
        .tab => blk: {
            selectTabItem(tree, target);
            break :blk true;
        },
        .selectable => selection.applySelectableKeyboardNavigation(tree, target, mouse),
        .grid => selection.applyGridItemKeyboardNavigation(tree, target, mouse),
        .table => selection.applyTableRowKeyboardNavigation(tree, target, mouse),
    };
    if (changed) {
        switch (kind) {
            .tab => mouse.emitItemSelection(tree, target, true),
            .selectable => {
                if (selection.selectableParentListBox(tree, target)) |container|
                    mouse.emitSelection(tree, container)
                else
                    mouse.emitItemSelection(tree, target, true);
            },
            .grid => {
                if (widget.gridItemParentSelector(tree, target)) |container|
                    mouse.emitSelection(tree, container)
                else
                    mouse.emitItemSelection(tree, target, true);
            },
            .table => {
                if (tree.getConst(target).parent) |container| mouse.emitSelection(tree, container);
            },
        }
    }
    mouse.focused = target;
    focus.syncFocusFlags(tree, mouse.focused);
}

pub fn selectTabItem(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    if (node.kind != .tab_item) return;
    const parent_handle = node.parent orelse {
        node.kind.tab_item.selected = true;
        return;
    };

    var iter = tree.children(parent_handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .tab_item) {
            tree.get(child).kind.tab_item.selected = child.eql(handle);
        }
    }
}

pub fn toggleTreeItem(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    const node = tree.get(handle);
    if (node.kind != .tree_item) return;
    if (!hasTreeItemChildren(tree, handle)) return;
    node.kind.tree_item.expanded = !node.kind.tree_item.expanded;
    mouse.emitToggle(tree, handle, node.kind.tree_item.expanded);
}

pub fn hasTreeItemChildren(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    if (node.kind == .tree_item and node.kind.tree_item.has_children) return true;
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .popup and tree.getConst(child).kind != .tooltip) return true;
    }
    return false;
}

fn prevTabItem(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    const parent_handle = tree.getConst(handle).parent orelse return null;
    var current = tree.getConst(handle).prev_sibling;
    while (current) |candidate| {
        if (tree.getConst(candidate).kind == .tab_item) return candidate;
        current = tree.getConst(candidate).prev_sibling;
    }

    var iter = tree.children(parent_handle);
    var last: ?widget.NodeHandle = null;
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .tab_item) continue;
        last = child;
    }
    return last;
}

fn nextTabItem(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    const parent_handle = tree.getConst(handle).parent orelse return null;
    var current = tree.getConst(handle).next_sibling;
    while (current) |candidate| {
        if (tree.getConst(candidate).kind == .tab_item) return candidate;
        current = tree.getConst(candidate).next_sibling;
    }

    var iter = tree.children(parent_handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .tab_item) return child;
    }
    return null;
}

fn prevSelectableSibling(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var current = tree.getConst(handle).prev_sibling;
    while (current) |candidate| {
        if (tree.getConst(candidate).kind == .selectable) return candidate;
        current = tree.getConst(candidate).prev_sibling;
    }
    return null;
}

fn nextSelectableSibling(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var current = tree.getConst(handle).next_sibling;
    while (current) |candidate| {
        if (tree.getConst(candidate).kind == .selectable) return candidate;
        current = tree.getConst(candidate).next_sibling;
    }
    return null;
}

fn firstSelectableSibling(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    const parent_handle = tree.getConst(handle).parent orelse return null;
    var iter = tree.children(parent_handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .selectable) return child;
    }
    return null;
}

fn lastSelectableSibling(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    const parent_handle = tree.getConst(handle).parent orelse return null;
    var iter = tree.children(parent_handle);
    var last: ?widget.NodeHandle = null;
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .selectable) last = child;
    }
    return last;
}

fn prevGridItem(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    const index = widget.gridItemIndex(tree, handle) orelse return null;
    const selector = widget.gridItemParentSelector(tree, handle) orelse return null;
    if (index == 0) return null;
    return widget.gridItemAt(tree, selector, index - 1);
}

fn nextGridItem(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    const index = widget.gridItemIndex(tree, handle) orelse return null;
    const selector = widget.gridItemParentSelector(tree, handle) orelse return null;
    return widget.gridItemAt(tree, selector, index + 1);
}

fn firstGridItemSibling(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    const selector = widget.gridItemParentSelector(tree, handle) orelse return null;
    return widget.gridItemAt(tree, selector, 0);
}

fn lastGridItemSibling(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    const selector = widget.gridItemParentSelector(tree, handle) orelse return null;
    const count = widget.gridSelectorItemCount(tree, selector);
    if (count == 0) return null;
    return widget.gridItemAt(tree, selector, count - 1);
}

fn gridItemAbove(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    const index = widget.gridItemIndex(tree, handle) orelse return null;
    const selector = widget.gridItemParentSelector(tree, handle) orelse return null;
    const columns = @max(tree.getConst(selector).kind.grid_selector.computed_columns, 1);
    if (index < columns) return null;
    return widget.gridItemAt(tree, selector, index - columns);
}

fn gridItemBelow(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    const index = widget.gridItemIndex(tree, handle) orelse return null;
    const selector = widget.gridItemParentSelector(tree, handle) orelse return null;
    const columns = @max(tree.getConst(selector).kind.grid_selector.computed_columns, 1);
    return widget.gridItemAt(tree, selector, index + columns);
}

fn prevTableRowSibling(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var current = tree.getConst(handle).prev_sibling;
    while (current) |candidate| {
        const node = tree.getConst(candidate);
        if (node.kind == .table_row and !node.kind.table_row.header) return candidate;
        current = node.prev_sibling;
    }
    return null;
}

fn nextTableRowSibling(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var current = tree.getConst(handle).next_sibling;
    while (current) |candidate| {
        const node = tree.getConst(candidate);
        if (node.kind == .table_row and !node.kind.table_row.header) return candidate;
        current = node.next_sibling;
    }
    return null;
}

fn firstTableDataRow(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    const parent_handle = tree.getConst(handle).parent orelse return null;
    var iter = tree.children(parent_handle);
    while (iter.next()) |child| {
        const node = tree.getConst(child);
        if (node.kind == .table_row and !node.kind.table_row.header) return child;
    }
    return null;
}

fn lastTableDataRow(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    const parent_handle = tree.getConst(handle).parent orelse return null;
    var iter = tree.children(parent_handle);
    var last: ?widget.NodeHandle = null;
    while (iter.next()) |child| {
        const node = tree.getConst(child);
        if (node.kind == .table_row and !node.kind.table_row.header) last = child;
    }
    return last;
}

fn firstChildTreeItem(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .tree_item) return child;
    }
    return null;
}

fn nextVisibleTreeItem(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var visible: std.ArrayListUnmanaged(widget.NodeHandle) = .empty;
    defer visible.deinit(tree.allocator);
    collectVisibleTreeItems(tree, &visible, tree.allocator) catch return null;

    for (visible.items, 0..) |item, i| {
        if (!item.eql(handle)) continue;
        if (i + 1 < visible.items.len) return visible.items[i + 1];
        return null;
    }
    return null;
}

fn prevVisibleTreeItem(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var visible: std.ArrayListUnmanaged(widget.NodeHandle) = .empty;
    defer visible.deinit(tree.allocator);
    collectVisibleTreeItems(tree, &visible, tree.allocator) catch return null;

    for (visible.items, 0..) |item, i| {
        if (!item.eql(handle)) continue;
        if (i > 0) return visible.items[i - 1];
        return null;
    }
    return null;
}

fn collectVisibleTreeItems(
    tree: *const widget.Tree,
    out: *std.ArrayListUnmanaged(widget.NodeHandle),
    allocator: std.mem.Allocator,
) !void {
    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive or node.parent != null) continue;
        try collectVisibleTreeItemsFrom(tree, tree.handleFromIndex(@intCast(i)), out, allocator);
    }
}

fn collectVisibleTreeItemsFrom(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    out: *std.ArrayListUnmanaged(widget.NodeHandle),
    allocator: std.mem.Allocator,
) !void {
    const node = tree.getConst(handle);
    if (node.kind == .tree_item) {
        try out.append(allocator, handle);
        if (!node.kind.tree_item.expanded) return;
    }

    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .popup or tree.getConst(child).kind == .tooltip) continue;
        try collectVisibleTreeItemsFrom(tree, child, out, allocator);
    }
}
