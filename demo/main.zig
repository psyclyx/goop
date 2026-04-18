const std = @import("std");
const goop = @import("goop");

pub fn main() !void {
    std.debug.print("goop demo\n", .{});

    var clay = try goop.Clay.init(std.heap.page_allocator);
    defer clay.deinit(std.heap.page_allocator);

    std.debug.print("clay initialized\n", .{});
}
