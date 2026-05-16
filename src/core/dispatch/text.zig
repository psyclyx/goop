const std = @import("std");
const widget = @import("../widget.zig");
const event = @import("../event.zig");
const types = @import("types.zig");
const selection = @import("selection.zig");

const MouseState = types.MouseState;
const Clipboard = types.Clipboard;

fn keyPressed(k: event.Event.Key) bool {
    return k.state == .pressed;
}

fn keyPressedOrRepeat(k: event.Event.Key) bool {
    return k.state == .pressed or k.state == .repeat;
}

pub fn handleClipboardShortcut(tree: *widget.Tree, mouse: *MouseState, clipboard: ?Clipboard, k: event.Event.Key) bool {
    if (!mouse.ctrl_down) return false;
    switch (k.keycode) {
        .a => {
            if (!keyPressedOrRepeat(k)) return true;
            const focused = mouse.focused orelse return true;
            if (focusedTextEditor(tree, focused)) |editor| {
                if (editor.len > 0) {
                    editor.selection_anchor = 0;
                    editor.cursor = editor.len;
                }
            } else if (tree.getConst(focused).kind == .grid_item) {
                if (widget.gridItemParentSelector(tree, focused)) |selector| {
                    if (tree.getConst(selector).kind.grid_selector.selection_mode == .multiple) {
                        _ = selection.selectAllGridSelector(tree, selector);
                    }
                }
            }
            return true;
        },
        .c => {
            if (!keyPressed(k)) return true;
            const cb = clipboard orelse return true;
            const focused = mouse.focused orelse return true;
            const editor = focusedTextEditor(tree, focused) orelse return true;
            if (editor.hasSelection()) cb.setText(editor.selectedContent());
            return true;
        },
        .x => {
            if (!keyPressed(k)) return true;
            const cb = clipboard orelse return true;
            const focused = mouse.focused orelse return true;
            const editor = focusedTextEditor(tree, focused) orelse return true;
            if (editor.hasSelection()) {
                cb.setText(editor.selectedContent());
                editor.deleteSelection();
            }
            return true;
        },
        .v => {
            if (!keyPressed(k)) return true;
            const cb = clipboard orelse return true;
            const focused = mouse.focused orelse return true;
            const editor = focusedTextEditor(tree, focused) orelse return true;
            if (cb.getText()) |text| editor.insertSlice(text);
            return true;
        },
        else => return false,
    }
}

pub fn handleTextEditorKey(tree: *widget.Tree, mouse: *MouseState, k: event.Event.Key) bool {
    if (!keyPressedOrRepeat(k)) return false;
    const focused = mouse.focused orelse return switch (k.keycode) {
        .backspace, .delete, .left, .right, .home, .end => true,
        else => false,
    };
    const editor = focusedTextEditor(tree, focused) orelse return switch (k.keycode) {
        .backspace, .delete => true,
        else => false,
    };

    switch (k.keycode) {
        .backspace => {
            if (mouse.ctrl_down) editor.deleteBackWord() else editor.deleteBack();
            return true;
        },
        .delete => {
            if (mouse.ctrl_down) editor.deleteForwardWord() else editor.deleteForward();
            return true;
        },
        .left => {
            moveTextCursorLeft(editor, mouse);
            return true;
        },
        .right => {
            moveTextCursorRight(editor, mouse);
            return true;
        },
        .home => {
            if (mouse.shift_down) {
                if (editor.selection_anchor == null) editor.selection_anchor = editor.cursor;
            } else {
                editor.clearSelection();
            }
            editor.cursor = 0;
            return true;
        },
        .end => {
            if (mouse.shift_down) {
                if (editor.selection_anchor == null) editor.selection_anchor = editor.cursor;
            } else {
                editor.clearSelection();
            }
            editor.cursor = editor.len;
            return true;
        },
        else => return false,
    }
}

pub fn moveTextCursorLeft(editor: *widget.WidgetKind.TextInput, mouse: *const MouseState) void {
    if (mouse.shift_down) {
        if (editor.selection_anchor == null) editor.selection_anchor = editor.cursor;
        if (mouse.ctrl_down) {
            editor.cursor = editor.prevWordBoundary(editor.cursor);
        } else if (editor.cursor > 0) {
            editor.cursor = editor.prevCodepointBoundary(editor.cursor);
        }
    } else if (editor.hasSelection()) {
        editor.cursor = editor.selectionRange().start;
        editor.clearSelection();
    } else if (mouse.ctrl_down) {
        editor.cursor = editor.prevWordBoundary(editor.cursor);
    } else if (editor.cursor > 0) {
        editor.cursor = editor.prevCodepointBoundary(editor.cursor);
    }
}

pub fn moveTextCursorRight(editor: *widget.WidgetKind.TextInput, mouse: *const MouseState) void {
    if (mouse.shift_down) {
        if (editor.selection_anchor == null) editor.selection_anchor = editor.cursor;
        if (mouse.ctrl_down) {
            editor.cursor = editor.nextWordBoundary(editor.cursor);
        } else if (editor.cursor < editor.len) {
            editor.cursor = editor.nextCodepointBoundary(editor.cursor);
        }
    } else if (editor.hasSelection()) {
        editor.cursor = editor.selectionRange().end;
        editor.clearSelection();
    } else if (mouse.ctrl_down) {
        editor.cursor = editor.nextWordBoundary(editor.cursor);
    } else if (editor.cursor < editor.len) {
        editor.cursor = editor.nextCodepointBoundary(editor.cursor);
    }
}

pub fn handleText(tree: *widget.Tree, mouse: *MouseState, t: event.Event.Text) void {
    if (mouse.focused) |f| {
        if (focusedTextEditor(tree, f)) |editor| {
            if (isPrintableTextCodepoint(t.codepoint) and
                (!numericEditorEditing(tree, f) or isNumericEditorCodepoint(t.codepoint)))
            {
                editor.insertCodepoint(t.codepoint);
            }
        } else if (isPrintableTextCodepoint(t.codepoint)) {
            beginNumericEditorTextInput(tree, f, t.codepoint);
        }
    }
}

pub fn isPrintableTextCodepoint(codepoint: u21) bool {
    if (!std.unicode.utf8ValidCodepoint(codepoint)) return false;
    return switch (codepoint) {
        0x00...0x1F, 0x7F...0x9F => false,
        else => true,
    };
}

pub fn isNumericEditorCodepoint(codepoint: u21) bool {
    return switch (codepoint) {
        '+', '-', '.', 'e', 'E', '0'...'9' => true,
        else => false,
    };
}

pub fn focusedTextEditor(tree: *widget.Tree, handle: widget.NodeHandle) ?*widget.WidgetKind.TextInput {
    const node = tree.get(handle);
    return switch (node.kind) {
        .text_input => &node.kind.text_input,
        .tree_item => if (node.kind.tree_item.editing) &node.kind.tree_item.internal.editor else null,
        .drag_value => if (node.kind.drag_value.editing) &node.kind.drag_value.internal.editor else null,
        .spinbox => if (node.kind.spinbox.editing) &node.kind.spinbox.internal.editor else null,
        else => null,
    };
}

pub fn treeItemEditing(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    return node.kind == .tree_item and node.kind.tree_item.editing;
}

pub fn numericEditorEditing(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    return switch (node.kind) {
        .drag_value => node.kind.drag_value.editing,
        .spinbox => node.kind.spinbox.editing,
        else => false,
    };
}

pub fn beginDragValueEdit(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const drag_value = &tree.get(handle).kind.drag_value;
    if (!drag_value.editing) drag_value.beginEdit();
}

pub fn beginSpinBoxEdit(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const spinbox = &tree.get(handle).kind.spinbox;
    if (!spinbox.editing) spinbox.beginEdit();
}

pub fn beginNumericEditorTextInput(tree: *widget.Tree, handle: widget.NodeHandle, codepoint: u21) void {
    if (!tree.isAlive(handle) or !isNumericEditorCodepoint(codepoint)) return;
    switch (tree.getConst(handle).kind) {
        .drag_value => {
            beginDragValueEdit(tree, handle);
            tree.get(handle).kind.drag_value.internal.editor.insertCodepoint(codepoint);
        },
        .spinbox => {
            beginSpinBoxEdit(tree, handle);
            tree.get(handle).kind.spinbox.internal.editor.insertCodepoint(codepoint);
        },
        else => {},
    }
}

pub fn commitNumericEditor(tree: *widget.Tree, handle: widget.NodeHandle) bool {
    if (!tree.isAlive(handle)) return false;
    const node = tree.get(handle);
    const result: widget.CommitResult = switch (node.kind) {
        .drag_value => node.kind.drag_value.commitEdit(),
        .spinbox => node.kind.spinbox.commitEdit(),
        else => return false,
    };
    if (result == .changed) node.interaction.changed = true;
    return result != .invalid;
}

pub fn cancelNumericEditor(tree: *widget.Tree, handle: widget.NodeHandle) void {
    if (!tree.isAlive(handle)) return;
    const node = tree.get(handle);
    switch (node.kind) {
        .drag_value => node.kind.drag_value.cancelEdit(),
        .spinbox => node.kind.spinbox.cancelEdit(),
        else => {},
    }
}

pub fn commitOrCancelNumericEditorOnBlur(tree: *widget.Tree, handle: widget.NodeHandle) void {
    if (!numericEditorEditing(tree, handle)) return;
    if (!commitNumericEditor(tree, handle)) cancelNumericEditor(tree, handle);
}
