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
pub const text_subpixel_frag_spv = alignedSpv(@embedFile("text_subpixel_frag_spv"));
pub const tt_hinted_text_subpixel_frag_spv = alignedSpv(@embedFile("tt_hinted_text_subpixel_frag_spv"));
pub const autohint_subpixel_frag_spv = alignedSpv(@embedFile("autohint_subpixel_frag_spv"));

/// A shape family the renderer builds one pipeline for. The `*subpixel`
/// families are the LCD dual-source variants of the three text kinds
/// (regular, TT-hinted, autohint); the rest map 1:1 to snail's `ShapeKind`.
/// Mirrors snail 0.18's dev/demo render/vulkan/contract.zig `Family`.
pub const Family = enum {
    text,
    colr,
    path_quadratic,
    path_conic,
    path,
    tt_hinted_text,
    autohint,
    subpixel,
    tt_hinted_subpixel,
    autohint_subpixel,
};

pub const FAMILY_COUNT = @typeInfo(Family).@"enum".fields.len;

/// Per-family blend. Every family blends premultiplied-over except subpixel,
/// which needs dual-source (and the `dualSrcBlend` device feature).
pub const Blend = enum { premultiplied, dual_source };

/// The shader modules + blend one pipeline for a family uses. Vertex input,
/// descriptor-set layout, and push constants are the same for all.
pub const PipelineRecipe = struct {
    vert_spv: []align(4) const u8,
    frag_spv: []align(4) const u8,
    blend: Blend,
    /// Subpixel needs the `dualSrcBlend` device feature; gate on it and fall
    /// back to `.text` (grayscale) when unavailable.
    requires_dual_src: bool = false,
};

/// Mirrors snail 0.18's contract.zig `recipe`, over goop-compiled artifacts.
pub fn recipe(family: Family) PipelineRecipe {
    return switch (family) {
        .text => .{ .vert_spv = text_vert_spv, .frag_spv = text_frag_spv, .blend = .premultiplied },
        .colr => .{ .vert_spv = text_vert_spv, .frag_spv = colr_frag_spv, .blend = .premultiplied },
        .path_quadratic => .{ .vert_spv = text_vert_spv, .frag_spv = path_quadratic_frag_spv, .blend = .premultiplied },
        .path_conic => .{ .vert_spv = text_vert_spv, .frag_spv = path_conic_frag_spv, .blend = .premultiplied },
        .path => .{ .vert_spv = text_vert_spv, .frag_spv = path_frag_spv, .blend = .premultiplied },
        .tt_hinted_text => .{ .vert_spv = text_vert_spv, .frag_spv = tt_hinted_text_frag_spv, .blend = .premultiplied },
        .autohint => .{ .vert_spv = autohint_vert_spv, .frag_spv = autohint_frag_spv, .blend = .premultiplied },
        .subpixel => .{ .vert_spv = text_vert_spv, .frag_spv = text_subpixel_frag_spv, .blend = .dual_source, .requires_dual_src = true },
        .tt_hinted_subpixel => .{ .vert_spv = text_vert_spv, .frag_spv = tt_hinted_text_subpixel_frag_spv, .blend = .dual_source, .requires_dual_src = true },
        .autohint_subpixel => .{ .vert_spv = autohint_vert_spv, .frag_spv = autohint_subpixel_frag_spv, .blend = .dual_source, .requires_dual_src = true },
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

test "exactly the subpixel families require dual-source blending" {
    for (std.enums.values(Family)) |family| {
        const r = recipe(family);
        const is_subpixel = switch (family) {
            .subpixel, .tt_hinted_subpixel, .autohint_subpixel => true,
            else => false,
        };
        try std.testing.expectEqual(is_subpixel, r.requires_dual_src);
        try std.testing.expectEqual(is_subpixel, r.blend == .dual_source);
    }
}
