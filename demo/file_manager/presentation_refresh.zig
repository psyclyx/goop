//! Behavior-owned preparation of renderer-neutral file-browser data.
//!
//! This is the only bridge from filesystem/clock effects into Presentation.
//! The visual projection receives the resulting plain data, never these
//! capabilities.

const std = @import("std");
const state = @import("state.zig");
const types = @import("types.zig");
const fs = @import("fs.zig");
const format = @import("format.zig");
const model_ops = @import("model.zig");
const preview = @import("preview.zig");
const image = @import("goop_image");

const allocator = std.heap.smp_allocator;

fn clearFolderTree(items: *std.ArrayListUnmanaged(state.Presentation.FolderTreeItem)) void {
    for (items.items) |item| allocator.free(item.path);
    items.clearRetainingCapacity();
}

pub fn deinit(value: *state.Presentation) void {
    clearFolderTree(&value.folder_tree);
    value.folder_tree.deinit(allocator);
    if (value.preview.text) |text| allocator.free(text);
    if (value.preview.image) |*pixels| pixels.deinit();
    if (value.preview.directory) |*directory| {
        for (directory.samples.items) |sample| allocator.free(sample.name);
        directory.samples.deinit(allocator);
    }
    value.* = .{};
}

fn appendFolder(
    value: *state.Presentation,
    path: []const u8,
    parent_index: ?usize,
    expansion: types.FolderTreeExpansion,
    selected: bool,
    has_children: bool,
) !usize {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const index = value.folder_tree.items.len;
    try value.folder_tree.append(allocator, .{
        .path = owned_path,
        .parent_index = parent_index,
        .expansion = expansion,
        .selected = selected,
        .has_children = has_children,
    });
    return index;
}

fn prepareFolderBranch(
    value: *state.Presentation,
    io: std.Io,
    model: *const state.Model,
    parent_index: usize,
    dir_path: []const u8,
    parent_expansion: types.FolderTreeExpansion,
) !void {
    var children: std.ArrayListUnmanaged(types.FolderTreeChild) = .empty;
    defer {
        fs.clearFolderTreeChildren(&children);
        children.deinit(allocator);
    }
    try fs.collectFolderTreeChildren(io, dir_path, &children);

    for (children.items, 0..) |child, index| {
        if (!model.show_hidden and child.name[0] == '.' and
            !model_ops.pathHasDirectoryPrefix(model.current_dir, child.path)) continue;
        if (!model_ops.shouldRenderFolderTreeChildForExpansion(model, parent_expansion, index, child.path)) continue;
        const expansion = model_ops.folderTreeExpansion(model, child.path);
        const item_index = try appendFolder(
            value,
            child.path,
            parent_index,
            expansion,
            std.mem.eql(u8, child.path, model.current_dir),
            try fs.folderTreeDirectoryHasChildren(
                io,
                child.path,
                model.show_hidden or model_ops.pathHasDirectoryPrefix(model.current_dir, child.path),
            ),
        );
        if (expansion != .collapsed) try prepareFolderBranch(value, io, model, item_index, child.path, expansion);
    }
}

fn prepareFolderTree(value: *state.Presentation, io: ?std.Io, model: *const state.Model) !void {
    const root_expansion = model_ops.folderTreeExpansion(model, "/");
    const root_index = try appendFolder(
        value,
        "/",
        null,
        root_expansion,
        std.mem.eql(u8, model.current_dir, "/"),
        if (io) |available| try fs.folderTreeDirectoryHasChildren(available, "/", model.show_hidden) else false,
    );
    if (io) |available| {
        if (root_expansion != .collapsed) {
            try prepareFolderBranch(value, available, model, root_index, "/", root_expansion);
        }
    }
}

fn currentUnixSeconds(io: ?std.Io) ?i64 {
    const available = io orelse return null;
    return format.unixSecondsFromNanoseconds(std.Io.Clock.real.now(available).nanoseconds);
}

fn sameImage(a: ?image.Pixels, b: ?image.Pixels) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.width == b.?.width and
        a.?.height == b.?.height and
        std.mem.eql(u8, a.?.rgba, b.?.rgba);
}

/// Prepare a complete replacement and publish it only after every allocation
/// succeeds. On error the caller's previous presentation remains intact.
pub fn refresh(
    target: *state.Presentation,
    io: ?std.Io,
    environment: ?*const std.process.Environ.Map,
    model: *const state.Model,
    transfer: *const state.Transfer,
    image_decoder: ?image.Decoder,
) !void {
    var next = state.Presentation{
        .now_unix_seconds = currentUnixSeconds(io),
        .home_available = if (environment) |env| env.get("HOME") != null else false,
        .file_clipboard_available = transfer.clipboard_file_action != null and transfer.clipboard_buf.items.len > 0,
    };
    errdefer deinit(&next);

    try prepareFolderTree(&next, io, model);
    if (io) |available| {
        if (std.Io.Dir.cwd().statFile(available, model.current_dir, .{ .follow_symlinks = true })) |stat| {
            next.current_directory_stat = fs.entryStat(stat);
        } else |_| {}
    }
    const next_preview = try preview.allocSelectionPreview(.{
        .io = io,
        .model = model,
        .image_decoder = image_decoder,
    });
    const image_changed = !sameImage(target.preview.image, next_preview.image);
    next.preview = .{
        .text = next_preview.text,
        .image = next_preview.image,
        .directory = next_preview.directory,
        .image_id = .{
            .value = target.preview.image_id.value,
            .revision = target.preview.image_id.revision +% @intFromBool(image_changed),
        },
        .framed = next_preview.framed,
    };

    std.mem.swap(state.Presentation, target, &next);
    deinit(&next);
}
