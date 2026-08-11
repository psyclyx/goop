const std = @import("std");

pub const BrowserSortColumn = enum(u8) {
    name = 0,
    modified = 1,
    kind = 2,
    size = 3,
};

pub const BrowserSortDirection = enum {
    ascending,
    descending,
};

pub const BrowserViewMode = enum {
    list,
    grid,
};

pub const BrowserCommand = enum {
    back,
    forward,
    up,
    home,
    refresh,
    copy,
    cut,
    paste,
    delete,
    rename,
    move_parent,
    copy_path,
    open_link_target,
    quit,
    select_all,
    clear_selection,
    toggle_sidebar,
    toggle_preview,
    toggle_info,
    toggle_status_bar,
    view_list,
    view_grid,
    toggle_sort_directories,
    about,
};

pub const FileClipboardAction = enum {
    copy,
    cut,
};

/// Opaque icon vocabulary chosen by the file-browser view. Renderers may draw
/// these with paths, sprites, an icon font, or any other graphics API.
pub const DemoIcon = enum(u32) {
    folder = 0,
    file = 1,
    symlink = 2,
    home = 3,
    back = 4,
    up = 5,
    refresh = 6,
    list = 7,
    grid = 8,
    info = 9,
};

pub const BrowserEntryKind = enum {
    directory,
    file,
    symlink,
    other,
};

pub const BrowserPlace = struct {
    label: []const u8,
    path: []u8,
};

pub const FolderTreeChild = struct {
    name: []u8,
    path: []u8,
};

pub const BrowserEntry = struct {
    name: []u8,
    path: []u8,
    kind: BrowserEntryKind,
    size_bytes: u64,
    modified_unix: i64,
    target_path: ?[]u8 = null,
    target_kind: ?BrowserEntryKind = null,

    pub fn typeLabel(self: *const BrowserEntry) []const u8 {
        return switch (self.kind) {
            .directory => "Directory",
            .symlink => switch (self.target_kind orelse .other) {
                .directory => "Symbolic link to Directory",
                .file => "Symbolic link to File",
                .symlink => "Symbolic link",
                .other => if (self.target_path != null) "Broken symbolic link" else "Symbolic link",
            },
            .other => "Special",
            .file => fileTypeLabel(self.name),
        };
    }

    pub fn isDirectory(self: *const BrowserEntry) bool {
        return self.kind == .directory or (self.kind == .symlink and self.target_kind == .directory);
    }

    pub fn isSymlinkToDirectory(self: *const BrowserEntry) bool {
        return self.kind == .symlink and self.target_kind == .directory;
    }

    pub fn canEnter(self: *const BrowserEntry) bool {
        return self.isDirectory();
    }

    pub fn navigationPath(self: *const BrowserEntry) []const u8 {
        if (self.isSymlinkToDirectory()) return self.target_path.?;
        return self.path;
    }

    pub fn previewPath(self: *const BrowserEntry) []const u8 {
        if (self.kind == .symlink and self.target_path != null) return self.target_path.?;
        return self.path;
    }
};

pub const ListVirtualWindow = struct {
    start: usize = 0,
    end: usize = 0,
    top_spacer: f32 = 0,
    bottom_spacer: f32 = 0,
    scroll_y: f32 = 0,
    content_height: f32 = 0,
};

pub const GridVirtualWindow = struct {
    start: usize = 0,
    end: usize = 0,
    columns: usize = 1,
    top_spacer: f32 = 0,
    bottom_spacer: f32 = 0,
    scroll_y: f32 = 0,
    content_height: f32 = 0,
};

pub const FolderTreeExpansion = enum {
    collapsed,
    partial,
    expanded,
};

pub const browser_grid_item_width: f32 = 132;
pub const browser_grid_item_height: f32 = 108;
pub const browser_grid_column_gap: f32 = 12;
pub const browser_grid_row_gap: f32 = 12;
pub const browser_grid_padding_h: f32 = 10;
pub const browser_grid_padding_v: f32 = 10;
pub const browser_overscan_rows: usize = 3;
pub const browser_virtual_chunk_rows_min: usize = 24;
pub const browser_double_click_time_ms: u64 = 400;
pub const browser_table_divider_width: f32 = 1;
pub const browser_name_icon_inset_left: f32 = 4;
pub const browser_name_text_inset_left: f32 = 28;
pub const folder_tree_max_visible_children: usize = 128;

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
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "WebP image";
    if (std.ascii.eqlIgnoreCase(ext, ".svg")) return "SVG";
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return "PDF";
    if (std.ascii.eqlIgnoreCase(ext, ".so")) return "Shared library";
    if (std.ascii.eqlIgnoreCase(ext, ".a")) return "Static library";
    if (std.ascii.eqlIgnoreCase(ext, ".o")) return "Object file";
    return "File";
}

test "native preview image extensions have specific labels" {
    try std.testing.expectEqualStrings("PNG image", fileTypeLabel("probe.PNG"));
    try std.testing.expectEqualStrings("JPEG image", fileTypeLabel("probe.jpeg"));
    try std.testing.expectEqualStrings("WebP image", fileTypeLabel("probe.WeBp"));
}
