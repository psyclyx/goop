const widget = @import("../widget.zig");
const event = @import("../event.zig");
const style = @import("../style.zig");
const types = @import("types.zig");
const activation = @import("activation.zig");
const menu = @import("menu.zig");
const navigation = @import("navigation.zig");
const text = @import("text.zig");

const MouseState = types.MouseState;
const Clipboard = types.Clipboard;

pub fn handleKey(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, clipboard: ?Clipboard, k: event.Event.Key) void {
    updateModifierState(mouse, k);
    if (text.handleClipboardShortcut(tree, mouse, clipboard, k)) return;
    if (navigation.handleFocusTraversalKey(tree, mouse, k)) return;
    if (text.handleTextEditorKey(tree, mouse, k)) return;
    if (navigation.handleFocusedNavigationKey(tree, mouse, theme, k)) return;
    if (handleActivationKey(tree, mouse, k)) return;
    if (handleEscapeKey(tree, mouse, k)) return;
}

fn keyPressed(k: event.Event.Key) bool {
    return k.state == .pressed;
}

fn keyPressedOrRepeat(k: event.Event.Key) bool {
    return k.state == .pressed or k.state == .repeat;
}

fn updateModifierState(mouse: *MouseState, k: event.Event.Key) void {
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

fn handleActivationKey(tree: *widget.Tree, mouse: *MouseState, k: event.Event.Key) bool {
    if (k.keycode != .space and k.keycode != .enter) return false;
    if (!keyPressed(k)) return true;
    const focused = mouse.focused orelse return true;
    if (text.treeItemEditing(tree, focused)) {
        if (k.keycode == .enter) activation.commitTreeItemRename(tree, focused);
    } else if (text.numericEditorEditing(tree, focused)) {
        if (k.keycode == .enter) _ = text.commitNumericEditor(tree, focused);
    } else if (text.focusedTextEditor(tree, focused) == null) {
        activation.fireClick(tree, focused);
    }
    return true;
}

fn handleEscapeKey(tree: *widget.Tree, mouse: *MouseState, k: event.Event.Key) bool {
    if (k.keycode != .escape) return false;
    if (!keyPressed(k)) return true;
    if (mouse.focused) |focused| {
        if (text.treeItemEditing(tree, focused)) {
            activation.cancelTreeItemRename(tree, focused);
        } else if (text.numericEditorEditing(tree, focused)) {
            text.cancelNumericEditor(tree, focused);
        } else {
            menu.closeAllPopups(tree);
        }
    } else {
        menu.closeAllPopups(tree);
    }
    return true;
}
