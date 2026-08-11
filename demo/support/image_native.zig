//! Demo-native image decoder. Format-specific libraries are composition-root
//! dependencies, not dependencies of Goop core, components, Snail integration,
//! or game renderers.

const std = @import("std");
const builtin = @import("builtin");
const image = @import("goop_image");

const c = @cImport({
    @cInclude("spng.h");
    @cInclude("turbojpeg.h");
    @cInclude("webp/decode.h");
});

var stateless: u8 = 0;
pub const supports_png = true;

pub const decoder: image.Decoder = .{
    .context = &stateless,
    .decode_fn = decode,
};

fn decode(
    _: *anyopaque,
    format: image.EncodedFormat,
    bytes: []const u8,
    allocator: std.mem.Allocator,
) image.DecodeError!image.Pixels {
    var pixels = switch (format) {
        .png => try decodePng(bytes, allocator),
        .jpeg => try decodeJpeg(bytes, allocator),
        .webp => try decodeWebp(bytes, allocator),
    };
    errdefer pixels.deinit();
    try pixels.resizeNearestToFit(max_preview_width, max_preview_height);
    return pixels;
}

fn decodePng(bytes: []const u8, allocator: std.mem.Allocator) image.DecodeError!image.Pixels {
    const context = c.spng_ctx_new(0) orelse return error.InvalidData;
    defer c.spng_ctx_free(context);
    const set_result = c.spng_set_png_buffer(context, bytes.ptr, bytes.len);
    if (set_result != c.SPNG_OK) return spngInvalid("set buffer", set_result);

    var header: c.spng_ihdr = undefined;
    const header_result = c.spng_get_ihdr(context, &header);
    if (header_result != c.SPNG_OK) return spngInvalid("read header", header_result);

    var output_len: usize = 0;
    const size_result = c.spng_decoded_image_size(context, c.SPNG_FMT_RGBA8, &output_len);
    if (size_result != c.SPNG_OK) return spngInvalid("size image", size_result);
    if (!validOutput(header.width, header.height, output_len)) return error.InvalidData;

    var pixels = try allocPixels(allocator, header.width, header.height);
    errdefer pixels.deinit();
    const decode_result = c.spng_decode_image(
        context,
        pixels.rgba.ptr,
        pixels.rgba.len,
        c.SPNG_FMT_RGBA8,
        c.SPNG_DECODE_TRNS,
    );
    if (decode_result != c.SPNG_OK) return spngInvalid("decode image", decode_result);
    return pixels;
}

fn spngInvalid(stage: []const u8, code: c_int) image.DecodeError {
    if (builtin.is_test) std.debug.print("PNG {s}: {s} ({d})\n", .{
        stage,
        std.mem.sliceTo(c.spng_strerror(code), 0),
        code,
    });
    return error.InvalidData;
}

fn decodeJpeg(bytes: []const u8, allocator: std.mem.Allocator) image.DecodeError!image.Pixels {
    const context = c.tjInitDecompress() orelse return error.InvalidData;
    defer _ = c.tjDestroy(context);
    const encoded_len = std.math.cast(c_ulong, bytes.len) orelse return error.InvalidData;

    var width: c_int = 0;
    var height: c_int = 0;
    var subsampling: c_int = 0;
    var colorspace: c_int = 0;
    if (c.tjDecompressHeader3(
        context,
        bytes.ptr,
        encoded_len,
        &width,
        &height,
        &subsampling,
        &colorspace,
    ) != 0 or width <= 0 or height <= 0) return turboJpegInvalid(context, "read header");

    const output_width: u32 = @intCast(width);
    const output_height: u32 = @intCast(height);
    var pixels = try allocPixels(allocator, output_width, output_height);
    errdefer pixels.deinit();
    if (c.tjDecompress2(
        context,
        bytes.ptr,
        encoded_len,
        pixels.rgba.ptr,
        width,
        0,
        height,
        c.TJPF_RGBA,
        0,
    ) != 0) return turboJpegInvalid(context, "decode image");
    return pixels;
}

fn turboJpegInvalid(context: c.tjhandle, stage: []const u8) image.DecodeError {
    if (builtin.is_test) std.debug.print("JPEG {s}: {s}\n", .{
        stage,
        std.mem.sliceTo(c.tjGetErrorStr2(context), 0),
    });
    return error.InvalidData;
}

fn decodeWebp(bytes: []const u8, allocator: std.mem.Allocator) image.DecodeError!image.Pixels {
    var width: c_int = 0;
    var height: c_int = 0;
    if (c.WebPGetInfo(bytes.ptr, bytes.len, &width, &height) == 0 or
        width <= 0 or height <= 0)
    {
        return error.InvalidData;
    }

    const output_width: u32 = @intCast(width);
    const output_height: u32 = @intCast(height);
    var pixels = try allocPixels(allocator, output_width, output_height);
    errdefer pixels.deinit();
    const stride = std.math.mul(c_int, width, 4) catch return error.InvalidData;
    if (c.WebPDecodeRGBAInto(
        bytes.ptr,
        bytes.len,
        pixels.rgba.ptr,
        pixels.rgba.len,
        stride,
    ) == null) return error.InvalidData;
    return pixels;
}

fn allocPixels(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
) image.DecodeError!image.Pixels {
    const pixel_count = std.math.mul(usize, width, height) catch return error.InvalidData;
    const output_len = std.math.mul(usize, pixel_count, 4) catch return error.InvalidData;
    if (!validOutput(width, height, output_len)) return error.InvalidData;
    return .{
        .allocator = allocator,
        .width = width,
        .height = height,
        .rgba = allocator.alloc(u8, output_len) catch return error.OutOfMemory,
    };
}

fn validOutput(width: u32, height: u32, output_len: usize) bool {
    if (width == 0 or height == 0 or output_len == 0 or output_len > max_decoded_bytes) return false;
    const pixel_count = std.math.mul(usize, width, height) catch return false;
    const expected = std.math.mul(usize, pixel_count, 4) catch return false;
    return output_len == expected;
}

const max_decoded_bytes: usize = 256 * 1024 * 1024;
const max_preview_width: u32 = 2048;
const max_preview_height: u32 = 2048;

fn expectDecode(format: image.EncodedFormat, encoded: []const u8) !void {
    const base64 = std.base64.standard.decoderWithIgnore("\r\n ");
    const buffer = try std.testing.allocator.alloc(u8, base64.calcSizeUpperBound(encoded.len));
    defer std.testing.allocator.free(buffer);
    const decoded_len = try base64.decode(buffer, encoded);
    var pixels = decode(
        &stateless,
        format,
        buffer[0..decoded_len],
        std.testing.allocator,
    ) catch |err| {
        std.debug.print("{s} fixture decode failed: {s}\n", .{ @tagName(format), @errorName(err) });
        return err;
    };
    defer pixels.deinit();
    try std.testing.expectEqual(@as(u32, 1), pixels.width);
    try std.testing.expectEqual(@as(u32, 1), pixels.height);
    try std.testing.expectEqual(@as(usize, 4), pixels.rgba.len);
}

test "native composition decodes PNG into the common pixel contract" {
    try expectDecode(
        .png,
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEX/AAAZ4gk3AAAACklEQVQI12NgAAAAAgAB4iG8MwAAAABJRU5ErkJggg==",
    );
}

test "native composition decodes JPEG into the common pixel contract" {
    try expectDecode(.jpeg,
        \\/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJ
        \\DRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB
        \\AQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAABAAEDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABQQAQ
        \\AAAAAAAAAAAAAAAAAAAAD/xAAVAQEBAAAAAAAAAAAAAAAAAAAHCf/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhED
        \\EQA/ADoDFU3/2Q==
    );
}

test "native composition decodes WebP into the common pixel contract" {
    try expectDecode(.webp, "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA");
}
