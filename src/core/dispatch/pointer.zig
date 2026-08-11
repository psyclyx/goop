const std = @import("std");
const widget = @import("../widget.zig");
const input = @import("goop_input");
const focus = @import("../focus.zig");
const hittest = @import("../hittest.zig");
const layout = @import("../layout.zig");
const style = @import("../style.zig");

const types = @import("types.zig");
const activation = @import("activation.zig");
const control = @import("control.zig");
const drag = @import("drag.zig");
const focus_state = @import("focus_state.zig");
const hit_dispatch = @import("hit.zig");
const menu = @import("menu.zig");
const navigation = @import("navigation.zig");
const scroll_dispatch = @import("scroll.zig");
const selection = @import("selection.zig");
const text = @import("text.zig");

const MouseState = types.MouseState;

pub fn cancelPointerGesture(tree: *widget.Tree, mouse: *MouseState) void {
    if (mouse.press_target) |target| {
        if (tree.isAlive(target)) tree.get(target).interaction.pressed = false;
    }
    if (mouse.drag_target) |target| {
        if (tree.isAlive(target)) pointerKindOps(tree.getConst(target).kind).cancel_drag(tree, target);
    }

    for (tree.nodes.items) |*node| {
        if (!node.alive) continue;
        node.interaction.drop_hovered = false;
        pointerKindOps(node.kind).cancel_gesture(node);
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

pub fn handleMouseMove(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mm: input.Event.MouseMove) void {
    mouse.x = mm.x;
    mouse.y = mm.y;
    updateScrollbarHover(tree, mouse, theme);
    drag.maybeBeginDeferredDrag(tree, mouse);
    if (mouse.drag_target) |dt| {
        pointerKindOps(tree.getConst(dt).kind).drag_move(tree, dt, mouse, theme);
        drag.updateWidgetDropPreview(tree, dt, mouse);
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
    if (!mouse.left_down) menu.syncMenuHover(tree, hovered, mouse);
}

pub fn handleMouseButton(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: input.Event.MouseButton) void {
    mouse.x = mb.x;
    mouse.y = mb.y;
    updateScrollbarHover(tree, mouse, theme);
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

pub fn handleMouseScroll(tree: *widget.Tree, mouse: *MouseState, ms: input.Event.MouseScroll) void {
    // Find the scroll area under the cursor and adjust scroll offset
    const target = hittest.hitTestKind(tree, mouse.x, mouse.y, .scroll_area);
    if (target) |t| {
        const node = tree.get(t);
        const scroll = node.kind.scroll_area;
        const old_scroll_x = scroll.scroll_x;
        const old_scroll_y = scroll.scroll_y;
        const viewport = node.layout_rect;
        const extent = scroll_dispatch.contentExtentForAppliedScroll(tree, t, scroll.effectiveScrollX(), scroll.effectiveScrollY());
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
        if (node.kind.scroll_area.scroll_x != old_scroll_x or node.kind.scroll_area.scroll_y != old_scroll_y) {
            mouse.emitScroll(tree, t);
        }
    }
}

fn handleInlineTextEditorPress(
    editor: *widget.WidgetKind.TextInput,
    content: []const u8,
    mouse_x: f32,
    text_x: f32,
    font_size: f32,
    mouse: *const MouseState,
    mb: input.Event.MouseButton,
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
    if (text.focusedTextEditor(tree, handle)) |editor| {
        if (hit_dispatch.textEditorTextX(tree, handle, theme)) |text_x| {
            const font_size = tree.getConst(handle).style_override.resolve(theme).font_size;
            const rel_x = mouse_x - text_x;
            editor.cursor = layout.charIndexAtX(editor.content(), editor.len, rel_x, font_size, text_ctx);
        }
    }
}

fn setFocusFromPressTarget(tree: *widget.Tree, mouse: *MouseState, target: ?widget.NodeHandle) void {
    if (target) |handle| {
        if (focus.nodeIsFocusable(tree, handle)) {
            focus_state.setFocusedWidget(tree, mouse, handle);
            return;
        }
    }
    focus_state.setFocusedWidget(tree, mouse, null);
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

fn pressTextInput(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: input.Event.MouseButton) void {
    const node = tree.get(handle);
    const rect = node.layout_rect;
    const resolved = node.style_override.resolve(theme);
    const text_input = &node.kind.text_input;
    handleInlineTextEditorPress(text_input, text_input.content(), mouse.x, rect.x + resolved.padding.left, resolved.font_size, mouse, mb, text_ctx);
}

fn pressDragValue(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: input.Event.MouseButton) void {
    if (tree.getConst(handle).kind.drag_value.editing) {
        if (hit_dispatch.textEditorTextX(tree, handle, theme)) |text_x| {
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
    const hit = scroll_dispatch.scrollbarHitAtPoint(tree, mouse.x, mouse.y, theme) orelse return;
    if (!hit.handle.eql(handle)) return;

    if (!hittest.pointInRect(mouse.x, mouse.y, hit.metrics.thumb)) {
        const next = scroll_dispatch.scrollPositionForTrackPoint(hit.metrics, mouse.x, mouse.y);
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
            mouse.emitScroll(tree, handle);
        }
    }

    beginImmediateDrag(mouse, handle);
    mouse.scroll_drag_axis = hit.metrics.axis;
    tree.get(handle).kind.scroll_area.internal.active_scrollbar = hit.metrics.axis;
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

fn pressSpinBox(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: input.Event.MouseButton) void {
    if (hit_dispatch.clickInSpinBoxDecrement(tree, handle, mouse.x)) {
        control.stepSpinBox(tree, handle, mouse, -1, true);
        clearPressedTarget(tree, mouse, handle);
    } else if (hit_dispatch.clickInSpinBoxIncrement(tree, handle, mouse.x)) {
        control.stepSpinBox(tree, handle, mouse, 1, true);
        clearPressedTarget(tree, mouse, handle);
    } else if (tree.getConst(handle).kind.spinbox.editing) {
        if (hit_dispatch.textEditorTextX(tree, handle, theme)) |text_x| {
            const resolved = tree.getConst(handle).style_override.resolve(theme);
            const editor = &tree.get(handle).kind.spinbox.internal.editor;
            handleInlineTextEditorPress(editor, editor.content(), mouse.x, text_x, resolved.font_size, mouse, mb, text_ctx);
        }
    }
}

fn pressTreeItem(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: input.Event.MouseButton) void {
    if (hit_dispatch.clickInTreeDisclosure(tree, handle, mouse.x, theme)) {
        navigation.toggleTreeItem(tree, handle, mouse);
        clearPressedTarget(tree, mouse, handle);
        mouse.press_can_defer_drag = false;
    } else if (tree.getConst(handle).kind.tree_item.editing) {
        dragTextEditorSelection(tree, handle, mouse.x, theme, text_ctx);
    } else {
        const item = &tree.get(handle).kind.tree_item;
        if (item.editable and activation.shouldBeginTreeRename(item.*, hit_dispatch.clickInTreeLabel(tree, handle, mouse.x, theme), isDoubleClick(mouse, mb))) {
            item.beginRename();
            clearPressedTarget(tree, mouse, handle);
        } else {
            mouse.press_can_defer_drag = true;
        }
    }
}

fn handlePrimaryPressTarget(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: input.Event.MouseButton, handle: widget.NodeHandle) void {
    tree.get(handle).interaction.pressed = true;
    pointerKindOps(tree.getConst(handle).kind).press(tree, handle, mouse, theme, text_ctx, mb);
}

fn handlePrimaryPress(tree: *widget.Tree, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: input.Event.MouseButton) void {
    mouse.left_down = true;
    mouse.press_origin_x = mouse.x;
    mouse.press_origin_y = mouse.y;
    mouse.press_can_defer_drag = false;
    _ = updateHover(tree, mouse);

    const target = scroll_dispatch.scrollbarTargetAtPoint(tree, mouse.x, mouse.y, theme) orelse hittest.hitTest(tree, mouse.x, mouse.y);
    menu.closePopupsForPress(tree, target);
    setFocusFromPressTarget(tree, mouse, target);
    mouse.press_target = target;
    mouse.press_target_element_id = if (target) |t| tree.elementId(t) else null;
    if (target) |handle| handlePrimaryPressTarget(tree, mouse, theme, text_ctx, mb, handle);
}

fn handlePrimaryRelease(tree: *widget.Tree, mouse: *MouseState) void {
    mouse.left_down = false;
    const dragged_target = mouse.drag_target;
    if (dragged_target) |dt| {
        pointerKindOps(tree.getConst(dt).kind).release_drag(tree, dt, mouse);
        drag.finalizeWidgetDrop(tree, dt, mouse);
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
                    pointerKindOps(tree.getConst(pt).kind).release_activate(tree, pt, mouse);
                }
            }
        }
        if (tree.isAlive(pt)) {
            tree.get(pt).interaction.pressed = false;
        }
    }
    mouse.press_target = null;
    mouse.press_target_element_id = null;
    mouse.press_can_defer_drag = false;
    _ = updateHover(tree, mouse);
}

const PointerKindOps = struct {
    cancel_drag: CancelDragFn = cancelDragNoop,
    cancel_gesture: CancelGestureFn = cancelGestureNoop,
    drag_move: DragMoveFn = dragMoveNoop,
    press: PressFn = pressNoop,
    release_drag: ReleaseDragFn = releaseDragNoop,
    release_activate: ReleaseActivateFn = releaseActivateDefault,
    suppresses_drag_click: bool = false,
};

const CancelDragFn = *const fn (*widget.Tree, widget.NodeHandle) void;
const CancelGestureFn = *const fn (*widget.Node) void;
const DragMoveFn = *const fn (*widget.Tree, widget.NodeHandle, *MouseState, style.Theme) void;
const PressFn = *const fn (*widget.Tree, widget.NodeHandle, *MouseState, style.Theme, ?*const layout.TextMeasureCtx, input.Event.MouseButton) void;
const ReleaseDragFn = *const fn (*widget.Tree, widget.NodeHandle, *MouseState) void;
const ReleaseActivateFn = *const fn (*widget.Tree, widget.NodeHandle, *MouseState) void;

fn pointerKindOps(kind: widget.WidgetKind) PointerKindOps {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return pointer_kind_ops[@intFromEnum(tag)];
}

const pointer_kind_ops = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var ops: [std.meta.fields(Tag).len]PointerKindOps = undefined;
    for (&ops) |*op| op.* = .{};
    ops[@intFromEnum(Tag.text_input)] = .{ .press = pressTextInputOp };
    ops[@intFromEnum(Tag.slider)] = .{
        .drag_move = dragMoveSlider,
        .press = pressSlider,
    };
    ops[@intFromEnum(Tag.drag_value)] = .{
        .drag_move = dragMoveDragValue,
        .press = pressDragValueOp,
        .suppresses_drag_click = true,
    };
    ops[@intFromEnum(Tag.splitter)] = .{
        .drag_move = dragMoveSplitter,
        .press = pressSplitter,
    };
    ops[@intFromEnum(Tag.scroll_area)] = .{
        .cancel_gesture = cancelScrollAreaGesture,
        .drag_move = dragMoveScrollArea,
        .press = pressScrollAreaOp,
        .release_drag = releaseScrollAreaDrag,
    };
    ops[@intFromEnum(Tag.table)] = .{
        .cancel_drag = cancelTableDrag,
        .cancel_gesture = cancelTableGesture,
        .drag_move = dragMoveTable,
        .press = pressTableOp,
        .release_drag = releaseTableDrag,
        .release_activate = releaseActivateTable,
        .suppresses_drag_click = true,
    };
    ops[@intFromEnum(Tag.tree_item)] = .{
        .cancel_gesture = cancelTreeItemGesture,
        .drag_move = dragMoveTreeItem,
        .press = pressTreeItemOp,
        .release_drag = releaseTreeItemDrag,
        .suppresses_drag_click = true,
    };
    ops[@intFromEnum(Tag.selectable)] = .{
        .cancel_gesture = cancelSelectableGesture,
        .drag_move = dragMoveSelectable,
        .press = pressSelectable,
        .release_drag = releaseSelectableDrag,
        .release_activate = releaseActivateSelectable,
        .suppresses_drag_click = true,
    };
    ops[@intFromEnum(Tag.list_box)] = .{
        .cancel_drag = cancelListBoxDrag,
        .cancel_gesture = cancelListBoxGesture,
        .drag_move = dragMoveListBox,
        .press = pressListBox,
        .release_drag = releaseListBoxDrag,
        .suppresses_drag_click = true,
    };
    ops[@intFromEnum(Tag.grid_selector)] = .{
        .cancel_drag = cancelGridSelectorDrag,
        .cancel_gesture = cancelGridSelectorGesture,
        .drag_move = dragMoveGridSelector,
        .press = pressGridSelector,
        .release_drag = releaseGridSelectorDrag,
        .release_activate = releaseActivateGridSelector,
        .suppresses_drag_click = true,
    };
    ops[@intFromEnum(Tag.grid_item)] = .{
        .cancel_gesture = cancelGridItemGesture,
        .drag_move = dragMoveGridItem,
        .press = pressGridItem,
        .release_drag = releaseGridItemDrag,
        .release_activate = releaseActivateGridItem,
        .suppresses_drag_click = true,
    };
    ops[@intFromEnum(Tag.table_row)] = .{
        .cancel_gesture = cancelTableRowGesture,
        .drag_move = dragMoveTableRow,
        .press = pressTableRow,
        .release_drag = releaseTableRowDrag,
        .release_activate = releaseActivateTableRow,
        .suppresses_drag_click = true,
    };
    ops[@intFromEnum(Tag.spinbox)] = .{ .press = pressSpinBoxOp };
    break :blk ops;
};

fn cancelDragNoop(_: *widget.Tree, _: widget.NodeHandle) void {}

fn cancelListBoxDrag(tree: *widget.Tree, handle: widget.NodeHandle) void {
    drag.cancelListBoxMarquee(tree, handle);
}

fn cancelGridSelectorDrag(tree: *widget.Tree, handle: widget.NodeHandle) void {
    drag.cancelGridSelectorMarquee(tree, handle);
}

fn cancelTableDrag(tree: *widget.Tree, handle: widget.NodeHandle) void {
    drag.cancelTableMarquee(tree, handle);
}

fn cancelGestureNoop(_: *widget.Node) void {}

fn cancelTreeItemGesture(node: *widget.Node) void {
    const item = &node.kind.tree_item;
    item.internal.drag.active = false;
    item.internal.drag.rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    item.internal.drop_preview = null;
}

fn cancelListBoxGesture(node: *widget.Node) void {
    const list_box = &node.kind.list_box;
    list_box.internal.marquee_active = false;
    list_box.internal.marquee_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    list_box.internal.drop_preview_background = false;
}

fn cancelSelectableGesture(node: *widget.Node) void {
    const item = &node.kind.selectable;
    item.internal.marquee_base_selected = false;
    item.internal.drag.active = false;
    item.internal.drag.rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    item.internal.drop_preview = false;
}

fn cancelGridSelectorGesture(node: *widget.Node) void {
    const selector = &node.kind.grid_selector;
    selector.internal.marquee_active = false;
    selector.internal.marquee_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    selector.internal.drop_preview_background = false;
}

fn cancelGridItemGesture(node: *widget.Node) void {
    const item = &node.kind.grid_item;
    item.internal.marquee_base_selected = false;
    item.internal.drag.active = false;
    item.internal.drag.rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    item.internal.drop_preview = false;
}

fn cancelTableGesture(node: *widget.Node) void {
    const table = &node.kind.table;
    table.internal.marquee_active = false;
    table.internal.marquee_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    table.internal.drop_preview_background = false;
}

fn cancelTableRowGesture(node: *widget.Node) void {
    const row = &node.kind.table_row;
    row.internal.marquee_base_selected = false;
    row.internal.drag.active = false;
    row.internal.drag.rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    row.internal.drop_preview = false;
}

fn cancelScrollAreaGesture(node: *widget.Node) void {
    node.kind.scroll_area.internal.active_scrollbar = null;
}

fn dragMoveNoop(_: *widget.Tree, _: widget.NodeHandle, _: *MouseState, _: style.Theme) void {}

fn dragMoveSlider(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme) void {
    control.updateSliderValue(tree, handle, mouse, mouse.x, theme);
}

fn dragMoveDragValue(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, _: style.Theme) void {
    control.updateDragValue(tree, handle, mouse.x, mouse);
}

fn dragMoveSplitter(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme) void {
    control.updateSplitterRatio(tree, handle, mouse.x, mouse.y, mouse, theme);
}

fn dragMoveScrollArea(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme) void {
    if (scroll_dispatch.updateScrollAreaDrag(tree, handle, mouse, theme)) {
        mouse.layout_changed = true;
        mouse.emitScroll(tree, handle);
    }
}

fn dragMoveTable(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, _: style.Theme) void {
    if (control.updateTableColumns(tree, handle, mouse)) mouse.layout_changed = true;
    drag.updateTableMarquee(tree, handle, mouse);
}

fn dragMoveTreeItem(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, _: style.Theme) void {
    drag.updateTreeDragPreview(tree, handle, mouse);
}

fn dragMoveSelectable(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, _: style.Theme) void {
    drag.updateSelectableDragPreview(tree, handle, mouse);
}

fn dragMoveListBox(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, _: style.Theme) void {
    drag.updateListBoxMarquee(tree, handle, mouse);
}

fn dragMoveGridItem(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, _: style.Theme) void {
    drag.updateGridItemDragPreview(tree, handle, mouse);
}

fn dragMoveGridSelector(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, _: style.Theme) void {
    drag.updateGridSelectorMarquee(tree, handle, mouse);
}

fn dragMoveTableRow(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, _: style.Theme) void {
    drag.updateTableRowDragPreview(tree, handle, mouse);
}

fn pressNoop(_: *widget.Tree, _: widget.NodeHandle, _: *MouseState, _: style.Theme, _: ?*const layout.TextMeasureCtx, _: input.Event.MouseButton) void {}

fn pressTextInputOp(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: input.Event.MouseButton) void {
    pressTextInput(tree, handle, mouse, theme, text_ctx, mb);
}

fn pressSlider(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme, _: ?*const layout.TextMeasureCtx, _: input.Event.MouseButton) void {
    beginImmediateDrag(mouse, handle);
    mouse.drag_origin_value = tree.getConst(handle).kind.slider.value;
    control.updateSliderValue(tree, handle, mouse, mouse.x, theme);
}

fn pressDragValueOp(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: input.Event.MouseButton) void {
    pressDragValue(tree, handle, mouse, theme, text_ctx, mb);
}

fn pressSplitter(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, _: style.Theme, _: ?*const layout.TextMeasureCtx, _: input.Event.MouseButton) void {
    beginImmediateDrag(mouse, handle);
    mouse.drag_origin_value = tree.getConst(handle).kind.splitter.ratio;
}

fn pressScrollAreaOp(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme, _: ?*const layout.TextMeasureCtx, _: input.Event.MouseButton) void {
    pressScrollArea(tree, handle, mouse, theme);
}

fn pressTableOp(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, _: style.Theme, _: ?*const layout.TextMeasureCtx, _: input.Event.MouseButton) void {
    pressTable(tree, handle, mouse);
}

fn pressSpinBoxOp(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: input.Event.MouseButton) void {
    pressSpinBox(tree, handle, mouse, theme, text_ctx, mb);
}

fn pressTreeItemOp(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, theme: style.Theme, text_ctx: ?*const layout.TextMeasureCtx, mb: input.Event.MouseButton) void {
    pressTreeItem(tree, handle, mouse, theme, text_ctx, mb);
}

fn pressSelectable(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, _: style.Theme, _: ?*const layout.TextMeasureCtx, _: input.Event.MouseButton) void {
    if (selection.selectableParentListBox(tree, handle) != null) mouse.press_can_defer_drag = true;
}

fn pressListBox(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, _: style.Theme, _: ?*const layout.TextMeasureCtx, _: input.Event.MouseButton) void {
    mouse.press_can_defer_drag = tree.getConst(handle).kind.list_box.selection_mode == .multiple;
}

fn pressGridItem(_: *widget.Tree, _: widget.NodeHandle, mouse: *MouseState, _: style.Theme, _: ?*const layout.TextMeasureCtx, _: input.Event.MouseButton) void {
    mouse.press_can_defer_drag = true;
}

fn pressGridSelector(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, _: style.Theme, _: ?*const layout.TextMeasureCtx, _: input.Event.MouseButton) void {
    mouse.press_can_defer_drag = tree.getConst(handle).kind.grid_selector.selection_mode == .multiple;
}

fn pressTableRow(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, _: style.Theme, _: ?*const layout.TextMeasureCtx, _: input.Event.MouseButton) void {
    if (widget.tableRowSelectable(tree, handle)) mouse.press_can_defer_drag = true;
}

fn releaseDragNoop(_: *widget.Tree, _: widget.NodeHandle, _: *MouseState) void {}

fn releaseTreeItemDrag(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    drag.finalizeTreeDrag(tree, handle, mouse);
}

fn releaseSelectableDrag(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    drag.finalizeSelectableDrag(tree, handle, mouse);
}

fn releaseListBoxDrag(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    drag.finalizeListBoxMarquee(tree, handle, mouse);
}

fn releaseGridItemDrag(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    drag.finalizeGridItemDrag(tree, handle, mouse);
}

fn releaseGridSelectorDrag(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    drag.finalizeGridSelectorMarquee(tree, handle, mouse);
}

fn releaseTableRowDrag(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    drag.finalizeTableRowDrag(tree, handle, mouse);
}

fn releaseScrollAreaDrag(tree: *widget.Tree, handle: widget.NodeHandle, _: *MouseState) void {
    tree.get(handle).kind.scroll_area.internal.active_scrollbar = null;
}

fn releaseTableDrag(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    drag.finalizeTableMarquee(tree, handle, mouse);
}

fn releaseActivateDefault(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    activation.fireClick(tree, handle, mouse);
}

fn releaseActivateTable(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    activation.activateTable(tree, handle, mouse, mouse.x, mouse.y);
}

fn releaseActivateSelectable(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    activation.activateSelectable(tree, handle, mouse);
}

fn releaseActivateGridSelector(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    activation.activateGridSelector(tree, handle, mouse);
}

fn releaseActivateGridItem(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    activation.activateGridItem(tree, handle, mouse);
}

fn releaseActivateTableRow(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) void {
    activation.activateTableRow(tree, handle, mouse);
}

fn handleSecondaryPress(tree: *widget.Tree, mouse: *MouseState) void {
    mouse.right_down = true;
    _ = updateHover(tree, mouse);
    const target = hittest.hitTest(tree, mouse.x, mouse.y);
    menu.closePopupsForPress(tree, target);
    mouse.right_press_target = target;
    mouse.right_press_target_element_id = if (target) |t| tree.elementId(t) else null;
}

fn handleSecondaryRelease(tree: *widget.Tree, mouse: *MouseState) void {
    mouse.right_down = false;
    const release_target = hittest.hitTest(tree, mouse.x, mouse.y);
    if (mouse.right_press_target) |pt| {
        if (release_target) |rt| {
            if (rt.eql(pt)) activation.fireSecondaryClick(tree, pt, mouse);
        }
    }
    mouse.right_press_target = null;
    mouse.right_press_target_element_id = null;
    _ = updateHover(tree, mouse);
}

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

fn updateScrollbarHover(tree: *widget.Tree, mouse: *const MouseState, theme: style.Theme) void {
    for (tree.nodes.items) |*node| {
        if (!node.alive or node.kind != .scroll_area) continue;
        node.kind.scroll_area.internal.hovered_scrollbar = null;
    }
    const hit = scroll_dispatch.scrollbarHitAtPoint(tree, mouse.x, mouse.y, theme) orelse return;
    tree.get(hit.handle).kind.scroll_area.internal.hovered_scrollbar = hit.metrics.axis;
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
    return pointerKindOps(tree.getConst(pressed_target).kind).suppresses_drag_click;
}

fn treeHasTooltip(tree: *const widget.Tree) bool {
    for (tree.nodes.items) |node| {
        if (node.alive and node.kind == .tooltip) return true;
    }
    return false;
}

fn isDoubleClick(mouse: *const MouseState, mb: input.Event.MouseButton) bool {
    if (mouse.last_click_time_ms == 0 or mb.timestamp_ms == 0) return false;
    const dt = mb.timestamp_ms -| mouse.last_click_time_ms;
    if (dt > MouseState.double_click_time_ms) return false;
    const dx = @abs(mb.x - mouse.last_click_x);
    const dy = @abs(mb.y - mouse.last_click_y);
    return dx <= MouseState.double_click_dist and dy <= MouseState.double_click_dist;
}
