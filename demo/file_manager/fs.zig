const std = @import("std");

const capabilities = @import("capabilities.zig");
const model_ops = @import("model.zig");
const types = @import("types.zig");
const format = @import("format.zig");
const Scope = capabilities.Filesystem;
const allocator = std.heap.smp_allocator;
const BrowserEntry = types.BrowserEntry;
const BrowserEntryKind = types.BrowserEntryKind;
const BrowserPlace = types.BrowserPlace;
const FolderTreeChild = types.FolderTreeChild;

test "filesystem seam has no UI core, effect, identity, or projection dependency" {
    const source = @embedFile("fs.zig");
    const forbidden = [_][]const u8{
        "@im" ++ "port(\"goop\")",
        "Beha" ++ "vior",
        ".eff" ++ "ects",
        ".iden" ++ "tities",
        ".projec" ++ "tion",
        ".dom" ++ "ain",
    };
    for (forbidden) |name| {
        try std.testing.expect(std.mem.indexOf(u8, source, name) == null);
    }
}

fn stateIo(state: Scope) !std.Io {
    return state.session.io orelse error.IoUnavailable;
}

fn clearPlaces(state: Scope) void {
    model_ops.clearPlaces(state.model);
}

fn clearEntries(state: Scope) void {
    model_ops.clearEntries(state.model);
}

fn clearSelectedPaths(state: Scope) void {
    model_ops.clearSelectedPaths(state.model);
}

const freeOptionalOwnedSlice = model_ops.freeOptionalOwnedSlice;
const clearTrackedPaths = model_ops.clearTrackedPaths;

fn syncSelectionAnchor(state: Scope) void {
    model_ops.syncSelectionAnchor(state.model);
}

fn syncPrimarySelection(state: Scope) !void {
    try model_ops.syncPrimarySelection(state.model);
}

fn syncAddressInputToCurrentDir(state: Scope) void {
    model_ops.syncAddressInputToCurrentDir(state.interaction, state.model);
}

fn appendSelectedPathIfMissing(state: Scope, path: []const u8) !void {
    try model_ops.appendSelectedPathIfMissing(state.model, path);
}

fn selectedEntryExists(state: Scope, path: []const u8) bool {
    return model_ops.selectedEntryExists(state.model, path);
}

fn preserveFolderTreeContextForNavigation(state: Scope, next_dir: []const u8) !void {
    try model_ops.preserveFolderTreeContextForNavigation(state.model, next_dir);
}

fn isPathSelected(state: Scope, path: []const u8) bool {
    return model_ops.isPathSelected(state.model, path);
}

fn selectedEntry(state: Scope) ?*const BrowserEntry {
    return model_ops.selectedEntry(state.model);
}

pub fn homePath(state: Scope) ?[]const u8 {
    const env = state.session.env orelse return null;
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

        const full_path = try joinPath(allocator, dir_path, name);

        const stat = std.Io.Dir.cwd().statFile(io, full_path, .{ .follow_symlinks = true }) catch {
            allocator.free(full_path);
            continue;
        };
        if (browserEntryKind(stat.kind) != .directory) {
            allocator.free(full_path);
            continue;
        }

        const entry_name = allocator.dupe(u8, name) catch |err| {
            allocator.free(full_path);
            return err;
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

pub fn folderTreeDirectoryHasChildren(io: std.Io, dir_path: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true, .follow_symlinks = false }) catch return false;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |dir_entry| {
        const name = dir_entry.name;
        if (name.len == 0) continue;

        const full_path = try joinPath(allocator, dir_path, name);
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

pub const fileTypeLabel = types.fileTypeLabel;

pub fn browserEntryKind(kind: std.Io.File.Kind) BrowserEntryKind {
    return switch (kind) {
        .directory => .directory,
        .file => .file,
        .sym_link => .symlink,
        else => .other,
    };
}

pub fn appendPlaceIfDirectory(state: Scope, label: []const u8, path: []const u8) !void {
    const normalized = try normalizeDirectoryPath(allocator, path);
    errdefer allocator.free(normalized);
    ensureDirectoryOpenable(try stateIo(state), normalized) catch {
        allocator.free(normalized);
        return;
    };

    for (state.model.places.items) |existing| {
        if (std.mem.eql(u8, existing.path, normalized)) {
            allocator.free(normalized);
            return;
        }
    }

    try state.model.places.append(allocator, .{ .label = label, .path = normalized });
}

pub fn refreshPlaces(state: Scope) !void {
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

pub fn sortFieldLess(state: Scope, a: BrowserEntry, b: BrowserEntry) bool {
    return switch (state.model.sort_column) {
        .name => switch (state.model.sort_direction) {
            .ascending => std.ascii.lessThanIgnoreCase(a.name, b.name),
            .descending => std.ascii.lessThanIgnoreCase(b.name, a.name),
        },
        .modified => switch (state.model.sort_direction) {
            .ascending => a.modified_unix < b.modified_unix,
            .descending => a.modified_unix > b.modified_unix,
        },
        .kind => switch (state.model.sort_direction) {
            .ascending => std.ascii.lessThanIgnoreCase(a.typeLabel(), b.typeLabel()),
            .descending => std.ascii.lessThanIgnoreCase(b.typeLabel(), a.typeLabel()),
        },
        .size => switch (state.model.sort_direction) {
            .ascending => a.size_bytes < b.size_bytes,
            .descending => a.size_bytes > b.size_bytes,
        },
    };
}

pub fn browserEntryLessThan(state: Scope, a: BrowserEntry, b: BrowserEntry) bool {
    if (state.model.sort_directories_together and a.isDirectory() != b.isDirectory()) return a.isDirectory();
    if (sortFieldLess(state, a, b)) return true;
    if (sortFieldLess(state, b, a)) return false;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

pub fn sortDirectoryEntries(state: Scope) void {
    std.mem.sort(BrowserEntry, state.model.entries.items, state, browserEntryLessThan);
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

pub fn preflightMovePathToDirectory(state: Scope, source_path: []const u8, target_dir: []const u8) !MovePreflight {
    if (pathIsSameOrInside(source_path, target_dir)) {
        state.interaction.status_note = "Cannot move a folder into itself.";
        return .blocked;
    }

    const destination = try moveDestinationPath(source_path, target_dir);
    defer allocator.free(destination);

    if (std.mem.eql(u8, source_path, destination)) return .noop;

    const io = state.session.io orelse {
        state.interaction.status_note = "Unable to move files.";
        return .blocked;
    };
    if (std.Io.Dir.cwd().statFile(io, destination, .{ .follow_symlinks = false })) |_| {
        state.interaction.status_note = "A file with that name already exists in the target folder.";
        return .blocked;
    } else |_| {}

    return .movable;
}

pub fn renamePathIntoDirectory(state: Scope, source_path: []const u8, target_dir: []const u8) !bool {
    const destination = try moveDestinationPath(source_path, target_dir);
    defer allocator.free(destination);
    if (std.mem.eql(u8, source_path, destination)) return false;

    const io = state.session.io orelse {
        state.interaction.status_note = "Unable to move files.";
        return false;
    };
    std.Io.Dir.renameAbsolute(source_path, destination, io) catch {
        state.interaction.status_note = "Unable to move files.";
        return false;
    };
    return true;
}

pub fn movePathsToDirectory(state: Scope, paths: []const []const u8, target_dir: []const u8) !bool {
    var movable_count: usize = 0;

    for (paths) |path| {
        switch (try preflightMovePathToDirectory(state, path, target_dir)) {
            .movable => movable_count += 1,
            .noop => {},
            .blocked => return false,
        }
    }

    if (movable_count == 0) {
        state.interaction.status_note = "Already in that folder.";
        return false;
    }

    var moved_count: usize = 0;
    for (paths) |path| {
        if (try renamePathIntoDirectory(state, path, target_dir)) {
            moved_count += 1;
        } else if (state.interaction.status_note != null) {
            break;
        }
    }

    if (moved_count == 0) return false;

    clearSelectedPaths(state);
    freeOptionalOwnedSlice(&state.model.selected_path);
    freeOptionalOwnedSlice(&state.model.last_click_path);
    state.model.last_click_ms = 0;
    state.model.selection_anchor_index = null;
    try loadDirectoryEntries(state);
    state.interaction.status_note = if (moved_count == 1) "Moved 1 item." else "Moved items.";
    return true;
}

pub fn moveDropPathsToDirectory(state: Scope, source_path: []const u8, target_dir: []const u8) !bool {
    if (isPathSelected(state, source_path) and state.model.selected_paths.items.len > 0) {
        return movePathsToDirectory(state, state.model.selected_paths.items, target_dir);
    }

    const single_path = [_][]const u8{source_path};
    return movePathsToDirectory(state, single_path[0..], target_dir);
}

pub fn preflightCopyPathToDirectory(state: Scope, source_path: []const u8, target_dir: []const u8) !bool {
    if (pathIsSameOrInside(source_path, target_dir)) {
        state.interaction.status_note = "Cannot copy a folder into itself.";
        return false;
    }

    const destination = try moveDestinationPath(source_path, target_dir);
    defer allocator.free(destination);

    const io = state.session.io orelse {
        state.interaction.status_note = "Unable to copy files.";
        return false;
    };
    if (std.Io.Dir.cwd().statFile(io, destination, .{ .follow_symlinks = false })) |_| {
        state.interaction.status_note = "A file with that name already exists in the target folder.";
        return false;
    } else |_| {}

    return true;
}

pub fn copyPathToDirectory(state: Scope, source_path: []const u8, target_dir: []const u8) ![]u8 {
    const destination = try moveDestinationPath(source_path, target_dir);
    errdefer allocator.free(destination);

    const io = state.session.io orelse {
        state.interaction.status_note = "Unable to copy files.";
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

pub fn copyPathsToDirectory(state: Scope, paths: []const []const u8, target_dir: []const u8) !bool {
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
            state.interaction.status_note = "Unable to copy files.";
            return false;
        };
        errdefer allocator.free(copied);
        try copied_paths.append(allocator, copied);
    }

    if (std.mem.eql(u8, target_dir, state.model.current_dir)) {
        clearSelectedPaths(state);
        for (copied_paths.items) |path| try appendSelectedPathIfMissing(state, path);
        try syncPrimarySelection(state);
        try loadDirectoryEntries(state);
    }

    state.interaction.status_note = if (copied_paths.items.len == 1) "Copied 1 item." else "Copied items.";
    return true;
}

pub fn deletePaths(state: Scope, paths: []const []const u8) !bool {
    if (paths.len == 0) return false;
    const io = state.session.io orelse {
        state.interaction.status_note = "Unable to delete files.";
        return false;
    };

    var deleted_count: usize = 0;
    for (paths) |path| {
        std.Io.Dir.cwd().deleteTree(io, path) catch {
            state.interaction.status_note = "Unable to delete files.";
            return false;
        };
        deleted_count += 1;
    }

    clearSelectedPaths(state);
    freeOptionalOwnedSlice(&state.model.selected_path);
    freeOptionalOwnedSlice(&state.model.last_click_path);
    state.model.last_click_ms = 0;
    state.model.selection_anchor_index = null;
    try loadDirectoryEntries(state);
    state.interaction.status_note = if (deleted_count == 1) "Deleted 1 item." else "Deleted items.";
    return true;
}

pub fn loadDirectoryEntries(state: Scope) !void {
    clearEntries(state);

    const io = try stateIo(state);
    var dir = std.Io.Dir.cwd().openDir(io, state.model.current_dir, .{ .iterate = true, .follow_symlinks = false }) catch return error.OpenDirFailed;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |dir_entry| {
        const name = dir_entry.name;
        if (name.len == 0) continue;

        const full_path = try joinPath(allocator, state.model.current_dir, name);
        errdefer allocator.free(full_path);

        const stat = std.Io.Dir.cwd().statFile(io, full_path, .{ .follow_symlinks = false }) catch {
            allocator.free(full_path);
            continue;
        };

        const entry_name = try allocator.dupe(u8, name);
        errdefer allocator.free(entry_name);

        const kind = browserEntryKind(stat.kind);
        var size_bytes = stat.size;
        var modified_unix = format.unixSecondsFromNanoseconds(stat.mtime.nanoseconds);
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
                    modified_unix = format.unixSecondsFromNanoseconds(target_stat.mtime.nanoseconds);
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
        try state.model.entries.append(allocator, entry);
    }

    sortDirectoryEntries(state);

    var index: usize = 0;
    while (index < state.model.selected_paths.items.len) {
        if (selectedEntryExists(state, state.model.selected_paths.items[index])) {
            index += 1;
            continue;
        }
        allocator.free(state.model.selected_paths.swapRemove(index));
    }

    if (state.model.selected_path) |selected_path| {
        if (!selectedEntryExists(state, selected_path)) freeOptionalOwnedSlice(&state.model.selected_path);
    }

    try syncPrimarySelection(state);
    syncSelectionAnchor(state);
}

pub fn setCurrentDirectory(state: Scope, path: []const u8, push_history: bool) !bool {
    const normalized = try normalizeDirectoryPath(allocator, path);
    errdefer allocator.free(normalized);
    try ensureDirectoryOpenable(try stateIo(state), normalized);

    if (state.model.current_dir.len > 0 and std.mem.eql(u8, state.model.current_dir, normalized)) {
        allocator.free(normalized);
        syncAddressInputToCurrentDir(state);
        try loadDirectoryEntries(state);
        return true;
    }

    try preserveFolderTreeContextForNavigation(state, normalized);

    if (push_history) {
        const history_path = try allocator.dupe(u8, normalized);
        errdefer allocator.free(history_path);
        while (state.model.history.items.len > state.model.history_index + 1) allocator.free(state.model.history.pop().?);
        try state.model.history.append(allocator, history_path);
        state.model.history_index = state.model.history.items.len - 1;
    }

    if (state.model.current_dir.len > 0) allocator.free(state.model.current_dir);
    state.model.current_dir = normalized;
    clearSelectedPaths(state);
    freeOptionalOwnedSlice(&state.model.selected_path);
    freeOptionalOwnedSlice(&state.model.last_click_path);
    state.model.last_click_ms = 0;
    state.model.selection_anchor_index = null;
    state.model.file_panel_scroll_y = 0;
    state.interaction.status_note = null;
    syncAddressInputToCurrentDir(state);
    try loadDirectoryEntries(state);
    return true;
}

pub fn navigateBack(state: Scope) !bool {
    if (state.model.history_index == 0 or state.model.history.items.len == 0) return false;
    state.model.history_index -= 1;
    return setCurrentDirectory(state, state.model.history.items[state.model.history_index], false);
}

pub fn navigateForward(state: Scope) !bool {
    if (state.model.history.items.len == 0 or state.model.history_index + 1 >= state.model.history.items.len) return false;
    state.model.history_index += 1;
    return setCurrentDirectory(state, state.model.history.items[state.model.history_index], false);
}

pub fn navigateUp(state: Scope) !bool {
    const parent = try parentPathAlloc(allocator, state.model.current_dir);
    defer if (parent) |path| allocator.free(path);
    const parent_path = parent orelse return false;
    return setCurrentDirectory(state, parent_path, true);
}

pub fn refreshCurrentDirectory(state: Scope) !void {
    freeOptionalOwnedSlice(&state.model.last_click_path);
    state.model.last_click_ms = 0;
    syncAddressInputToCurrentDir(state);
    try loadDirectoryEntries(state);
}

pub fn selectedSymlinkDirectoryEntry(state: Scope) ?*const BrowserEntry {
    const entry = selectedEntry(state) orelse return null;
    return if (entry.isSymlinkToDirectory()) entry else null;
}

pub fn entryForPath(state: Scope, path: []const u8) ?*const BrowserEntry {
    for (state.model.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}

pub fn entryIndexForPath(state: Scope, path: []const u8) ?usize {
    for (state.model.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.path, path)) return index;
    }
    return null;
}
