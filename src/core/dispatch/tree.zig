const widget = @import("../widget.zig");

pub fn isDescendantOf(tree: *const widget.Tree, handle: widget.NodeHandle, ancestor: widget.NodeHandle) bool {
    var current = tree.getConst(handle).parent;
    while (current) |parent_handle| {
        if (parent_handle.eql(ancestor)) return true;
        current = tree.getConst(parent_handle).parent;
    }
    return false;
}
