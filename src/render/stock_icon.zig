//! Backend-neutral geometry for the compact stock icon vocabulary.

const std = @import("std");
const visual = @import("goop_visual");

pub const max_parts = 8;
pub const Tone = enum { base, detail, highlight, paper };
pub const Part = struct { rect: visual.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, tone: Tone = .base };
pub const Parts = [max_parts]Part;

const z: Part = .{};
fn p(x: f32, y: f32, w: f32, h: f32, tone: Tone) Part {
    return .{ .rect = .{ .x = x, .y = y, .w = w, .h = h }, .tone = tone };
}

pub fn geometry(kind: visual.IconId) Parts {
    return switch (kind) {
        @intFromEnum(visual.StockIcon.folder) => .{
            p(0.07, 0.28, 0.86, 0.58, .base), p(0.12, 0.18, 0.34, 0.20, .highlight), z, z, z, z, z, z,
        },
        @intFromEnum(visual.StockIcon.folder_symlink) => .{
            p(0.07, 0.28, 0.86, 0.58, .base),   p(0.12, 0.18, 0.34, 0.20, .highlight),
            p(0.02, 0.57, 0.44, 0.40, .paper),  p(0.10, 0.73, 0.27, 0.09, .detail),
            p(0.10, 0.65, 0.09, 0.17, .detail), p(0.10, 0.65, 0.16, 0.08, .detail),
            z,                                  z,
        },
        @intFromEnum(visual.StockIcon.file) => fileParts(),
        @intFromEnum(visual.StockIcon.file_symlink) => .{
            p(0.18, 0.08, 0.64, 0.84, .base),   p(0.30, 0.35, 0.40, 0.05, .detail),
            p(0.02, 0.57, 0.44, 0.40, .paper),  p(0.10, 0.73, 0.27, 0.09, .detail),
            p(0.10, 0.65, 0.09, 0.17, .detail), p(0.10, 0.65, 0.16, 0.08, .detail),
            z,                                  z,
        },
        @intFromEnum(visual.StockIcon.symlink) => .{
            p(0.08, 0.22, 0.84, 0.64, .paper),  p(0.18, 0.52, 0.58, 0.10, .detail),
            p(0.18, 0.40, 0.10, 0.22, .detail), p(0.18, 0.40, 0.20, 0.09, .detail),
            z,                                  z,
            z,                                  z,
        },
        @intFromEnum(visual.StockIcon.list) => .{
            p(0.18, 0.22, 0.64, 0.10, .base), p(0.18, 0.46, 0.64, 0.10, .base), p(0.18, 0.70, 0.64, 0.10, .base), z, z, z, z, z,
        },
        @intFromEnum(visual.StockIcon.grid) => .{
            p(0.18, 0.18, 0.25, 0.25, .base), p(0.57, 0.18, 0.25, 0.25, .base), p(0.18, 0.57, 0.25, 0.25, .base), p(0.57, 0.57, 0.25, 0.25, .base), z, z, z, z,
        },
        @intFromEnum(visual.StockIcon.back) => arrowHorizontal(false),
        @intFromEnum(visual.StockIcon.forward) => arrowHorizontal(true),
        @intFromEnum(visual.StockIcon.up) => .{
            p(0.45, 0.36, 0.10, 0.48, .base), p(0.45, 0.14, 0.10, 0.12, .base),
            p(0.35, 0.24, 0.30, 0.11, .base), p(0.25, 0.34, 0.20, 0.11, .base),
            p(0.55, 0.34, 0.20, 0.11, .base), z,
            z,                                z,
        },
        @intFromEnum(visual.StockIcon.home) => .{
            p(0.24, 0.42, 0.52, 0.44, .base),  p(0.44, 0.16, 0.12, 0.10, .base),
            p(0.34, 0.25, 0.32, 0.10, .base),  p(0.24, 0.34, 0.52, 0.10, .base),
            p(0.45, 0.62, 0.14, 0.24, .paper), z,
            z,                                 z,
        },
        @intFromEnum(visual.StockIcon.refresh) => .{
            p(0.25, 0.20, 0.50, 0.10, .base), p(0.65, 0.20, 0.10, 0.35, .base),
            p(0.55, 0.12, 0.20, 0.10, .base), p(0.65, 0.12, 0.10, 0.20, .base),
            p(0.25, 0.70, 0.50, 0.10, .base), p(0.25, 0.45, 0.10, 0.35, .base),
            p(0.25, 0.68, 0.20, 0.10, .base), p(0.25, 0.60, 0.10, 0.18, .base),
        },
        @intFromEnum(visual.StockIcon.sidebar) => panelParts(0.30),
        @intFromEnum(visual.StockIcon.preview) => panelParts(0.58),
        @intFromEnum(visual.StockIcon.info) => .{
            p(0.45, 0.38, 0.10, 0.42, .base), p(0.45, 0.20, 0.10, 0.10, .base), z, z, z, z, z, z,
        },
        @intFromEnum(visual.StockIcon.zoom_in) => zoomParts(true),
        @intFromEnum(visual.StockIcon.zoom_out) => zoomParts(false),
        @intFromEnum(visual.StockIcon.zoom_reset) => .{
            p(0.16, 0.16, 0.56, 0.10, .base), p(0.16, 0.16, 0.10, 0.56, .base), p(0.62, 0.16, 0.10, 0.56, .base), p(0.16, 0.62, 0.56, 0.10, .base), p(0.68, 0.68, 0.18, 0.10, .base), p(0.78, 0.68, 0.10, 0.18, .base), z, z,
        },
        @intFromEnum(visual.StockIcon.hidden) => .{
            p(0.30, 0.24, 0.40, 0.09, .base), p(0.20, 0.32, 0.18, 0.09, .base),
            p(0.62, 0.32, 0.18, 0.09, .base), p(0.12, 0.41, 0.76, 0.18, .base),
            p(0.20, 0.59, 0.18, 0.09, .base), p(0.62, 0.59, 0.18, 0.09, .base),
            p(0.30, 0.68, 0.40, 0.09, .base), p(0.44, 0.36, 0.12, 0.28, .detail),
        },
        @intFromEnum(visual.StockIcon.close) => .{
            p(0.22, 0.22, 0.13, 0.13, .base), p(0.33, 0.33, 0.13, 0.13, .base),
            p(0.44, 0.44, 0.13, 0.13, .base), p(0.55, 0.55, 0.13, 0.13, .base),
            p(0.55, 0.22, 0.13, 0.13, .base), p(0.44, 0.33, 0.13, 0.13, .base),
            p(0.33, 0.44, 0.13, 0.13, .base), p(0.22, 0.55, 0.13, 0.13, .base),
        },
        @intFromEnum(visual.StockIcon.go) => arrowHorizontal(true),
        @intFromEnum(visual.StockIcon.collapse_left) => collapsePanel(false),
        @intFromEnum(visual.StockIcon.collapse_right) => collapsePanel(true),
        @intFromEnum(visual.StockIcon.check) => .{
            // A checkmark as an overlapping staircase of squares: a short arm
            // stepping down to the vertex, then a long arm stepping up-right.
            p(0.16, 0.44, 0.16, 0.16, .base), p(0.26, 0.54, 0.16, 0.16, .base),
            p(0.34, 0.60, 0.16, 0.16, .base), p(0.44, 0.50, 0.16, 0.16, .base),
            p(0.54, 0.40, 0.16, 0.16, .base), p(0.62, 0.30, 0.16, 0.16, .base),
            p(0.70, 0.22, 0.16, 0.16, .base), z,
        },
        else => .{ p(0.20, 0.20, 0.60, 0.60, .base), z, z, z, z, z, z, z },
    };
}

fn fileParts() Parts {
    return .{ p(0.18, 0.08, 0.64, 0.84, .base), p(0.30, 0.35, 0.40, 0.05, .detail), p(0.30, 0.50, 0.40, 0.05, .detail), p(0.30, 0.65, 0.28, 0.05, .detail), z, z, z, z };
}

fn arrowHorizontal(forward: bool) Parts {
    return if (forward)
        .{ p(0.20, 0.45, 0.60, 0.10, .base), p(0.62, 0.28, 0.10, 0.27, .base), p(0.62, 0.45, 0.10, 0.27, .base), z, z, z, z, z }
    else
        .{ p(0.20, 0.45, 0.60, 0.10, .base), p(0.28, 0.28, 0.10, 0.27, .base), p(0.28, 0.45, 0.10, 0.27, .base), z, z, z, z, z };
}

fn panelParts(divider_x: f32) Parts {
    return .{ p(0.14, 0.16, 0.72, 0.10, .base), p(0.14, 0.74, 0.72, 0.10, .base), p(0.14, 0.16, 0.10, 0.68, .base), p(0.76, 0.16, 0.10, 0.68, .base), p(divider_x, 0.16, 0.08, 0.68, .detail), z, z, z };
}

fn zoomParts(plus: bool) Parts {
    return .{ p(0.18, 0.18, 0.48, 0.09, .base), p(0.18, 0.18, 0.09, 0.48, .base), p(0.57, 0.18, 0.09, 0.48, .base), p(0.18, 0.57, 0.48, 0.09, .base), p(0.61, 0.61, 0.24, 0.10, .base), if (plus) p(0.37, 0.30, 0.09, 0.26, .detail) else z, p(0.29, 0.39, 0.25, 0.09, .detail), z };
}

fn collapsePanel(right: bool) Parts {
    const rail = if (right) p(0.74, 0.16, 0.08, 0.68, .detail) else p(0.18, 0.16, 0.08, 0.68, .detail);
    const arrow = arrowHorizontal(right);
    return .{ rail, arrow[0], arrow[1], arrow[2], z, z, z, z };
}

test "all stock icon parts stay inside normalized bounds" {
    for (std.meta.tags(visual.StockIcon)) |kind| for (geometry(@intFromEnum(kind))) |part| {
        try std.testing.expect(part.rect.x >= 0 and part.rect.y >= 0);
        try std.testing.expect(part.rect.w >= 0 and part.rect.h >= 0);
        try std.testing.expect(part.rect.x + part.rect.w <= 1.001);
        try std.testing.expect(part.rect.y + part.rect.h <= 1.001);
    };
}

test "symlink variants reserve a readable badge" {
    for ([_]visual.StockIcon{ .folder_symlink, .file_symlink }) |kind| {
        const badge = geometry(@intFromEnum(kind))[2];
        try std.testing.expectEqual(Tone.paper, badge.tone);
        try std.testing.expect(badge.rect.w >= 0.4 and badge.rect.h >= 0.35);
    }
}
