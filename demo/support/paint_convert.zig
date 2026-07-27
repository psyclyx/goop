//! Stateless conversion from the core semantic paint list to the
//! renderer-neutral display command stream. This is all the full-redraw
//! renderer needs from the old paint bridge: no retained identity, no damage,
//! no reconciliation — just map the vocabulary and apply the display scale.

const std = @import("std");
const goop = @import("goop");
const display = @import("goop_display");

/// Convert a frame's paint list into display commands. The returned slice is
/// caller-owned; text payloads are borrowed from the paint list and remain
/// valid for the same frame lifetime.
pub fn convert(
    allocator: std.mem.Allocator,
    paint_list: goop.PaintList,
    scale: f32,
) ![]display.PaintCommand {
    const out = try allocator.alloc(display.PaintCommand, paint_list.commands.len);
    for (paint_list.commands, 0..) |command, index| out[index] = convertOne(command, scale);
    return out;
}

fn convertOne(source: goop.PaintCommand, scale: f32) display.PaintCommand {
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
    return .{ .x = rect.x * scale, .y = rect.y * scale, .w = rect.w * scale, .h = rect.h * scale };
}

fn color(value: goop.Color) display.Color {
    return .rgba(value.r, value.g, value.b, value.a);
}
