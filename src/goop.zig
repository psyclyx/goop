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
        c.Clay_SetCurrentContext(null);
        allocator.free(self.clay_arena);
    }

    /// Run layout: walk the widget tree through clay and write back rects.
    pub fn doLayout(self: *Context) void {
        layout.run(&self.tree, self.theme);
    }

    /// Update layout dimensions (e.g. on window resize).
    pub fn setDimensions(self: *Context, width: u32, height: u32) void {
        _ = self;
        c.Clay_SetLayoutDimensions(.{
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        });
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

test "layout produces non-zero rects" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .{ .width = 800, .height = 600 });
    defer ctx.deinit(allocator);

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    _ = try ctx.tree.addChild(root, .{ .button = .{ .label = "OK" } });
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "hello" } });

    ctx.doLayout();

    const root_rect = ctx.tree.getConst(root).layout_rect;
    try std.testing.expect(root_rect.w > 0);
    try std.testing.expect(root_rect.h > 0);
}

test {
    _ = widget;
    _ = style;
    _ = layout;
}
