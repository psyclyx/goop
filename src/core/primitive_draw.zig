const std = @import("std");
const style = @import("style.zig");
const layout = @import("layout.zig");
const paint = @import("paint_types.zig");
const handle = @import("handle.zig");

pub const Rect = paint.Rect;
pub const TextAlign = paint.TextAlign;
pub const TextOverflow = paint.TextOverflow;
pub const IconId = paint.IconId;
pub const PaintCommand = paint.PaintCommand;
pub const PaintList = paint.PaintList;

/// Renderer-facing primitive draw commands.
pub const DrawCommand = union(enum) {
    rect: DrawRect,
    text: DrawText,
    clip: ClipRect,
    icon: DrawIcon,
    custom: DrawCustom,

    pub const DrawRect = struct {
        bounds: Rect,
        color: style.Color,
        border_color: style.Color,
        border_width: f32,
        corner_radius: f32,
    };

    pub const DrawText = struct {
        bounds: Rect,
        baseline_y: f32,
        text: []const u8,
        color: style.Color,
        font_size: f32,
        text_align: TextAlign = .start,
        overflow: TextOverflow = .visible,
    };

    pub const ClipRect = struct {
        bounds: ?Rect,
    };

    pub const DrawIcon = struct {
        bounds: Rect,
        kind: IconId,
        color: style.Color,
    };

    pub const DrawCustom = struct {
        handle: handle.NodeHandle,
        bounds: Rect,
    };
};

pub const DrawList = struct {
    commands: []const DrawCommand,
};

pub fn lowerPaintList(paint_list: PaintList, allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx) !DrawList {
    var commands: std.ArrayListUnmanaged(DrawCommand) = .empty;
    errdefer commands.deinit(allocator);
    var metrics_cache = TextMetricsCache{};

    for (paint_list.commands) |command| {
        switch (command) {
            .surface => |surface| try commands.append(allocator, .{ .rect = .{
                .bounds = surface.bounds,
                .color = surface.color,
                .border_color = surface.border_color,
                .border_width = surface.border_width,
                .corner_radius = surface.corner_radius,
            } }),
            .text => |text| {
                const metrics = metrics_cache.metricsFor(text.font_size, text_ctx);
                try commands.append(allocator, .{ .text = lowerTextCommand(text, metrics) });
            },
            .clip => |clip| try commands.append(allocator, .{ .clip = .{ .bounds = clip.bounds } }),
            .icon => |icon| try commands.append(allocator, .{ .icon = .{
                .bounds = icon.bounds,
                .kind = icon.kind,
                .color = icon.color,
            } }),
            .custom => |custom| try commands.append(allocator, .{ .custom = .{
                .handle = custom.handle,
                .bounds = custom.bounds,
            } }),
        }
    }

    return .{ .commands = try commands.toOwnedSlice(allocator) };
}

pub fn freeDrawList(draw_list: *DrawList, allocator: std.mem.Allocator) void {
    allocator.free(draw_list.commands);
    draw_list.commands = &.{};
}

const TextMetricsCache = struct {
    const Entry = struct {
        font_size: f32,
        metrics: layout.TextDimensions,
    };

    entries: [8]?Entry = [_]?Entry{null} ** 8,
    len: usize = 0,
    next_slot: usize = 0,

    fn metricsFor(self: *TextMetricsCache, font_size: f32, text_ctx: ?*const layout.TextMeasureCtx) layout.TextDimensions {
        for (self.entries[0..self.len]) |entry_opt| {
            const entry = entry_opt orelse continue;
            if (entry.font_size == font_size) return entry.metrics;
        }

        const metrics = layout.textMetrics(font_size, text_ctx);
        if (self.len < self.entries.len) {
            self.entries[self.len] = .{
                .font_size = font_size,
                .metrics = metrics,
            };
            self.len += 1;
        } else {
            self.entries[self.next_slot] = .{
                .font_size = font_size,
                .metrics = metrics,
            };
            self.next_slot = (self.next_slot + 1) % self.entries.len;
        }
        return metrics;
    }
};

fn lowerTextCommand(text: PaintCommand.Text, metrics: layout.TextDimensions) DrawCommand.DrawText {
    return .{
        .bounds = text.bounds,
        .baseline_y = textBaselineY(text.bounds, metrics),
        .text = text.text,
        .color = text.color,
        .font_size = text.font_size,
        .text_align = text.text_align,
        .overflow = text.overflow,
    };
}

fn textBaselineY(bounds: Rect, metrics: layout.TextDimensions) f32 {
    const extra_vertical = @max(bounds.h - metrics.height, 0);
    return bounds.y + extra_vertical * 0.5 + metrics.ascent;
}
