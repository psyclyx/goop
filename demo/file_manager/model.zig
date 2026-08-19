//! Domain ownership and selection operations for the file browser.
//!
//! This module knows how Model and Interaction own their strings and how
//! selection and navigation state relate. It deliberately knows nothing about
//! widgets, control journals, the filesystem, or rendering.

const std = @import("std");
const state = @import("state.zig");
const types = @import("types.zig");

pub const allocator = std.heap.smp_allocator;

pub fn freeOptionalOwnedSlice(buf: *?[]u8) void {
    if (buf.*) |slice| allocator.free(slice);
    buf.* = null;
}

pub fn clearTrackedPaths(paths: *std.ArrayListUnmanaged([]u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.clearRetainingCapacity();
}

pub fn clearPlaces(model: *state.Model) void {
    for (model.places.items) |place| allocator.free(place.path);
    model.places.clearRetainingCapacity();
}

pub fn clearEntries(model: *state.Model) void {
    for (model.entries.items) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.path);
        if (entry.target_path) |target_path| allocator.free(target_path);
    }
    model.entries.clearRetainingCapacity();
}

pub fn clearSelectedPaths(model: *state.Model) void {
    for (model.selected_paths.items) |path| allocator.free(path);
    model.selected_paths.clearRetainingCapacity();
}

pub fn isPathSelected(model: *const state.Model, path: []const u8) bool {
    for (model.selected_paths.items) |selected| {
        if (std.mem.eql(u8, selected, path)) return true;
    }
    return false;
}

pub fn selectedPathCount(model: *const state.Model) usize {
    return model.selected_paths.items.len;
}

pub fn entryForPath(model: *const state.Model, path: []const u8) ?*const types.BrowserEntry {
    for (model.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}

pub fn entryIndexForPath(model: *const state.Model, path: []const u8) ?usize {
    for (model.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.path, path)) return index;
    }
    return null;
}

pub fn selectedEntryExists(model: *const state.Model, path: []const u8) bool {
    return entryForPath(model, path) != null;
}

pub fn selectedEntry(model: *const state.Model) ?*const types.BrowserEntry {
    const selected_path = model.selected_path orelse return null;
    return entryForPath(model, selected_path);
}

pub fn setSelectedPath(model: *state.Model, path: ?[]const u8) !void {
    const replacement = if (path) |value| try allocator.dupe(u8, value) else null;
    freeOptionalOwnedSlice(&model.selected_path);
    model.selected_path = replacement;
}

pub fn setLastClickPath(model: *state.Model, path: ?[]const u8) !void {
    const replacement = if (path) |value| try allocator.dupe(u8, value) else null;
    freeOptionalOwnedSlice(&model.last_click_path);
    model.last_click_path = replacement;
}

pub fn setContextTargetPath(interaction: *state.Interaction, path: ?[]const u8) !void {
    const replacement = if (path) |value| try allocator.dupe(u8, value) else null;
    freeOptionalOwnedSlice(&interaction.context_target_path);
    interaction.context_target_path = replacement;
}

pub fn clearRename(interaction: *state.Interaction) void {
    freeOptionalOwnedSlice(&interaction.rename_path);
    interaction.rename_input = .{};
    interaction.rename_commit_requested = false;
    interaction.rename_cancel_requested = false;
}

pub fn clearPermissionEdit(interaction: *state.Interaction) void {
    freeOptionalOwnedSlice(&interaction.permission_path);
    interaction.permission_draft = 0;
    interaction.permission_commit_requested = false;
    interaction.permission_cancel_requested = false;
}

fn selectedPathIndex(model: *const state.Model, path: []const u8) ?usize {
    for (model.selected_paths.items, 0..) |selected, index| {
        if (std.mem.eql(u8, selected, path)) return index;
    }
    return null;
}

pub fn appendSelectedPathIfMissing(model: *state.Model, path: []const u8) !void {
    if (selectedPathIndex(model, path) != null) return;
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try model.selected_paths.append(allocator, owned);
}

pub fn removeSelectedPath(model: *state.Model, path: []const u8) bool {
    const index = selectedPathIndex(model, path) orelse return false;
    allocator.free(model.selected_paths.orderedRemove(index));
    return true;
}

pub fn syncPrimarySelection(model: *state.Model) !void {
    if (model.selected_path) |selected_path| {
        if (isPathSelected(model, selected_path)) return;
        freeOptionalOwnedSlice(&model.selected_path);
    }
    if (model.selected_paths.items.len > 0) {
        try setSelectedPath(model, model.selected_paths.items[0]);
    }
}

pub fn syncSelectionAnchor(model: *state.Model) void {
    const selected_path = model.selected_path orelse {
        model.selection_anchor_index = null;
        return;
    };
    model.selection_anchor_index = entryIndexForPath(model, selected_path);
}

pub fn applyEntrySelectionClick(
    model: *state.Model,
    interaction: *const state.Interaction,
    entry_index: usize,
) !void {
    if (entry_index >= model.entries.items.len) return;
    const entry = model.entries.items[entry_index];

    if (interaction.shift_down) {
        const anchor = model.selection_anchor_index orelse entry_index;
        if (!interaction.ctrl_down) clearSelectedPaths(model);

        const start = @min(anchor, entry_index);
        const end = @max(anchor, entry_index);
        for (start..end + 1) |index| {
            try appendSelectedPathIfMissing(model, model.entries.items[index].path);
        }
        model.selection_anchor_index = anchor;
    } else if (interaction.ctrl_down) {
        model.selection_anchor_index = entry_index;
        if (!removeSelectedPath(model, entry.path)) {
            try appendSelectedPathIfMissing(model, entry.path);
        }
    } else {
        clearSelectedPaths(model);
        try appendSelectedPathIfMissing(model, entry.path);
        model.selection_anchor_index = entry_index;
    }

    if (isPathSelected(model, entry.path)) {
        try setSelectedPath(model, entry.path);
    } else {
        try syncPrimarySelection(model);
    }
}

pub fn clearSelection(model: *state.Model) bool {
    if (model.selected_paths.items.len == 0 and model.selected_path == null) return false;
    clearSelectedPaths(model);
    freeOptionalOwnedSlice(&model.selected_path);
    freeOptionalOwnedSlice(&model.last_click_path);
    model.last_click_ms = 0;
    model.selection_anchor_index = null;
    return true;
}

pub fn selectAllEntries(model: *state.Model) !bool {
    if (model.entries.items.len == 0) return false;
    if (model.selected_paths.items.len == model.entries.items.len) return false;

    var replacement: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        clearTrackedPaths(&replacement);
        replacement.deinit(allocator);
    }
    try replacement.ensureTotalCapacity(allocator, model.entries.items.len);
    for (model.entries.items) |entry| {
        const owned = try allocator.dupe(u8, entry.path);
        replacement.appendAssumeCapacity(owned);
    }
    const primary = try allocator.dupe(u8, model.entries.items[0].path);
    errdefer allocator.free(primary);

    clearSelectedPaths(model);
    model.selected_paths.deinit(allocator);
    model.selected_paths = replacement;
    replacement = .empty;
    freeOptionalOwnedSlice(&model.selected_path);
    model.selected_path = primary;
    syncSelectionAnchor(model);
    freeOptionalOwnedSlice(&model.last_click_path);
    model.last_click_ms = 0;
    return true;
}

pub fn syncAddressInputToCurrentDir(interaction: *state.Interaction, model: *const state.Model) void {
    interaction.address_input = .{ .placeholder = "Path" };
    interaction.address_input.insertSlice(model.current_dir);
    interaction.address_input.cursor = interaction.address_input.len;
}

pub fn pathHasDirectoryPrefix(path: []const u8, prefix: []const u8) bool {
    if (std.mem.eql(u8, prefix, "/")) return path.len > 0 and path[0] == '/';
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

fn trackedPathIndex(paths: []const []u8, path: []const u8) ?usize {
    for (paths, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, path)) return index;
    }
    return null;
}

pub fn isFolderTreePathExpanded(model: *const state.Model, path: []const u8) bool {
    return trackedPathIndex(model.folder_tree_expanded_paths.items, path) != null;
}

pub fn folderTreeExpansion(model: *const state.Model, path: []const u8) types.FolderTreeExpansion {
    if (isFolderTreePathExpanded(model, path)) return .expanded;
    if (std.mem.eql(u8, path, model.current_dir)) return .expanded;
    if (pathHasDirectoryPrefix(model.current_dir, path)) return .partial;
    return .collapsed;
}

pub fn setFolderTreePathExpanded(model: *state.Model, path: []const u8, expanded: bool) !bool {
    if (trackedPathIndex(model.folder_tree_expanded_paths.items, path)) |index| {
        if (expanded) return false;
        allocator.free(model.folder_tree_expanded_paths.swapRemove(index));
        return true;
    }
    if (!expanded) return false;
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try model.folder_tree_expanded_paths.append(allocator, owned);
    return true;
}

pub fn preserveFolderTreeContextForNavigation(model: *state.Model, next_dir: []const u8) !void {
    if (model.current_dir.len == 0) return;
    if (std.mem.eql(u8, model.current_dir, next_dir)) return;
    if (!pathHasDirectoryPrefix(model.current_dir, next_dir)) return;
    _ = try setFolderTreePathExpanded(model, model.current_dir, true);
}

pub fn shouldRenderFolderTreeChildForExpansion(
    model: *const state.Model,
    parent_expansion: types.FolderTreeExpansion,
    index: usize,
    child_path: []const u8,
) bool {
    return switch (parent_expansion) {
        .collapsed => false,
        .partial => pathHasDirectoryPrefix(model.current_dir, child_path),
        .expanded => index < types.folder_tree_max_visible_children or
            pathHasDirectoryPrefix(model.current_dir, child_path) or
            isFolderTreePathExpanded(model, child_path),
    };
}

pub fn deinit(model: *state.Model, interaction: *state.Interaction) void {
    clearEntries(model);
    clearPlaces(model);
    clearSelectedPaths(model);
    for (model.history.items) |path| allocator.free(path);
    model.history.deinit(allocator);
    model.places.deinit(allocator);
    model.entries.deinit(allocator);
    model.selected_paths.deinit(allocator);
    clearTrackedPaths(&model.folder_tree_expanded_paths);
    model.folder_tree_expanded_paths.deinit(allocator);
    if (model.current_dir.len > 0) allocator.free(model.current_dir);
    model.current_dir = &.{};
    freeOptionalOwnedSlice(&model.selected_path);
    freeOptionalOwnedSlice(&model.last_click_path);
    freeOptionalOwnedSlice(&interaction.context_target_path);
    clearRename(interaction);
    clearPermissionEdit(interaction);
    interaction.address_input = .{ .placeholder = "Path" };
}
