//! Cohesive file-browser state owners.
//!
//! Window, graphics, renderer, and platform-presentation state intentionally
//! do not appear here. Renderer-neutral browser presentation data is an
//! explicit domain-owned value below.

const std = @import("std");
const image = @import("goop_image");
const goop = @import("goop");
const types = @import("types.zig");
const ids = @import("ids.zig");

pub const Session = struct {
    running: bool = true,
    io: ?std.Io = null,
    env: ?*const std.process.Environ.Map = null,
};

/// Live visual metrics. Kept separate from Session so projection never gains
/// ambient I/O or environment capabilities merely to read dimensions.
pub const Viewport = struct {
    logical_width: u32 = 800,
    logical_height: u32 = 600,
    ui_scale: f32 = 1,
};

pub const Model = struct {
    current_dir: []u8 = &.{},
    history: std.ArrayListUnmanaged([]u8) = .empty,
    history_index: usize = 0,
    places: std.ArrayListUnmanaged(types.BrowserPlace) = .empty,
    entries: std.ArrayListUnmanaged(types.BrowserEntry) = .empty,
    selected_paths: std.ArrayListUnmanaged([]u8) = .empty,
    selected_path: ?[]u8 = null,
    last_click_path: ?[]u8 = null,
    last_click_ms: u64 = 0,
    selection_anchor_index: ?usize = null,
    sort_column: types.BrowserSortColumn = .name,
    sort_direction: types.BrowserSortDirection = .ascending,
    sort_directories_together: bool = true,
    view_mode: types.BrowserViewMode = .list,
    show_sidebar: bool = true,
    show_preview: bool = true,
    show_info: bool = true,
    show_status_bar: bool = true,
    nav_ratio: f32 = 0.22,
    detail_ratio: f32 = 0.72,
    preview_ratio: f32 = 0.58,
    table_column_weights: [4]f32 = .{ 0.50, 0.22, 0.16, 0.12 },
    sidebar_scroll_x: f32 = 0,
    sidebar_scroll_y: f32 = 0,
    file_panel_scroll_y: f32 = 0,
    folder_tree_expanded_paths: std.ArrayListUnmanaged([]u8) = .empty,
};

pub const LayoutCache = struct {
    file_panel_viewport_width: f32 = 0,
    file_panel_viewport_height: f32 = 0,
    scroll_debug_enabled: bool = false,
    layout_debug_enabled: bool = false,
    scroll_debug_last_scroll_y: f32 = -1000000,
    scroll_debug_last_visible_start: usize = std.math.maxInt(usize),
    scroll_debug_last_visible_end: usize = std.math.maxInt(usize),
    layout_debug_last_header_x: f32 = -1000000,
    layout_debug_last_header_w: f32 = -1000000,
    layout_debug_last_body_x: f32 = -1000000,
    layout_debug_last_body_w: f32 = -1000000,
    layout_debug_last_header_widths: [4]f32 = .{ -1, -1, -1, -1 },
    layout_debug_last_body_widths: [4]f32 = .{ -1, -1, -1, -1 },
};

pub const AssetProjection = struct {
    asset_visible_start: usize = 0,
    asset_visible_end: usize = 0,
    asset_visible_columns: usize = 0,
    folder_tree_paths: std.ArrayListUnmanaged([]u8) = .empty,
    breadcrumb_paths: std.ArrayListUnmanaged([]u8) = .empty,
};

pub const View = struct {
    layout: LayoutCache = .{},
    assets: AssetProjection = .{},
    ui_strings: std.ArrayListUnmanaged([]u8) = .empty,
    asset_ui_strings: std.ArrayListUnmanaged([]u8) = .empty,
    text_measure_ctx: ?*const goop.TextMeasureCtx = null,
};

pub const Interaction = struct {
    context_visible: bool = false,
    context_x: f32 = 0,
    context_y: f32 = 0,
    context_target_path: ?[]u8 = null,
    rename_path: ?[]u8 = null,
    rename_input: goop.TextEditState = .{},
    address_input: goop.TextEditState = .{ .placeholder = "Path" },
    rename_commit_requested: bool = false,
    rename_cancel_requested: bool = false,
    status_note: ?[]const u8 = null,
    pending_command: ?types.BrowserCommand = null,
    address_submit_requested: bool = false,
    ctrl_down: bool = false,
    shift_down: bool = false,
};

/// Renderer-neutral data prepared by the behavior side for visual projection.
/// Every slice here is owned by this value and remains valid until the next
/// successful presentation refresh.
pub const Presentation = struct {
    folder_tree: std.ArrayListUnmanaged(FolderTreeItem) = .empty,
    preview: Preview = .{},
    now_unix_seconds: ?i64 = null,
    home_available: bool = false,
    file_clipboard_available: bool = false,

    pub const FolderTreeItem = struct {
        path: []u8,
        parent_index: ?usize,
        expanded: bool,
        selected: bool,
        has_children: bool,
    };

    pub const Preview = struct {
        text: ?[]u8 = null,
        image: ?image.Pixels = null,
        image_id: image.ResourceId = .{ .value = 0x676f_6f70_7072_6576 },
        framed: bool = false,
    };
};

pub const Transfer = struct {
    clipboard_buf: std.ArrayListUnmanaged(u8) = .empty,
    clipboard_uri_list_buf: std.ArrayListUnmanaged(u8) = .empty,
    clipboard_gnome_files_buf: std.ArrayListUnmanaged(u8) = .empty,
    clipboard_file_action: ?types.FileClipboardAction = null,
    drag_uri_list_buf: std.ArrayListUnmanaged(u8) = .empty,
    drag_plain_buf: std.ArrayListUnmanaged(u8) = .empty,
    drag_gnome_files_buf: std.ArrayListUnmanaged(u8) = .empty,
};

pub const Domain = struct {
    model: Model = .{},
    interaction: Interaction = .{},
    presentation: Presentation = .{},
    identities: ids.Registry = .{},
};

pub const Effects = struct {
    transfer: Transfer = .{},
};

/// Composition-only owner. Application code owns one of these, but behavior,
/// effects, and projection APIs take the focused owners above rather than this
/// aggregate.
pub const Browser = struct {
    session: Session = .{},
    viewport: Viewport = .{},
    domain: Domain = .{},
    effects: Effects = .{},
    projection: View = .{},
};

test "browser state excludes window and graphics ownership" {
    try std.testing.expect(!@hasField(Browser, "display"));
    try std.testing.expect(!@hasField(Browser, "surface"));
    try std.testing.expect(!@hasField(Browser, "renderer"));
    try std.testing.expect(!@hasField(Browser, "swapchain"));
    try std.testing.expect(!@hasField(Session, "ctx"));
    try std.testing.expect(!@hasField(Session, "logical_width"));
    try std.testing.expect(!@hasField(Session, "ui_scale"));
    try std.testing.expect(!@hasField(View, "root_handle"));
}
