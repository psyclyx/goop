//! Minimal game-owned look and render-pipeline composition.
//!
//! Goop supplies interaction/layout data. Reusable components emit directly
//! into the game's queue; neither stock Chrome nor a Goop renderer is present.

const std = @import("std");
const goop = @import("goop");
const components = @import("goop_components");
const visual = @import("goop_visual");

const allocator = std.heap.smp_allocator;

const element = struct {
    const root = goop.ElementId.init(1);
    const play = goop.ElementId.init(2);
    const minimap = goop.ElementId.init(3);
};

const action = struct {
    const play = goop.ActionId.init(1);
};

/// Representative game-native queue. These are deliberately not Goop visual
/// operations: encoder methods write straight into the game's own command
/// vocabulary.
const GameQueue = struct {
    commands: [16]Command = undefined,
    len: usize = 0,

    const NativeRect = struct {
        left: f32,
        top: f32,
        right: f32,
        bottom: f32,
    };

    const Command = union(enum) {
        begin_scissor: NativeRect,
        end_scissor,
        quad: struct {
            bounds: NativeRect,
            rgba: u32,
            border_rgba: u32,
        },
        glyphs: struct {
            bounds: NativeRect,
            bytes: []const u8,
            rgba: u32,
        },
        image: struct { bounds: NativeRect, asset: u64 },
        game_visual: struct { bounds: NativeRect, id: u64 },
    };

    fn nativeRect(value: visual.Rect) NativeRect {
        return .{
            .left = value.x,
            .top = value.y,
            .right = value.x + value.w,
            .bottom = value.y + value.h,
        };
    }

    fn rgba(value: visual.Color) u32 {
        return (@as(u32, value.r) << 24) |
            (@as(u32, value.g) << 16) |
            (@as(u32, value.b) << 8) |
            @as(u32, value.a);
    }

    fn append(self: *GameQueue, command: Command) error{QueueFull}!void {
        if (self.len == self.commands.len) return error.QueueFull;
        self.commands[self.len] = command;
        self.len += 1;
    }

    pub fn pushClip(self: *GameQueue, bounds: visual.Rect) !void {
        try self.append(.{ .begin_scissor = nativeRect(bounds) });
    }

    pub fn popClip(self: *GameQueue) !void {
        try self.append(.end_scissor);
    }

    pub fn surface(self: *GameQueue, value: visual.Surface) !void {
        try self.append(.{ .quad = .{
            .bounds = nativeRect(value.bounds),
            .rgba = rgba(value.color),
            .border_rgba = rgba(value.border_color),
        } });
    }

    pub fn text(self: *GameQueue, value: visual.Text) !void {
        try self.append(.{ .glyphs = .{
            .bounds = nativeRect(value.bounds),
            .bytes = value.text,
            .rgba = rgba(value.color),
        } });
    }

    pub fn icon(self: *GameQueue, value: visual.Icon) !void {
        try self.append(.{ .image = .{ .bounds = nativeRect(value.bounds), .asset = value.kind } });
    }

    pub fn image(self: *GameQueue, value: visual.Image) !void {
        try self.append(.{ .image = .{
            .bounds = nativeRect(value.bounds),
            .asset = value.source.id.value,
        } });
    }

    pub fn custom(self: *GameQueue, value: visual.Custom) !void {
        try self.append(.{ .game_visual = .{ .bounds = nativeRect(value.bounds), .id = value.id.value } });
    }
};

/// The custom look holds only the game's render capability. Resolved elements
/// arrive as semantic values; retained tree storage never crosses this seam.
const GameLook = struct {
    queue: *GameQueue,

    pub fn enter(self: *GameLook, value: goop.ResolvedElement) !void {
        const clips_children = value.widget == .scroll_area;
        if (clips_children) try self.queue.pushClip(value.bounds);

        switch (value.widget) {
            .button => |button| try (components.Button{
                .background = .{
                    .bounds = value.bounds,
                    .color = if (value.pressed) value.style.bg_active else value.style.bg,
                    .border_color = value.style.border,
                    .border_width = value.style.border_width,
                    .corner_radius = value.style.border_radius,
                },
                .label = .{
                    .bounds = value.bounds,
                    .content = button.label,
                    .color = value.style.fg,
                    .font_size = value.style.font_size,
                    .text_align = .center,
                },
                .focus = .{
                    .bounds = value.bounds,
                    .color = value.style.focus_ring,
                    .corner_radius = value.style.border_radius,
                    .visible = value.focused,
                },
            }).emit(self.queue),
            .custom => {
                const id = value.id orelse return;
                try self.queue.custom(.{
                    .id = .fromElementId(id.value()),
                    .bounds = value.bounds,
                });
            },
            else => {},
        }
    }

    pub fn leave(self: *GameLook, value: goop.ResolvedElement) !void {
        if (value.widget == .scroll_area) try self.queue.popClip();
    }
};

pub fn main() !void {
    var context = try goop.Context.init(allocator, .{ .width = 640, .height = 360 });
    defer context.deinit();

    const root = try context.tree.addRootControl(.{
        .identity = .{ .element_id = element.root },
        .widget = .{ .scroll_area = .{} },
    });
    const play = try context.tree.addChildControl(root, .{
        .identity = .{ .element_id = element.play, .action_id = action.play },
        .widget = .{ .button = .{ .label = "Play" } },
    });
    _ = try context.tree.addChildControl(root, .{
        .identity = .{ .element_id = element.minimap },
        .widget = .{ .custom = .{ .type_id = 9, .width = 160, .height = 90 } },
    });

    // Style is data owned by the application/look boundary, not behavior in a
    // component object.
    _ = context.setStyle(play, .{
        .bg = .rgb(28, 72, 110),
        .fg = .rgb(245, 250, 255),
        .border = .rgb(80, 170, 235),
    });
    context.doLayout(null);
    std.debug.assert(context.focusWidget(play));
    try context.pushEvent(.{ .key = .{ .keycode = .enter, .state = .pressed } });

    const output = try context.processEvents();
    std.debug.assert(output.items.len == 1);
    std.debug.assert(output.items[0] == .activated);
    std.debug.assert(output.items[0].activated.element == element.play);
    std.debug.assert(output.items[0].activated.action.? == action.play);

    var queue = GameQueue{};
    var look = GameLook{ .queue = &queue };
    try context.visitResolved(&look);
    std.debug.assert(queue.len >= 6);
    std.debug.assert(queue.commands[0] == .begin_scissor);
    std.debug.assert(queue.commands[queue.len - 1] == .end_scissor);
}
