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
    for (events) |ev| {
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

test {
    _ = @import("dispatch/behavior_test.zig");
    _ = @import("dispatch_text_input_test.zig");
}
