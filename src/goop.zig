const std = @import("std");
const c = @cImport({
    @cInclude("clay.h");
});

pub const Clay = struct {
    arena: []u8,

    pub fn init(allocator: std.mem.Allocator) !Clay {
        const min_memory = c.Clay_MinMemorySize();
        const arena = try allocator.alloc(u8, min_memory);
        const clay_arena = c.Clay_Arena{
            .capacity = min_memory,
            .memory = arena.ptr,
        };
        _ = c.Clay_Initialize(clay_arena, .{ .width = 800, .height = 600 }, .{});
        return .{ .arena = arena };
    }

    pub fn deinit(self: *Clay, allocator: std.mem.Allocator) void {
        allocator.free(self.arena);
    }
};

test "clay initializes" {
    const allocator = std.testing.allocator;
    var clay = try Clay.init(allocator);
    defer clay.deinit(allocator);
}
