//! Renderer-neutral decoded-image data and an explicit codec capability.
//!
//! Goop core, components, and renderers depend only on these values. Native
//! composition roots may provide whatever codecs they need; games may decode
//! packed assets with their existing image stack. No format discovery, I/O,
//! cache, or GPU upload is hidden behind this boundary.

const std = @import("std");

pub const EncodedFormat = enum { png, jpeg, webp };

pub const DecodeError = error{ UnsupportedFormat, InvalidData, OutOfMemory };

/// Stable application identity plus a monotonic content revision. The values
/// name CPU image data, never a renderer/GPU object.
pub const ResourceId = extern struct {
    value: u64,
    revision: u32 = 0,
};

/// Borrowed decoded pixels supplied with a visual operation. Renderers may
/// cache by `id`; changing bytes requires changing `id.revision`.
pub const View = struct {
    id: ResourceId,
    width: u32,
    height: u32,
    rgba: []const u8,

    pub fn validate(self: View) DecodeError!void {
        const pixel_count = std.math.mul(usize, self.width, self.height) catch return error.InvalidData;
        const expected = std.math.mul(usize, pixel_count, 4) catch return error.InvalidData;
        if (self.width == 0 or self.height == 0 or self.rgba.len != expected) return error.InvalidData;
    }
};

/// Owned, tightly packed straight-alpha sRGBA8 pixels, top row first.
pub const Pixels = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    rgba: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        rgba: []const u8,
    ) DecodeError!Pixels {
        const pixel_count = std.math.mul(usize, width, height) catch return error.InvalidData;
        const expected = std.math.mul(usize, pixel_count, 4) catch return error.InvalidData;
        if (width == 0 or height == 0 or rgba.len != expected) return error.InvalidData;
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .rgba = allocator.dupe(u8, rgba) catch return error.OutOfMemory,
        };
    }

    pub fn deinit(self: *Pixels) void {
        self.allocator.free(self.rgba);
        self.* = undefined;
    }

    pub fn view(self: *const Pixels, id: ResourceId) View {
        return .{ .id = id, .width = self.width, .height = self.height, .rgba = self.rgba };
    }

    /// Explicitly reduce an owned image to fit a pixel box. This is nearest
    /// sampling: callers that need a particular resampler remain free to use
    /// one before crossing the visual seam.
    pub fn resizeNearestToFit(self: *Pixels, max_width: u32, max_height: u32) DecodeError!void {
        if (max_width == 0 or max_height == 0) return error.InvalidData;
        if (self.width <= max_width and self.height <= max_height) return;

        const width_limited = @as(u64, self.width) * max_height >=
            @as(u64, self.height) * max_width;
        const target_width: u32 = if (width_limited)
            max_width
        else
            @max(1, @as(u32, @intCast(@as(u64, self.width) * max_height / self.height)));
        const target_height: u32 = if (width_limited)
            @max(1, @as(u32, @intCast(@as(u64, self.height) * max_width / self.width)))
        else
            max_height;
        const pixel_count = std.math.mul(usize, target_width, target_height) catch return error.InvalidData;
        const byte_count = std.math.mul(usize, pixel_count, 4) catch return error.InvalidData;
        const resized = self.allocator.alloc(u8, byte_count) catch return error.OutOfMemory;
        errdefer self.allocator.free(resized);

        for (0..target_height) |y| {
            const source_y: usize = @intCast(@as(u64, y) * self.height / target_height);
            for (0..target_width) |x| {
                const source_x: usize = @intCast(@as(u64, x) * self.width / target_width);
                const source_offset = (source_y * self.width + source_x) * 4;
                const target_offset = (y * target_width + x) * 4;
                @memcpy(resized[target_offset..][0..4], self.rgba[source_offset..][0..4]);
            }
        }

        self.allocator.free(self.rgba);
        self.width = target_width;
        self.height = target_height;
        self.rgba = resized;
    }
};

/// Caller-supplied encoded-image decoder. The capability is borrowed and may
/// be stateless. Every decode and allocation is visible at the call site.
pub const Decoder = struct {
    context: *anyopaque,
    decode_fn: *const fn (
        context: *anyopaque,
        format: EncodedFormat,
        bytes: []const u8,
        allocator: std.mem.Allocator,
    ) DecodeError!Pixels,

    pub fn decode(
        self: Decoder,
        format: EncodedFormat,
        bytes: []const u8,
        allocator: std.mem.Allocator,
    ) DecodeError!Pixels {
        return self.decode_fn(self.context, format, bytes, allocator);
    }
};

/// Content-based format detection for preview dispatch. Extensions are only
/// hints to file browsers; codecs are selected from the bytes themselves.
pub fn detectFormat(bytes: []const u8) ?EncodedFormat {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return .png;
    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "\xff\xd8\xff")) return .jpeg;
    if (bytes.len >= 12 and
        std.mem.eql(u8, bytes[0..4], "RIFF") and
        std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
    return null;
}

test "image formats are detected from signatures" {
    try std.testing.expectEqual(EncodedFormat.png, detectFormat("\x89PNG\r\n\x1a\nrest").?);
    try std.testing.expectEqual(EncodedFormat.jpeg, detectFormat("\xff\xd8\xffrest").?);
    try std.testing.expectEqual(EncodedFormat.webp, detectFormat("RIFFxxxxWEBPrest").?);
    try std.testing.expect(detectFormat("not an image") == null);
}

test "decoded pixels require exact rgba8 storage" {
    try std.testing.expectError(
        error.InvalidData,
        Pixels.init(std.testing.allocator, 2, 2, &[_]u8{0} ** 15),
    );
    var pixels = try Pixels.init(std.testing.allocator, 2, 2, &[_]u8{0} ** 16);
    defer pixels.deinit();
    try std.testing.expectEqual(@as(usize, 16), pixels.rgba.len);
}

test "owned pixels can be explicitly constrained without changing aspect ratio" {
    var pixels = try Pixels.init(std.testing.allocator, 4, 2, &.{
        1, 0, 0, 255, 2, 0, 0, 255, 3, 0, 0, 255, 4, 0, 0, 255,
        5, 0, 0, 255, 6, 0, 0, 255, 7, 0, 0, 255, 8, 0, 0, 255,
    });
    defer pixels.deinit();
    try pixels.resizeNearestToFit(2, 2);
    try std.testing.expectEqual(@as(u32, 2), pixels.width);
    try std.testing.expectEqual(@as(u32, 1), pixels.height);
    try std.testing.expectEqualSlices(u8, &.{
        1, 0, 0, 255,
        3, 0, 0, 255,
    }, pixels.rgba);
}
