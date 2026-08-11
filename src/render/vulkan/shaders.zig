//! Vulkan SPIR-V artifacts and the per-family pipeline recipe.
//!
//! The SPIR-V is compiled by goop's own build from snail's slang sources
//! (flat atlas storage; see `compileSnailSlang` in build.zig). This module is
//! pure data — no Vulkan imports — so the family table stays unit-testable.
//! The descriptor/push-constant contract lives in `snail_reflection`.

const std = @import("std");

/// Re-materialize embedded SPIR-V into a 4-byte-aligned static array:
/// `@embedFile` hands back an unaligned slice, and `vkCreateShaderModule`
/// requires a word-aligned `pCode`.
fn alignedSpv(comptime bytes: []const u8) []align(4) const u8 {
    const holder = struct {
        const aligned: [bytes.len]u8 align(4) = blk: {
            var a: [bytes.len]u8 align(4) = undefined;
            @memcpy(a[0..], bytes);
            break :blk a;
        };
    };
    return &holder.aligned;
}

pub const text_vert_spv = alignedSpv(@embedFile("text_vert_spv"));
pub const text_frag_spv = alignedSpv(@embedFile("text_frag_spv"));
pub const colr_frag_spv = alignedSpv(@embedFile("colr_frag_spv"));
pub const path_quadratic_frag_spv = alignedSpv(@embedFile("path_quadratic_frag_spv"));
pub const path_conic_frag_spv = alignedSpv(@embedFile("path_conic_frag_spv"));
pub const path_frag_spv = alignedSpv(@embedFile("path_frag_spv"));
pub const tt_hinted_text_frag_spv = alignedSpv(@embedFile("tt_hinted_text_frag_spv"));
pub const autohint_vert_spv = alignedSpv(@embedFile("autohint_vert_spv"));
pub const autohint_frag_spv = alignedSpv(@embedFile("autohint_frag_spv"));

/// A grayscale shape family the renderer builds one pipeline for. These map
/// 1:1 to Snail's `ShapeKind`; LCD/subpixel variants are intentionally absent.
pub const Family = enum {
    text,
    colr,
    path_quadratic,
    path_conic,
    path,
    tt_hinted_text,
    autohint,
};

pub const FAMILY_COUNT = @typeInfo(Family).@"enum".fields.len;

/// The shader modules + blend one pipeline for a family uses. Vertex input,
/// descriptor-set layout, and push constants are the same for all.
pub const PipelineRecipe = struct {
    vert_spv: []align(4) const u8,
    frag_spv: []align(4) const u8,
};

/// Mirrors Snail's contract.zig `recipe`, over goop-compiled artifacts.
pub fn recipe(family: Family) PipelineRecipe {
    return switch (family) {
        .text => .{ .vert_spv = text_vert_spv, .frag_spv = text_frag_spv },
        .colr => .{ .vert_spv = text_vert_spv, .frag_spv = colr_frag_spv },
        .path_quadratic => .{ .vert_spv = text_vert_spv, .frag_spv = path_quadratic_frag_spv },
        .path_conic => .{ .vert_spv = text_vert_spv, .frag_spv = path_conic_frag_spv },
        .path => .{ .vert_spv = text_vert_spv, .frag_spv = path_frag_spv },
        .tt_hinted_text => .{ .vert_spv = text_vert_spv, .frag_spv = tt_hinted_text_frag_spv },
        .autohint => .{ .vert_spv = autohint_vert_spv, .frag_spv = autohint_frag_spv },
    };
}

test "every family recipe carries non-empty word-aligned SPIR-V" {
    for (std.enums.values(Family)) |family| {
        const r = recipe(family);
        try std.testing.expect(r.vert_spv.len > 0 and r.vert_spv.len % 4 == 0);
        try std.testing.expect(r.frag_spv.len > 0 and r.frag_spv.len % 4 == 0);
        // SPIR-V magic number, little-endian.
        try std.testing.expectEqual(@as(u32, 0x07230203), std.mem.readInt(u32, r.vert_spv[0..4], .little));
        try std.testing.expectEqual(@as(u32, 0x07230203), std.mem.readInt(u32, r.frag_spv[0..4], .little));
    }
}

test "pipeline family set is grayscale-only" {
    try std.testing.expectEqual(@as(usize, 7), FAMILY_COUNT);
    inline for (@typeInfo(Family).@"enum".fields) |field| {
        try std.testing.expect(std.mem.indexOf(u8, field.name, "subpixel") == null);
    }
}
