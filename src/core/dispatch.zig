const std = @import("std");
const widget = @import("widget.zig");
const event = @import("event.zig");
const focus = @import("focus.zig");
const hittest = @import("hittest.zig");
const layout = @import("layout.zig");
const draw = @import("draw.zig");

/// Transient input state tracked across events.
pub const SecondaryClick = struct {
    target: widget.NodeHandle,
    x: f32,
    y: f32,
};

pub const MouseState = struct {
    x: f32 = 0,
    y: f32 = 0,
    left_down: bool = false,
    right_down: bool = false,
    /// The widget that the left button went down on (for click detection).
    press_target: ?widget.NodeHandle = null,
    right_press_target: ?widget.NodeHandle = null,
    /// The widget currently being dragged, if any.
    drag_target: ?widget.NodeHandle = null,
    drag_origin_x: f32 = 0,
    drag_origin_y: f32 = 0,
    drag_origin_value: f32 = 0,
    drag_origin_secondary_value: f32 = 0,
    drag_origin_extent: f32 = 0,
    drag_column_index: ?u8 = null,
    /// The currently keyboard-focused widget, if any.
    focused: ?widget.NodeHandle = null,
    /// The widget currently hovered by the pointer, if any.
    hovered: ?widget.NodeHandle = null,
    /// Set when dispatch changes widget state that affects layout.
    layout_changed: bool = false,
    /// The most recent secondary click observed this frame.
    last_secondary_click: ?SecondaryClick = null,
    /// Whether a shift key is currently held.
    shift_down: bool = false,
    /// Whether a ctrl key is currently held.
    ctrl_down: bool = false,
    /// Double-click detection state.
    last_click_time_ms: u64 = 0,
    last_click_x: f32 = 0,
    last_click_y: f32 = 0,

    /// Maximum time between clicks for a double-click (milliseconds).
    const double_click_time_ms: u64 = 400;
    /// Maximum distance between clicks for a double-click (pixels).
    const double_click_dist: f32 = 5;
};

/// Clipboard interface for copy/paste. Provided by the embedder.
pub const Clipboard = struct {
    ptr: *anyopaque,
    getTextFn: *const fn (*anyopaque) ?[]const u8,
    setTextFn: *const fn (*anyopaque, []const u8) void,

    pub fn getText(self: Clipboard) ?[]const u8 {
        return self.getTextFn(self.ptr);
    }

    pub fn setText(self: Clipboard, text: []const u8) void {
        self.setTextFn(self.ptr, text);
    }
};

/// Process a batch of events against the widget tree.
/// Updates interaction state (hovered, pressed) and widget state (clicked).
/// Call after doLayout so layout_rects are populated.
const style = @import("style.zig");

pub fn process(tree: *widget.Tree, events: []const event.Event, mouse: *MouseState, theme: style.Theme) void {
    processWithClipboard(tree, events, mouse, theme, null, null);
}

pub fn processWithClipboard(tree: *widget.Tree, events: []const event.Event, mouse: *MouseState, theme: style.Theme, clipboard: ?Clipboard, text_ctx: ?*const layout.TextMeasureCtx) void {
    for (events) |ev| {
        processOne(tree, ev, mouse, theme, clipboard, text_ctx);
    }
}

fn processOne(tree: *widget.Tree, ev: event.Event, mouse: *MouseState, theme: style.Theme, clipboard: ?Clipboard, text_ctx: ?*const layout.TextMeasureCtx) void {
    switch (ev) {
        .mouse_move => |mm| {
            mouse.x = mm.x;
            mouse.y = mm.y;
            if (mouse.drag_target) |dt| {
                switch (tree.getConst(dt).kind) {
                    .slider => updateSliderValue(tree, dt, mouse.x, theme),
                    .drag_value => updateDragValue(tree, dt, mouse.x, mouse),
                    .splitter => updateSplitterRatio(tree, dt, mouse.x, mouse.y, mouse, theme),
                    .table => {
                        if (updateTableColumns(tree, dt, mouse)) mouse.layout_changed = true;
                    },
                    else => {},
                }
            }
            // Text editor drag selection
            if (mouse.left_down) {
                if (mouse.press_target) |pt| {
                    dragTextEditorSelection(tree, pt, mm.x, theme, text_ctx);
                }
            }
            const hovered = updateHover(tree, mouse);
            if (hoverChanged(mouse, hovered) and treeHasTooltip(tree)) {
                mouse.layout_changed = true;
            }
            mouse.hovered = hovered;
            if (!mouse.left_down) syncMenuHover(tree, hovered, mouse);
        },
        .mouse_button => |mb| {
            mouse.x = mb.x;
            mouse.y = mb.y;
            if (mb.button == .left) {
                if (mb.state == .pressed) {
                    handlePrimaryPress(tree, mouse, theme, text_ctx, mb);
                    mouse.last_click_time_ms = mb.timestamp_ms;
                    mouse.last_click_x = mb.x;
                    mouse.last_click_y = mb.y;
                } else {
                    handlePrimaryRelease(tree, mouse);
                }
            } else if (mb.button == .right) {
                if (mb.state == .pressed) {
                    handleSecondaryPress(tree, mouse);
                } else {
                    handleSecondaryRelease(tree, mouse);
                }
            }
        },
        .mouse_scroll => |ms| {
            // Find the scroll area under the cursor and adjust scroll offset
            const target = hittest.hitTestKind(tree, mouse.x, mouse.y, .scroll_area);
            if (target) |t| {
                const node = tree.get(t);
                node.kind.scroll_area.scroll_x += ms.dx;
                node.kind.scroll_area.scroll_y += ms.dy;
                clampScroll(tree, t);
            }
        },
        .key => |k| {
            switch (k.keycode) {
                .left_shift, .right_shift => {
                    mouse.shift_down = k.state == .pressed or k.state == .repeat;
                },
                .left_ctrl, .right_ctrl => {
                    mouse.ctrl_down = k.state == .pressed or k.state == .repeat;
                },
                .a => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.ctrl_down) {
                            if (mouse.focused) |f| {
                                if (focusedTextEditor(tree, f)) |editor| {
                                    if (editor.len > 0) {
                                        editor.selection_anchor = 0;
                                        editor.cursor = editor.len;
                                    }
                                }
                            }
                        }
                    }
                },
                .c => {
                    if (k.state == .pressed and mouse.ctrl_down) {
                        if (clipboard) |cb| {
                            if (mouse.focused) |f| {
                                if (focusedTextEditor(tree, f)) |editor| {
                                    if (editor.hasSelection()) {
                                        cb.setText(editor.selectedContent());
                                    }
                                }
                            }
                        }
                    }
                },
                .x => {
                    if (k.state == .pressed and mouse.ctrl_down) {
                        if (clipboard) |cb| {
                            if (mouse.focused) |f| {
                                if (focusedTextEditor(tree, f)) |editor| {
                                    if (editor.hasSelection()) {
                                        cb.setText(editor.selectedContent());
                                        editor.deleteSelection();
                                    }
                                }
                            }
                        }
                    }
                },
                .v => {
                    if (k.state == .pressed and mouse.ctrl_down) {
                        if (clipboard) |cb| {
                            if (mouse.focused) |f| {
                                if (focusedTextEditor(tree, f)) |editor| {
                                    if (cb.getText()) |text| {
                                        editor.insertSlice(text);
                                    }
                                }
                            }
                        }
                    }
                },
                .tab => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.shift_down) {
                            mouse.focused = focus.focusPrev(tree, mouse.focused);
                        } else {
                            mouse.focused = focus.focusNext(tree, mouse.focused);
                        }
                        focus.syncFocusFlags(tree, mouse.focused);
                    }
                },
                .backspace => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.focused) |f| {
                            if (focusedTextEditor(tree, f)) |editor| {
                                if (mouse.ctrl_down) {
                                    editor.deleteBackWord();
                                } else {
                                    editor.deleteBack();
                                }
                            }
                        }
                    }
                },
                .delete => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.focused) |f| {
                            if (focusedTextEditor(tree, f)) |editor| {
                                if (mouse.ctrl_down) {
                                    editor.deleteForwardWord();
                                } else {
                                    editor.deleteForward();
                                }
                            }
                        }
                    }
                },
                .left => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.focused) |f| {
                            if (focusedTextEditor(tree, f)) |editor| {
                                if (mouse.shift_down) {
                                    if (editor.selection_anchor == null) editor.selection_anchor = editor.cursor;
                                    if (mouse.ctrl_down) {
                                        editor.cursor = editor.prevWordBoundary(editor.cursor);
                                    } else if (editor.cursor > 0) {
                                        editor.cursor -= 1;
                                    }
                                } else if (editor.hasSelection()) {
                                    editor.cursor = editor.selectionRange().start;
                                    editor.clearSelection();
                                } else if (mouse.ctrl_down) {
                                    editor.cursor = editor.prevWordBoundary(editor.cursor);
                                } else if (editor.cursor > 0) {
                                    editor.cursor -= 1;
                                }
                            } else if (tree.getConst(f).kind == .drag_value) {
                                stepDragValue(tree, f, -1);
                            } else if (tree.getConst(f).kind == .spinbox) {
                                stepSpinBox(tree, f, -1, false);
                            } else if (tree.getConst(f).kind == .splitter and tree.getConst(f).kind.splitter.direction == .row) {
                                stepSplitter(tree, f, -1, theme);
                            } else if (tree.getConst(f).kind == .tab_item) {
                                if (prevTabItem(tree, f)) |prev| {
                                    selectTabItem(tree, prev);
                                    mouse.focused = prev;
                                    focus.syncFocusFlags(tree, mouse.focused);
                                }
                            } else if (tree.getConst(f).kind == .tree_item) {
                                const node = tree.get(f);
                                if (node.kind.tree_item.expanded and hasTreeItemChildren(tree, f)) {
                                    toggleTreeItem(tree, f);
                                } else if (findTreeParent(tree, f)) |parent| {
                                    mouse.focused = parent;
                                    focus.syncFocusFlags(tree, mouse.focused);
                                }
                            }
                        }
                    }
                },
                .right => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.focused) |f| {
                            if (focusedTextEditor(tree, f)) |editor| {
                                if (mouse.shift_down) {
                                    if (editor.selection_anchor == null) editor.selection_anchor = editor.cursor;
                                    if (mouse.ctrl_down) {
                                        editor.cursor = editor.nextWordBoundary(editor.cursor);
                                    } else if (editor.cursor < editor.len) {
                                        editor.cursor += 1;
                                    }
                                } else if (editor.hasSelection()) {
                                    editor.cursor = editor.selectionRange().end;
                                    editor.clearSelection();
                                } else if (mouse.ctrl_down) {
                                    editor.cursor = editor.nextWordBoundary(editor.cursor);
                                } else if (editor.cursor < editor.len) {
                                    editor.cursor += 1;
                                }
                            } else if (tree.getConst(f).kind == .drag_value) {
                                stepDragValue(tree, f, 1);
                            } else if (tree.getConst(f).kind == .spinbox) {
                                stepSpinBox(tree, f, 1, false);
                            } else if (tree.getConst(f).kind == .splitter and tree.getConst(f).kind.splitter.direction == .row) {
                                stepSplitter(tree, f, 1, theme);
                            } else if (tree.getConst(f).kind == .tab_item) {
                                if (nextTabItem(tree, f)) |next| {
                                    selectTabItem(tree, next);
                                    mouse.focused = next;
                                    focus.syncFocusFlags(tree, mouse.focused);
                                }
                            } else if (tree.getConst(f).kind == .tree_item) {
                                const node = tree.get(f);
                                if (!node.kind.tree_item.expanded and hasTreeItemChildren(tree, f)) {
                                    toggleTreeItem(tree, f);
                                } else if (node.kind.tree_item.expanded) {
                                    mouse.focused = firstChildTreeItem(tree, f) orelse mouse.focused;
                                    focus.syncFocusFlags(tree, mouse.focused);
                                }
                            }
                        }
                    }
                },
                .up => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.focused) |f| {
                            if (tree.getConst(f).kind == .spinbox) {
                                stepSpinBox(tree, f, 1, false);
                            } else if (tree.getConst(f).kind == .drag_value) {
                                stepDragValue(tree, f, 1);
                            } else if (tree.getConst(f).kind == .splitter and tree.getConst(f).kind.splitter.direction == .column) {
                                stepSplitter(tree, f, -1, theme);
                            } else if (tree.getConst(f).kind == .selectable) {
                                if (prevSelectableSibling(tree, f)) |prev| {
                                    _ = selectSelectable(tree, prev);
                                    mouse.focused = prev;
                                    focus.syncFocusFlags(tree, mouse.focused);
                                }
                            } else if (tree.getConst(f).kind == .tree_item and !treeItemEditing(tree, f)) {
                                mouse.focused = prevVisibleTreeItem(tree, f) orelse mouse.focused;
                                focus.syncFocusFlags(tree, mouse.focused);
                            }
                        }
                    }
                },
                .down => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.focused) |f| {
                            if (tree.getConst(f).kind == .spinbox) {
                                stepSpinBox(tree, f, -1, false);
                            } else if (tree.getConst(f).kind == .drag_value) {
                                stepDragValue(tree, f, -1);
                            } else if (tree.getConst(f).kind == .splitter and tree.getConst(f).kind.splitter.direction == .column) {
                                stepSplitter(tree, f, 1, theme);
                            } else if (tree.getConst(f).kind == .selectable) {
                                if (nextSelectableSibling(tree, f)) |next| {
                                    _ = selectSelectable(tree, next);
                                    mouse.focused = next;
                                    focus.syncFocusFlags(tree, mouse.focused);
                                }
                            } else if (tree.getConst(f).kind == .tree_item and !treeItemEditing(tree, f)) {
                                mouse.focused = nextVisibleTreeItem(tree, f) orelse mouse.focused;
                                focus.syncFocusFlags(tree, mouse.focused);
                            }
                        }
                    }
                },
                .home => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.focused) |f| {
                            if (focusedTextEditor(tree, f)) |editor| {
                                if (mouse.shift_down) {
                                    if (editor.selection_anchor == null) editor.selection_anchor = editor.cursor;
                                } else {
                                    editor.clearSelection();
                                }
                                editor.cursor = 0;
                            }
                        }
                    }
                },
                .end => {
                    if (k.state == .pressed or k.state == .repeat) {
                        if (mouse.focused) |f| {
                            if (focusedTextEditor(tree, f)) |editor| {
                                if (mouse.shift_down) {
                                    if (editor.selection_anchor == null) editor.selection_anchor = editor.cursor;
                                } else {
                                    editor.clearSelection();
                                }
                                editor.cursor = editor.len;
                            }
                        }
                    }
                },
                .space, .enter => {
                    if (k.state == .pressed) {
                        if (mouse.focused) |f| {
                            if (treeItemEditing(tree, f)) {
                                if (k.keycode == .enter) commitTreeItemRename(tree, f);
                            } else if (focusedTextEditor(tree, f) == null) {
                                fireClick(tree, f);
                            }
                        }
                    }
                },
                .escape => {
                    if (k.state == .pressed) {
                        if (mouse.focused) |f| {
                            if (treeItemEditing(tree, f)) {
                                cancelTreeItemRename(tree, f);
                            } else {
                                closeAllPopups(tree);
                            }
                        } else {
                            closeAllPopups(tree);
                        }
                    }
                },
                else => {},
            }
        },
        .text => |t| {
            if (mouse.focused) |f| {
                if (focusedTextEditor(tree, f)) |editor| {
                    // Only handle printable ASCII for now
                    if (t.codepoint >= 0x20 and t.codepoint < 0x7F) {
                        editor.insert(@intCast(t.codepoint));
                    }
                }
            }
        },
        else => {},
    }
}

fn focusedTextEditor(tree: *widget.Tree, handle: widget.NodeHandle) ?*widget.WidgetKind.TextInput {
    const node = tree.get(handle);
    return switch (node.kind) {
        .text_input => &node.kind.text_input,
        .tree_item => if (node.kind.tree_item.editing) &node.kind.tree_item.editor else null,
        else => null,
    };
}

fn treeItemEditing(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    return node.kind == .tree_item and node.kind.tree_item.editing;
}

fn dragTextEditorSelection(
    tree: *widget.Tree,
    handle: widget.NodeHandle,
    mouse_x: f32,
    theme: style.Theme,
    text_ctx: ?*const layout.TextMeasureCtx,
) void {
    if (focusedTextEditor(tree, handle)) |editor| {
        if (textEditorTextX(tree, handle, theme)) |text_x| {
            const font_size = tree.getConst(handle).style_override.resolve(theme).font_size;
            const rel_x = mouse_x - text_x;
            editor.cursor = layout.charIndexAtX(editor.content(), editor.len, rel_x, font_size, text_ctx);
        }
    }
}

fn handlePrimaryPress(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: event.Event.MouseButton) void {
    mouse.left_down = true;
    _ = updateHover(tree, mouse);

    const target = hittest.hitTest(tree, mouse.x, mouse.y);
    closePopupsForPress(tree, target);
    mouse.press_target = target;
    if (target) |t| {
        tree.get(t).interaction.pressed = true;

        if (focus.isFocusable(tree.getConst(t).kind)) {
            mouse.focused = t;
            focus.syncFocusFlags(tree, mouse.focused);
        }

        switch (tree.getConst(t).kind) {
            .text_input => {
                const node = tree.get(t);
                const rect = node.layout_rect;
                const resolved = node.style_override.resolve(theme);
                const ti = &node.kind.text_input;
                const text_x = rect.x + resolved.padding.left;
                const rel_x = mouse.x - text_x;
                const rounded = layout.charIndexAtX(ti.content(), ti.len, rel_x, resolved.font_size, text_ctx);

                if (isDoubleClick(mouse, mb)) {
                    const bounds = ti.wordBounds(rounded);
                    ti.selection_anchor = bounds.start;
                    ti.cursor = bounds.end;
                } else if (mouse.shift_down) {
                    if (ti.selection_anchor == null) ti.selection_anchor = ti.cursor;
                    ti.cursor = rounded;
                } else {
                    ti.selection_anchor = rounded;
                    ti.cursor = rounded;
                }
            },
            .slider => {
                mouse.drag_target = t;
                mouse.drag_origin_x = mouse.x;
                mouse.drag_origin_y = mouse.y;
                mouse.drag_origin_value = tree.getConst(t).kind.slider.value;
                updateSliderValue(tree, t, mouse.x, theme);
            },
            .drag_value => {
                mouse.drag_target = t;
                mouse.drag_origin_x = mouse.x;
                mouse.drag_origin_y = mouse.y;
                mouse.drag_origin_value = tree.getConst(t).kind.drag_value.value;
            },
            .splitter => {
                mouse.drag_target = t;
                mouse.drag_origin_x = mouse.x;
                mouse.drag_origin_y = mouse.y;
                mouse.drag_origin_value = tree.getConst(t).kind.splitter.ratio;
            },
            .table => {
                if (widget.tableResizeHandleIndexAtPoint(tree, t, mouse.x, mouse.y)) |divider_index| {
                    const reference_row = widget.tableReferenceRow(tree, t) orelse return;
                    const left_cell = widget.tableCellAt(tree, reference_row, divider_index) orelse return;
                    const right_cell = widget.tableCellAt(tree, reference_row, divider_index + 1) orelse return;
                    mouse.drag_target = t;
                    mouse.drag_origin_x = mouse.x;
                    mouse.drag_origin_y = mouse.y;
                    mouse.drag_origin_value = tree.getConst(left_cell).layout_rect.w;
                    mouse.drag_origin_secondary_value = tree.getConst(right_cell).layout_rect.w;
                    mouse.drag_origin_extent = tree.getConst(reference_row).layout_rect.w;
                    mouse.drag_column_index = divider_index;
                }
            },
            .spinbox => {
                if (clickInSpinBoxDecrement(tree, t, mouse.x)) {
                    stepSpinBox(tree, t, -1, true);
                    tree.get(t).interaction.pressed = false;
                    mouse.press_target = null;
                } else if (clickInSpinBoxIncrement(tree, t, mouse.x)) {
                    stepSpinBox(tree, t, 1, true);
                    tree.get(t).interaction.pressed = false;
                    mouse.press_target = null;
                }
            },
            .tree_item => {
                if (clickInTreeDisclosure(tree, t, mouse.x, theme)) {
                    toggleTreeItem(tree, t);
                } else if (tree.getConst(t).kind.tree_item.editing) {
                    dragTextEditorSelection(tree, t, mouse.x, theme, text_ctx);
                } else {
                    const item = &tree.get(t).kind.tree_item;
                    if (item.editable and shouldBeginTreeRename(item.*, clickInTreeLabel(tree, t, mouse.x, theme), isDoubleClick(mouse, mb))) {
                        item.beginRename();
                        tree.get(t).interaction.pressed = false;
                        mouse.press_target = null;
                    }
                }
            },
            else => {},
        }
    }
}

fn handlePrimaryRelease(tree: *widget.Tree, mouse: *MouseState) void {
    mouse.left_down = false;
    const dragged_target = mouse.drag_target;
    mouse.drag_target = null;
    mouse.drag_column_index = null;
    mouse.drag_origin_secondary_value = 0;
    mouse.drag_origin_extent = 0;
    const release_target = hittest.hitTest(tree, mouse.x, mouse.y);

    if (mouse.press_target) |pt| {
        if (release_target) |rt| {
            if (rt.eql(pt) and !dragSuppressedClick(tree, dragged_target, pt)) {
                if (tree.isAlive(pt) and tree.getConst(pt).kind == .table) {
                    activateTable(tree, pt, mouse.x, mouse.y);
                } else {
                    fireClick(tree, pt);
                }
            }
        }
        if (tree.isAlive(pt)) {
            tree.get(pt).interaction.pressed = false;
        }
    }
    mouse.press_target = null;
    _ = updateHover(tree, mouse);
}

fn handleSecondaryPress(tree: *widget.Tree, mouse: *MouseState) void {
    mouse.right_down = true;
    _ = updateHover(tree, mouse);
    const target = hittest.hitTest(tree, mouse.x, mouse.y);
    closePopupsForPress(tree, target);
    mouse.right_press_target = target;
}

fn handleSecondaryRelease(tree: *widget.Tree, mouse: *MouseState) void {
    mouse.right_down = false;
    const release_target = hittest.hitTest(tree, mouse.x, mouse.y);
    if (mouse.right_press_target) |pt| {
        if (release_target) |rt| {
            if (rt.eql(pt)) fireSecondaryClick(tree, pt, mouse);
        }
    }
    mouse.right_press_target = null;
    _ = updateHover(tree, mouse);
}

/// Update hovered state for all nodes based on current mouse position.
fn updateHover(tree: *widget.Tree, mouse: *const MouseState) ?widget.NodeHandle {
    const top = hittest.hitTest(tree, mouse.x, mouse.y);
    for (tree.nodes.items) |*node| {
        if (!node.alive) continue;
        node.interaction.hovered = false;
    }
    if (top) |t| {
        tree.get(t).interaction.hovered = true;
    }
    return top;
}

fn hoverChanged(mouse: *const MouseState, hovered: ?widget.NodeHandle) bool {
    if (mouse.hovered) |previous| {
        return hovered == null or !hovered.?.eql(previous);
    }
    return hovered != null;
}

fn dragSuppressedClick(tree: *const widget.Tree, dragged_target: ?widget.NodeHandle, pressed_target: widget.NodeHandle) bool {
    const dragged = dragged_target orelse return false;
    if (!dragged.eql(pressed_target) or !tree.isAlive(pressed_target)) return false;
    return switch (tree.getConst(pressed_target).kind) {
        .table => true,
        else => false,
    };
}

fn treeHasTooltip(tree: *const widget.Tree) bool {
    for (tree.nodes.items) |node| {
        if (node.alive and node.kind == .tooltip) return true;
    }
    return false;
}

fn activateTable(tree: *widget.Tree, handle: widget.NodeHandle, x: f32, y: f32) void {
    const column = widget.tableHeaderCellIndexAtPoint(tree, handle, x, y) orelse return;
    const node = tree.get(handle);
    node.interaction.primary_clicked = true;
    _ = node.kind.table.toggleSort(column);
}

/// Update a slider's value based on mouse x position within its track.
fn updateSliderValue(tree: *widget.Tree, handle: widget.NodeHandle, mouse_x: f32, theme: style.Theme) void {
    const node = tree.get(handle);
    const rect = node.layout_rect;
    const resolved = node.style_override.resolve(theme);
    const thumb_w = resolved.thumb_width;
    const usable = rect.w - thumb_w;
    if (usable <= 0) return;
    const t = std.math.clamp((mouse_x - rect.x - thumb_w * 0.5) / usable, 0, 1);
    node.kind.slider.value = node.kind.slider.min + t * (node.kind.slider.max - node.kind.slider.min);
}

fn updateTableColumns(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) bool {
    const divider_index = mouse.drag_column_index orelse return false;
    const total_width = if (mouse.drag_origin_extent > 0)
        mouse.drag_origin_extent
    else if (widget.tableReferenceRow(tree, handle)) |row|
        tree.getConst(row).layout_rect.w
    else
        return false;
    if (total_width <= 0) return false;

    const delta = mouse.x - mouse.drag_origin_x;
    return tree.get(handle).kind.table.resizeColumns(
        divider_index,
        total_width,
        mouse.drag_origin_value,
        mouse.drag_origin_secondary_value,
        delta,
    );
}

fn updateDragValue(tree: *widget.Tree, handle: widget.NodeHandle, mouse_x: f32, mouse: *const MouseState) void {
    const node = tree.get(handle);
    const drag_value = &node.kind.drag_value;
    const delta = (mouse_x - mouse.drag_origin_x) * drag_value.speed;
    const next = std.math.clamp(mouse.drag_origin_value + delta, drag_value.min, drag_value.max);
    if (next != drag_value.value) {
        drag_value.value = next;
        drag_value.syncLabel();
        drag_value.changed = true;
    }
}

fn stepDragValue(tree: *widget.Tree, handle: widget.NodeHandle, direction: i8) void {
    const node = tree.get(handle);
    const drag_value = &node.kind.drag_value;
    const delta = drag_value.speed * @as(f32, @floatFromInt(direction));
    const next = std.math.clamp(drag_value.value + delta, drag_value.min, drag_value.max);
    if (next != drag_value.value) {
        drag_value.value = next;
        drag_value.syncLabel();
        drag_value.changed = true;
    }
}

fn stepSpinBox(tree: *widget.Tree, handle: widget.NodeHandle, direction: i8, activate: bool) void {
    const node = tree.get(handle);
    const spinbox = &node.kind.spinbox;
    const delta = spinbox.step * @as(f32, @floatFromInt(direction));
    const next = std.math.clamp(spinbox.value + delta, spinbox.min, spinbox.max);
    if (next != spinbox.value) {
        spinbox.value = next;
        spinbox.syncLabel();
        spinbox.changed = true;
        if (activate) node.interaction.primary_clicked = true;
    }
}

fn updateSplitterRatio(
    tree: *widget.Tree,
    handle: widget.NodeHandle,
    mouse_x: f32,
    mouse_y: f32,
    mouse: *MouseState,
    theme: style.Theme,
) void {
    const node = tree.get(handle);
    const splitter = &node.kind.splitter;
    const resolved = node.style_override.resolve(theme);
    const available = splitterAvailableExtent(splitter.*, node.layout_rect, resolved);
    if (available <= 0) return;

    const delta_px = switch (splitter.direction) {
        .row => mouse_x - mouse.drag_origin_x,
        .column => mouse_y - mouse.drag_origin_y,
    };
    const next = clampSplitterRatio(splitter.*, node.layout_rect, resolved, mouse.drag_origin_value + delta_px / available);
    if (next != splitter.ratio) {
        splitter.ratio = next;
        splitter.changed = true;
        mouse.layout_changed = true;
    }
}

fn stepSplitter(tree: *widget.Tree, handle: widget.NodeHandle, direction: i8, theme: style.Theme) void {
    const node = tree.get(handle);
    const splitter = &node.kind.splitter;
    const resolved = node.style_override.resolve(theme);
    const next = clampSplitterRatio(
        splitter.*,
        node.layout_rect,
        resolved,
        splitter.ratio + splitter.keyboard_step * @as(f32, @floatFromInt(direction)),
    );
    if (next != splitter.ratio) {
        splitter.ratio = next;
        splitter.changed = true;
    }
}

fn syncMenuHover(tree: *widget.Tree, hovered: ?widget.NodeHandle, mouse: *MouseState) void {
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

fn syncPopupMenuHover(tree: *widget.Tree, popup: widget.NodeHandle, hovered: widget.NodeHandle, mouse: *MouseState) void {
    var iter = tree.children(popup);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .menu_item) continue;
        const submenu = directPopupChild(tree, child) orelse continue;
        if (hovered.eql(child) or isDescendantOf(tree, hovered, child)) {
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

/// Clamp a scroll area's scroll values to keep content in bounds.
/// Uses children's layout rects from the previous frame.
fn clampScroll(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    const viewport = node.layout_rect;
    const extent = contentExtent(tree, handle);

    const max_x = @max(extent.w - viewport.w, 0);
    const max_y = @max(extent.h - viewport.h, 0);

    node.kind.scroll_area.scroll_x = std.math.clamp(node.kind.scroll_area.scroll_x, 0, max_x);
    node.kind.scroll_area.scroll_y = std.math.clamp(node.kind.scroll_area.scroll_y, 0, max_y);
}

/// Compute the bounding box size of all direct children of a node.
/// Returns the total width and height the content occupies.
fn contentExtent(tree: *const widget.Tree, parent: widget.NodeHandle) struct { w: f32, h: f32 } {
    const parent_rect = tree.getConst(parent).layout_rect;
    var max_x: f32 = parent_rect.x;
    var max_y: f32 = parent_rect.y;

    var iter = tree.children(parent);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .popup or tree.getConst(child).kind == .tooltip) continue;
        const r = tree.getConst(child).layout_rect;
        max_x = @max(max_x, r.x + r.w);
        max_y = @max(max_y, r.y + r.h);
    }

    return .{
        .w = max_x - parent_rect.x,
        .h = max_y - parent_rect.y,
    };
}

/// Check if a mouse press constitutes a double-click based on timing and position.
fn isDoubleClick(mouse: *const MouseState, mb: event.Event.MouseButton) bool {
    if (mouse.last_click_time_ms == 0 or mb.timestamp_ms == 0) return false;
    const dt = mb.timestamp_ms -| mouse.last_click_time_ms;
    if (dt > MouseState.double_click_time_ms) return false;
    const dx = @abs(mb.x - mouse.last_click_x);
    const dy = @abs(mb.y - mouse.last_click_y);
    return dx <= MouseState.double_click_dist and dy <= MouseState.double_click_dist;
}

/// Fire a click on a widget.
fn fireClick(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    switch (node.kind) {
        .button => {
            node.interaction.primary_clicked = true;
            node.kind.button.clicked = true;
        },
        .checkbox => {
            node.interaction.primary_clicked = true;
            node.kind.checkbox.checked = !node.kind.checkbox.checked;
            node.kind.checkbox.clicked = true;
        },
        .radio_button => {
            node.interaction.primary_clicked = true;
            const group = node.kind.radio_button.group;
            // Deselect all other radio buttons in the same group
            for (tree.nodes.items) |*n| {
                if (n.kind == .radio_button and n.kind.radio_button.group == group) {
                    n.kind.radio_button.selected = false;
                }
            }
            node.kind.radio_button.selected = true;
            node.kind.radio_button.clicked = true;
        },
        .tree_item => {
            if (node.kind.tree_item.editing) return;
            node.interaction.primary_clicked = true;
            const group = node.kind.tree_item.group;
            for (tree.nodes.items) |*n| {
                if (n.alive and n.kind == .tree_item and n.kind.tree_item.group == group) {
                    n.kind.tree_item.selected = false;
                }
            }
            node.kind.tree_item.selected = true;
            node.kind.tree_item.clicked = true;
        },
        .dropdown => {
            node.interaction.primary_clicked = true;
            node.kind.dropdown.open = !node.kind.dropdown.open;
            node.kind.dropdown.clicked = true;
        },
        .selectable => {
            node.interaction.primary_clicked = true;
            _ = selectSelectable(tree, handle);
            node.kind.selectable.clicked = true;
        },
        .menu => {
            node.interaction.primary_clicked = true;
            node.kind.menu.clicked = true;
            toggleOwnedPopup(tree, handle, null);
        },
        .menu_item => {
            node.interaction.primary_clicked = true;
            node.kind.menu_item.clicked = true;
            if (directPopupChild(tree, handle) != null) {
                toggleOwnedPopup(tree, handle, null);
            } else {
                applyMenuSelection(tree, handle);
            }
        },
        .tab_item => {
            node.interaction.primary_clicked = true;
            selectTabItem(tree, handle);
            node.kind.tab_item.clicked = true;
        },
        else => {},
    }
}

fn selectSelectable(tree: *widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.get(handle);
    if (node.kind != .selectable) return false;

    var changed = false;
    const group = node.kind.selectable.group;

    if (group != 0) {
        for (tree.nodes.items, 0..) |*candidate, i| {
            if (!candidate.alive or candidate.kind != .selectable or candidate.kind.selectable.group != group) continue;
            const candidate_handle = tree.handleFromIndex(@intCast(i));
            const should_select = candidate_handle.eql(handle);
            if (candidate.kind.selectable.selected != should_select) {
                candidate.kind.selectable.selected = should_select;
                changed = true;
                markSelectableListBoxChanged(tree, candidate_handle);
            }
        }
        return changed;
    }

    if (node.parent) |parent_handle| {
        var iter = tree.children(parent_handle);
        while (iter.next()) |child| {
            if (tree.getConst(child).kind != .selectable) continue;
            const should_select = child.eql(handle);
            if (tree.getConst(child).kind.selectable.selected != should_select) {
                tree.get(child).kind.selectable.selected = should_select;
                changed = true;
                markSelectableListBoxChanged(tree, child);
            }
        }
        return changed;
    }

    if (!node.kind.selectable.selected) {
        node.kind.selectable.selected = true;
        changed = true;
        markSelectableListBoxChanged(tree, handle);
    }
    return changed;
}

fn markSelectableListBoxChanged(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const parent_handle = tree.getConst(handle).parent orelse return;
    if (tree.getConst(parent_handle).kind == .list_box) {
        tree.get(parent_handle).kind.list_box.changed = true;
    }
}

fn fireSecondaryClick(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    const node = tree.get(handle);
    node.interaction.secondary_clicked = true;
    mouse.last_secondary_click = .{
        .target = handle,
        .x = mouse.x,
        .y = mouse.y,
    };
}

fn applyMenuSelection(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.getConst(handle);
    const popup_handle = node.parent orelse return;
    if (tree.getConst(popup_handle).kind != .popup) return;

    if (tree.getConst(popup_handle).parent) |parent_handle| {
        const parent = tree.get(parent_handle);
        if (parent.kind == .dropdown) {
            const index = menuItemIndex(tree, popup_handle, handle);
            parent.kind.dropdown.selected_text = node.kind.menu_item.label;
            parent.kind.dropdown.selected_index = index;
            parent.kind.dropdown.changed = true;
        }
    }

    closePopupSubtree(tree, popupRoot(tree, popup_handle));
}

fn closeAllPopups(tree: *widget.Tree) void {
    for (tree.nodes.items) |*node| {
        if (!node.alive) continue;
        switch (node.kind) {
            .popup => node.kind.popup.visible = false,
            .dropdown => node.kind.dropdown.open = false,
            else => {},
        }
    }
}

fn closePopupsForPress(tree: *widget.Tree, target: ?widget.NodeHandle) void {
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

fn directPopupChild(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .popup) return child;
    }
    return null;
}

fn toggleOwnedPopup(tree: *widget.Tree, owner: widget.NodeHandle, mouse: ?*MouseState) void {
    const popup = directPopupChild(tree, owner) orelse return;
    if (tree.getConst(popup).kind.popup.visible) {
        closePopupSubtree(tree, popup);
        if (mouse) |m| m.layout_changed = true;
    } else {
        openOwnedPopup(tree, owner, mouse);
    }
}

fn openOwnedPopup(tree: *widget.Tree, owner: widget.NodeHandle, mouse: ?*MouseState) void {
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

fn closeSiblingOwnedPopups(tree: *widget.Tree, parent: widget.NodeHandle, keep_owner: widget.NodeHandle) bool {
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

fn closePopupSubtree(tree: *widget.Tree, popup: widget.NodeHandle) void {
    closeDescendantPopups(tree, popup);
    tree.get(popup).kind.popup.visible = false;
    if (tree.getConst(popup).parent) |parent_handle| {
        if (tree.getConst(parent_handle).kind == .dropdown) {
            tree.get(parent_handle).kind.dropdown.open = false;
        }
    }
}

fn closeDescendantPopups(tree: *widget.Tree, handle: widget.NodeHandle) void {
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .popup) {
            closePopupSubtree(tree, child);
        } else {
            closeDescendantPopups(tree, child);
        }
    }
}

fn popupOwnsTarget(tree: *const widget.Tree, popup: widget.NodeHandle, target: widget.NodeHandle) bool {
    if (target.eql(popup) or isDescendantOf(tree, target, popup)) return true;
    const owner = tree.getConst(popup).parent orelse return false;
    return target.eql(owner) or isDescendantOf(tree, target, owner);
}

fn popupRoot(tree: *const widget.Tree, popup: widget.NodeHandle) widget.NodeHandle {
    var current = popup;
    while (true) {
        const owner = tree.getConst(current).parent orelse return current;
        const ancestor_popup = findAncestorPopup(tree, owner) orelse return current;
        current = ancestor_popup;
    }
}

fn findAncestorPopup(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var current: ?widget.NodeHandle = handle;
    while (current) |candidate| {
        if (tree.getConst(candidate).kind == .popup) return candidate;
        current = tree.getConst(candidate).parent;
    }
    return null;
}

fn findAncestorMenu(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var current: ?widget.NodeHandle = handle;
    while (current) |candidate| {
        if (tree.getConst(candidate).kind == .menu) return candidate;
        current = tree.getConst(candidate).parent;
    }
    return null;
}

fn menuBarHasOpenMenu(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        const popup = directPopupChild(tree, child) orelse continue;
        if (tree.getConst(popup).kind.popup.visible) return true;
    }
    return false;
}

fn selectTabItem(tree: *widget.Tree, handle: widget.NodeHandle) void {
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

fn toggleTreeItem(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    if (node.kind != .tree_item) return;
    if (!hasTreeItemChildren(tree, handle)) return;
    node.kind.tree_item.expanded = !node.kind.tree_item.expanded;
    node.kind.tree_item.toggled = true;
}

fn commitTreeItemRename(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    if (node.kind != .tree_item or !node.kind.tree_item.editing) return;
    node.kind.tree_item.commitRename();
}

fn cancelTreeItemRename(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const node = tree.get(handle);
    if (node.kind != .tree_item or !node.kind.tree_item.editing) return;
    node.kind.tree_item.cancelRename();
}

fn shouldBeginTreeRename(item: widget.WidgetKind.TreeItem, clicked_label: bool, is_double_click: bool) bool {
    if (!clicked_label) return false;
    return switch (item.rename_trigger) {
        .none => false,
        .selected_click => item.selected,
        .double_click => is_double_click,
    };
}

fn clickInTreeDisclosure(tree: *const widget.Tree, handle: widget.NodeHandle, mouse_x: f32, theme: style.Theme) bool {
    if (!hasTreeItemChildren(tree, handle)) return false;
    const left = treeDisclosureX(tree, handle, theme);
    const right = left + treeDisclosureWidth(tree, handle, theme);
    return mouse_x >= left and mouse_x <= right;
}

fn clickInTreeLabel(tree: *const widget.Tree, handle: widget.NodeHandle, mouse_x: f32, theme: style.Theme) bool {
    const left = treeLabelX(tree, handle, theme);
    const node = tree.getConst(handle);
    const resolved = node.style_override.resolve(theme);
    const right = node.layout_rect.x + node.layout_rect.w - resolved.padding.right;
    return mouse_x >= left and mouse_x <= right;
}

fn hasTreeItemChildren(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .popup and tree.getConst(child).kind != .tooltip) return true;
    }
    return false;
}

fn clickInSpinBoxDecrement(tree: *const widget.Tree, handle: widget.NodeHandle, mouse_x: f32) bool {
    return mouse_x < spinBoxMiddleStart(tree, handle);
}

fn clickInSpinBoxIncrement(tree: *const widget.Tree, handle: widget.NodeHandle, mouse_x: f32) bool {
    return mouse_x > spinBoxMiddleEnd(tree, handle);
}

fn menuItemIndex(tree: *const widget.Tree, popup: widget.NodeHandle, handle: widget.NodeHandle) ?u16 {
    var idx: u16 = 0;
    var iter = tree.children(popup);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .menu_item) continue;
        if (child.eql(handle)) return idx;
        idx += 1;
    }
    return null;
}

fn isDescendantOf(tree: *const widget.Tree, handle: widget.NodeHandle, ancestor: widget.NodeHandle) bool {
    var current = tree.getConst(handle).parent;
    while (current) |parent_handle| {
        if (parent_handle.eql(ancestor)) return true;
        current = tree.getConst(parent_handle).parent;
    }
    return false;
}

fn treeDepth(tree: *const widget.Tree, handle: widget.NodeHandle) u32 {
    var depth: u32 = 0;
    var current = tree.getConst(handle).parent;
    while (current) |parent_handle| {
        const parent = tree.getConst(parent_handle);
        if (parent.kind == .tree_item) depth += 1;
        current = parent.parent;
    }
    return depth;
}

fn spinBoxButtonWidth(tree: *const widget.Tree, handle: widget.NodeHandle) f32 {
    const rect = tree.getConst(handle).layout_rect;
    return @min(rect.h, 28);
}

fn spinBoxMiddleStart(tree: *const widget.Tree, handle: widget.NodeHandle) f32 {
    return tree.getConst(handle).layout_rect.x + spinBoxButtonWidth(tree, handle);
}

fn spinBoxMiddleEnd(tree: *const widget.Tree, handle: widget.NodeHandle) f32 {
    const rect = tree.getConst(handle).layout_rect;
    return rect.x + rect.w - spinBoxButtonWidth(tree, handle);
}

fn clampSplitterRatio(
    splitter: widget.WidgetKind.Splitter,
    rect: draw.Rect,
    resolved: style.ResolvedStyle,
    ratio: f32,
) f32 {
    const raw = std.math.clamp(ratio, 0, 1);
    const available = splitterAvailableExtent(splitter, rect, resolved);
    if (available <= 0) return raw;

    const min_ratio = std.math.clamp(splitter.min_first / available, 0, 1);
    const max_ratio = std.math.clamp(1 - splitter.min_second / available, 0, 1);
    if (min_ratio > max_ratio) return raw;
    return std.math.clamp(raw, min_ratio, max_ratio);
}

fn splitterAvailableExtent(
    splitter: widget.WidgetKind.Splitter,
    rect: draw.Rect,
    resolved: style.ResolvedStyle,
) f32 {
    return switch (splitter.direction) {
        .row => rect.w - resolved.padding.left - resolved.padding.right - splitter.thickness,
        .column => rect.h - resolved.padding.top - resolved.padding.bottom - splitter.thickness,
    };
}

fn treeDisclosureX(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) f32 {
    const node = tree.getConst(handle);
    const resolved = node.style_override.resolve(theme);
    const indent = @as(f32, @floatFromInt(treeDepth(tree, handle))) * (resolved.font_size + theme.spacing);
    return node.layout_rect.x + resolved.padding.left + indent;
}

fn treeDisclosureWidth(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) f32 {
    const node = tree.getConst(handle);
    return node.style_override.resolve(theme).font_size + 4;
}

fn treeLabelX(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) f32 {
    return treeDisclosureX(tree, handle, theme) + treeDisclosureWidth(tree, handle, theme);
}

fn textEditorTextX(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) ?f32 {
    const node = tree.getConst(handle);
    const resolved = node.style_override.resolve(theme);
    return switch (node.kind) {
        .text_input => node.layout_rect.x + resolved.padding.left,
        .tree_item => if (node.kind.tree_item.editing) treeLabelX(tree, handle, theme) else null,
        else => null,
    };
}

fn findTreeParent(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var current = tree.getConst(handle).parent;
    while (current) |parent_handle| {
        if (tree.getConst(parent_handle).kind == .tree_item) return parent_handle;
        current = tree.getConst(parent_handle).parent;
    }
    return null;
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

// --- Tests ---

test "hover updates on mouse move" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "OK" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };

    var mouse = MouseState{};

    // Move onto button
    process(&tree, &.{.{ .mouse_move = .{ .x = 50, .y = 20 } }}, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(btn).interaction.hovered);
    try std.testing.expect(!tree.getConst(root).interaction.hovered);

    // Move off button but still on root
    process(&tree, &.{.{ .mouse_move = .{ .x = 500, .y = 300 } }}, &mouse, style.Theme.default);
    try std.testing.expect(!tree.getConst(btn).interaction.hovered);
    try std.testing.expect(tree.getConst(root).interaction.hovered);
}

test "button click sets clicked flag" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "Click me" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };

    var mouse = MouseState{};

    // Press and release on button
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(btn).kind.button.clicked);
    try std.testing.expect(!tree.getConst(btn).interaction.pressed);
}

test "press and release on different widgets does not click" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "A" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };

    var mouse = MouseState{};

    // Press on button, release elsewhere
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 500, .y = 300 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(!tree.getConst(btn).kind.button.clicked);
}

test "slider drag updates value" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const sl = try tree.addChild(root, .{ .slider = .{ .value = 0, .min = 0, .max = 100 } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(sl).layout_rect = .{ .x = 10, .y = 10, .w = 200, .h = 24 };

    var mouse = MouseState{};

    // Click at the midpoint of the slider track
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 110, .y = 20 } },
    }, &mouse, style.Theme.default);

    // Should have started dragging
    try std.testing.expect(mouse.drag_target != null);
    const val_after_press = tree.getConst(sl).kind.slider.value;
    try std.testing.expect(val_after_press > 40 and val_after_press < 60);

    // Drag to the right end
    process(&tree, &.{
        .{ .mouse_move = .{ .x = 210, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 100), tree.getConst(sl).kind.slider.value, 1.0);

    // Drag to the left end
    process(&tree, &.{
        .{ .mouse_move = .{ .x = 10, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(sl).kind.slider.value, 1.0);

    // Release — drag should stop
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 10, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(mouse.drag_target == null);

    // Move after release should not change value
    process(&tree, &.{
        .{ .mouse_move = .{ .x = 150, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(sl).kind.slider.value, 1.0);
}

test "drag value drag updates value" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const drag_value = try tree.addChild(root, .{ .drag_value = .{
        .value = 10,
        .min = 0,
        .max = 100,
        .speed = 0.5,
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(drag_value).layout_rect = .{ .x = 10, .y = 10, .w = 120, .h = 28 };

    var mouse = MouseState{};
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(mouse.drag_target != null);
    process(&tree, &.{
        .{ .mouse_move = .{ .x = 40, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expectApproxEqAbs(@as(f32, 20), tree.getConst(drag_value).kind.drag_value.value, 0.01);
    try std.testing.expect(tree.getConst(drag_value).kind.drag_value.changed);
}

test "spinbox click steps value" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const spinbox = try tree.addChild(root, .{ .spinbox = .{
        .value = 5,
        .min = 0,
        .max = 10,
        .step = 2,
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(spinbox).layout_rect = .{ .x = 10, .y = 10, .w = 120, .h = 28 };

    var mouse = MouseState{};
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 120, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 120, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 7), tree.getConst(spinbox).kind.spinbox.value, 0.01);
    try std.testing.expect(tree.getConst(spinbox).kind.spinbox.changed);

    tree.get(spinbox).kind.spinbox.changed = false;
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 20, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 5), tree.getConst(spinbox).kind.spinbox.value, 0.01);
}

test "checkbox toggles on click" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const cb = try tree.addChild(root, .{ .checkbox = .{ .label = "Enable", .checked = false } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(cb).layout_rect = .{ .x = 10, .y = 10, .w = 200, .h = 26 };

    var mouse = MouseState{};

    // Click to check
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(cb).kind.checkbox.checked);

    // Click again to uncheck
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(!tree.getConst(cb).kind.checkbox.checked);
}

test "radio button selects and deselects group siblings" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const rb1 = try tree.addChild(root, .{ .radio_button = .{ .label = "A", .group = 1 } });
    const rb2 = try tree.addChild(root, .{ .radio_button = .{ .label = "B", .group = 1 } });
    const rb3 = try tree.addChild(root, .{ .radio_button = .{ .label = "Other", .group = 2 } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(rb1).layout_rect = .{ .x = 10, .y = 10, .w = 200, .h = 26 };
    tree.get(rb2).layout_rect = .{ .x = 10, .y = 40, .w = 200, .h = 26 };
    tree.get(rb3).layout_rect = .{ .x = 10, .y = 70, .w = 200, .h = 26 };

    var mouse = MouseState{};

    // Click rb1
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(rb1).kind.radio_button.selected);
    try std.testing.expect(!tree.getConst(rb2).kind.radio_button.selected);

    // Click rb2 — should deselect rb1
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 50 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 50 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(!tree.getConst(rb1).kind.radio_button.selected);
    try std.testing.expect(tree.getConst(rb2).kind.radio_button.selected);

    // rb3 (different group) should be unaffected
    try std.testing.expect(!tree.getConst(rb3).kind.radio_button.selected);

    // Click rb3 — group 1 should be unaffected
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 80 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 50, .y = 80 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(rb2).kind.radio_button.selected);
    try std.testing.expect(tree.getConst(rb3).kind.radio_button.selected);
}

test "scroll area responds to mouse scroll" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    // Add a child taller than the viewport so scrolling is possible
    const child = try tree.addChild(scroll, .{ .text = .{ .content = "tall content" } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 200 };
    tree.get(child).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 500 };

    var mouse = MouseState{ .x = 150, .y = 100 };

    process(&tree, &.{.{ .mouse_scroll = .{ .dx = 0, .dy = 30 } }}, &mouse, style.Theme.default);

    try std.testing.expectApproxEqAbs(@as(f32, 30), tree.getConst(scroll).kind.scroll_area.scroll_y, 0.01);
}

test "scroll clamped to content bounds" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    const child = try tree.addChild(scroll, .{ .text = .{ .content = "content" } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 200 };
    tree.get(child).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 400 };

    var mouse = MouseState{ .x = 150, .y = 100 };

    // Scroll way past content — should clamp to max (400 - 200 = 200)
    process(&tree, &.{.{ .mouse_scroll = .{ .dx = 0, .dy = 9999 } }}, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 200), tree.getConst(scroll).kind.scroll_area.scroll_y, 0.01);

    // Scroll negative — should clamp to 0
    process(&tree, &.{.{ .mouse_scroll = .{ .dx = 0, .dy = -9999 } }}, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(scroll).kind.scroll_area.scroll_y, 0.01);
}

test "scroll clamped when content fits viewport" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    const child = try tree.addChild(scroll, .{ .text = .{ .content = "small" } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 200 };
    tree.get(child).layout_rect = .{ .x = 0, .y = 0, .w = 100, .h = 50 };

    var mouse = MouseState{ .x = 150, .y = 100 };

    // Content fits — any scroll should clamp to 0
    process(&tree, &.{.{ .mouse_scroll = .{ .dx = 50, .dy = 50 } }}, &mouse, style.Theme.default);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(scroll).kind.scroll_area.scroll_x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(scroll).kind.scroll_area.scroll_y, 0.01);
}

test "tab cycles focus through focusable widgets" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "A" } });
    _ = try tree.addChild(root, .{ .text = .{ .content = "skip me" } });
    const cb = try tree.addChild(root, .{ .checkbox = .{ .label = "B" } });
    const sl = try tree.addChild(root, .{ .slider = .{ .value = 0 } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };
    tree.get(cb).layout_rect = .{ .x = 10, .y = 50, .w = 200, .h = 26 };
    tree.get(sl).layout_rect = .{ .x = 10, .y = 80, .w = 200, .h = 24 };

    var mouse = MouseState{};
    const tab_press = event.Event{ .key = .{ .scancode = 15, .keycode = .tab, .state = .pressed } };

    // First tab: focus button (first focusable)
    process(&tree, &.{tab_press}, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(btn));
    try std.testing.expect(tree.getConst(btn).interaction.focused);

    // Second tab: focus checkbox (skips text)
    process(&tree, &.{tab_press}, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(cb));
    try std.testing.expect(!tree.getConst(btn).interaction.focused);
    try std.testing.expect(tree.getConst(cb).interaction.focused);

    // Third tab: focus slider
    process(&tree, &.{tab_press}, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(sl));

    // Fourth tab: wraps to button
    process(&tree, &.{tab_press}, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(btn));
}

test "shift+tab cycles focus backwards" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "A" } });
    const cb = try tree.addChild(root, .{ .checkbox = .{ .label = "B" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };
    tree.get(cb).layout_rect = .{ .x = 10, .y = 50, .w = 200, .h = 26 };

    var mouse = MouseState{};
    const shift_down = event.Event{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .pressed } };
    const tab_press = event.Event{ .key = .{ .scancode = 15, .keycode = .tab, .state = .pressed } };
    const shift_up = event.Event{ .key = .{ .scancode = 42, .keycode = .left_shift, .state = .released } };

    // Shift+Tab from no focus: should go to last focusable (checkbox)
    process(&tree, &.{ shift_down, tab_press, shift_up }, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(cb));

    // Shift+Tab again: should go to button
    process(&tree, &.{ shift_down, tab_press, shift_up }, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(btn));
}

test "enter/space activates focused widget" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "OK" } });
    const cb = try tree.addChild(root, .{ .checkbox = .{ .label = "Toggle" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };
    tree.get(cb).layout_rect = .{ .x = 10, .y = 50, .w = 200, .h = 26 };

    var mouse = MouseState{};

    // Tab to button, then press Enter
    process(&tree, &.{
        .{ .key = .{ .scancode = 15, .keycode = .tab, .state = .pressed } },
        .{ .key = .{ .scancode = 28, .keycode = .enter, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(btn).kind.button.clicked);

    // Tab to checkbox, press Space to toggle
    process(&tree, &.{
        .{ .key = .{ .scancode = 15, .keycode = .tab, .state = .pressed } },
        .{ .key = .{ .scancode = 57, .keycode = .space, .state = .pressed } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(cb).kind.checkbox.checked);
}

test "click sets focus" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "A" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 };

    var mouse = MouseState{};

    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 50, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(mouse.focused.?.eql(btn));
    try std.testing.expect(tree.getConst(btn).interaction.focused);
}

test "tab item click selects sibling tab" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const tabs = try tree.addChild(root, .{ .tab_bar = .{} });
    const scene = try tree.addChild(tabs, .{ .tab_item = .{
        .label = "Scene",
        .selected = true,
    } });
    const render = try tree.addChild(tabs, .{ .tab_item = .{
        .label = "Render",
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(tabs).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 80 };
    tree.get(scene).layout_rect = .{ .x = 10, .y = 10, .w = 70, .h = 28 };
    tree.get(render).layout_rect = .{ .x = 84, .y = 10, .w = 80, .h = 28 };

    var mouse = MouseState{};
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 100, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 100, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(!tree.getConst(scene).kind.tab_item.selected);
    try std.testing.expect(tree.getConst(render).kind.tab_item.selected);
    try std.testing.expect(tree.getConst(render).kind.tab_item.clicked);
}

test "selectable rows update sibling selection and list box change state" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const list_box = try tree.addChild(root, .{ .list_box = .{} });
    const first = try tree.addChild(list_box, .{ .selectable = .{
        .label = "Scene",
        .selected = true,
    } });
    const second = try tree.addChild(list_box, .{ .selectable = .{
        .label = "Camera",
    } });
    const third = try tree.addChild(list_box, .{ .selectable = .{
        .label = "Light",
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(list_box).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 90 };
    tree.get(first).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };
    tree.get(second).layout_rect = .{ .x = 10, .y = 36, .w = 220, .h = 26 };
    tree.get(third).layout_rect = .{ .x = 10, .y = 62, .w = 220, .h = 26 };

    var mouse = MouseState{};
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 40, .y = 46 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 40, .y = 46 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(!tree.getConst(first).kind.selectable.selected);
    try std.testing.expect(tree.getConst(second).kind.selectable.selected);
    try std.testing.expect(tree.getConst(second).kind.selectable.clicked);
    try std.testing.expect(tree.getConst(list_box).kind.list_box.changed);
    try std.testing.expect(mouse.focused.?.eql(second));

    tree.get(list_box).kind.list_box.changed = false;
    tree.get(second).kind.selectable.clicked = false;

    process(&tree, &.{.{ .key = .{ .scancode = 108, .keycode = .down, .state = .pressed } }}, &mouse, style.Theme.default);

    try std.testing.expect(!tree.getConst(second).kind.selectable.selected);
    try std.testing.expect(tree.getConst(third).kind.selectable.selected);
    try std.testing.expect(tree.getConst(list_box).kind.list_box.changed);
    try std.testing.expect(mouse.focused.?.eql(third));
}

test "tree item toggles and keyboard navigation follows visible items" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const parent = try tree.addChild(root, .{ .tree_item = .{ .label = "Parent", .group = 7 } });
    const child = try tree.addChild(parent, .{ .tree_item = .{ .label = "Child", .group = 7 } });
    const sibling = try tree.addChild(root, .{ .tree_item = .{ .label = "Sibling", .group = 7 } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(parent).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };
    tree.get(child).layout_rect = .{ .x = 10, .y = 40, .w = 220, .h = 26 };
    tree.get(sibling).layout_rect = .{ .x = 10, .y = 70, .w = 220, .h = 26 };

    var mouse = MouseState{};

    // Click in the disclosure slot. This collapses the parent and still selects it.
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 18, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 18, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(!tree.getConst(parent).kind.tree_item.expanded);
    try std.testing.expect(tree.getConst(parent).kind.tree_item.toggled);
    try std.testing.expect(tree.getConst(parent).kind.tree_item.selected);

    mouse.focused = parent;
    focus.syncFocusFlags(&tree, mouse.focused);

    // Right expands the focused tree item.
    process(&tree, &.{.{ .key = .{ .scancode = 106, .keycode = .right, .state = .pressed } }}, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(parent).kind.tree_item.expanded);

    // Down moves into the now-visible child, then to the sibling.
    process(&tree, &.{.{ .key = .{ .scancode = 108, .keycode = .down, .state = .pressed } }}, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(child));
    process(&tree, &.{.{ .key = .{ .scancode = 108, .keycode = .down, .state = .pressed } }}, &mouse, style.Theme.default);
    try std.testing.expect(mouse.focused.?.eql(sibling));
}

test "collapsed tree item can be reopened with the mouse" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const parent = try tree.addChild(root, .{ .tree_item = .{ .label = "Scene", .group = 11 } });
    _ = try tree.addChild(parent, .{ .tree_item = .{ .label = "Child", .group = 11 } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(parent).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };

    var mouse = MouseState{};
    const click = [_]event.Event{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 18, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 18, .y = 20 } },
    };

    process(&tree, &click, &mouse, style.Theme.default);
    try std.testing.expect(!tree.getConst(parent).kind.tree_item.expanded);

    process(&tree, &click, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(parent).kind.tree_item.expanded);
}

test "selected editable tree item can rename inline on click" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const item = try tree.addChild(root, .{ .tree_item = .{
        .label = "Scene",
        .group = 12,
        .editable = true,
        .rename_trigger = .selected_click,
        .selected = true,
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(item).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };

    var mouse = MouseState{};

    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 40, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 40, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(item).kind.tree_item.editing);

    process(&tree, &.{
        .{ .text = .{ .codepoint = 'X' } },
        .{ .key = .{ .scancode = 28, .keycode = .enter, .state = .pressed } },
    }, &mouse, style.Theme.default);

    try std.testing.expectEqualStrings("X", tree.getConst(item).kind.tree_item.label);
    try std.testing.expect(tree.getConst(item).kind.tree_item.rename_committed);
    try std.testing.expect(!tree.getConst(item).kind.tree_item.editing);
}

test "editable tree item can rename on double click" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const item = try tree.addChild(root, .{ .tree_item = .{
        .label = "Camera",
        .group = 13,
        .editable = true,
        .rename_trigger = .double_click,
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(item).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };

    var mouse = MouseState{};

    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 40, .y = 20, .timestamp_ms = 100 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 40, .y = 20, .timestamp_ms = 100 } },
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 40, .y = 20, .timestamp_ms = 250 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(item).kind.tree_item.editing);
}

test "dropdown menu item selection updates dropdown state" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const dropdown = try tree.addChild(root, .{ .dropdown = .{ .placeholder = "Select item" } });
    const popup = try tree.addChild(dropdown, .{ .popup = .{ .placement = .below_start } });
    const a = try tree.addChild(popup, .{ .menu_item = .{ .label = "Alpha" } });
    const b = try tree.addChild(popup, .{ .menu_item = .{ .label = "Beta" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(dropdown).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };
    tree.get(popup).layout_rect = .{ .x = 10, .y = 36, .w = 220, .h = 52 };
    tree.get(a).layout_rect = .{ .x = 10, .y = 36, .w = 220, .h = 26 };
    tree.get(b).layout_rect = .{ .x = 10, .y = 62, .w = 220, .h = 26 };

    var mouse = MouseState{};

    // Open the dropdown.
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 30, .y = 20 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 30, .y = 20 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(dropdown).kind.dropdown.open);

    // Pick the second item.
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 30, .y = 72 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 30, .y = 72 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(b).kind.menu_item.clicked);
    try std.testing.expectEqualStrings("Beta", tree.getConst(dropdown).kind.dropdown.selected_text);
    try std.testing.expectEqual(@as(?u16, 1), tree.getConst(dropdown).kind.dropdown.selected_index);
    try std.testing.expect(tree.getConst(dropdown).kind.dropdown.changed);
    try std.testing.expect(!tree.getConst(dropdown).kind.dropdown.open);
    try std.testing.expect(!tree.getConst(popup).kind.popup.visible);
}

test "menu hover opens submenu and leaf selection closes the stack" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const bar = try tree.addChild(root, .{ .menu_bar = .{} });
    const file = try tree.addChild(bar, .{ .menu = .{ .label = "File" } });
    const file_popup = try tree.addChild(file, .{ .popup = .{ .placement = .below_start, .visible = false } });
    const open_recent = try tree.addChild(file_popup, .{ .menu_item = .{ .label = "Open Recent" } });
    const recent_popup = try tree.addChild(open_recent, .{ .popup = .{ .placement = .right_start, .visible = false } });
    const recent_a = try tree.addChild(recent_popup, .{ .menu_item = .{ .label = "Shot A" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(bar).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 28 };
    tree.get(file).layout_rect = .{ .x = 10, .y = 4, .w = 48, .h = 20 };
    tree.get(file_popup).layout_rect = .{ .x = 10, .y = 28, .w = 140, .h = 26 };
    tree.get(open_recent).layout_rect = .{ .x = 10, .y = 28, .w = 140, .h = 26 };
    tree.get(recent_popup).layout_rect = .{ .x = 150, .y = 28, .w = 120, .h = 26 };
    tree.get(recent_a).layout_rect = .{ .x = 150, .y = 28, .w = 120, .h = 26 };

    var mouse = MouseState{};

    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 20, .y = 12 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 20, .y = 12 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(file_popup).kind.popup.visible);

    process(&tree, &.{
        .{ .mouse_move = .{ .x = 40, .y = 40 } },
    }, &mouse, style.Theme.default);
    try std.testing.expect(tree.getConst(recent_popup).kind.popup.visible);

    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 170, .y = 40 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 170, .y = 40 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(recent_a).kind.menu_item.clicked);
    try std.testing.expect(!tree.getConst(file_popup).kind.popup.visible);
    try std.testing.expect(!tree.getConst(recent_popup).kind.popup.visible);
}

test "splitter drag updates ratio" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const splitter = try tree.addChild(root, .{ .splitter = .{
        .direction = .row,
        .ratio = 0.5,
        .min_first = 40,
        .min_second = 40,
        .thickness = 8,
    } });
    const left = try tree.addChild(splitter, .{ .container = .{} });
    const right = try tree.addChild(splitter, .{ .container = .{} });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(splitter).layout_rect = .{ .x = 10, .y = 10, .w = 300, .h = 120 };
    tree.get(left).layout_rect = .{ .x = 16, .y = 16, .w = 140, .h = 108 };
    tree.get(right).layout_rect = .{ .x = 164, .y = 16, .w = 140, .h = 108 };

    var mouse = MouseState{};
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 160, .y = 60 } },
        .{ .mouse_move = .{ .x = 210, .y = 60 } },
        .{ .mouse_button = .{ .button = .left, .state = .released, .x = 210, .y = 60 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(splitter).kind.splitter.ratio > 0.5);
    try std.testing.expect(tree.getConst(splitter).kind.splitter.changed);
}

test "secondary click is reported on the target widget" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const btn = try tree.addChild(root, .{ .button = .{ .label = "Context" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(btn).layout_rect = .{ .x = 10, .y = 10, .w = 120, .h = 30 };

    var mouse = MouseState{};
    process(&tree, &.{
        .{ .mouse_button = .{ .button = .right, .state = .pressed, .x = 30, .y = 20 } },
        .{ .mouse_button = .{ .button = .right, .state = .released, .x = 30, .y = 20 } },
    }, &mouse, style.Theme.default);

    try std.testing.expect(tree.getConst(btn).interaction.secondary_clicked);
    try std.testing.expect(mouse.last_secondary_click != null);
    try std.testing.expect(mouse.last_secondary_click.?.target.eql(btn));
    try std.testing.expectApproxEqAbs(@as(f32, 30), mouse.last_secondary_click.?.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 20), mouse.last_secondary_click.?.y, 0.01);
}

test {
    _ = @import("dispatch_text_input_test.zig");
}
