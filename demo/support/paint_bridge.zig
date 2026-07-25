//! Adapter from the established goop widget paint list to the renderer-neutral
//! retained display protocol.
//!
//! The widget library and application logic know nothing about Vulkan. This
//! module is the sole compatibility boundary while the public widget API is
//! retained.

const std = @import("std");
const goop = @import("goop");
const display = @import("goop_display");
const driver = @import("goop_driver");

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    scene: driver.Scene,
    commands: std.ArrayListUnmanaged(display.Command) = .empty,
    scale: f32 = 1,

    pub fn init(allocator: std.mem.Allocator) Bridge {
        return .{
            .allocator = allocator,
            .scene = driver.Scene.init(allocator),
        };
    }

    pub fn deinit(self: *Bridge) void {
        self.commands.deinit(self.allocator);
        self.scene.deinit();
        self.* = undefined;
    }

    pub fn invalidateAll(self: *Bridge) void {
        self.scene.invalidateAll();
    }

    /// Convert and reconcile one complete paint snapshot. Returned slices live
    /// until the next call.
    pub fn frame(
        self: *Bridge,
        paint_list: goop.PaintList,
        scale: f32,
    ) !display.DisplayDelta {
        if (self.scale != scale) {
            self.scale = scale;
            self.scene.invalidateAll();
        }
        self.commands.clearRetainingCapacity();
        try self.commands.ensureTotalCapacity(self.allocator, paint_list.commands.len);
        for (paint_list.commands, 0..) |paint_command, index| {
            const converted = convertPaint(paint_command, scale);
            self.commands.appendAssumeCapacity(.{
                .id = .init(@as(u64, @intCast(index)) + 1),
                .fingerprint = display.fingerprint(converted),
                .order = @intCast(index),
                .paint = converted,
            });
        }
        return self.scene.reconcile(self.commands.items);
    }
};

fn convertPaint(source: goop.PaintCommand, scale: f32) display.PaintCommand {
    return switch (source) {
        .surface => |surface| .{ .surface = .{
            .bounds = scaledRect(surface.bounds, scale),
            .role = @enumFromInt(@intFromEnum(surface.role)),
            .state = @bitCast(surface.state),
            .color = color(surface.color),
            .border_color = color(surface.border_color),
            .border_width = surface.border_width * scale,
            .corner_radius = surface.corner_radius * scale,
        } },
        .text => |text| .{ .text = .{
            .bounds = scaledRect(text.bounds, scale),
            .text = text.text,
            .color = color(text.color),
            .font_size = text.font_size * scale,
            .text_align = @enumFromInt(@intFromEnum(text.text_align)),
            .overflow = @enumFromInt(@intFromEnum(text.overflow)),
        } },
        .clip => |clip| .{ .clip = .{
            .bounds = if (clip.bounds) |bounds| scaledRect(bounds, scale) else null,
        } },
        .icon => |icon| .{ .icon = .{
            .bounds = scaledRect(icon.bounds, scale),
            .kind = icon.kind,
            .color = color(icon.color),
        } },
        .custom => |custom| .{ .custom = .{
            .id = (@as(u64, custom.handle.generation) << 32) | custom.handle.index,
            .bounds = scaledRect(custom.bounds, scale),
        } },
    };
}

fn scaledRect(rect: goop.paint.Rect, scale: f32) display.Rect {
    return .{
        .x = rect.x * scale,
        .y = rect.y * scale,
        .w = rect.w * scale,
        .h = rect.h * scale,
    };
}

fn color(value: goop.Color) display.Color {
    return .rgba(value.r, value.g, value.b, value.a);
}

test "bridge preserves the complete semantic paint vocabulary" {
    const allocator = std.testing.allocator;
    var bridge = Bridge.init(allocator);
    defer bridge.deinit();

    const commands = [_]goop.PaintCommand{
        .{ .surface = .{
            .bounds = .{ .x = 1, .y = 2, .w = 3, .h = 4 },
            .color = .rgb(1, 2, 3),
            .border_color = .rgb(4, 5, 6),
            .border_width = 1,
            .corner_radius = 2,
        } },
        .{ .clip = .{ .bounds = null } },
    };
    const delta = try bridge.frame(.{ .commands = &commands }, 2);
    try std.testing.expect(delta.damage == .full);
    try std.testing.expectEqual(@as(usize, 2), delta.operations.len);
}
