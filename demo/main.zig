const std = @import("std");
const goop = @import("goop");

pub fn main() !void {
    std.debug.print("goop demo\n", .{});

    var ctx = try goop.Context.init(std.heap.page_allocator, .{});
    defer ctx.deinit(std.heap.page_allocator);

    std.debug.print("context initialized, tree has {d} nodes\n", .{ctx.tree.count()});
}
