const std = @import("std");
const widget = @import("widget.zig");
const event = @import("event.zig");
const focus = @import("focus.zig");
const hittest = @import("hittest.zig");
const layout = @import("layout.zig");
const paint = @import("paint.zig");
const style = @import("style.zig");
const geometry = @import("geometry.zig");

const dispatch_types = @import("dispatch/types.zig");
const dispatch_drag = @import("dispatch/drag.zig");
const dispatch_menu = @import("dispatch/menu.zig");
const dispatch_scroll = @import("dispatch/scroll.zig");
const dispatch_selection = @import("dispatch/selection.zig");
pub const SecondaryClick = dispatch_types.SecondaryClick;
pub const TreeDrop = dispatch_types.TreeDrop;
pub const ContainerDrop = dispatch_types.ContainerDrop;
pub const WidgetDrop = dispatch_types.WidgetDrop;
pub const Drop = dispatch_types.Drop;
pub const MouseState = dispatch_types.MouseState;
pub const Clipboard = dispatch_types.Clipboard;

/// Process a batch of events against the widget tree.
/// Updates interaction state (hovered, pressed) and widget state (clicked).
/// Call after doLayout so layout_rects are populated.
pub fn process(tree: *widget.Tree, events: []const event.Event, mouse: *MouseState, theme: style.Theme) void {
    processWithClipboard(tree, events, mouse, theme, null, null);
}

pub fn processWithClipboard(tree: *widget.Tree, events: []const event.Event, mouse: *MouseState, theme: style.Theme, clipboard: ?Clipboard, text_ctx: ?*const layout.TextMeasureCtx) void {
    for (events) |ev| {
        processOne(tree, ev, mouse, theme, clipboard, text_ctx);
    }
}

pub fn cancelPointerGesture(tree: *widget.Tree, mouse: *MouseState) void {
    if (mouse.press_target) |target| {
        if (tree.isAlive(target)) tree.get(target).interaction.pressed = false;
    }

    for (tree.nodes.items) |*node| {
        if (!node.alive) continue;
        node.interaction.drop_hovered = false;
        node.interaction.drop_received = false;
        switch (node.kind) {
            .tree_item => |*item| {
                item.internal.drag.active = false;
                item.internal.drag.rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
                item.internal.drop_preview = null;
            },
            .list_box => |*list_box| {
                list_box.internal.marquee_active = false;
                list_box.internal.marquee_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
                list_box.internal.drop_preview_background = false;
            },
            .selectable => |*item| {
                item.internal.marquee_base_selected = false;
                item.internal.drag.active = false;
                item.internal.drag.rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
                item.internal.drop_preview = false;
            },
            .grid_selector => |*selector| {
                selector.internal.marquee_active = false;
                selector.internal.marquee_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
                selector.internal.drop_preview_background = false;
            },
            .grid_item => |*item| {
                item.internal.marquee_base_selected = false;
                item.internal.drag.active = false;
                item.internal.drag.rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
                item.internal.drop_preview = false;
            },
            .table => |*table| {
                table.internal.marquee_active = false;
                table.internal.marquee_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
                table.internal.drop_preview_background = false;
            },
            .table_row => |*row| {
                row.internal.marquee_base_selected = false;
                row.internal.drag.active = false;
                row.internal.drag.rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
                row.internal.drop_preview = false;
            },
            else => {},
        }
    }

    mouse.left_down = false;
    mouse.press_target = null;
    mouse.press_can_defer_drag = false;
    mouse.drag_target = null;
    mouse.drag_column_index = null;
    mouse.drag_origin_secondary_value = 0;
    mouse.drag_origin_extent = 0;
    mouse.tree_drop_preview = null;
    mouse.grid_drop_preview = null;
    mouse.list_drop_preview = null;
    mouse.table_drop_preview = null;
    mouse.widget_drop_preview = null;
}

fn setFocusedWidget(tree: *widget.Tree, mouse: *MouseState, target: ?widget.NodeHandle) void {
    if (mouse.focused) |previous_focus| {
        if (target == null or !target.?.eql(previous_focus)) {
            if (tree.isAlive(previous_focus)) {
                commitOrCancelNumericEditorOnBlur(tree, previous_focus);
            }
        }
    }
    mouse.focused = target;
    focus.syncFocusFlags(tree, mouse.focused);
}

fn processOne(tree: *widget.Tree, ev: event.Event, mouse: *MouseState, theme: style.Theme, clipboard: ?Clipboard, text_ctx: ?*const layout.TextMeasureCtx) void {
    switch (ev) {
        .mouse_move => |mm| handleMouseMove(tree, mouse, theme, text_ctx, mm),
        .mouse_button => |mb| handleMouseButton(tree, mouse, theme, text_ctx, mb),
        .mouse_scroll => |ms| handleMouseScroll(tree, mouse, ms),
        .focus => |f| handleFocus(tree, mouse, f),
        .key => |k| handleKey(tree, mouse, theme, clipboard, k),
        .text => |t| handleText(tree, mouse, t),
        else => {},
    }
}

fn handleMouseMove(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mm: event.Event.MouseMove) void {
    mouse.x = mm.x;
    mouse.y = mm.y;
    dispatch_drag.maybeBeginDeferredDrag(tree, mouse);
    if (mouse.drag_target) |dt| {
        switch (tree.getConst(dt).kind) {
            .slider => updateSliderValue(tree, dt, mouse.x, theme),
            .drag_value => updateDragValue(tree, dt, mouse.x, mouse),
            .splitter => updateSplitterRatio(tree, dt, mouse.x, mouse.y, mouse, theme),
            .scroll_area => {
                if (dispatch_scroll.updateScrollAreaDrag(tree, dt, mouse, theme)) mouse.layout_changed = true;
            },
            .table => {
                if (updateTableColumns(tree, dt, mouse)) mouse.layout_changed = true;
                dispatch_drag.updateTableMarquee(tree, dt, mouse);
            },
            .tree_item => dispatch_drag.updateTreeDragPreview(tree, dt, mouse),
            .selectable => dispatch_drag.updateSelectableDragPreview(tree, dt, mouse),
            .list_box => dispatch_drag.updateListBoxMarquee(tree, dt, mouse),
            .grid_item => dispatch_drag.updateGridItemDragPreview(tree, dt, mouse),
            .grid_selector => dispatch_drag.updateGridSelectorMarquee(tree, dt, mouse),
            .table_row => dispatch_drag.updateTableRowDragPreview(tree, dt, mouse),
            else => {},
        }
        dispatch_drag.updateWidgetDropPreview(tree, dt, mouse);
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
    if (!mouse.left_down) dispatch_menu.syncMenuHover(tree, hovered, mouse);
}

fn handleMouseButton(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: event.Event.MouseButton) void {
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
    } else if (mb.button == .middle) {
        mouse.middle_down = mb.state == .pressed;
    }
}

fn handleMouseScroll(tree: *widget.Tree, mouse: *MouseState, ms: event.Event.MouseScroll) void {
    // Find the scroll area under the cursor and adjust scroll offset
    const target = hittest.hitTestKind(tree, mouse.x, mouse.y, .scroll_area);
    if (target) |t| {
        const node = tree.get(t);
        const scroll = node.kind.scroll_area;
        const old_scroll_x = scroll.scroll_x;
        const old_scroll_y = scroll.scroll_y;
        const viewport = node.layout_rect;
        const extent = dispatch_scroll.contentExtentForAppliedScroll(tree, t, scroll.effectiveScrollX(), scroll.effectiveScrollY());
        const scroll_dx = if (scroll.disable_horizontal_scroll)
            0
        else if (mouse.shift_down and ms.dx == 0) ms.dy else ms.dx;
        const scroll_dy = if (scroll.disable_vertical_scroll)
            0
        else if (mouse.shift_down and ms.dx == 0) 0 else ms.dy;

        const max_x = if (scroll.disable_horizontal_scroll) 0 else @max(extent.w - viewport.w, 0);
        const max_y = if (scroll.disable_vertical_scroll) 0 else @max(extent.h - viewport.h, 0);
        node.kind.scroll_area.scroll_x = std.math.clamp(old_scroll_x + scroll_dx, 0, max_x);
        node.kind.scroll_area.scroll_y = std.math.clamp(old_scroll_y + scroll_dy, 0, max_y);
    }
}

fn handleFocus(tree: *widget.Tree, mouse: *MouseState, f: event.Event.Focus) void {
    if (!f.focused) {
        setFocusedWidget(tree, mouse, null);
    }
}

fn handleKey(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, clipboard: ?Clipboard, k: event.Event.Key) void {
    updateModifierState(mouse, k);
    if (handleClipboardShortcut(tree, mouse, clipboard, k)) return;
    if (handleFocusTraversalKey(tree, mouse, k)) return;
    if (handleTextEditorKey(tree, mouse, k)) return;
    if (handleFocusedNavigationKey(tree, mouse, theme, k)) return;
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

fn handleClipboardShortcut(tree: *widget.Tree, mouse: *MouseState, clipboard: ?Clipboard, k: event.Event.Key) bool {
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
                        _ = dispatch_selection.selectAllGridSelector(tree, selector);
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

fn handleFocusTraversalKey(tree: *widget.Tree, mouse: *MouseState, k: event.Event.Key) bool {
    if (k.keycode != .tab) return false;
    if (!keyPressedOrRepeat(k)) return true;
    if (mouse.focused) |f| commitOrCancelNumericEditorOnBlur(tree, f);
    mouse.focused = if (mouse.shift_down)
        focus.focusPrev(tree, mouse.focused)
    else
        focus.focusNext(tree, mouse.focused);
    focus.syncFocusFlags(tree, mouse.focused);
    return true;
}

fn handleTextEditorKey(tree: *widget.Tree, mouse: *MouseState, k: event.Event.Key) bool {
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

fn moveTextCursorLeft(editor: *widget.WidgetKind.TextInput, mouse: *const MouseState) void {
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

fn moveTextCursorRight(editor: *widget.WidgetKind.TextInput, mouse: *const MouseState) void {
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

fn handleFocusedNavigationKey(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, k: event.Event.Key) bool {
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
        stepDragValue(tree, focused, -1);
    } else if (tree.getConst(focused).kind == .spinbox) {
        stepSpinBox(tree, focused, -1, false);
    } else if (tree.getConst(focused).kind == .splitter and tree.getConst(focused).kind.splitter.direction == .row) {
        stepSplitter(tree, focused, -1, theme);
    } else if (tree.getConst(focused).kind == .tab_item) {
        if (prevTabItem(tree, focused)) |prev| setKeyboardFocusAfterNavigation(tree, mouse, prev, .tab);
    } else if (tree.getConst(focused).kind == .grid_item) {
        if (prevGridItem(tree, focused)) |prev| setKeyboardFocusAfterNavigation(tree, mouse, prev, .grid);
    } else if (tree.getConst(focused).kind == .tree_item) {
        const node = tree.get(focused);
        if (node.kind.tree_item.expanded and hasTreeItemChildren(tree, focused)) {
            toggleTreeItem(tree, focused);
        } else if (findTreeParent(tree, focused)) |parent| {
            mouse.focused = parent;
            focus.syncFocusFlags(tree, mouse.focused);
        }
    }
    return true;
}

fn navigateRight(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, focused: widget.NodeHandle) bool {
    if (tree.getConst(focused).kind == .drag_value) {
        stepDragValue(tree, focused, 1);
    } else if (tree.getConst(focused).kind == .spinbox) {
        stepSpinBox(tree, focused, 1, false);
    } else if (tree.getConst(focused).kind == .splitter and tree.getConst(focused).kind.splitter.direction == .row) {
        stepSplitter(tree, focused, 1, theme);
    } else if (tree.getConst(focused).kind == .tab_item) {
        if (nextTabItem(tree, focused)) |next| setKeyboardFocusAfterNavigation(tree, mouse, next, .tab);
    } else if (tree.getConst(focused).kind == .grid_item) {
        if (nextGridItem(tree, focused)) |next| setKeyboardFocusAfterNavigation(tree, mouse, next, .grid);
    } else if (tree.getConst(focused).kind == .tree_item) {
        const node = tree.get(focused);
        if (!node.kind.tree_item.expanded and hasTreeItemChildren(tree, focused)) {
            toggleTreeItem(tree, focused);
        } else if (node.kind.tree_item.expanded) {
            mouse.focused = firstChildTreeItem(tree, focused) orelse mouse.focused;
            focus.syncFocusFlags(tree, mouse.focused);
        }
    }
    return true;
}

fn navigateUp(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, focused: widget.NodeHandle) bool {
    if (tree.getConst(focused).kind == .spinbox) {
        stepSpinBox(tree, focused, 1, false);
    } else if (tree.getConst(focused).kind == .drag_value) {
        stepDragValue(tree, focused, 1);
    } else if (tree.getConst(focused).kind == .splitter and tree.getConst(focused).kind.splitter.direction == .column) {
        stepSplitter(tree, focused, -1, theme);
    } else if (tree.getConst(focused).kind == .selectable) {
        if (prevSelectableSibling(tree, focused)) |prev| setKeyboardFocusAfterNavigation(tree, mouse, prev, .selectable);
    } else if (tree.getConst(focused).kind == .grid_item) {
        if (gridItemAbove(tree, focused)) |prev| setKeyboardFocusAfterNavigation(tree, mouse, prev, .grid);
    } else if (tree.getConst(focused).kind == .table_row) {
        if (prevTableRowSibling(tree, focused)) |prev| setKeyboardFocusAfterNavigation(tree, mouse, prev, .table);
    } else if (tree.getConst(focused).kind == .tree_item and !treeItemEditing(tree, focused)) {
        mouse.focused = prevVisibleTreeItem(tree, focused) orelse mouse.focused;
        focus.syncFocusFlags(tree, mouse.focused);
    }
    return true;
}

fn navigateDown(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, focused: widget.NodeHandle) bool {
    if (tree.getConst(focused).kind == .spinbox) {
        stepSpinBox(tree, focused, -1, false);
    } else if (tree.getConst(focused).kind == .drag_value) {
        stepDragValue(tree, focused, -1);
    } else if (tree.getConst(focused).kind == .splitter and tree.getConst(focused).kind.splitter.direction == .column) {
        stepSplitter(tree, focused, 1, theme);
    } else if (tree.getConst(focused).kind == .selectable) {
        if (nextSelectableSibling(tree, focused)) |next| setKeyboardFocusAfterNavigation(tree, mouse, next, .selectable);
    } else if (tree.getConst(focused).kind == .grid_item) {
        if (gridItemBelow(tree, focused)) |next| setKeyboardFocusAfterNavigation(tree, mouse, next, .grid);
    } else if (tree.getConst(focused).kind == .table_row) {
        if (nextTableRowSibling(tree, focused)) |next| setKeyboardFocusAfterNavigation(tree, mouse, next, .table);
    } else if (tree.getConst(focused).kind == .tree_item and !treeItemEditing(tree, focused)) {
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
    switch (kind) {
        .tab => selectTabItem(tree, target),
        .selectable => dispatch_selection.applySelectableKeyboardNavigation(tree, target, mouse),
        .grid => dispatch_selection.applyGridItemKeyboardNavigation(tree, target, mouse),
        .table => dispatch_selection.applyTableRowKeyboardNavigation(tree, target, mouse),
    }
    mouse.focused = target;
    focus.syncFocusFlags(tree, mouse.focused);
}

fn handleActivationKey(tree: *widget.Tree, mouse: *MouseState, k: event.Event.Key) bool {
    if (k.keycode != .space and k.keycode != .enter) return false;
    if (!keyPressed(k)) return true;
    const focused = mouse.focused orelse return true;
    if (treeItemEditing(tree, focused)) {
        if (k.keycode == .enter) commitTreeItemRename(tree, focused);
    } else if (numericEditorEditing(tree, focused)) {
        if (k.keycode == .enter) _ = commitNumericEditor(tree, focused);
    } else if (focusedTextEditor(tree, focused) == null) {
        fireClick(tree, focused);
    }
    return true;
}

fn handleEscapeKey(tree: *widget.Tree, mouse: *MouseState, k: event.Event.Key) bool {
    if (k.keycode != .escape) return false;
    if (!keyPressed(k)) return true;
    if (mouse.focused) |focused| {
        if (treeItemEditing(tree, focused)) {
            cancelTreeItemRename(tree, focused);
        } else if (numericEditorEditing(tree, focused)) {
            cancelNumericEditor(tree, focused);
        } else {
            dispatch_menu.closeAllPopups(tree);
        }
    } else {
        dispatch_menu.closeAllPopups(tree);
    }
    return true;
}

fn handleText(tree: *widget.Tree, mouse: *MouseState, t: event.Event.Text) void {
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

fn isPrintableTextCodepoint(codepoint: u21) bool {
    if (!std.unicode.utf8ValidCodepoint(codepoint)) return false;
    return switch (codepoint) {
        0x00...0x1F, 0x7F...0x9F => false,
        else => true,
    };
}

fn isNumericEditorCodepoint(codepoint: u21) bool {
    return switch (codepoint) {
        '+', '-', '.', 'e', 'E', '0'...'9' => true,
        else => false,
    };
}

fn focusedTextEditor(tree: *widget.Tree, handle: widget.NodeHandle) ?*widget.WidgetKind.TextInput {
    const node = tree.get(handle);
    return switch (node.kind) {
        .text_input => &node.kind.text_input,
        .tree_item => if (node.kind.tree_item.editing) &node.kind.tree_item.internal.editor else null,
        .drag_value => if (node.kind.drag_value.editing) &node.kind.drag_value.internal.editor else null,
        .spinbox => if (node.kind.spinbox.editing) &node.kind.spinbox.internal.editor else null,
        else => null,
    };
}

fn treeItemEditing(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    return node.kind == .tree_item and node.kind.tree_item.editing;
}

fn numericEditorEditing(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    return switch (node.kind) {
        .drag_value => node.kind.drag_value.editing,
        .spinbox => node.kind.spinbox.editing,
        else => false,
    };
}

fn handleInlineTextEditorPress(
    editor: *widget.WidgetKind.TextInput,
    content: []const u8,
    mouse_x: f32,
    text_x: f32,
    font_size: f32,
    mouse: *const MouseState,
    mb: event.Event.MouseButton,
    text_ctx: ?*const layout.TextMeasureCtx,
) void {
    const rel_x = mouse_x - text_x;
    const rounded = layout.charIndexAtX(content, editor.len, rel_x, font_size, text_ctx);

    if (isDoubleClick(mouse, mb)) {
        const bounds = editor.wordBounds(rounded);
        editor.selection_anchor = bounds.start;
        editor.cursor = bounds.end;
    } else if (mouse.shift_down) {
        if (editor.selection_anchor == null) editor.selection_anchor = editor.cursor;
        editor.cursor = rounded;
    } else {
        editor.selection_anchor = rounded;
        editor.cursor = rounded;
    }
}

fn beginDragValueEdit(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const drag_value = &tree.get(handle).kind.drag_value;
    if (!drag_value.editing) drag_value.beginEdit();
}

fn beginSpinBoxEdit(tree: *widget.Tree, handle: widget.NodeHandle) void {
    const spinbox = &tree.get(handle).kind.spinbox;
    if (!spinbox.editing) spinbox.beginEdit();
}

fn beginNumericEditorTextInput(tree: *widget.Tree, handle: widget.NodeHandle, codepoint: u21) void {
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

fn commitNumericEditor(tree: *widget.Tree, handle: widget.NodeHandle) bool {
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

fn cancelNumericEditor(tree: *widget.Tree, handle: widget.NodeHandle) void {
    if (!tree.isAlive(handle)) return;
    const node = tree.get(handle);
    switch (node.kind) {
        .drag_value => node.kind.drag_value.cancelEdit(),
        .spinbox => node.kind.spinbox.cancelEdit(),
        else => {},
    }
}

fn commitOrCancelNumericEditorOnBlur(tree: *widget.Tree, handle: widget.NodeHandle) void {
    if (!numericEditorEditing(tree, handle)) return;
    if (!commitNumericEditor(tree, handle)) cancelNumericEditor(tree, handle);
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

fn setFocusFromPressTarget(tree: *widget.Tree, mouse: *MouseState, target: ?widget.NodeHandle) void {
    if (target) |handle| {
        if (focus.isFocusable(tree.getConst(handle).kind)) {
            setFocusedWidget(tree, mouse, handle);
            return;
        }
    }
    setFocusedWidget(tree, mouse, null);
}

fn clearPressedTarget(tree: *widget.Tree, mouse: *MouseState, handle: widget.NodeHandle) void {
    tree.get(handle).interaction.pressed = false;
    mouse.press_target = null;
}

fn beginImmediateDrag(mouse: *MouseState, handle: widget.NodeHandle) void {
    mouse.drag_target = handle;
    mouse.drag_origin_x = mouse.x;
    mouse.drag_origin_y = mouse.y;
}

fn pressTextInput(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: event.Event.MouseButton) void {
    const node = tree.get(handle);
    const rect = node.layout_rect;
    const resolved = node.style_override.resolve(theme);
    const text_input = &node.kind.text_input;
    handleInlineTextEditorPress(text_input, text_input.content(), mouse.x, rect.x + resolved.padding.left, resolved.font_size, mouse, mb, text_ctx);
}

fn pressDragValue(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: event.Event.MouseButton) void {
    if (tree.getConst(handle).kind.drag_value.editing) {
        if (textEditorTextX(tree, handle, theme)) |text_x| {
            const resolved = tree.getConst(handle).style_override.resolve(theme);
            const editor = &tree.get(handle).kind.drag_value.internal.editor;
            handleInlineTextEditorPress(editor, editor.content(), mouse.x, text_x, resolved.font_size, mouse, mb, text_ctx);
        }
    } else {
        mouse.drag_origin_value = tree.getConst(handle).kind.drag_value.value;
        mouse.press_can_defer_drag = true;
    }
}

fn pressScrollArea(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme) void {
    const hit = dispatch_scroll.scrollbarHitAtPoint(tree, mouse.x, mouse.y, theme) orelse return;
    if (!hit.handle.eql(handle)) return;

    if (!hittest.pointInRect(mouse.x, mouse.y, hit.metrics.thumb)) {
        const next = dispatch_scroll.scrollPositionForTrackPoint(hit.metrics, mouse.x, mouse.y);
        const scroll_area = &tree.get(handle).kind.scroll_area;
        const current = switch (hit.metrics.axis) {
            .vertical => scroll_area.scroll_y,
            .horizontal => scroll_area.scroll_x,
        };
        if (@abs(next - current) > 0.01) {
            switch (hit.metrics.axis) {
                .vertical => scroll_area.scroll_y = next,
                .horizontal => scroll_area.scroll_x = next,
            }
            mouse.layout_changed = true;
        }
    }

    beginImmediateDrag(mouse, handle);
    mouse.scroll_drag_axis = hit.metrics.axis;
    mouse.drag_origin_value = switch (hit.metrics.axis) {
        .vertical => tree.getConst(handle).kind.scroll_area.scroll_y,
        .horizontal => tree.getConst(handle).kind.scroll_area.scroll_x,
    };
}

fn pressTable(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    if (widget.tableResizeHandleIndexAtPoint(tree, handle, mouse.x, mouse.y)) |divider_index| {
        const reference_row = widget.tableReferenceRow(tree, handle) orelse return;
        const left_cell = widget.tableCellAt(tree, reference_row, divider_index) orelse return;
        const right_cell = widget.tableCellAt(tree, reference_row, divider_index + 1) orelse return;
        beginImmediateDrag(mouse, handle);
        mouse.drag_origin_value = tree.getConst(left_cell).layout_rect.w;
        mouse.drag_origin_secondary_value = tree.getConst(right_cell).layout_rect.w;
        mouse.drag_origin_extent = tree.getConst(reference_row).layout_rect.w;
        mouse.drag_column_index = divider_index;
    } else if (widget.tableHeaderCellIndexAtPoint(tree, handle, mouse.x, mouse.y) == null and
        tree.getConst(handle).kind.table.selection_mode == .multiple)
    {
        mouse.press_can_defer_drag = true;
    }
}

fn pressSpinBox(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: event.Event.MouseButton) void {
    if (clickInSpinBoxDecrement(tree, handle, mouse.x)) {
        stepSpinBox(tree, handle, -1, true);
        clearPressedTarget(tree, mouse, handle);
    } else if (clickInSpinBoxIncrement(tree, handle, mouse.x)) {
        stepSpinBox(tree, handle, 1, true);
        clearPressedTarget(tree, mouse, handle);
    } else if (tree.getConst(handle).kind.spinbox.editing) {
        if (textEditorTextX(tree, handle, theme)) |text_x| {
            const resolved = tree.getConst(handle).style_override.resolve(theme);
            const editor = &tree.get(handle).kind.spinbox.internal.editor;
            handleInlineTextEditorPress(editor, editor.content(), mouse.x, text_x, resolved.font_size, mouse, mb, text_ctx);
        }
    }
}

fn pressTreeItem(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: event.Event.MouseButton) void {
    if (clickInTreeDisclosure(tree, handle, mouse.x, theme)) {
        toggleTreeItem(tree, handle);
        clearPressedTarget(tree, mouse, handle);
        mouse.press_can_defer_drag = false;
    } else if (tree.getConst(handle).kind.tree_item.editing) {
        dragTextEditorSelection(tree, handle, mouse.x, theme, text_ctx);
    } else {
        const item = &tree.get(handle).kind.tree_item;
        if (item.editable and shouldBeginTreeRename(item.*, clickInTreeLabel(tree, handle, mouse.x, theme), isDoubleClick(mouse, mb))) {
            item.beginRename();
            clearPressedTarget(tree, mouse, handle);
        } else {
            mouse.press_can_defer_drag = true;
        }
    }
}

fn handlePrimaryPressTarget(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: event.Event.MouseButton, handle: widget.NodeHandle) void {
    tree.get(handle).interaction.pressed = true;
    switch (tree.getConst(handle).kind) {
        .text_input => pressTextInput(tree, handle, mouse, theme, text_ctx, mb),
        .slider => {
            beginImmediateDrag(mouse, handle);
            mouse.drag_origin_value = tree.getConst(handle).kind.slider.value;
            updateSliderValue(tree, handle, mouse.x, theme);
        },
        .drag_value => pressDragValue(tree, handle, mouse, theme, text_ctx, mb),
        .splitter => {
            beginImmediateDrag(mouse, handle);
            mouse.drag_origin_value = tree.getConst(handle).kind.splitter.ratio;
        },
        .scroll_area => pressScrollArea(tree, handle, mouse, theme),
        .table => pressTable(tree, handle, mouse),
        .spinbox => pressSpinBox(tree, handle, mouse, theme, text_ctx, mb),
        .tree_item => pressTreeItem(tree, handle, mouse, theme, text_ctx, mb),
        .selectable => {
            if (dispatch_selection.selectableParentListBox(tree, handle) != null) mouse.press_can_defer_drag = true;
        },
        .list_box => {
            mouse.press_can_defer_drag = tree.getConst(handle).kind.list_box.selection_mode == .multiple;
        },
        .grid_item => {
            mouse.press_can_defer_drag = true;
        },
        .grid_selector => {
            mouse.press_can_defer_drag = tree.getConst(handle).kind.grid_selector.selection_mode == .multiple;
        },
        .table_row => {
            if (widget.tableRowSelectable(tree, handle)) mouse.press_can_defer_drag = true;
        },
        else => {},
    }
}

fn handlePrimaryPress(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: event.Event.MouseButton) void {
    mouse.left_down = true;
    mouse.press_origin_x = mouse.x;
    mouse.press_origin_y = mouse.y;
    mouse.press_can_defer_drag = false;
    _ = updateHover(tree, mouse);

    const target = dispatch_scroll.scrollbarTargetAtPoint(tree, mouse.x, mouse.y, theme) orelse hittest.hitTest(tree, mouse.x, mouse.y);
    dispatch_menu.closePopupsForPress(tree, target);
    setFocusFromPressTarget(tree, mouse, target);
    mouse.press_target = target;
    if (target) |handle| handlePrimaryPressTarget(tree, mouse, theme, text_ctx, mb, handle);
}

fn handlePrimaryRelease(tree: *widget.Tree, mouse: *MouseState) void {
    mouse.left_down = false;
    const dragged_target = mouse.drag_target;
    if (dragged_target) |dt| {
        switch (tree.getConst(dt).kind) {
            .tree_item => dispatch_drag.finalizeTreeDrag(tree, dt, mouse),
            .selectable => dispatch_drag.finalizeSelectableDrag(tree, dt, mouse),
            .list_box => dispatch_drag.finalizeListBoxMarquee(tree, dt),
            .grid_item => dispatch_drag.finalizeGridItemDrag(tree, dt, mouse),
            .drag_value => {},
            .grid_selector => dispatch_drag.finalizeGridSelectorMarquee(tree, dt),
            .table_row => dispatch_drag.finalizeTableRowDrag(tree, dt, mouse),
            .table => dispatch_drag.finalizeTableMarquee(tree, dt),
            else => {},
        }
        dispatch_drag.finalizeWidgetDrop(tree, dt, mouse);
    }
    mouse.drag_target = null;
    mouse.drag_column_index = null;
    mouse.drag_origin_secondary_value = 0;
    mouse.drag_origin_extent = 0;
    const release_target = hittest.hitTest(tree, mouse.x, mouse.y);

    if (mouse.press_target) |pt| {
        if (release_target) |rt| {
            if (rt.eql(pt) and !dragSuppressedClick(tree, dragged_target, pt)) {
                if (tree.isAlive(pt)) {
                    switch (tree.getConst(pt).kind) {
                        .table => activateTable(tree, pt, mouse.x, mouse.y),
                        .selectable => activateSelectable(tree, pt, mouse),
                        .grid_selector => activateGridSelector(tree, pt, mouse),
                        .grid_item => activateGridItem(tree, pt, mouse),
                        .table_row => activateTableRow(tree, pt, mouse),
                        else => fireClick(tree, pt),
                    }
                }
            }
        }
        if (tree.isAlive(pt)) {
            tree.get(pt).interaction.pressed = false;
        }
    }
    mouse.press_target = null;
    mouse.press_can_defer_drag = false;
    _ = updateHover(tree, mouse);
}

fn handleSecondaryPress(tree: *widget.Tree, mouse: *MouseState) void {
    mouse.right_down = true;
    _ = updateHover(tree, mouse);
    const target = hittest.hitTest(tree, mouse.x, mouse.y);
    dispatch_menu.closePopupsForPress(tree, target);
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
        .tree_item => true,
        .selectable => true,
        .list_box => true,
        .grid_item => true,
        .grid_selector => true,
        .table_row => true,
        .drag_value => true,
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

fn activateSelectable(tree: *widget.Tree, handle: widget.NodeHandle, mouse: ?*const MouseState) void {
    const node = tree.get(handle);
    if (node.kind != .selectable) return;

    node.interaction.primary_clicked = true;

    if (mouse) |state| {
        if (dispatch_selection.selectableParentListBox(tree, handle)) |list_box| {
            if (tree.getConst(list_box).kind.list_box.selection_mode == .multiple) {
                _ = dispatch_selection.selectListBoxMulti(tree, list_box, handle, state);
                return;
            }
        }
    }

    _ = dispatch_selection.selectSelectable(tree, handle);
}

fn activateGridSelector(tree: *widget.Tree, handle: widget.NodeHandle, mouse: ?*const MouseState) void {
    const node = tree.get(handle);
    if (node.kind != .grid_selector) return;

    node.interaction.primary_clicked = true;
    if (mouse) |state| {
        if (state.ctrl_down or state.shift_down) return;
    }
    _ = dispatch_selection.clearGridSelectorSelection(tree, handle);
}

fn activateGridItem(tree: *widget.Tree, handle: widget.NodeHandle, mouse: ?*const MouseState) void {
    const node = tree.get(handle);
    if (node.kind != .grid_item) return;

    node.interaction.primary_clicked = true;

    if (mouse) |state| {
        if (widget.gridItemParentSelector(tree, handle)) |selector| {
            if (tree.getConst(selector).kind.grid_selector.selection_mode == .multiple) {
                _ = dispatch_selection.selectGridItemsMulti(tree, selector, handle, state);
                return;
            }
        }
    }

    _ = dispatch_selection.selectGridItem(tree, handle);
}

fn activateTableRow(tree: *widget.Tree, handle: widget.NodeHandle, mouse: ?*const MouseState) void {
    if (!widget.tableRowSelectable(tree, handle)) return;

    const node = tree.get(handle);
    node.interaction.primary_clicked = true;

    if (mouse) |state| {
        const table_handle = node.parent orelse return;
        if (tree.getConst(table_handle).kind.table.selection_mode == .multiple) {
            _ = dispatch_selection.selectTableRowsMulti(tree, table_handle, handle, state);
            return;
        }
    }

    _ = dispatch_selection.selectTableRow(tree, handle);
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
    const node = tree.get(handle);
    const did_resize = node.kind.table.resizeColumns(
        divider_index,
        total_width,
        mouse.drag_origin_value,
        mouse.drag_origin_secondary_value,
        delta,
    );
    if (did_resize) node.interaction.changed = true;
    return did_resize;
}

fn updateDragValue(tree: *widget.Tree, handle: widget.NodeHandle, mouse_x: f32, mouse: *const MouseState) void {
    const node = tree.get(handle);
    const drag_value = &node.kind.drag_value;
    const delta = (mouse_x - mouse.drag_origin_x) * drag_value.speed;
    const next = std.math.clamp(mouse.drag_origin_value + delta, drag_value.min, drag_value.max);
    if (next != drag_value.value) {
        drag_value.value = next;
        drag_value.syncLabel();
        node.interaction.changed = true;
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
        node.interaction.changed = true;
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
        node.interaction.changed = true;
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
    const available = geometry.splitterAvailableExtent(splitter.*, node.layout_rect, resolved);
    if (available <= 0) return;

    const delta_px = switch (splitter.direction) {
        .row => mouse_x - mouse.drag_origin_x,
        .column => mouse_y - mouse.drag_origin_y,
    };
    const next = clampSplitterRatio(splitter.*, node.layout_rect, resolved, mouse.drag_origin_value + delta_px / available);
    if (next != splitter.ratio) {
        splitter.ratio = next;
        node.interaction.changed = true;
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
        node.interaction.changed = true;
    }
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
        },
        .checkbox => {
            node.interaction.primary_clicked = true;
            node.kind.checkbox.checked = !node.kind.checkbox.checked;
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
        },
        .dropdown => {
            node.interaction.primary_clicked = true;
            node.kind.dropdown.open = !node.kind.dropdown.open;
        },
        .selectable => {
            activateSelectable(tree, handle, null);
        },
        .grid_item => {
            activateGridItem(tree, handle, null);
        },
        .drag_value => {
            if (!node.kind.drag_value.editing) node.kind.drag_value.beginEdit();
        },
        .spinbox => {
            if (!node.kind.spinbox.editing) node.kind.spinbox.beginEdit();
        },
        .table_row => {
            activateTableRow(tree, handle, null);
        },
        .menu => {
            node.interaction.primary_clicked = true;
            dispatch_menu.toggleOwnedPopup(tree, handle, null);
        },
        .menu_item => {
            if (node.kind.menu_item.disabled) return;
            node.interaction.primary_clicked = true;
            if (dispatch_menu.directPopupChild(tree, handle) != null) {
                dispatch_menu.toggleOwnedPopup(tree, handle, null);
            } else {
                dispatch_menu.applyMenuSelection(tree, handle);
            }
        },
        .tab_item => {
            node.interaction.primary_clicked = true;
            selectTabItem(tree, handle);
        },
        .custom => {
            node.interaction.primary_clicked = true;
        },
        else => {},
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
    node.interaction.toggled = true;
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
    const node = tree.getConst(handle);
    if (node.kind == .tree_item and node.kind.tree_item.has_children) return true;
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

fn clickInSpinBoxField(tree: *const widget.Tree, handle: widget.NodeHandle, mouse_x: f32) bool {
    return mouse_x >= spinBoxMiddleStart(tree, handle) and mouse_x <= spinBoxMiddleEnd(tree, handle);
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
    rect: paint.Rect,
    resolved: style.ResolvedStyle,
    ratio: f32,
) f32 {
    const raw = std.math.clamp(ratio, 0, 1);
    const available = geometry.splitterAvailableExtent(splitter, rect, resolved);
    if (available <= 0) return raw;

    const min_ratio = std.math.clamp(splitter.min_first / available, 0, 1);
    const max_ratio = std.math.clamp(1 - splitter.min_second / available, 0, 1);
    if (min_ratio > max_ratio) return raw;
    return std.math.clamp(raw, min_ratio, max_ratio);
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

fn treeTextX(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) f32 {
    const label_x = treeLabelX(tree, handle, theme);
    const node = tree.getConst(handle);
    if (node.kind != .tree_item or node.kind.tree_item.icon == null) return label_x;
    const resolved = node.style_override.resolve(theme);
    const inner_h = @max(node.layout_rect.h - resolved.padding.top - resolved.padding.bottom, 0);
    const icon_size = @min(@max(resolved.font_size, 10), inner_h);
    return label_x + icon_size + @max(theme.spacing * 0.5, 4);
}

fn textEditorTextX(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) ?f32 {
    const node = tree.getConst(handle);
    const resolved = node.style_override.resolve(theme);
    return switch (node.kind) {
        .text_input => node.layout_rect.x + resolved.padding.left,
        .tree_item => if (node.kind.tree_item.editing) treeTextX(tree, handle, theme) else null,
        .drag_value => if (node.kind.drag_value.editing) node.layout_rect.x + resolved.padding.left else null,
        .spinbox => if (node.kind.spinbox.editing) spinBoxMiddleStart(tree, handle) + resolved.padding.left else null,
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

test {
    _ = @import("dispatch/behavior_test.zig");
    _ = @import("dispatch_text_input_test.zig");
}
