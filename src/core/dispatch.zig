const widget = @import("widget.zig");
const input = @import("goop_input");
const layout = @import("layout.zig");
const style = @import("style.zig");

const dispatch_types = @import("dispatch/types.zig");
const dispatch_focus = @import("dispatch/focus_state.zig");
const dispatch_keyboard = @import("dispatch/keyboard.zig");
const dispatch_pointer = @import("dispatch/pointer.zig");
const dispatch_text = @import("dispatch/text.zig");
const dispatch_tooltip = @import("dispatch/tooltip.zig");
const control_event = @import("control_event.zig");
pub const MouseState = dispatch_types.MouseState;
pub const Clipboard = dispatch_types.Clipboard;
pub const TooltipState = dispatch_tooltip.State;
pub const UpdateResult = dispatch_tooltip.UpdateResult;

/// Process a batch of events and append semantic occurrences to `journal`.
/// The caller must reserve the full batch with `Journal.prepareBatch` before
/// calling; dispatch itself is allocation-free.
pub fn process(
    tree: *widget.Tree,
    events: []const input.Event,
    mouse: *MouseState,
    theme: style.Theme,
    clipboard: ?Clipboard,
    text_ctx: ?*const layout.TextMeasureCtx,
    journal: *control_event.Journal,
) void {
    discardDeadHandles(tree, mouse);
    mouse.control_journal = journal;
    defer mouse.control_journal = null;
    for (events) |ev| {
        discardDeadHandles(tree, mouse);
        processOne(tree, ev, mouse, theme, clipboard, text_ctx);
    }
}

pub fn cancelPointerGesture(tree: *widget.Tree, mouse: *MouseState) void {
    dispatch_pointer.cancelPointerGesture(tree, mouse);
}

pub fn updateTimedState(tree: *widget.Tree, mouse: *const MouseState, tooltips: *TooltipState, now_ms: u64) UpdateResult {
    return dispatch_tooltip.update(tree, mouse, tooltips, now_ms);
}

fn processOne(tree: *widget.Tree, ev: input.Event, mouse: *MouseState, theme: style.Theme, clipboard: ?Clipboard, text_ctx: ?*const layout.TextMeasureCtx) void {
    switch (ev) {
        .mouse_move => |mm| dispatch_pointer.handleMouseMove(tree, mouse, theme, text_ctx, mm),
        .mouse_button => |mb| dispatch_pointer.handleMouseButton(tree, mouse, theme, text_ctx, mb),
        .mouse_scroll => |ms| dispatch_pointer.handleMouseScroll(tree, mouse, theme, ms),
        .focus => |f| handleFocus(tree, mouse, f),
        .key => |k| dispatch_keyboard.handleKey(tree, mouse, theme, clipboard, k),
        .text => |t| dispatch_text.handleText(tree, mouse, t),
        else => {},
    }
}

fn handleFocus(tree: *widget.Tree, mouse: *MouseState, f: input.Event.Focus) void {
    if (!f.focused) {
        dispatch_pointer.cancelPointerGesture(tree, mouse);
        dispatch_focus.setFocusedWidget(tree, mouse, null);
    }
}

fn discardDeadHandles(tree: *const widget.Tree, mouse: *MouseState) void {
    if (mouse.focused) |handle| {
        if (!tree.isAlive(handle)) mouse.focused = null;
    }
    if (mouse.hovered) |handle| {
        if (!tree.isAlive(handle)) mouse.hovered = null;
    }
    if (mouse.press_target) |handle| {
        if (!tree.isAlive(handle)) {
            // A click spans press and release, often several frames apart. If
            // the tree was rebuilt in between, re-resolve the press target by
            // its stable semantic element ID so the release still registers on
            // the same logical widget instead of being dropped.
            mouse.press_target = if (mouse.press_target_element_id) |id| tree.findByElementId(id) else null;
            if (mouse.press_target == null) {
                mouse.press_target_element_id = null;
                mouse.press_can_defer_drag = false;
            }
        }
    }
    if (mouse.right_press_target) |handle| {
        if (!tree.isAlive(handle)) {
            mouse.right_press_target = if (mouse.right_press_target_element_id) |id| tree.findByElementId(id) else null;
            if (mouse.right_press_target == null) mouse.right_press_target_element_id = null;
        }
    }
    if (mouse.drag_target) |handle| {
        if (!tree.isAlive(handle)) {
            mouse.drag_target = null;
            mouse.tree_drop_preview = null;
            mouse.grid_drop_preview = null;
            mouse.list_drop_preview = null;
            mouse.table_drop_preview = null;
            mouse.widget_drop_preview = null;
        }
    }
    if (mouse.tree_drop_preview) |drop| {
        if (!tree.isAlive(drop.source) or !tree.isAlive(drop.target))
            mouse.tree_drop_preview = null;
    }
    if (mouse.grid_drop_preview) |drop| {
        if (!tree.isAlive(drop.source) or !tree.isAlive(drop.target))
            mouse.grid_drop_preview = null;
    }
    if (mouse.list_drop_preview) |drop| {
        if (!tree.isAlive(drop.source) or !tree.isAlive(drop.target))
            mouse.list_drop_preview = null;
    }
    if (mouse.table_drop_preview) |drop| {
        if (!tree.isAlive(drop.source) or !tree.isAlive(drop.target))
            mouse.table_drop_preview = null;
    }
    if (mouse.widget_drop_preview) |drop| {
        if (!tree.isAlive(drop.source) or !tree.isAlive(drop.target))
            mouse.widget_drop_preview = null;
    }
}

test {
    _ = @import("dispatch/behavior_test.zig");
    _ = @import("dispatch/pointer_capture_test.zig");
    _ = @import("dispatch/tooltip.zig");
    _ = @import("dispatch_text_input_test.zig");
}
