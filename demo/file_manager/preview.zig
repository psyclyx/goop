const std = @import("std");
const goop = @import("goop");

const fm = @import("../file_manager_main.zig");
const State = fm.State;
const allocator = fm.allocator;

const BrowserEntry = fm.BrowserEntry;
const allocUtf8LossyOwned = fm.allocUtf8LossyOwned;
const browserEntryKind = fm.browserEntryKind;
const resolveSymlinkTargetAlloc = fm.resolveSymlinkTargetAlloc;
const joinPath = fm.joinPath;
const selectedPathCount = fm.selectedPathCount;
const isPathSelected = fm.isPathSelected;
const selectedEntry = fm.selectedEntry;
const formatSizeText = fm.formatSizeText;
const previewBodyFontSizePx = fm.previewBodyFontSizePx;
const allocUiWrappedOwnedText = fm.allocUiWrappedOwnedText;

pub fn appendPreviewLine(buffer: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    if (buffer.items.len > 0) try buffer.append(allocator, '\n');
    try buffer.appendSlice(allocator, text);
}

pub fn appendPreviewPrintLine(buffer: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(line);
    try appendPreviewLine(buffer, line);
}

pub fn isPreviewTextControlByte(byte: u8) bool {
    return switch (byte) {
        '\t', '\n', '\r', 0x0c, 0x1b => true,
        else => false,
    };
}

pub fn bytesLookLikeTextPreview(bytes: []const u8) bool {
    if (bytes.len == 0) return true;

    for (bytes) |byte| {
        if (byte == 0) return false;
        if (byte < 0x20 and !isPreviewTextControlByte(byte)) return false;
        if (byte == 0x7f) return false;
    }
    return true;
}

pub fn readFilePreviewBytesAlloc(io: std.Io, alloc: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const buf = try alloc.alloc(u8, max_bytes);
    errdefer alloc.free(buf);
    const read = reader.interface.readSliceShort(buf) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
    };
    return alloc.realloc(buf, read);
}

pub fn appendPreviewEntryName(buffer: *std.ArrayListUnmanaged(u8), name: []const u8, is_directory: bool) !void {
    const lossy = try allocUtf8LossyOwned(name);
    defer allocator.free(lossy);

    if (is_directory) {
        const suffixed = try std.fmt.allocPrint(allocator, "{s}/", .{lossy});
        defer allocator.free(suffixed);
        try appendPreviewPrintLine(buffer, "- {s}", .{suffixed});
        return;
    }

    try appendPreviewPrintLine(buffer, "- {s}", .{lossy});
}

pub fn appendDirectoryPreviewSummary(
    state: *State,
    buffer: *std.ArrayListUnmanaged(u8),
    path: []const u8,
    loaded_entries: ?[]const BrowserEntry,
) !void {
    var directory_count: usize = 0;
    var file_count: usize = 0;
    var shown_names: usize = 0;
    const name_limit = 10;

    if (loaded_entries) |entries| {
        for (entries) |entry| {
            if (entry.isDirectory()) {
                directory_count += 1;
            } else {
                file_count += 1;
            }

            if (shown_names >= name_limit) continue;
            try appendPreviewEntryName(buffer, entry.name, entry.isDirectory());
            shown_names += 1;
        }
    } else {
        const io = state.io orelse return;
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false }) catch return;
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |dir_entry| {
            const name = dir_entry.name;
            if (name.len == 0) continue;

            const full_path = try joinPath(allocator, path, name);
            defer allocator.free(full_path);

            const stat = std.Io.Dir.cwd().statFile(io, full_path, .{ .follow_symlinks = false }) catch continue;

            const kind = browserEntryKind(stat.kind);
            var is_directory = kind == .directory;
            if (!is_directory and kind == .symlink) {
                if (resolveSymlinkTargetAlloc(io, allocator, full_path)) |target_path| {
                    defer allocator.free(target_path);
                    const target_stat = std.Io.Dir.cwd().statFile(io, target_path, .{ .follow_symlinks = true }) catch continue;
                    is_directory = browserEntryKind(target_stat.kind) == .directory;
                } else |_| {}
            }

            if (is_directory) {
                directory_count += 1;
            } else {
                file_count += 1;
            }

            if (shown_names >= name_limit) continue;
            try appendPreviewEntryName(buffer, name, is_directory);
            shown_names += 1;
        }
    }

    const listing = try allocator.dupe(u8, buffer.items);
    defer allocator.free(listing);
    buffer.clearRetainingCapacity();

    try appendPreviewPrintLine(buffer, "{d} directories, {d} files", .{ directory_count, file_count });
    if (listing.len > 0) {
        try appendPreviewLine(buffer, "");
        try appendPreviewLine(buffer, "Contents:");
        try appendPreviewLine(buffer, listing);
    }
}

pub const SelectionPreview = struct {
    text: []const u8,
    framed: bool = false,
};

pub fn allocSelectionPreview(state: *State) !SelectionPreview {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);
    var framed = false;

    const selected_count = selectedPathCount(state);
    if (selected_count == 0) {
        try appendDirectoryPreviewSummary(state, &buffer, state.current_dir, state.entries.items);
    } else if (selected_count > 1) {
        var selected_directory_count: usize = 0;
        var selected_file_count: usize = 0;
        var selected_file_bytes: u64 = 0;
        for (state.entries.items) |entry| {
            if (!isPathSelected(state, entry.path)) continue;
            if (entry.isDirectory()) {
                selected_directory_count += 1;
            } else {
                selected_file_count += 1;
                selected_file_bytes += entry.size_bytes;
            }
        }

        try appendPreviewPrintLine(&buffer, "{d} items selected", .{selected_count});
        if (selected_file_count > 0) {
            var size_buf: [24]u8 = undefined;
            const size_text = formatSizeText(size_buf[0..], .file, selected_file_bytes, null);
            try appendPreviewPrintLine(&buffer, "{d} directories, {d} files, {s}", .{
                selected_directory_count,
                selected_file_count,
                size_text,
            });
        } else {
            try appendPreviewPrintLine(&buffer, "{d} directories, {d} files", .{
                selected_directory_count,
                selected_file_count,
            });
        }

        try appendPreviewLine(&buffer, "");
        var shown: usize = 0;
        for (state.selected_paths.items) |selected_path| {
            if (shown >= 8) break;
            try appendPreviewEntryName(&buffer, std.fs.path.basename(selected_path), false);
            shown += 1;
        }
        if (state.selected_paths.items.len > shown) {
            try appendPreviewPrintLine(&buffer, "...and {d} more", .{state.selected_paths.items.len - shown});
        }
    } else if (selectedEntry(state)) |entry| {
        if (entry.kind == .symlink) {
            if (entry.target_path) |target_path| {
                try appendPreviewPrintLine(&buffer, "Link target: {f}", .{std.unicode.fmtUtf8(target_path)});
                try appendPreviewLine(&buffer, "");
            }
        }

        if (entry.canEnter()) {
            const preview_path = entry.navigationPath();
            const loaded_entries = if (std.mem.eql(u8, preview_path, state.current_dir))
                state.entries.items
            else
                null;
            try appendDirectoryPreviewSummary(state, &buffer, preview_path, loaded_entries);
        } else {
            const preview_bytes = if (state.io) |io|
                readFilePreviewBytesAlloc(io, allocator, entry.previewPath(), 8192) catch null
            else
                null;
            if (preview_bytes) |bytes| {
                defer allocator.free(bytes);
                if (bytesLookLikeTextPreview(bytes)) {
                    framed = buffer.items.len == 0;
                    if (bytes.len == 0) {
                        try appendPreviewLine(&buffer, "Empty file.");
                    } else {
                        const lossy = try allocUtf8LossyOwned(bytes);
                        defer allocator.free(lossy);
                        try appendPreviewLine(&buffer, lossy);
                    }
                    if (bytes.len == 8192) {
                        try appendPreviewLine(&buffer, "");
                        try appendPreviewLine(&buffer, "Preview truncated.");
                    }
                } else {
                    var size_buf: [24]u8 = undefined;
                    const size_text = formatSizeText(size_buf[0..], entry.kind, entry.size_bytes, entry.target_kind);
                    try appendPreviewLine(&buffer, entry.typeLabel());
                    if (size_text.len > 0) try appendPreviewPrintLine(&buffer, "Size: {s}", .{size_text});
                    try appendPreviewLine(&buffer, "");
                    try appendPreviewLine(&buffer, "Preview unavailable for non-text files.");
                }
            } else {
                try appendPreviewLine(&buffer, "Unable to read this file.");
            }
        }
    }

    if (buffer.items.len == 0) {
        try appendPreviewLine(&buffer, "Preview unavailable.");
    }

    return .{
        .text = try allocUiWrappedOwnedText(state, try allocator.dupe(u8, buffer.items), previewBodyFontSizePx(state)),
        .framed = framed,
    };
}
