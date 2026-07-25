//! Cohesive file-browser state owners.
//!
//! Window, graphics, renderer, and presentation state intentionally do not
//! appear here.

const std = @import("std");
const goop = @import("goop");
const types = @import("types.zig");

pub const Runtime = struct {
    running: bool = true,
    logical_width: u32 = 800,
    logical_height: u32 = 600,
    io: ?std.Io = null,
    env: ?*const std.process.Environ.Map = null,
    ui_scale: f32 = 1,
    ctx: ?*goop.Context = null,
    text_measure_ctx: ?*const goop.TextMeasureCtx = null,
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
};

pub const LayoutCache = struct {
    file_panel_viewport_width: f32 = 0,
    file_panel_viewport_height: f32 = 0,
    scroll_debug_enabled: bool = false,
    layout_debug_enabled: bool = false,
    scroll_debug_last_scroll_y: f32 = -1000000,
    scroll_debug_last_visible_start: usize = std.math.maxInt(usize),
    scroll_debug_last_visible_end: usize = std.math.maxInt(usize),
    layout_debug_last_focus_index: u32 = std.math.maxInt(u32),
    layout_debug_last_header_x: f32 = -1000000,
    layout_debug_last_header_w: f32 = -1000000,
    layout_debug_last_body_x: f32 = -1000000,
    layout_debug_last_body_w: f32 = -1000000,
    layout_debug_last_header_widths: [4]f32 = .{ -1, -1, -1, -1 },
    layout_debug_last_body_widths: [4]f32 = .{ -1, -1, -1, -1 },
};

pub const ChromeHandles = struct {
    ui_root: ?goop.NodeHandle = null,
    btn_back: ?goop.NodeHandle = null,
    btn_forward: ?goop.NodeHandle = null,
    btn_up: ?goop.NodeHandle = null,
    btn_home: ?goop.NodeHandle = null,
    btn_refresh: ?goop.NodeHandle = null,
    btn_toggle_sidebar: ?goop.NodeHandle = null,
    btn_toggle_preview: ?goop.NodeHandle = null,
    btn_toggle_info: ?goop.NodeHandle = null,
    btn_list_view: ?goop.NodeHandle = null,
    btn_grid_view: ?goop.NodeHandle = null,
    btn_address_go: ?goop.NodeHandle = null,
    address_input_handle: ?goop.NodeHandle = null,
    nav_splitter: ?goop.NodeHandle = null,
    detail_splitter: ?goop.NodeHandle = null,
    preview_splitter: ?goop.NodeHandle = null,
    sidebar_scroll: ?goop.NodeHandle = null,
    file_panel_scroll: ?goop.NodeHandle = null,
};

pub const AssetHandles = struct {
    asset_view_root: ?goop.NodeHandle = null,
    asset_table: ?goop.NodeHandle = null,
    asset_table_body: ?goop.NodeHandle = null,
    asset_grid: ?goop.NodeHandle = null,
    asset_visible_start: usize = 0,
    asset_visible_end: usize = 0,
    asset_visible_columns: usize = 0,
    place_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    folder_tree_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    breadcrumb_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    folder_tree_paths: std.ArrayListUnmanaged([]u8) = .empty,
    folder_tree_expanded_paths: std.ArrayListUnmanaged([]u8) = .empty,
    breadcrumb_paths: std.ArrayListUnmanaged([]u8) = .empty,
    row_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    name_cell_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    grid_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
};

pub const FileMenuHandles = struct {
    button: ?goop.NodeHandle = null,
    popup: ?goop.NodeHandle = null,
    refresh: ?goop.NodeHandle = null,
    copy_path: ?goop.NodeHandle = null,
    open_target: ?goop.NodeHandle = null,
    quit: ?goop.NodeHandle = null,
};

pub const EditMenuHandles = struct {
    button: ?goop.NodeHandle = null,
    popup: ?goop.NodeHandle = null,
    copy: ?goop.NodeHandle = null,
    cut: ?goop.NodeHandle = null,
    paste: ?goop.NodeHandle = null,
    delete: ?goop.NodeHandle = null,
    rename: ?goop.NodeHandle = null,
    move_parent: ?goop.NodeHandle = null,
    select_all: ?goop.NodeHandle = null,
    clear_selection: ?goop.NodeHandle = null,
};

pub const ViewMenuHandles = struct {
    button: ?goop.NodeHandle = null,
    popup: ?goop.NodeHandle = null,
    sidebar: ?goop.NodeHandle = null,
    preview: ?goop.NodeHandle = null,
    info: ?goop.NodeHandle = null,
    status_bar: ?goop.NodeHandle = null,
    list: ?goop.NodeHandle = null,
    grid: ?goop.NodeHandle = null,
    sort_directories: ?goop.NodeHandle = null,
};

pub const GoMenuHandles = struct {
    button: ?goop.NodeHandle = null,
    popup: ?goop.NodeHandle = null,
    back: ?goop.NodeHandle = null,
    forward: ?goop.NodeHandle = null,
    up: ?goop.NodeHandle = null,
    home: ?goop.NodeHandle = null,
};

pub const HelpMenuHandles = struct {
    button: ?goop.NodeHandle = null,
    popup: ?goop.NodeHandle = null,
    about: ?goop.NodeHandle = null,
};

pub const MenuHandles = struct {
    file: FileMenuHandles = .{},
    edit: EditMenuHandles = .{},
    view: ViewMenuHandles = .{},
    go: GoMenuHandles = .{},
    help: HelpMenuHandles = .{},
};

pub const ContextMenuHandles = struct {
    context_popup: ?goop.NodeHandle = null,
    context_open: ?goop.NodeHandle = null,
    context_copy: ?goop.NodeHandle = null,
    context_cut: ?goop.NodeHandle = null,
    context_paste: ?goop.NodeHandle = null,
    context_delete: ?goop.NodeHandle = null,
    context_rename: ?goop.NodeHandle = null,
    context_move_parent: ?goop.NodeHandle = null,
    context_copy_path: ?goop.NodeHandle = null,
    context_open_link_target: ?goop.NodeHandle = null,
};

pub const View = struct {
    layout: LayoutCache = .{},
    chrome: ChromeHandles = .{},
    assets: AssetHandles = .{},
    menus: MenuHandles = .{},
    context_menu: ContextMenuHandles = .{},
    ui_strings: std.ArrayListUnmanaged([]u8) = .empty,
    asset_ui_strings: std.ArrayListUnmanaged([]u8) = .empty,
    composed_paint_commands: std.ArrayListUnmanaged(goop.PaintCommand) = .empty,
    address_input: goop.widget.WidgetKind.TextInput = .{ .placeholder = "Path" },
};

pub const Interaction = struct {
    context_visible: bool = false,
    context_x: f32 = 0,
    context_y: f32 = 0,
    context_target_path: ?[]u8 = null,
    rename_input_handle: ?goop.NodeHandle = null,
    rename_path: ?[]u8 = null,
    rename_input: goop.widget.WidgetKind.TextInput = .{},
    rename_commit_requested: bool = false,
    rename_cancel_requested: bool = false,
    asset_selection_rebuild_pending: bool = false,
    asset_drag_source_path: ?[]u8 = null,
    asset_drop_target_path: ?[]u8 = null,
    primary_release_pending: bool = false,
    primary_release_x: f32 = 0,
    primary_release_y: f32 = 0,
    status_note: ?[]const u8 = null,
    pending_command: ?types.BrowserCommand = null,
    address_submit_requested: bool = false,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    ctrl_down: bool = false,
    shift_down: bool = false,
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

pub const State = struct {
    runtime: Runtime = .{},
    model: Model = .{},
    view: View = .{},
    interaction: Interaction = .{},
    transfer: Transfer = .{},
};

test "browser state excludes window and graphics ownership" {
    try std.testing.expect(!@hasField(State, "display"));
    try std.testing.expect(!@hasField(State, "surface"));
    try std.testing.expect(!@hasField(State, "renderer"));
    try std.testing.expect(!@hasField(State, "swapchain"));
}
