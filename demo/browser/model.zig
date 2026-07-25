//! File browser application model.
//!
//! No component, driver, platform, or graphics imports are allowed here.

const std = @import("std");

pub const Entry = struct {
    name: []u8,
    path: []u8,
    kind: Kind,
    size_bytes: u64,
    modified_unix: i64,

    pub const Kind = enum {
        directory,
        file,
        symlink,
        other,
    };

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    current_dir: []u8,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    history: std.ArrayListUnmanaged([]u8) = .empty,
    history_index: usize = 0,
    selected_index: ?usize = null,
    scroll_offset: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        start_directory: []const u8,
    ) !Model {
        var self = Model{
            .allocator = allocator,
            .io = io,
            .current_dir = try normalizeDirectory(allocator, start_directory),
        };
        errdefer allocator.free(self.current_dir);
        try self.history.append(allocator, try allocator.dupe(u8, self.current_dir));
        errdefer {
            for (self.history.items) |path| allocator.free(path);
            self.history.deinit(allocator);
        }
        try self.refresh();
        return self;
    }

    pub fn deinit(self: *Model) void {
        self.clearEntries();
        self.entries.deinit(self.allocator);
        for (self.history.items) |path| self.allocator.free(path);
        self.history.deinit(self.allocator);
        self.allocator.free(self.current_dir);
        self.* = undefined;
    }

    pub fn refresh(self: *Model) !void {
        self.clearEntries();
        errdefer self.clearEntries();

        var directory = std.Io.Dir.cwd().openDir(self.io, self.current_dir, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch return error.OpenDirectoryFailed;
        defer directory.close(self.io);

        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |directory_entry| {
            if (directory_entry.name.len == 0) continue;
            const path = try joinPath(self.allocator, self.current_dir, directory_entry.name);
            errdefer self.allocator.free(path);
            const stat = std.Io.Dir.cwd().statFile(self.io, path, .{
                .follow_symlinks = false,
            }) catch {
                self.allocator.free(path);
                continue;
            };
            const name = try self.allocator.dupe(u8, directory_entry.name);
            errdefer self.allocator.free(name);
            try self.entries.append(self.allocator, .{
                .name = name,
                .path = path,
                .kind = entryKind(stat.kind),
                .size_bytes = stat.size,
                .modified_unix = timestampSeconds(stat.mtime),
            });
        }
        std.mem.sort(Entry, self.entries.items, {}, lessThan);
        if (self.selected_index) |selected| {
            if (selected >= self.entries.items.len) self.selected_index = null;
        }
        self.scroll_offset = @min(self.scroll_offset, self.entries.items.len);
    }

    pub fn navigate(self: *Model, path: []const u8, push_history: bool) !void {
        const normalized = try normalizeDirectory(self.allocator, path);
        errdefer self.allocator.free(normalized);
        var probe = std.Io.Dir.cwd().openDir(self.io, normalized, .{}) catch
            return error.NotDirectory;
        probe.close(self.io);

        if (push_history) {
            while (self.history.items.len > self.history_index + 1) {
                self.allocator.free(self.history.pop().?);
            }
            try self.history.append(self.allocator, try self.allocator.dupe(u8, normalized));
            self.history_index = self.history.items.len - 1;
        }
        self.allocator.free(self.current_dir);
        self.current_dir = normalized;
        self.selected_index = null;
        self.scroll_offset = 0;
        try self.refresh();
    }

    pub fn back(self: *Model) !bool {
        if (self.history_index == 0) return false;
        self.history_index -= 1;
        try self.navigate(self.history.items[self.history_index], false);
        return true;
    }

    pub fn forward(self: *Model) !bool {
        if (self.history_index + 1 >= self.history.items.len) return false;
        self.history_index += 1;
        try self.navigate(self.history.items[self.history_index], false);
        return true;
    }

    pub fn up(self: *Model) !bool {
        const parent = try parentPath(self.allocator, self.current_dir) orelse return false;
        defer self.allocator.free(parent);
        try self.navigate(parent, true);
        return true;
    }

    pub fn activate(self: *Model, index: usize) !void {
        if (index >= self.entries.items.len) return;
        const selected = &self.entries.items[index];
        self.selected_index = index;
        if (selected.kind == .directory) try self.navigate(selected.path, true);
    }

    pub fn scrollRows(self: *Model, rows: i32, visible_rows: usize) void {
        const maximum = self.entries.items.len -| visible_rows;
        if (rows < 0) {
            self.scroll_offset -|= @intCast(-rows);
        } else {
            self.scroll_offset = @min(maximum, self.scroll_offset + @as(usize, @intCast(rows)));
        }
    }

    fn clearEntries(self: *Model) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.clearRetainingCapacity();
    }
};

pub fn currentDirectory(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    return std.process.currentPathAlloc(io, allocator);
}

fn normalizeDirectory(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return allocator.dupe(u8, "/");
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return allocator.dupe(u8, path[0..end]);
}

fn joinPath(allocator: std.mem.Allocator, directory: []const u8, name: []const u8) ![]u8 {
    if (std.mem.eql(u8, directory, "/")) {
        return std.fmt.allocPrint(allocator, "/{s}", .{name});
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, name });
}

fn parentPath(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return null;
    const separator = std.mem.lastIndexOfScalar(u8, path, '/') orelse
        return @as(?[]u8, try allocator.dupe(u8, "/"));
    if (separator == 0) return @as(?[]u8, try allocator.dupe(u8, "/"));
    return @as(?[]u8, try allocator.dupe(u8, path[0..separator]));
}

fn entryKind(kind: std.Io.File.Kind) Entry.Kind {
    return switch (kind) {
        .directory => .directory,
        .file => .file,
        .sym_link => .symlink,
        else => .other,
    };
}

fn timestampSeconds(timestamp: std.Io.Timestamp) i64 {
    const seconds = @divFloor(timestamp.nanoseconds, std.time.ns_per_s);
    return std.math.cast(i64, seconds) orelse if (seconds < 0)
        std.math.minInt(i64)
    else
        std.math.maxInt(i64);
}

fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
    if (lhs.kind == .directory and rhs.kind != .directory) return true;
    if (lhs.kind != .directory and rhs.kind == .directory) return false;
    return std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
}

test "path helpers preserve root boundaries" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeDirectory(allocator, "/tmp///");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("/tmp", normalized);

    const parent = (try parentPath(allocator, "/tmp/a")).?;
    defer allocator.free(parent);
    try std.testing.expectEqualStrings("/tmp", parent);
}
