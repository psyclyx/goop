//! Skia rendering backend (GPU/Ganesh target).
//!
//! This module is the sole snail-free renderer alternative: it consumes the
//! backend-neutral `goop_visual` operations and draws them with Skia. Skia is
//! C++, so the actual draw calls live in `skia/shim.cpp` behind a POD-only C
//! ABI; this file is the thin Zig wrapper.
//!
//! Toolchain status: the raster self-test below proves Skia links and draws
//! under `zig build`. The GPU (Ganesh-on-Vulkan) surface and the visual-op
//! replay build on the same shim.

const std = @import("std");

extern fn goop_skia_raster_selftest(width: c_int, height: c_int, out_rgba: [*]u8) c_int;

/// Render a fixed scene into `out_rgba` (`width*height*4` premultiplied RGBA8).
pub fn rasterSelftest(width: u32, height: u32, out_rgba: []u8) !void {
    if (out_rgba.len < width * height * 4) return error.BufferTooSmall;
    const rc = goop_skia_raster_selftest(@intCast(width), @intCast(height), out_rgba.ptr);
    if (rc != 0) return error.SkiaRasterFailed;
}

test "skia raster self-test draws a non-blank scene" {
    const w: u32 = 64;
    const h: u32 = 48;
    var pixels: [w * h * 4]u8 = undefined;
    try rasterSelftest(w, h, &pixels);

    // The scene clears to a dark background and draws a bright rounded rect,
    // so at least one pixel must be non-background and the buffer non-uniform.
    var saw_fill = false;
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        // The fill's blue channel (220) is far brighter than the background (28).
        if (pixels[i + 2] > 150) {
            saw_fill = true;
            break;
        }
    }
    try std.testing.expect(saw_fill);
}
