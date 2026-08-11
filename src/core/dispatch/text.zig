const std = @import("std");
const widget = @import("../widget.zig");
const input = @import("goop_input");
const types = @import("types.zig");
const selection = @import("selection.zig");

const MouseState = types.MouseState;
const Clipboard = types.Clipboard;

fn keyPressed(k: input.Event.Key) bool {
    return k.state == .pressed;
}

fn keyPressedOrRepeat(k: input.Event.Key) bool {
    return k.state == .pressed or k.state == .repeat;
}

pub fn handleClipboardShortcut(tree: *widget.Tree, mouse: *MouseState, clipboard: ?Clipboard, k: input.Event.Key) bool {
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
                        if (selection.selectAllGridSelector(tree, selector)) mouse.emitSelection(tree, selector);
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
                mouse.emitText(tree, focused, editor.content(), false);
            }
            return true;
        },
        .v => {
            if (!keyPressed(k)) return true;
            const cb = clipboard orelse return true;
            const focused = mouse.focused orelse return true;
            const editor = focusedTextEditor(tree, focused) orelse return true;
            if (cb.getText()) |text_value| {
                const could_change = text_value.len > 0 or editor.hasSelection();
                editor.insertSlice(text_value);
                if (could_change) mouse.emitText(tree, focused, editor.content(), false);
            }
            return true;
        },
        else => return false,
    }
}

pub fn handleTextEditorKey(tree: *widget.Tree, mouse: *MouseState, k: input.Event.Key) bool {
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
            const changed = editor.hasSelection() or editor.cursor > 0;
            if (mouse.ctrl_down) editor.deleteBackWord() else editor.deleteBack();
            if (changed) mouse.emitText(tree, focused, editor.content(), false);
            return true;
        },
        .delete => {
            const changed = editor.hasSelection() or editor.cursor < editor.len;
            if (mouse.ctrl_down) editor.deleteForwardWord() else editor.deleteForward();
            if (changed) mouse.emitText(tree, focused, editor.content(), false);
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

pub fn handleText(tree: *widget.Tree, mouse: *MouseState, t: input.Event.Text) void {
    if (mouse.focused) |f| {
        if (focusedTextEditor(tree, f)) |editor| {
            if (isPrintableTextCodepoint(t.codepoint) and
                (!numericEditorEditing(tree, f) or isNumericEditorCodepoint(t.codepoint)))
            {
                const could_change = editor.len < editor.buffer.len or editor.hasSelection();
                editor.insertCodepoint(t.codepoint);
                if (could_change) mouse.emitText(tree, f, editor.content(), false);
            }
        } else if (isPrintableTextCodepoint(t.codepoint)) {
            beginNumericEditorTextInput(tree, f, t.codepoint);
            if (focusedTextEditor(tree, f)) |editor| mouse.emitText(tree, f, editor.content(), false);
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
    if (!tree.isAlive(handle)) return null;
    const node = tree.get(handle);
    return textKindOps(node.kind).editor(node);
}

pub fn treeItemEditing(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    if (!tree.isAlive(handle)) return false;
    const node = tree.getConst(handle);
    return node.kind == .tree_item and node.kind.tree_item.editing;
}

pub fn numericEditorEditing(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    if (!tree.isAlive(handle)) return false;
    const node = tree.getConst(handle);
    return textKindOps(node.kind).numeric_editing(node);
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
    const node = tree.getConst(handle);
    textKindOps(node.kind).begin_numeric_text(tree, handle, codepoint);
}

pub fn commitNumericEditor(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) bool {
    if (!tree.isAlive(handle)) return false;
    const node = tree.get(handle);
    const result = textKindOps(node.kind).commit_numeric(node) orelse return false;
    if (result == .changed) {
        switch (node.kind) {
            .drag_value => |value| mouse.emitScalar(tree, handle, value.value),
            .spinbox => |value| mouse.emitScalar(tree, handle, value.value),
            else => {},
        }
    }
    return result != .invalid;
}

pub fn cancelNumericEditor(tree: *widget.Tree, handle: widget.NodeHandle) void {
    if (!tree.isAlive(handle)) return;
    const node = tree.get(handle);
    textKindOps(node.kind).cancel_numeric(node);
}

const TextKindOps = struct {
    editor: EditorGetter = noTextEditor,
    numeric_editing: NumericEditingFn = numericNotEditing,
    begin_numeric_text: BeginNumericTextFn = beginNumericTextNoop,
    commit_numeric: CommitNumericFn = commitNumericNone,
    cancel_numeric: CancelNumericFn = cancelNumericNoop,
};

const EditorGetter = *const fn (*widget.Node) ?*widget.WidgetKind.TextInput;
const NumericEditingFn = *const fn (*const widget.Node) bool;
const BeginNumericTextFn = *const fn (*widget.Tree, widget.NodeHandle, u21) void;
const CommitNumericFn = *const fn (*widget.Node) ?widget.CommitResult;
const CancelNumericFn = *const fn (*widget.Node) void;

fn textKindOps(kind: widget.WidgetKind) TextKindOps {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return text_kind_ops[@intFromEnum(tag)];
}

const text_kind_ops = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var ops: [std.meta.fields(Tag).len]TextKindOps = undefined;
    for (&ops) |*op| op.* = .{};
    ops[@intFromEnum(Tag.text_input)] = .{ .editor = textInputEditor };
    ops[@intFromEnum(Tag.tree_item)] = .{ .editor = treeItemEditor };
    ops[@intFromEnum(Tag.drag_value)] = .{
        .editor = dragValueEditor,
        .numeric_editing = dragValueEditing,
        .begin_numeric_text = beginDragValueText,
        .commit_numeric = commitDragValue,
        .cancel_numeric = cancelDragValue,
    };
    ops[@intFromEnum(Tag.spinbox)] = .{
        .editor = spinBoxEditor,
        .numeric_editing = spinBoxEditing,
        .begin_numeric_text = beginSpinBoxText,
        .commit_numeric = commitSpinBox,
        .cancel_numeric = cancelSpinBox,
    };
    break :blk ops;
};

fn noTextEditor(_: *widget.Node) ?*widget.WidgetKind.TextInput {
    return null;
}

fn textInputEditor(node: *widget.Node) ?*widget.WidgetKind.TextInput {
    return &node.kind.text_input;
}

fn treeItemEditor(node: *widget.Node) ?*widget.WidgetKind.TextInput {
    return if (node.kind.tree_item.editing) &node.kind.tree_item.internal.editor else null;
}

fn dragValueEditor(node: *widget.Node) ?*widget.WidgetKind.TextInput {
    return if (node.kind.drag_value.editing) &node.kind.drag_value.internal.editor else null;
}

fn spinBoxEditor(node: *widget.Node) ?*widget.WidgetKind.TextInput {
    return if (node.kind.spinbox.editing) &node.kind.spinbox.internal.editor else null;
}

fn numericNotEditing(_: *const widget.Node) bool {
    return false;
}

fn dragValueEditing(node: *const widget.Node) bool {
    return node.kind.drag_value.editing;
}

fn spinBoxEditing(node: *const widget.Node) bool {
    return node.kind.spinbox.editing;
}

fn beginNumericTextNoop(_: *widget.Tree, _: widget.NodeHandle, _: u21) void {}

fn beginDragValueText(tree: *widget.Tree, handle: widget.NodeHandle, codepoint: u21) void {
    beginDragValueEdit(tree, handle);
    tree.get(handle).kind.drag_value.internal.editor.insertCodepoint(codepoint);
}

fn beginSpinBoxText(tree: *widget.Tree, handle: widget.NodeHandle, codepoint: u21) void {
    beginSpinBoxEdit(tree, handle);
    tree.get(handle).kind.spinbox.internal.editor.insertCodepoint(codepoint);
}

fn commitNumericNone(_: *widget.Node) ?widget.CommitResult {
    return null;
}

fn commitDragValue(node: *widget.Node) ?widget.CommitResult {
    return node.kind.drag_value.commitEdit();
}

fn commitSpinBox(node: *widget.Node) ?widget.CommitResult {
    return node.kind.spinbox.commitEdit();
}

fn cancelNumericNoop(_: *widget.Node) void {}

fn cancelDragValue(node: *widget.Node) void {
    node.kind.drag_value.cancelEdit();
}

fn cancelSpinBox(node: *widget.Node) void {
    node.kind.spinbox.cancelEdit();
}

pub fn commitOrCancelNumericEditorOnBlur(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    if (!numericEditorEditing(tree, handle)) return;
    if (!commitNumericEditor(tree, handle, mouse)) cancelNumericEditor(tree, handle);
}
