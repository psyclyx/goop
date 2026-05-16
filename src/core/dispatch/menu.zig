const widget = @import("../widget.zig");
const types = @import("types.zig");
const tree_util = @import("tree.zig");

const MouseState = types.MouseState;

pub fn syncMenuHover(tree: *widget.Tree, hovered: ?widget.NodeHandle, mouse: *MouseState) void {
    const target = hovered orelse return;

    if (findAncestorPopup(tree, target)) |popup| {
        syncPopupMenuHover(tree, popup, target, mouse);
    }

    if (findAncestorMenu(tree, target)) |menu| {
        const parent_handle = tree.getConst(menu).parent orelse return;
        if (tree.getConst(parent_handle).kind == .menu_bar and menuBarHasOpenMenu(tree, parent_handle)) {
            openOwnedPopup(tree, menu, mouse);
        }
    }
}

pub fn syncPopupMenuHover(tree: *widget.Tree, popup: widget.NodeHandle, hovered: widget.NodeHandle, mouse: *MouseState) void {
    var iter = tree.children(popup);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .menu_item) continue;
        const submenu = directPopupChild(tree, child) orelse continue;
        if (hovered.eql(child) or tree_util.isDescendantOf(tree, hovered, child)) {
            if (!tree.getConst(submenu).kind.popup.visible) {
                tree.get(submenu).kind.popup.visible = true;
                mouse.layout_changed = true;
            }
        } else {
            if (tree.getConst(submenu).kind.popup.visible) {
                closePopupSubtree(tree, submenu);
                mouse.layout_changed = true;
            }
        }
    }
}

pub fn applyMenuSelection(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.getConst(handle);
    const popup_handle = node.parent orelse return;
    if (tree.getConst(popup_handle).kind != .popup) return;

    if (tree.getConst(popup_handle).parent) |parent_handle| {
        const parent = tree.get(parent_handle);
        if (parent.kind == .dropdown) {
            const index = menuItemIndex(tree, popup_handle, handle);
            parent.kind.dropdown.selected_text = node.kind.menu_item.label;
            parent.kind.dropdown.selected_index = index;
            parent.interaction.changed = true;
        }
    }

    closePopupSubtree(tree, popupRoot(tree, popup_handle));
}

pub fn closeAllPopups(tree: *widget.Tree) void {
    for (tree.nodes.items) |*node| {
        if (!node.alive) continue;
        switch (node.kind) {
            .popup => node.kind.popup.visible = false,
            .dropdown => node.kind.dropdown.open = false,
            else => {},
        }
    }
}

pub fn closePopupsForPress(tree: *widget.Tree, target: ?widget.NodeHandle) void {
    for (tree.nodes.items, 0..) |*node, i| {
        if (!node.alive or node.kind != .popup) continue;
        const popup_handle = tree.handleFromIndex(@intCast(i));
        if (!node.kind.popup.close_on_outside_click) continue;
        if (target) |t| {
            if (popupOwnsTarget(tree, popup_handle, t)) continue;
        }
        closePopupSubtree(tree, popup_handle);
    }
}

pub fn directPopupChild(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .popup) return child;
    }
    return null;
}

pub fn toggleOwnedPopup(tree: *widget.Tree, owner: widget.NodeHandle, mouse: ?*MouseState) void {
    const popup = directPopupChild(tree, owner) orelse return;
    if (tree.getConst(popup).kind.popup.visible) {
        closePopupSubtree(tree, popup);
        if (mouse) |m| m.layout_changed = true;
    } else {
        openOwnedPopup(tree, owner, mouse);
    }
}

pub fn openOwnedPopup(tree: *widget.Tree, owner: widget.NodeHandle, mouse: ?*MouseState) void {
    const popup = directPopupChild(tree, owner) orelse return;
    var changed = false;
    if (tree.getConst(owner).parent) |parent_handle| {
        changed = closeSiblingOwnedPopups(tree, parent_handle, owner) or changed;
    }
    if (!tree.getConst(popup).kind.popup.visible) {
        tree.get(popup).kind.popup.visible = true;
        changed = true;
    }
    if (changed) {
        if (mouse) |m| {
            m.layout_changed = true;
        }
    }
}

pub fn closeSiblingOwnedPopups(tree: *widget.Tree, parent: widget.NodeHandle, keep_owner: widget.NodeHandle) bool {
    var changed = false;
    var iter = tree.children(parent);
    while (iter.next()) |child| {
        if (child.eql(keep_owner)) continue;
        const popup = directPopupChild(tree, child) orelse continue;
        if (tree.getConst(popup).kind.popup.visible) {
            closePopupSubtree(tree, popup);
            changed = true;
        }
    }
    return changed;
}

pub fn closePopupSubtree(tree: *widget.Tree, popup: widget.NodeHandle) void {
    closeDescendantPopups(tree, popup);
    tree.get(popup).kind.popup.visible = false;
    if (tree.getConst(popup).parent) |parent_handle| {
        if (tree.getConst(parent_handle).kind == .dropdown) {
            tree.get(parent_handle).kind.dropdown.open = false;
        }
    }
}

pub fn closeDescendantPopups(tree: *widget.Tree, handle: widget.NodeHandle) void {
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .popup) {
            closePopupSubtree(tree, child);
        } else {
            closeDescendantPopups(tree, child);
        }
    }
}

pub fn popupOwnsTarget(tree: *const widget.Tree, popup: widget.NodeHandle, target: widget.NodeHandle) bool {
    if (target.eql(popup) or tree_util.isDescendantOf(tree, target, popup)) return true;
    const owner = tree.getConst(popup).parent orelse return false;
    return target.eql(owner) or tree_util.isDescendantOf(tree, target, owner);
}

pub fn popupRoot(tree: *const widget.Tree, popup: widget.NodeHandle) widget.NodeHandle {
    var current = popup;
    while (true) {
        const owner = tree.getConst(current).parent orelse return current;
        const ancestor_popup = findAncestorPopup(tree, owner) orelse return current;
        current = ancestor_popup;
    }
}

pub fn findAncestorPopup(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var current: ?widget.NodeHandle = handle;
    while (current) |candidate| {
        if (tree.getConst(candidate).kind == .popup) return candidate;
        current = tree.getConst(candidate).parent;
    }
    return null;
}

pub fn findAncestorMenu(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var current: ?widget.NodeHandle = handle;
    while (current) |candidate| {
        if (tree.getConst(candidate).kind == .menu) return candidate;
        current = tree.getConst(candidate).parent;
    }
    return null;
}

pub fn menuBarHasOpenMenu(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        const popup = directPopupChild(tree, child) orelse continue;
        if (tree.getConst(popup).kind.popup.visible) return true;
    }
    return false;
}

pub fn menuItemIndex(tree: *const widget.Tree, popup: widget.NodeHandle, handle: widget.NodeHandle) ?u16 {
    var idx: u16 = 0;
    var iter = tree.children(popup);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .menu_item) continue;
        if (child.eql(handle)) return idx;
        idx += 1;
    }
    return null;
}
