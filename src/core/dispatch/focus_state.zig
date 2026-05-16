const widget = @import("../widget.zig");
const focus = @import("../focus.zig");
const types = @import("types.zig");
const text = @import("text.zig");

const MouseState = types.MouseState;

pub fn setFocusedWidget(tree: *widget.Tree, mouse: *MouseState, target: ?widget.NodeHandle) void {
    if (mouse.focused) |previous_focus| {
        if (target == null or !target.?.eql(previous_focus)) {
            if (tree.isAlive(previous_focus)) {
                text.commitOrCancelNumericEditorOnBlur(tree, previous_focus);
            }
        }
    }
    mouse.focused = target;
    focus.syncFocusFlags(tree, mouse.focused);
}
