const std = @import("std");
const c = @cImport({
    @cInclude("clay.h");
});

pub const widget = @import("core/widget.zig");
pub const event = @import("core/event.zig");
pub const style = @import("core/style.zig");
pub const draw = @import("core/draw.zig");
pub const layout = @import("core/layout.zig");

pub const Tree = widget.Tree;
pub const NodeHandle = widget.NodeHandle;
pub const WidgetKind = widget.WidgetKind;
pub const Event = event.Event;
pub const Theme = style.Theme;
pub const Style = style.Style;
pub const Color = style.Color;

pub const Context = struct {
    clay_arena: []u8,
    tree: Tree,
    theme: Theme,

    pub fn init(allocator: std.mem.Allocator, opts: InitOptions) !Context {
        const min_memory = c.Clay_MinMemorySize();
        const arena = try allocator.alloc(u8, min_memory);
        const clay_arena = c.Clay_Arena{
            .capacity = min_memory,
            .memory = arena.ptr,
        };
        _ = c.Clay_Initialize(clay_arena, .{
            .width = @floatFromInt(opts.width),
            .height = @floatFromInt(opts.height),
        }, .{});
        return .{
            .clay_arena = arena,
            .tree = Tree.init(allocator),
            .theme = opts.theme,
        };
    }

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        self.tree.deinit();
        allocator.free(self.clay_arena);
    }

    pub const InitOptions = struct {
        width: u32 = 800,
        height: u32 = 600,
        theme: Theme = .{},
    };
};

test "context initializes" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .{});
    defer ctx.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), ctx.tree.count());
}

test {
    _ = widget;
    _ = style;
}
