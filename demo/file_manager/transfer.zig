//! Backend-neutral clipboard and file-transfer payload ownership.

const std = @import("std");
const goop = @import("goop");
const state = @import("state.zig");
const types = @import("types.zig");

const default_allocator = std.heap.smp_allocator;

pub fn clipboard(transfer: *state.Transfer) goop.Clipboard {
    return .{
        .ptr = transfer,
        .getTextFn = @ptrCast(&clipboardGetText),
        .setTextFn = @ptrCast(&clipboardSetText),
    };
}

fn clipboardGetText(pointer: *anyopaque) ?[]const u8 {
    const transfer: *state.Transfer = @ptrCast(@alignCast(pointer));
    return if (transfer.clipboard_buf.items.len == 0) null else transfer.clipboard_buf.items;
}

fn clipboardSetText(pointer: *anyopaque, text: []const u8) void {
    const transfer: *state.Transfer = @ptrCast(@alignCast(pointer));
    setClipboardText(transfer, text) catch {};
}

pub fn setClipboardText(transfer: *state.Transfer, text: []const u8) !void {
    clearFilePayload(transfer);
    transfer.clipboard_buf.clearRetainingCapacity();
    try transfer.clipboard_buf.appendSlice(default_allocator, text);
}

pub fn clearFilePayload(transfer: *state.Transfer) void {
    transfer.clipboard_uri_list_buf.clearRetainingCapacity();
    transfer.clipboard_gnome_files_buf.clearRetainingCapacity();
    transfer.clipboard_file_action = null;
}

pub fn setFileSelection(
    transfer: *state.Transfer,
    paths: []const []const u8,
    action: types.FileClipboardAction,
) !void {
    if (paths.len == 0) return;
    transfer.clipboard_buf.clearRetainingCapacity();
    transfer.clipboard_uri_list_buf.clearRetainingCapacity();
    transfer.clipboard_gnome_files_buf.clearRetainingCapacity();
    transfer.clipboard_file_action = action;

    try transfer.clipboard_gnome_files_buf.appendSlice(
        default_allocator,
        if (action == .cut) "cut\n" else "copy\n",
    );
    for (paths) |path| {
        try appendFileUri(default_allocator, &transfer.clipboard_uri_list_buf, path, "\r\n");
        try appendFileUri(default_allocator, &transfer.clipboard_gnome_files_buf, path, "\n");
        try transfer.clipboard_buf.appendSlice(default_allocator, path);
        try transfer.clipboard_buf.append(default_allocator, '\n');
    }
}

pub fn collectFilePaths(
    transfer: *const state.Transfer,
    paths: *std.ArrayListUnmanaged([]u8),
) !?types.FileClipboardAction {
    for (paths.items) |path| default_allocator.free(path);
    paths.clearRetainingCapacity();

    const action = transfer.clipboard_file_action orelse return null;
    var lines = std.mem.splitScalar(u8, transfer.clipboard_buf.items, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trimEnd(u8, line, "\r");
        if (path.len == 0) continue;
        const owned = try default_allocator.dupe(u8, path);
        errdefer default_allocator.free(owned);
        try paths.append(default_allocator, owned);
    }
    return if (paths.items.len > 0) action else null;
}

pub fn deinit(transfer: *state.Transfer) void {
    transfer.clipboard_buf.deinit(default_allocator);
    transfer.clipboard_uri_list_buf.deinit(default_allocator);
    transfer.clipboard_gnome_files_buf.deinit(default_allocator);
    transfer.drag_uri_list_buf.deinit(default_allocator);
    transfer.drag_plain_buf.deinit(default_allocator);
    transfer.drag_gnome_files_buf.deinit(default_allocator);
}

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
