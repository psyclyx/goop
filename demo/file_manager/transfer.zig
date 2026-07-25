//! Backend-neutral file-transfer payload encoding.

const std = @import("std");

pub fn appendFileUri(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayListUnmanaged(u8),
    path: []const u8,
    line_end: []const u8,
) !void {
    try buffer.appendSlice(allocator, "file://");
    for (path) |byte| {
        if (uriPathByteCanPass(byte)) {
            try buffer.append(allocator, byte);
        } else {
            const hex = "0123456789ABCDEF";
            try buffer.append(allocator, '%');
            try buffer.append(allocator, hex[byte >> 4]);
            try buffer.append(allocator, hex[byte & 0x0f]);
        }
    }
    try buffer.appendSlice(allocator, line_end);
}

pub fn uriPathByteCanPass(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '/', '-', '.', '_', '~' => true,
        else => false,
    };
}

pub fn appendClipboardPathFromFileUri(
    allocator: std.mem.Allocator,
    paths: *std.ArrayListUnmanaged([]u8),
    line: []const u8,
) !void {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return;
    if (!std.mem.startsWith(u8, trimmed, "file://")) return;

    var uri_path = trimmed["file://".len..];
    if (std.mem.startsWith(u8, uri_path, "localhost/")) {
        uri_path = uri_path["localhost".len..];
    }
    if (uri_path.len == 0 or uri_path[0] != '/') return;

    const decoded = try percentDecodeAlloc(allocator, uri_path);
    errdefer allocator.free(decoded);
    try paths.append(allocator, decoded);
}

pub fn percentDecodeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = try std.ArrayListUnmanaged(u8).initCapacity(allocator, text.len);
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '%' and index + 2 < text.len) {
            if (hexValue(text[index + 1])) |hi| {
                if (hexValue(text[index + 2])) |lo| {
                    try out.append(allocator, (hi << 4) | lo);
                    index += 3;
                    continue;
                }
            }
        }
        try out.append(allocator, text[index]);
        index += 1;
    }
    return out.toOwnedSlice(allocator);
}

pub fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}
