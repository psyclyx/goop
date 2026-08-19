const std = @import("std");
const widget = @import("../widget.zig");
const geometry = @import("../geometry.zig");
const types = @import("types.zig");
const tree_util = @import("tree.zig");

const MouseState = types.MouseState;

fn handleFromIndex(tree: *const widget.Tree, i: usize) widget.NodeHandle {
    return .{ .index = @intCast(i), .generation = tree.nodes.items[i].generation };
}

fn mnemonicMatches(mnemonic: ?u8, letter: u8) bool {
    const key = mnemonic orelse return false;
    return std.ascii.toLower(key) == std.ascii.toLower(letter);
}

/// The menu-bar menu whose mnemonic matches `letter` (for Alt+letter access).
pub fn menuBarMenuByMnemonic(tree: *const widget.Tree, letter: u8) ?widget.NodeHandle {
    for (tree.nodes.items, 0..) |*node, i| {
        if (!node.alive or node.kind != .menu_bar) continue;
        const bar = handleFromIndex(tree, i);
        var it = tree.children(bar);
        while (it.next()) |child| {
            const child_node = tree.getConst(child);
            if (child_node.kind != .menu) continue;
            if (mnemonicMatches(child_node.kind.menu.mnemonic, letter)) return child;
        }
    }
    return null;
}

/// Is any menu popup currently open? Used to decide whether a plain letter is
/// an access key rather than text input.
pub fn anyMenuPopupVisible(tree: *const widget.Tree) bool {
    for (tree.nodes.items) |*node| {
        if (node.alive and node.kind == .popup and node.kind.popup.visible) return true;
    }
    return false;
}

/// The enabled menu item under a visible popup whose mnemonic matches `letter`.
pub fn visibleMenuItemByMnemonic(tree: *const widget.Tree, letter: u8) ?widget.NodeHandle {
    for (tree.nodes.items, 0..) |*node, i| {
        if (!node.alive or node.kind != .popup or !node.kind.popup.visible) continue;
        const popup = handleFromIndex(tree, i);
        var it = tree.children(popup);
        while (it.next()) |child| {
            const child_node = tree.getConst(child);
            if (child_node.kind != .menu_item or child_node.kind.menu_item.disabled) continue;
            if (mnemonicMatches(child_node.kind.menu_item.mnemonic, letter)) return child;
        }
    }
    return null;
}

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
                closePopupSubtree(tree, submenu, mouse);
                mouse.layout_changed = true;
            }
        }
    }
}

pub fn applyMenuSelection(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    const node = tree.getConst(handle);
    const popup_handle = node.parent orelse return;
    if (tree.getConst(popup_handle).kind != .popup) return;

    if (tree.getConst(popup_handle).parent) |parent_handle| {
        const parent = tree.get(parent_handle);
        if (parent.kind == .dropdown) {
            const index = menuItemIndex(tree, popup_handle, handle);
            parent.kind.dropdown.selected_text = node.kind.menu_item.label;
            parent.kind.dropdown.selected_index = index;
            mouse.emitIndex(tree, parent_handle, index);
        }
    }

    closePopupSubtree(tree, popupRoot(tree, popup_handle), mouse);
}

pub fn closeAllPopups(tree: *widget.Tree, mouse: ?*MouseState) void {
    for (tree.nodes.items, 0..) |*node, index| {
        if (!node.alive) continue;
        if (node.kind == .popup and node.kind.popup.visible) {
            const handle = tree.handleFromIndex(@intCast(index));
            if (mouse) |m| m.emitPopupVisibility(tree, handle, false);
        }
        menuCloseAction(node.kind)(node);
    }
}

const MenuCloseAction = *const fn (*widget.Node) void;

fn menuCloseAction(kind: widget.WidgetKind) MenuCloseAction {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return menu_close_actions[@intFromEnum(tag)];
}

const menu_close_actions = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var actions: [std.meta.fields(Tag).len]MenuCloseAction = undefined;
    for (&actions) |*action| action.* = closeMenuNoop;
    actions[@intFromEnum(Tag.popup)] = closePopupNode;
    actions[@intFromEnum(Tag.dropdown)] = closeDropdownNode;
    break :blk actions;
};

fn closeMenuNoop(_: *widget.Node) void {}

fn closePopupNode(node: *widget.Node) void {
    node.kind.popup.visible = false;
}

fn closeDropdownNode(node: *widget.Node) void {
    node.kind.dropdown.open = false;
}

pub fn closePopupsForPress(tree: *widget.Tree, target: ?widget.NodeHandle, mouse: *MouseState) void {
    for (tree.nodes.items, 0..) |*node, i| {
        if (!node.alive or node.kind != .popup) continue;
        const popup_handle = tree.handleFromIndex(@intCast(i));
        if (!node.kind.popup.close_on_outside_click) continue;
        if (target) |t| {
            if (popupOwnsTarget(tree, popup_handle, t)) continue;
        }
        closePopupSubtree(tree, popup_handle, mouse);
    }
}

pub fn directPopupChild(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    return geometry.directPopupChild(tree, handle);
}

pub fn toggleOwnedPopup(tree: *widget.Tree, owner: widget.NodeHandle, mouse: ?*MouseState) void {
    const popup = directPopupChild(tree, owner) orelse return;
    if (tree.getConst(popup).kind.popup.visible) {
        closePopupSubtree(tree, popup, mouse);
        if (mouse) |m| m.layout_changed = true;
    } else {
        openOwnedPopup(tree, owner, mouse);
    }
}

pub fn openOwnedPopup(tree: *widget.Tree, owner: widget.NodeHandle, mouse: ?*MouseState) void {
    const popup = directPopupChild(tree, owner) orelse return;
    var changed = false;
    if (tree.getConst(owner).parent) |parent_handle| {
        changed = closeSiblingOwnedPopups(tree, parent_handle, owner, mouse) or changed;
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

pub fn closeSiblingOwnedPopups(tree: *widget.Tree, parent: widget.NodeHandle, keep_owner: widget.NodeHandle, mouse: ?*MouseState) bool {
    var changed = false;
    var iter = tree.children(parent);
    while (iter.next()) |child| {
        if (child.eql(keep_owner)) continue;
        const popup = directPopupChild(tree, child) orelse continue;
        if (tree.getConst(popup).kind.popup.visible) {
            closePopupSubtree(tree, popup, mouse);
            changed = true;
        }
    }
    return changed;
}

pub fn closePopupSubtree(tree: *widget.Tree, popup: widget.NodeHandle, mouse: ?*MouseState) void {
    const was_visible = tree.getConst(popup).kind.popup.visible;
    closeDescendantPopups(tree, popup);
    tree.get(popup).kind.popup.visible = false;
    if (was_visible) if (mouse) |m| m.emitPopupVisibility(tree, popup, false);
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
            closePopupSubtree(tree, child, null);
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

test "mnemonic lookup finds menu-bar menus and visible menu items" {
    var tree = widget.Tree.init(std.testing.allocator);
    defer tree.deinit();

    const bar = try tree.addRoot(.{ .menu_bar = .{} });
    const file = try tree.addChild(bar, .{ .menu = .{ .label = "File", .mnemonic = 'F' } });
    const popup = try tree.addChild(file, .{ .popup = .{ .placement = .below_start, .visible = false } });
    const refresh = try tree.addChild(popup, .{ .menu_item = .{ .label = "Refresh", .mnemonic = 'R' } });
    _ = try tree.addChild(popup, .{ .menu_item = .{ .label = "Quit", .mnemonic = 'Q', .disabled = true } });

    // Menu bar lookup is case-insensitive and matches the mnemonic char.
    try std.testing.expect(menuBarMenuByMnemonic(&tree, 'f').?.eql(file));
    try std.testing.expectEqual(@as(?widget.NodeHandle, null), menuBarMenuByMnemonic(&tree, 'z'));

    // Items are only reachable while their popup is visible.
    try std.testing.expect(!anyMenuPopupVisible(&tree));
    try std.testing.expectEqual(@as(?widget.NodeHandle, null), visibleMenuItemByMnemonic(&tree, 'r'));
    tree.get(popup).kind.popup.visible = true;
    try std.testing.expect(anyMenuPopupVisible(&tree));
    try std.testing.expect(visibleMenuItemByMnemonic(&tree, 'r').?.eql(refresh));
    // Disabled items never match.
    try std.testing.expectEqual(@as(?widget.NodeHandle, null), visibleMenuItemByMnemonic(&tree, 'q'));
}
