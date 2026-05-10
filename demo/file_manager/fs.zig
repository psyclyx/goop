const std = @import("std");
const goop = @import("goop");

const fm = @import("../file_manager_main.zig");
const State = fm.State;
const allocator = fm.allocator;
const BrowserEntry = fm.BrowserEntry;
const BrowserEntryKind = fm.BrowserEntryKind;
const BrowserPlace = fm.BrowserPlace;
const FolderTreeChild = fm.FolderTreeChild;
const BrowserSortColumn = fm.BrowserSortColumn;
const BrowserSortDirection = fm.BrowserSortDirection;

// Callbacks back into the main module:
const stateIo = fm.stateIo;
const clearPlaces = fm.clearPlaces;
const clearEntries = fm.clearEntries;
const clearSelectedPaths = fm.clearSelectedPaths;
const freeOptionalOwnedSlice = fm.freeOptionalOwnedSlice;
const syncSelectionAnchor = fm.syncSelectionAnchor;
const syncPrimarySelection = fm.syncPrimarySelection;
const syncAddressInputToCurrentDir = fm.syncAddressInputToCurrentDir;
const appendSelectedPathIfMissing = fm.appendSelectedPathIfMissing;
const selectedEntryExists = fm.selectedEntryExists;
const preserveFolderTreeContextForNavigation = fm.preserveFolderTreeContextForNavigation;
const isPathSelected = fm.isPathSelected;
const clearTrackedPaths = fm.clearTrackedPaths;
const selectedEntry = fm.selectedEntry;
const allocAssetUiString = fm.allocAssetUiString;
const allocUiString = fm.allocUiString;

pub fn homePath(state: *const State) ?[]const u8 {
    const env = state.env orelse return null;
    return env.get("HOME");
}

pub fn currentWorkingDirectoryAlloc(alloc: std.mem.Allocator, io: std.Io) ![]u8 {
    return std.process.currentPathAlloc(io, alloc);
}

pub fn normalizeDirectoryPath(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return alloc.dupe(u8, "/");
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return alloc.dupe(u8, path[0..end]);
}

pub fn ensureDirectoryOpenable(io: std.Io, path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return error.NotDir;
    defer dir.close(io);
}

pub fn joinPath(alloc: std.mem.Allocator, dir_path: []const u8, name: []const u8) ![]u8 {
    if (std.mem.eql(u8, dir_path, "/")) return std.fmt.allocPrint(alloc, "/{s}", .{name});
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, name });
}

pub fn parentPathAlloc(alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return null;

    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    const trimmed = path[0..end];
    const slash_index = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse {
        return try alloc.dupe(u8, "/");
    };
    if (slash_index == 0) return try alloc.dupe(u8, "/");
    return try alloc.dupe(u8, trimmed[0..slash_index]);
}

pub fn pathHasDirectoryPrefix(path: []const u8, prefix: []const u8) bool {
    if (std.mem.eql(u8, prefix, "/")) return path.len > 0 and path[0] == '/';
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

pub fn folderTreeChildLessThan(_: void, a: FolderTreeChild, b: FolderTreeChild) bool {
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

pub fn clearFolderTreeChildren(children: *std.ArrayListUnmanaged(FolderTreeChild)) void {
    for (children.items) |child| {
        allocator.free(child.name);
        allocator.free(child.path);
    }
    children.clearRetainingCapacity();
}

pub fn collectFolderTreeChildren(io: std.Io, dir_path: []const u8, children: *std.ArrayListUnmanaged(FolderTreeChild)) !void {
    clearFolderTreeChildren(children);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true, .follow_symlinks = false }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |dir_entry| {
        const name = dir_entry.name;
        if (name.len == 0) continue;

        const full_path = joinPath(allocator, dir_path, name) catch continue;

        const stat = std.Io.Dir.cwd().statFile(io, full_path, .{ .follow_symlinks = true }) catch {
            allocator.free(full_path);
            continue;
        };
        if (browserEntryKind(stat.kind) != .directory) {
            allocator.free(full_path);
            continue;
        }

        const entry_name = allocator.dupe(u8, name) catch {
            allocator.free(full_path);
            continue;
        };

        children.append(allocator, .{
            .name = entry_name,
            .path = full_path,
        }) catch |err| {
            allocator.free(entry_name);
            allocator.free(full_path);
            return err;
        };
    }

    std.mem.sort(FolderTreeChild, children.items, {}, folderTreeChildLessThan);
}

pub fn folderTreeDirectoryHasChildren(io: std.Io, dir_path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true, .follow_symlinks = false }) catch return false;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch return false) |dir_entry| {
        const name = dir_entry.name;
        if (name.len == 0) continue;

        const full_path = joinPath(allocator, dir_path, name) catch return false;
        defer allocator.free(full_path);

        const stat = std.Io.Dir.cwd().statFile(io, full_path, .{ .follow_symlinks = true }) catch continue;
        if (browserEntryKind(stat.kind) == .directory) return true;
    }
    return false;
}

pub fn resolveSymlinkTargetAlloc(io: std.Io, alloc: std.mem.Allocator, link_path: []const u8) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const read_len = try std.Io.Dir.readLinkAbsolute(io, link_path, &buf);
    const target = buf[0..read_len];
    if (std.fs.path.isAbsolute(target)) return alloc.dupe(u8, target);

    const parent = std.fs.path.dirname(link_path) orelse "/";
    return std.fs.path.resolve(alloc, &.{ parent, target });
}

pub fn fileTypeLabel(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    if (std.ascii.eqlIgnoreCase(ext, ".zig")) return "Zig source";
    if (std.ascii.eqlIgnoreCase(ext, ".md")) return "Markdown";
    if (std.ascii.eqlIgnoreCase(ext, ".txt")) return "Text file";
    if (std.ascii.eqlIgnoreCase(ext, ".json")) return "JSON";
    if (std.ascii.eqlIgnoreCase(ext, ".zon")) return "ZON";
    if (std.ascii.eqlIgnoreCase(ext, ".nix")) return "Nix expression";
    if (std.ascii.eqlIgnoreCase(ext, ".toml")) return "TOML";
    if (std.ascii.eqlIgnoreCase(ext, ".yaml") or std.ascii.eqlIgnoreCase(ext, ".yml")) return "YAML";
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "PNG image";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "JPEG image";
    if (std.ascii.eqlIgnoreCase(ext, ".svg")) return "SVG";
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return "PDF";
    if (std.ascii.eqlIgnoreCase(ext, ".so")) return "Shared library";
    if (std.ascii.eqlIgnoreCase(ext, ".a")) return "Static library";
    if (std.ascii.eqlIgnoreCase(ext, ".o")) return "Object file";
    return "File";
}

pub fn browserEntryKind(kind: std.Io.File.Kind) BrowserEntryKind {
    return switch (kind) {
        .directory => .directory,
        .file => .file,
        .sym_link => .symlink,
        else => .other,
    };
}

pub fn unixSecondsFromTimestamp(timestamp: std.Io.Timestamp) i64 {
    const seconds = @divFloor(timestamp.nanoseconds, std.time.ns_per_s);
    return std.math.cast(i64, seconds) orelse if (seconds < 0)
        std.math.minInt(i64)
    else
        std.math.maxInt(i64);
}

pub const DecodedTimestamp = struct {
    year: u16,
    yday: u16,
    month_index: u8,
    day: u8,
    hour: u8,
    minute: u8,
};

pub fn decodeUnixSecondsUtc(unix_seconds: i64) ?DecodedTimestamp {
    if (unix_seconds < 0) return null;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return .{
        .year = year_day.year,
        .yday = year_day.day,
        .month_index = @intCast(@intFromEnum(month_day.month) - 1),
        .day = month_day.day_index + 1,
        .hour = day_seconds.getHoursIntoDay(),
        .minute = day_seconds.getMinutesIntoHour(),
    };
}

pub fn timestampMonthAbbrev(index: usize) []const u8 {
    const months = [_][]const u8{
        "Jan",
        "Feb",
        "Mar",
        "Apr",
        "May",
        "Jun",
        "Jul",
        "Aug",
        "Sep",
        "Oct",
        "Nov",
        "Dec",
    };
    return months[@min(index, months.len - 1)];
}

pub fn formatTimestampCompactText(buffer: []u8, unix_seconds: i64, now_seconds: ?i64) []const u8 {
    if (unix_seconds <= 0) return "";

    const tm_buf = decodeUnixSecondsUtc(unix_seconds) orelse return "";
    const now_tm = if (now_seconds) |now| decodeUnixSecondsUtc(now) else null;
    const diff_seconds = if (now_seconds) |now| now - unix_seconds else std.math.maxInt(i64);

    if (now_tm) |now| if (tm_buf.year == now.year and tm_buf.yday == now.yday) {
        return std.fmt.bufPrint(buffer, "Today {d:0>2}:{d:0>2}", .{
            tm_buf.hour,
            tm_buf.minute,
        }) catch "";
    };
    if (now_tm != null and diff_seconds >= 0 and diff_seconds < 48 * 60 * 60) {
        return std.fmt.bufPrint(buffer, "Yesterday {d:0>2}:{d:0>2}", .{
            tm_buf.hour,
            tm_buf.minute,
        }) catch "";
    }
    if (now_tm) |now| if (tm_buf.year == now.year) {
        return std.fmt.bufPrint(buffer, "{s} {d} {d:0>2}:{d:0>2}", .{
            timestampMonthAbbrev(tm_buf.month_index),
            tm_buf.day,
            tm_buf.hour,
            tm_buf.minute,
        }) catch "";
    };

    return std.fmt.bufPrint(buffer, "{s} {d}, {d}", .{
        timestampMonthAbbrev(tm_buf.month_index),
        tm_buf.day,
        tm_buf.year,
    }) catch "";
}

pub fn formatTimestampDetailText(buffer: []u8, unix_seconds: i64) []const u8 {
    if (unix_seconds <= 0) return "";

    const tm_buf = decodeUnixSecondsUtc(unix_seconds) orelse return "";

    return std.fmt.bufPrint(buffer, "{s} {d}, {d} at {d:0>2}:{d:0>2}", .{
        timestampMonthAbbrev(tm_buf.month_index),
        tm_buf.day,
        tm_buf.year,
        tm_buf.hour,
        tm_buf.minute,
    }) catch "";
}

pub fn formatSizeText(buffer: []u8, kind: BrowserEntryKind, size_bytes: u64, target_kind: ?BrowserEntryKind) []const u8 {
    if (kind == .directory or target_kind == .directory) return "";
    if (size_bytes < 1024) return std.fmt.bufPrint(buffer, "{} B", .{size_bytes}) catch "";

    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var scaled = @as(f64, @floatFromInt(size_bytes));
    var unit_index: usize = 0;
    while (scaled >= 1024 and unit_index + 1 < units.len) : (unit_index += 1) {
        scaled /= 1024;
    }
    return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ scaled, units[unit_index] }) catch "";
}

pub fn sortColumnLabel(column: BrowserSortColumn) []const u8 {
    return switch (column) {
        .name => "name",
        .modified => "modified time",
        .kind => "type",
        .size => "size",
    };
}

pub fn sortDirectionLabel(direction: BrowserSortDirection) []const u8 {
    return switch (direction) {
        .ascending => "ascending",
        .descending => "descending",
    };
}

pub fn allocAssetEntryNameText(state: *State, entry: BrowserEntry) ![]const u8 {
    return allocAssetUiString(state, "{f}", .{
        std.unicode.fmtUtf8(entry.name),
    });
}

pub fn currentUnixSeconds(state: *const State) ?i64 {
    const io = state.io orelse return null;
    const ns = std.Io.Clock.real.now(io).nanoseconds;
    const seconds = @divFloor(ns, std.time.ns_per_s);
    return std.math.cast(i64, seconds);
}

pub fn allocFormattedTimestamp(state: *State, unix_seconds: i64) ![]const u8 {
    var buf: [40]u8 = undefined;
    const text = formatTimestampCompactText(buf[0..], unix_seconds, currentUnixSeconds(state));
    return allocUiString(state, "{s}", .{text});
}

pub fn allocAssetFormattedTimestamp(state: *State, unix_seconds: i64) ![]const u8 {
    var buf: [40]u8 = undefined;
    const text = formatTimestampCompactText(buf[0..], unix_seconds, currentUnixSeconds(state));
    return allocAssetUiString(state, "{s}", .{text});
}

pub fn allocFormattedTimestampDetail(state: *State, unix_seconds: i64) ![]const u8 {
    var buf: [48]u8 = undefined;
    const text = formatTimestampDetailText(buf[0..], unix_seconds);
    return allocUiString(state, "{s}", .{text});
}

pub fn allocFormattedSize(state: *State, kind: BrowserEntryKind, size_bytes: u64, target_kind: ?BrowserEntryKind) ![]const u8 {
    var buf: [24]u8 = undefined;
    const text = formatSizeText(buf[0..], kind, size_bytes, target_kind);
    return allocUiString(state, "{s}", .{text});
}

pub fn allocAssetFormattedSize(state: *State, kind: BrowserEntryKind, size_bytes: u64, target_kind: ?BrowserEntryKind) ![]const u8 {
    var buf: [24]u8 = undefined;
    const text = formatSizeText(buf[0..], kind, size_bytes, target_kind);
    return allocAssetUiString(state, "{s}", .{text});
}

pub fn appendPlaceIfDirectory(state: *State, label: []const u8, path: []const u8) !void {
    const normalized = try normalizeDirectoryPath(allocator, path);
    errdefer allocator.free(normalized);
    ensureDirectoryOpenable(try stateIo(state), normalized) catch return;

    for (state.places.items) |existing| {
        if (std.mem.eql(u8, existing.path, normalized)) return;
    }

    try state.places.append(allocator, .{ .label = label, .path = normalized });
}

pub fn refreshPlaces(state: *State) !void {
    clearPlaces(state);

    if (homePath(state)) |home| {
        try appendPlaceIfDirectory(state, "Home", home);

        const desktop = try std.fmt.allocPrint(allocator, "{s}/Desktop", .{home});
        defer allocator.free(desktop);
        try appendPlaceIfDirectory(state, "Desktop", desktop);

        const documents = try std.fmt.allocPrint(allocator, "{s}/Documents", .{home});
        defer allocator.free(documents);
        try appendPlaceIfDirectory(state, "Documents", documents);

        const downloads = try std.fmt.allocPrint(allocator, "{s}/Downloads", .{home});
        defer allocator.free(downloads);
        try appendPlaceIfDirectory(state, "Downloads", downloads);
    }

    try appendPlaceIfDirectory(state, "/tmp", "/tmp");
    try appendPlaceIfDirectory(state, "/", "/");
}

pub fn sortFieldLess(state: *const State, a: BrowserEntry, b: BrowserEntry) bool {
    return switch (state.sort_column) {
        .name => switch (state.sort_direction) {
            .ascending => std.ascii.lessThanIgnoreCase(a.name, b.name),
            .descending => std.ascii.lessThanIgnoreCase(b.name, a.name),
        },
        .modified => switch (state.sort_direction) {
            .ascending => a.modified_unix < b.modified_unix,
            .descending => a.modified_unix > b.modified_unix,
        },
        .kind => switch (state.sort_direction) {
            .ascending => std.ascii.lessThanIgnoreCase(a.typeLabel(), b.typeLabel()),
            .descending => std.ascii.lessThanIgnoreCase(b.typeLabel(), a.typeLabel()),
        },
        .size => switch (state.sort_direction) {
            .ascending => a.size_bytes < b.size_bytes,
            .descending => a.size_bytes > b.size_bytes,
        },
    };
}

pub fn browserEntryLessThan(state: *const State, a: BrowserEntry, b: BrowserEntry) bool {
    if (state.sort_directories_together and a.isDirectory() != b.isDirectory()) return a.isDirectory();
    if (sortFieldLess(state, a, b)) return true;
    if (sortFieldLess(state, b, a)) return false;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

pub fn sortDirectoryEntries(state: *State) void {
    std.mem.sort(BrowserEntry, state.entries.items, state, browserEntryLessThan);
}

pub fn pathIsSameOrInside(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    if (parent.len == 0 or child.len <= parent.len) return false;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return if (std.mem.eql(u8, parent, "/"))
        child[0] == '/'
    else
        child[parent.len] == '/';
}

pub fn moveDestinationPath(source_path: []const u8, target_dir: []const u8) ![]u8 {
    return joinPath(allocator, target_dir, std.fs.path.basename(source_path));
}

pub const MovePreflight = enum {
    movable,
    noop,
    blocked,
};

pub fn preflightMovePathToDirectory(state: *State, source_path: []const u8, target_dir: []const u8) !MovePreflight {
    if (pathIsSameOrInside(source_path, target_dir)) {
        state.status_note = "Cannot move a folder into itself.";
        return .blocked;
    }

    const destination = try moveDestinationPath(source_path, target_dir);
    defer allocator.free(destination);

    if (std.mem.eql(u8, source_path, destination)) return .noop;

    const io = state.io orelse {
        state.status_note = "Unable to move files.";
        return .blocked;
    };
    if (std.Io.Dir.cwd().statFile(io, destination, .{ .follow_symlinks = false })) |_| {
        state.status_note = "A file with that name already exists in the target folder.";
        return .blocked;
    } else |_| {}

    return .movable;
}

pub fn renamePathIntoDirectory(state: *State, source_path: []const u8, target_dir: []const u8) !bool {
    const destination = try moveDestinationPath(source_path, target_dir);
    defer allocator.free(destination);
    if (std.mem.eql(u8, source_path, destination)) return false;

    const io = state.io orelse {
        state.status_note = "Unable to move files.";
        return false;
    };
    std.Io.Dir.renameAbsolute(source_path, destination, io) catch {
        state.status_note = "Unable to move files.";
        return false;
    };
    return true;
}

pub fn movePathsToDirectory(state: *State, paths: []const []const u8, target_dir: []const u8) !bool {
    var movable_count: usize = 0;

    for (paths) |path| {
        switch (try preflightMovePathToDirectory(state, path, target_dir)) {
            .movable => movable_count += 1,
            .noop => {},
            .blocked => return false,
        }
    }

    if (movable_count == 0) {
        state.status_note = "Already in that folder.";
        return false;
    }

    var moved_count: usize = 0;
    for (paths) |path| {
        if (try renamePathIntoDirectory(state, path, target_dir)) {
            moved_count += 1;
        } else if (state.status_note != null) {
            break;
        }
    }

    if (moved_count == 0) return false;

    clearSelectedPaths(state);
    freeOptionalOwnedSlice(&state.selected_path);
    freeOptionalOwnedSlice(&state.last_click_path);
    state.last_click_ms = 0;
    state.selection_anchor_index = null;
    try loadDirectoryEntries(state);
    state.status_note = if (moved_count == 1) "Moved 1 item." else "Moved items.";
    return true;
}

pub fn moveDropPathsToDirectory(state: *State, source_path: []const u8, target_dir: []const u8) !bool {
    if (isPathSelected(state, source_path) and state.selected_paths.items.len > 0) {
        return movePathsToDirectory(state, state.selected_paths.items, target_dir);
    }

    const single_path = [_][]const u8{source_path};
    return movePathsToDirectory(state, single_path[0..], target_dir);
}

pub fn preflightCopyPathToDirectory(state: *State, source_path: []const u8, target_dir: []const u8) !bool {
    if (pathIsSameOrInside(source_path, target_dir)) {
        state.status_note = "Cannot copy a folder into itself.";
        return false;
    }

    const destination = try moveDestinationPath(source_path, target_dir);
    defer allocator.free(destination);

    const io = state.io orelse {
        state.status_note = "Unable to copy files.";
        return false;
    };
    if (std.Io.Dir.cwd().statFile(io, destination, .{ .follow_symlinks = false })) |_| {
        state.status_note = "A file with that name already exists in the target folder.";
        return false;
    } else |_| {}

    return true;
}

pub fn copyPathToDirectory(state: *State, source_path: []const u8, target_dir: []const u8) ![]u8 {
    const destination = try moveDestinationPath(source_path, target_dir);
    errdefer allocator.free(destination);

    const io = state.io orelse {
        state.status_note = "Unable to copy files.";
        return error.IoUnavailable;
    };
    try copyPathAbsolute(io, source_path, destination);
    return destination;
}

pub fn copyPathAbsolute(io: std.Io, source_path: []const u8, destination: []const u8) anyerror!void {
    const stat = try std.Io.Dir.cwd().statFile(io, source_path, .{ .follow_symlinks = false });
    switch (stat.kind) {
        .directory => try copyDirectoryAbsolute(io, source_path, destination),
        .sym_link => try copySymlinkAbsolute(io, source_path, destination),
        else => try std.Io.Dir.copyFileAbsolute(source_path, destination, io, .{ .replace = false }),
    }
}

pub fn copyDirectoryAbsolute(io: std.Io, source_path: []const u8, destination: []const u8) anyerror!void {
    try std.Io.Dir.createDirAbsolute(io, destination, .default_dir);
    var dir = try std.Io.Dir.cwd().openDir(io, source_path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const child_source = try joinPath(allocator, source_path, entry.name);
        defer allocator.free(child_source);
        const child_destination = try joinPath(allocator, destination, entry.name);
        defer allocator.free(child_destination);
        try copyPathAbsolute(io, child_source, child_destination);
    }
}

pub fn copySymlinkAbsolute(io: std.Io, source_path: []const u8, destination: []const u8) anyerror!void {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.readLinkAbsolute(io, source_path, &buf);
    const target = buf[0..len];
    var is_directory = false;
    if (resolveSymlinkTargetAlloc(io, allocator, source_path)) |resolved| {
        defer allocator.free(resolved);
        const target_stat = std.Io.Dir.cwd().statFile(io, resolved, .{ .follow_symlinks = true }) catch null;
        if (target_stat) |stat| is_directory = stat.kind == .directory;
    } else |_| {}
    try std.Io.Dir.cwd().symLink(io, target, destination, .{ .is_directory = is_directory });
}

pub fn copyPathsToDirectory(state: *State, paths: []const []const u8, target_dir: []const u8) !bool {
    if (paths.len == 0) return false;
    for (paths) |path| {
        if (!try preflightCopyPathToDirectory(state, path, target_dir)) return false;
    }

    var copied_paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        clearTrackedPaths(&copied_paths);
        copied_paths.deinit(allocator);
    }

    for (paths) |path| {
        const copied = copyPathToDirectory(state, path, target_dir) catch {
            state.status_note = "Unable to copy files.";
            return false;
        };
        try copied_paths.append(allocator, copied);
    }

    if (std.mem.eql(u8, target_dir, state.current_dir)) {
        clearSelectedPaths(state);
        for (copied_paths.items) |path| try appendSelectedPathIfMissing(state, path);
        try syncPrimarySelection(state);
        try loadDirectoryEntries(state);
    }

    state.status_note = if (copied_paths.items.len == 1) "Copied 1 item." else "Copied items.";
    return true;
}

pub fn deletePaths(state: *State, paths: []const []const u8) !bool {
    if (paths.len == 0) return false;
    const io = state.io orelse {
        state.status_note = "Unable to delete files.";
        return false;
    };

    var deleted_count: usize = 0;
    for (paths) |path| {
        std.Io.Dir.cwd().deleteTree(io, path) catch {
            state.status_note = "Unable to delete files.";
            return false;
        };
        deleted_count += 1;
    }

    clearSelectedPaths(state);
    freeOptionalOwnedSlice(&state.selected_path);
    freeOptionalOwnedSlice(&state.last_click_path);
    state.last_click_ms = 0;
    state.selection_anchor_index = null;
    try loadDirectoryEntries(state);
    state.status_note = if (deleted_count == 1) "Deleted 1 item." else "Deleted items.";
    return true;
}

pub fn loadDirectoryEntries(state: *State) !void {
    clearEntries(state);

    const io = try stateIo(state);
    var dir = std.Io.Dir.cwd().openDir(io, state.current_dir, .{ .iterate = true, .follow_symlinks = false }) catch return error.OpenDirFailed;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |dir_entry| {
        const name = dir_entry.name;
        if (name.len == 0) continue;

        const full_path = try joinPath(allocator, state.current_dir, name);
        errdefer allocator.free(full_path);

        const stat = std.Io.Dir.cwd().statFile(io, full_path, .{ .follow_symlinks = false }) catch {
            allocator.free(full_path);
            continue;
        };

        const entry_name = try allocator.dupe(u8, name);
        errdefer allocator.free(entry_name);

        const kind = browserEntryKind(stat.kind);
        var size_bytes = stat.size;
        var modified_unix = unixSecondsFromTimestamp(stat.mtime);
        var target_path: ?[]u8 = null;
        var target_kind: ?BrowserEntryKind = null;

        if (kind == .symlink) {
            target_path = resolveSymlinkTargetAlloc(io, allocator, full_path) catch null;
            errdefer if (target_path) |path| allocator.free(path);

            if (target_path) |resolved_target| {
                if (std.Io.Dir.cwd().statFile(io, resolved_target, .{ .follow_symlinks = true })) |target_stat| {
                    target_kind = browserEntryKind(target_stat.kind);
                    size_bytes = if (target_kind == .directory)
                        0
                    else
                        target_stat.size;
                    modified_unix = unixSecondsFromTimestamp(target_stat.mtime);
                } else |_| {}
            }
        }

        const entry = BrowserEntry{
            .name = entry_name,
            .path = full_path,
            .kind = kind,
            .size_bytes = size_bytes,
            .modified_unix = modified_unix,
            .target_path = target_path,
            .target_kind = target_kind,
        };
        try state.entries.append(allocator, entry);
    }

    sortDirectoryEntries(state);

    var index: usize = 0;
    while (index < state.selected_paths.items.len) {
        if (selectedEntryExists(state, state.selected_paths.items[index])) {
            index += 1;
            continue;
        }
        allocator.free(state.selected_paths.swapRemove(index));
    }

    if (state.selected_path) |selected_path| {
        if (!selectedEntryExists(state, selected_path)) freeOptionalOwnedSlice(&state.selected_path);
    }

    try syncPrimarySelection(state);
    syncSelectionAnchor(state);
}

pub fn setCurrentDirectory(state: *State, path: []const u8, push_history: bool) !bool {
    const normalized = try normalizeDirectoryPath(allocator, path);
    errdefer allocator.free(normalized);
    try ensureDirectoryOpenable(try stateIo(state), normalized);

    if (state.current_dir.len > 0 and std.mem.eql(u8, state.current_dir, normalized)) {
        allocator.free(normalized);
        syncAddressInputToCurrentDir(state);
        try loadDirectoryEntries(state);
        return true;
    }

    try preserveFolderTreeContextForNavigation(state, normalized);

    if (push_history) {
        while (state.history.items.len > state.history_index + 1) allocator.free(state.history.pop().?);
        try state.history.append(allocator, try allocator.dupe(u8, normalized));
        state.history_index = state.history.items.len - 1;
    }

    if (state.current_dir.len > 0) allocator.free(state.current_dir);
    state.current_dir = normalized;
    clearSelectedPaths(state);
    freeOptionalOwnedSlice(&state.selected_path);
    freeOptionalOwnedSlice(&state.last_click_path);
    state.last_click_ms = 0;
    state.selection_anchor_index = null;
    state.file_panel_scroll_y = 0;
    state.status_note = null;
    syncAddressInputToCurrentDir(state);
    try loadDirectoryEntries(state);
    return true;
}

pub fn navigateBack(state: *State) !bool {
    if (state.history_index == 0 or state.history.items.len == 0) return false;
    state.history_index -= 1;
    return setCurrentDirectory(state, state.history.items[state.history_index], false);
}

pub fn navigateForward(state: *State) !bool {
    if (state.history.items.len == 0 or state.history_index + 1 >= state.history.items.len) return false;
    state.history_index += 1;
    return setCurrentDirectory(state, state.history.items[state.history_index], false);
}

pub fn navigateUp(state: *State) !bool {
    const parent = try parentPathAlloc(allocator, state.current_dir);
    defer if (parent) |path| allocator.free(path);
    const parent_path = parent orelse return false;
    return setCurrentDirectory(state, parent_path, true);
}

pub fn refreshCurrentDirectory(state: *State) !void {
    freeOptionalOwnedSlice(&state.last_click_path);
    state.last_click_ms = 0;
    syncAddressInputToCurrentDir(state);
    try loadDirectoryEntries(state);
}

pub fn selectedSymlinkDirectoryEntry(state: *const State) ?*const BrowserEntry {
    const entry = selectedEntry(state) orelse return null;
    return if (entry.isSymlinkToDirectory()) entry else null;
}

pub fn entryForPath(state: *const State, path: []const u8) ?*const BrowserEntry {
    for (state.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}

pub fn entryIndexForPath(state: *const State, path: []const u8) ?usize {
    for (state.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.path, path)) return index;
    }
    return null;
}
