//! Explicit no-codec demo composition used by minimal/headless builds.

const std = @import("std");
const image = @import("goop_image");

var stateless: u8 = 0;
pub const supports_png = false;

pub const decoder: image.Decoder = .{
    .context = &stateless,
    .decode_fn = decode,
};

fn decode(
    _: *anyopaque,
    _: image.EncodedFormat,
    _: []const u8,
    _: std.mem.Allocator,
) image.DecodeError!image.Pixels {
    return error.UnsupportedFormat;
}
