//! Owned, renderer-neutral scratch used while projecting browser state.

const std = @import("std");
const goop = @import("goop");
const state = @import("state.zig");

pub const allocator = std.heap.smp_allocator;

pub fn configure(view: *state.View, text_measure: *const goop.TextMeasureCtx) void {
    view.text_measure_ctx = text_measure;
}

pub fn clearTrackedPaths(paths: *std.ArrayListUnmanaged([]u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.clearRetainingCapacity();
}

pub fn clearUi(view: *state.View) void {
    for (view.ui_strings.items) |text| allocator.free(text);
    view.ui_strings.clearRetainingCapacity();
    clearAsset(view);
    clearTrackedPaths(&view.assets.folder_tree_paths);
    clearTrackedPaths(&view.assets.breadcrumb_paths);
}

pub fn clearAsset(view: *state.View) void {
    for (view.asset_ui_strings.items) |text| allocator.free(text);
    view.asset_ui_strings.clearRetainingCapacity();
    view.assets.asset_visible_start = 0;
    view.assets.asset_visible_end = 0;
    view.assets.asset_visible_columns = 0;
}

pub fn deinit(view: *state.View) void {
    clearUi(view);
    view.assets.folder_tree_paths.deinit(allocator);
    view.assets.breadcrumb_paths.deinit(allocator);
    view.ui_strings.deinit(allocator);
    view.asset_ui_strings.deinit(allocator);
    view.* = .{};
}

/// Takes ownership of `text`, including when tracking fails.
pub fn trackUiString(view: *state.View, text: []u8) ![]const u8 {
    errdefer allocator.free(text);
    try view.ui_strings.append(allocator, text);
    return text;
}

/// Takes ownership of `text`, including when tracking fails.
pub fn trackAssetUiString(view: *state.View, text: []u8) ![]const u8 {
    errdefer allocator.free(text);
    try view.asset_ui_strings.append(allocator, text);
    return text;
}

pub fn trackPath(paths: *std.ArrayListUnmanaged([]u8), path: []const u8) !void {
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try paths.append(allocator, owned);
}

pub fn allocUiString(view: *state.View, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return trackUiString(view, try std.fmt.allocPrint(allocator, fmt, args));
}

pub fn allocAssetUiString(view: *state.View, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return trackAssetUiString(view, try std.fmt.allocPrint(allocator, fmt, args));
}

pub fn allocUtf8LossyOwned(bytes: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.unicode.fmtUtf8(bytes)});
}

pub fn allocUiUtf8Lossy(view: *state.View, bytes: []const u8) ![]const u8 {
    return trackUiString(view, try allocUtf8LossyOwned(bytes));
}

pub fn allocAssetUiEllipsizedUtf8Lossy(
    view: *state.View,
    bytes: []const u8,
    max_width: f32,
    font_size: f32,
) ![]const u8 {
    const full = try allocUtf8LossyOwned(bytes);
    var owns_full = true;
    errdefer if (owns_full) allocator.free(full);
    const text_ctx = view.text_measure_ctx;
    if (text_ctx == null or goop.layout.measureTextDimensions(full, font_size, text_ctx).width <= max_width) {
        owns_full = false;
        return trackAssetUiString(view, full);
    }

    const ellipsis = "...";
    const ellipsis_width = goop.layout.measureTextDimensions(ellipsis, font_size, text_ctx).width;
    if (ellipsis_width >= max_width) {
        allocator.free(full);
        owns_full = false;
        return allocAssetUiString(view, "{s}", .{ellipsis});
    }

    var ends: std.ArrayListUnmanaged(usize) = .empty;
    defer ends.deinit(allocator);
    var total: usize = 0;
    var utf8 = std.unicode.Utf8View.init(full) catch unreachable;
    var iterator = utf8.iterator();
    while (iterator.nextCodepointSlice()) |slice| {
        total += slice.len;
        try ends.append(allocator, total);
    }

    var keep = ends.items.len;
    while (keep > 0) : (keep -= 1) {
        const prefix_len = ends.items[keep - 1];
        const prefix_width = goop.layout.measureTextDimensions(full[0..prefix_len], font_size, text_ctx).width;
        if (prefix_width + ellipsis_width <= max_width) {
            const truncated = try std.fmt.allocPrint(allocator, "{s}{s}", .{ full[0..prefix_len], ellipsis });
            allocator.free(full);
            owns_full = false;
            return trackAssetUiString(view, truncated);
        }
    }

    allocator.free(full);
    owns_full = false;
    return allocAssetUiString(view, "{s}", .{ellipsis});
}
