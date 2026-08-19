const widget = @import("../widget.zig");
const input = @import("goop_input");
const style = @import("../style.zig");
const types = @import("types.zig");
const activation = @import("activation.zig");
const menu = @import("menu.zig");
const navigation = @import("navigation.zig");
const text = @import("text.zig");

const MouseState = types.MouseState;
const Clipboard = types.Clipboard;

pub fn handleKey(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, clipboard: ?Clipboard, k: input.Event.Key) void {
    updateModifierState(mouse, k);
    if (handleMnemonicKey(tree, mouse, k)) return;
    if (text.handleClipboardShortcut(tree, mouse, clipboard, k)) return;
    if (navigation.handleFocusTraversalKey(tree, mouse, k)) return;
    if (text.handleTextEditorKey(tree, mouse, k)) return;
    if (navigation.handleFocusedNavigationKey(tree, mouse, theme, k)) return;
    if (handleActivationKey(tree, mouse, k)) return;
    if (handleEscapeKey(tree, mouse, k)) return;
}

/// The ASCII letter a key produces, or null for non-letters. Keycodes `a`..`z`
/// are contiguous from 0, so the offset maps directly.
fn keycodeLetter(keycode: input.Keycode) ?u8 {
    const value = @intFromEnum(keycode);
    if (value <= @intFromEnum(input.Keycode.z)) return @as(u8, 'a') + @as(u8, @intCast(value));
    return null;
}

/// win32-style access keys. Alt+<letter> opens the matching menu-bar menu; with
/// a menu open, a bare <letter> activates the item with that mnemonic. Returns
/// false (does not consume) for ordinary typing so text input is unaffected.
fn handleMnemonicKey(tree: *widget.Tree, mouse: *MouseState, k: input.Event.Key) bool {
    if (!keyPressed(k)) return false;
    const letter = keycodeLetter(k.keycode) orelse return false;

    if (k.mods.alt and !k.mods.ctrl and !k.mods.super) {
        const menu_handle = menu.menuBarMenuByMnemonic(tree, letter) orelse return false;
        const bar = tree.getConst(menu_handle).parent orelse return false;
        _ = menu.closeSiblingOwnedPopups(tree, bar, menu_handle, mouse);
        menu.openOwnedPopup(tree, menu_handle, mouse);
        mouse.focused = menu_handle;
        return true;
    }

    if (!k.mods.ctrl and !k.mods.alt and !k.mods.super and menu.anyMenuPopupVisible(tree)) {
        if (menu.visibleMenuItemByMnemonic(tree, letter)) |item| {
            activation.fireClick(tree, item, mouse);
        }
        // A menu is open: swallow the letter either way so it never leaks to
        // other handlers as text.
        return true;
    }
    return false;
}

fn keyPressed(k: input.Event.Key) bool {
    return k.state == .pressed;
}

fn keyPressedOrRepeat(k: input.Event.Key) bool {
    return k.state == .pressed or k.state == .repeat;
}

fn updateModifierState(mouse: *MouseState, k: input.Event.Key) void {
    // Modifier state is read from two sources:
    //   1. `Key.mods` set by embedders that translate native modifier state directly.
    //   2. Discrete modifier press/release events from embedders that do not fill `mods`.
    if (k.mods.shift or k.mods.ctrl) {
        mouse.shift_down = k.mods.shift;
        mouse.ctrl_down = k.mods.ctrl;
    }
    switch (k.keycode) {
        .left_shift, .right_shift => mouse.shift_down = keyPressedOrRepeat(k),
        .left_ctrl, .right_ctrl => mouse.ctrl_down = keyPressedOrRepeat(k),
        else => {},
    }
}

fn handleActivationKey(tree: *widget.Tree, mouse: *MouseState, k: input.Event.Key) bool {
    if (k.keycode != .space and k.keycode != .enter) return false;
    if (!keyPressed(k)) return true;
    const focused = mouse.focused orelse return true;
    if (text.treeItemEditing(tree, focused)) {
        if (k.keycode == .enter) activation.commitTreeItemRename(tree, focused, mouse);
    } else if (text.numericEditorEditing(tree, focused)) {
        if (k.keycode == .enter) _ = text.commitNumericEditor(tree, focused, mouse);
    } else if (text.focusedTextEditor(tree, focused) == null) {
        activation.fireClick(tree, focused, mouse);
    }
    return true;
}

fn handleEscapeKey(tree: *widget.Tree, mouse: *MouseState, k: input.Event.Key) bool {
    if (k.keycode != .escape) return false;
    if (!keyPressed(k)) return true;
    if (mouse.focused) |focused| {
        if (text.treeItemEditing(tree, focused)) {
            activation.cancelTreeItemRename(tree, focused);
        } else if (text.numericEditorEditing(tree, focused)) {
            text.cancelNumericEditor(tree, focused);
        } else {
            menu.closeAllPopups(tree, mouse);
        }
    } else {
        menu.closeAllPopups(tree, mouse);
    }
    return true;
}
