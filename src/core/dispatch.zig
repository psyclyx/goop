const std = @import("std");
const widget = @import("widget.zig");
const event = @import("event.zig");
const focus = @import("focus.zig");
const hittest = @import("hittest.zig");
const layout = @import("layout.zig");
const style = @import("style.zig");

const dispatch_types = @import("dispatch/types.zig");
const dispatch_activation = @import("dispatch/activation.zig");
const dispatch_control = @import("dispatch/control.zig");
const dispatch_navigation = @import("dispatch/navigation.zig");
const dispatch_drag = @import("dispatch/drag.zig");
const dispatch_hit = @import("dispatch/hit.zig");
const dispatch_keyboard = @import("dispatch/keyboard.zig");
const dispatch_menu = @import("dispatch/menu.zig");
const dispatch_scroll = @import("dispatch/scroll.zig");
const dispatch_selection = @import("dispatch/selection.zig");
const dispatch_text = @import("dispatch/text.zig");
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
                dispatch_text.commitOrCancelNumericEditorOnBlur(tree, previous_focus);
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
        .key => |k| dispatch_keyboard.handleKey(tree, mouse, theme, clipboard, k),
        .text => |t| dispatch_text.handleText(tree, mouse, t),
        else => {},
    }
}

fn handleMouseMove(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mm: event.Event.MouseMove) void {
    mouse.x = mm.x;
    mouse.y = mm.y;
    dispatch_drag.maybeBeginDeferredDrag(tree, mouse);
    if (mouse.drag_target) |dt| {
        switch (tree.getConst(dt).kind) {
            .slider => dispatch_control.updateSliderValue(tree, dt, mouse.x, theme),
            .drag_value => dispatch_control.updateDragValue(tree, dt, mouse.x, mouse),
            .splitter => dispatch_control.updateSplitterRatio(tree, dt, mouse.x, mouse.y, mouse, theme),
            .scroll_area => {
                if (dispatch_scroll.updateScrollAreaDrag(tree, dt, mouse, theme)) mouse.layout_changed = true;
            },
            .table => {
                if (dispatch_control.updateTableColumns(tree, dt, mouse)) mouse.layout_changed = true;
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

fn dragTextEditorSelection(
    tree: *widget.Tree,
    handle: widget.NodeHandle,
    mouse_x: f32,
    theme: style.Theme,
    text_ctx: ?*const layout.TextMeasureCtx,
) void {
    if (dispatch_text.focusedTextEditor(tree, handle)) |editor| {
        if (dispatch_hit.textEditorTextX(tree, handle, theme)) |text_x| {
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
        if (dispatch_hit.textEditorTextX(tree, handle, theme)) |text_x| {
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
    if (dispatch_hit.clickInSpinBoxDecrement(tree, handle, mouse.x)) {
        dispatch_control.stepSpinBox(tree, handle, -1, true);
        clearPressedTarget(tree, mouse, handle);
    } else if (dispatch_hit.clickInSpinBoxIncrement(tree, handle, mouse.x)) {
        dispatch_control.stepSpinBox(tree, handle, 1, true);
        clearPressedTarget(tree, mouse, handle);
    } else if (tree.getConst(handle).kind.spinbox.editing) {
        if (dispatch_hit.textEditorTextX(tree, handle, theme)) |text_x| {
            const resolved = tree.getConst(handle).style_override.resolve(theme);
            const editor = &tree.get(handle).kind.spinbox.internal.editor;
            handleInlineTextEditorPress(editor, editor.content(), mouse.x, text_x, resolved.font_size, mouse, mb, text_ctx);
        }
    }
}

fn pressTreeItem(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: event.Event.MouseButton) void {
    if (dispatch_hit.clickInTreeDisclosure(tree, handle, mouse.x, theme)) {
        dispatch_navigation.toggleTreeItem(tree, handle);
        clearPressedTarget(tree, mouse, handle);
        mouse.press_can_defer_drag = false;
    } else if (tree.getConst(handle).kind.tree_item.editing) {
        dragTextEditorSelection(tree, handle, mouse.x, theme, text_ctx);
    } else {
        const item = &tree.get(handle).kind.tree_item;
        if (item.editable and dispatch_activation.shouldBeginTreeRename(item.*, dispatch_hit.clickInTreeLabel(tree, handle, mouse.x, theme), isDoubleClick(mouse, mb))) {
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
            dispatch_control.updateSliderValue(tree, handle, mouse.x, theme);
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
                        .table => dispatch_activation.activateTable(tree, pt, mouse.x, mouse.y),
                        .selectable => dispatch_activation.activateSelectable(tree, pt, mouse),
                        .grid_selector => dispatch_activation.activateGridSelector(tree, pt, mouse),
                        .grid_item => dispatch_activation.activateGridItem(tree, pt, mouse),
                        .table_row => dispatch_activation.activateTableRow(tree, pt, mouse),
                        else => dispatch_activation.fireClick(tree, pt),
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
            if (rt.eql(pt)) dispatch_activation.fireSecondaryClick(tree, pt, mouse);
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

/// Check if a mouse press constitutes a double-click based on timing and position.
fn isDoubleClick(mouse: *const MouseState, mb: event.Event.MouseButton) bool {
    if (mouse.last_click_time_ms == 0 or mb.timestamp_ms == 0) return false;
    const dt = mb.timestamp_ms -| mouse.last_click_time_ms;
    if (dt > MouseState.double_click_time_ms) return false;
    const dx = @abs(mb.x - mouse.last_click_x);
    const dy = @abs(mb.y - mouse.last_click_y);
    return dx <= MouseState.double_click_dist and dy <= MouseState.double_click_dist;
}

test {
    _ = @import("dispatch/behavior_test.zig");
    _ = @import("dispatch_text_input_test.zig");
}
