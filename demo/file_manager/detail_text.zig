//! Renderer-neutral text wrapping used by the detail projection.

const std = @import("std");
const goop = @import("goop");

const allocator = std.heap.smp_allocator;

pub fn measureWidth(text: []const u8, font_size: f32, text_ctx: *const goop.TextMeasureCtx) f32 {
    return goop.layout.measureTextDimensions(text, font_size, text_ctx).width;
}

fn isBoundary(codepoint: u21) bool {
    return switch (codepoint) {
        ' ', '\t', '/', '\\', '-', '_', '.' => true,
        else => false,
    };
}

fn flushLine(out: *std.ArrayListUnmanaged(u8), line: *std.ArrayListUnmanaged(u8)) !void {
    if (line.items.len == 0) return;
    if (out.items.len > 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, line.items);
    line.clearRetainingCapacity();
}

fn appendForcedToken(
    out: *std.ArrayListUnmanaged(u8),
    line: *std.ArrayListUnmanaged(u8),
    token: []const u8,
    max_width: f32,
    font_size: f32,
    text_ctx: *const goop.TextMeasureCtx,
) !void {
    var view = std.unicode.Utf8View.init(token) catch unreachable;
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const previous_len = line.items.len;
        try line.appendSlice(allocator, slice);
        if (previous_len == 0 or measureWidth(line.items, font_size, text_ctx) <= max_width) continue;

        line.items.len = previous_len;
        try flushLine(out, line);
        try line.appendSlice(allocator, slice);
    }
}

fn appendToken(
    out: *std.ArrayListUnmanaged(u8),
    line: *std.ArrayListUnmanaged(u8),
    token: []const u8,
    max_width: f32,
    font_size: f32,
    text_ctx: *const goop.TextMeasureCtx,
) !void {
    if (token.len == 0) return;

    const previous_len = line.items.len;
    try line.appendSlice(allocator, token);
    if (measureWidth(line.items, font_size, text_ctx) <= max_width) return;

    line.items.len = previous_len;
    if (previous_len > 0) try flushLine(out, line);
    try appendForcedToken(out, line, token, max_width, font_size, text_ctx);
}

/// Takes ownership of `text`. Returns it unchanged when no wrap is needed;
/// otherwise frees it and returns a newly-owned wrapped allocation.
pub fn wrapOwned(
    text: []u8,
    font_size: f32,
    max_width: f32,
    text_ctx: ?*const goop.TextMeasureCtx,
) ![]u8 {
    errdefer allocator.free(text);
    const measure = text_ctx orelse return text;
    if (std.mem.indexOfScalar(u8, text, '\n') == null and measureWidth(text, font_size, measure) <= max_width) {
        return text;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(allocator);
    var token: std.ArrayListUnmanaged(u8) = .empty;
    defer token.deinit(allocator);

    var view = std.unicode.Utf8View.init(text) catch unreachable;
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const codepoint = std.unicode.utf8Decode(slice) catch unreachable;
        if (codepoint == '\n') {
            try appendToken(&out, &line, token.items, max_width, font_size, measure);
            token.clearRetainingCapacity();
            try flushLine(&out, &line);
            continue;
        }

        try token.appendSlice(allocator, slice);
        if (isBoundary(codepoint)) {
            try appendToken(&out, &line, token.items, max_width, font_size, measure);
            token.clearRetainingCapacity();
        }
    }

    try appendToken(&out, &line, token.items, max_width, font_size, measure);
    try flushLine(&out, &line);

    if (out.items.len == 0 or std.mem.eql(u8, out.items, text)) return text;
    const wrapped = try allocator.dupe(u8, out.items);
    allocator.free(text);
    return wrapped;
}
