const widget = @import("widget.zig");
const event = @import("event.zig");
const layout = @import("layout.zig");
const style = @import("style.zig");

const dispatch_types = @import("dispatch/types.zig");
const dispatch_focus = @import("dispatch/focus_state.zig");
const dispatch_keyboard = @import("dispatch/keyboard.zig");
const dispatch_pointer = @import("dispatch/pointer.zig");
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
    discardDeadHandles(tree, mouse);
    for (events) |ev| {
        // Custom behavior callbacks may mutate the tree while a batch is
        // being dispatched, so validate retained interaction handles before
        // every event rather than only once per frame.
        discardDeadHandles(tree, mouse);
        processOne(tree, ev, mouse, theme, clipboard, text_ctx);
    }
}

pub fn cancelPointerGesture(tree: *widget.Tree, mouse: *MouseState) void {
    dispatch_pointer.cancelPointerGesture(tree, mouse);
}

fn processOne(tree: *widget.Tree, ev: event.Event, mouse: *MouseState, theme: style.Theme, clipboard: ?Clipboard, text_ctx: ?*const layout.TextMeasureCtx) void {
    switch (ev) {
        .mouse_move => |mm| dispatch_pointer.handleMouseMove(tree, mouse, theme, text_ctx, mm),
        .mouse_button => |mb| dispatch_pointer.handleMouseButton(tree, mouse, theme, text_ctx, mb),
        .mouse_scroll => |ms| dispatch_pointer.handleMouseScroll(tree, mouse, ms),
        .focus => |f| handleFocus(tree, mouse, f),
        .key => |k| dispatch_keyboard.handleKey(tree, mouse, theme, clipboard, k),
        .text => |t| dispatch_text.handleText(tree, mouse, t),
        else => {},
    }
}

fn handleFocus(tree: *widget.Tree, mouse: *MouseState, f: event.Event.Focus) void {
    if (!f.focused) {
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
            mouse.press_target = null;
            mouse.press_can_defer_drag = false;
        }
    }
    if (mouse.right_press_target) |handle| {
        if (!tree.isAlive(handle)) mouse.right_press_target = null;
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
    if (mouse.last_secondary_click) |click| {
        if (!tree.isAlive(click.target)) mouse.last_secondary_click = null;
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
    if (mouse.last_drop) |drop| {
        if (!tree.isAlive(drop.source()) or !tree.isAlive(drop.target()))
            mouse.last_drop = null;
    }
}

test {
    _ = @import("dispatch/behavior_test.zig");
    _ = @import("dispatch_text_input_test.zig");
}
