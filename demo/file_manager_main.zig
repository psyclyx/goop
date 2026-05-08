const std = @import("std");
const goop = @import("goop");
const snail = @import("snail");
const render = @import("render.zig");
const posix = std.posix;

const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-cursor.h");
    @cInclude("wayland-egl.h");
    @cInclude("xdg-shell-client-protocol.h");
});

const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

const egl = @cImport({
    @cInclude("EGL/egl.h");
});

const allocator = std.heap.page_allocator;
const clipboard_mime_utf8 = "text/plain;charset=utf-8";
const clipboard_mime_utf8_string = "UTF8_STRING";
const clipboard_mime_text = "text/plain";
const dnd_mime_uri_list = "text/uri-list";
const dnd_mime_gnome_copied_files = "x-special/gnome-copied-files";

/// Snail-based text measurement adapter for goop.
const SnailTextCtx = struct {
    allocator: std.mem.Allocator,
    text_atlas: *const snail.TextAtlas,
    scratch_buf: []u8,
    ascent_units: f32,
    descent_units: f32,

    fn ensureScratchCapacity(self: *SnailTextCtx, byte_len: usize) !void {
        if (self.scratch_buf.len >= byte_len) return;
        const next_len = std.math.ceilPowerOfTwo(usize, @max(byte_len, 64)) catch @max(byte_len, 64);
        self.scratch_buf = try self.allocator.realloc(self.scratch_buf, next_len);
    }

    fn sanitizeUtf8Lossy(self: *SnailTextCtx, text: []const u8) []const u8 {
        if (std.unicode.Utf8View.init(text)) |_| return text else |_| {}

        var out_len: usize = 0;
        var index: usize = 0;
        while (index < text.len) {
            const cp = blk: {
                const cp_len = std.unicode.utf8ByteSequenceLength(text[index]) catch {
                    index += 1;
                    break :blk std.unicode.replacement_character;
                };
                if (index + cp_len > text.len) {
                    index += 1;
                    break :blk std.unicode.replacement_character;
                }
                const slice = text[index .. index + cp_len];
                const decoded = std.unicode.utf8Decode(slice) catch {
                    index += 1;
                    break :blk std.unicode.replacement_character;
                };
                index += cp_len;
                break :blk decoded;
            };

            var encoded: [4]u8 = undefined;
            const encoded_len = std.unicode.utf8Encode(cp, &encoded) catch 0;
            self.ensureScratchCapacity(out_len + encoded_len) catch return text;
            @memcpy(self.scratch_buf[out_len..][0..encoded_len], encoded[0..encoded_len]);
            out_len += encoded_len;
        }

        return self.scratch_buf[0..out_len];
    }

    fn fallbackWidth(text: []const u8, font_size: f32) f32 {
        const glyphs = std.unicode.utf8CountCodepoints(text) catch text.len;
        return @as(f32, @floatFromInt(glyphs)) * font_size * 0.6;
    }
};

const OutputState = struct {
    global_name: u32,
    output: *wl.wl_output,
    scale: u32 = 1,
    entered: bool = false,
    next: ?*OutputState = null,
};

const CursorKind = enum {
    default,
    pointer,
    text,
    ew_resize,
    ns_resize,
};

fn snailMeasureText(text: []const u8, font_size: f32, user_data: ?*anyopaque) goop.TextDimensions {
    const ctx: *SnailTextCtx = @ptrCast(@alignCast(user_data));
    const sanitized = ctx.sanitizeUtf8Lossy(text);
    const units_per_em = ctx.text_atlas.unitsPerEm() catch 1000;
    const scale = font_size / @as(f32, @floatFromInt(units_per_em));
    const width = ctx.text_atlas.measureText(.{}, sanitized, font_size) catch SnailTextCtx.fallbackWidth(sanitized, font_size);

    return .{
        .width = width,
        .height = (ctx.ascent_units + ctx.descent_units) * scale,
        .ascent = ctx.ascent_units * scale,
        .descent = ctx.descent_units * scale,
    };
}

fn fontLineMetrics(text_atlas: *const snail.TextAtlas) struct { ascent: f32, descent: f32 } {
    const metrics = text_atlas.lineMetrics() catch {
        const units_per_em = text_atlas.unitsPerEm() catch 1000;
        return .{ .ascent = @floatFromInt(units_per_em), .descent = 0 };
    };
    return .{
        .ascent = @floatFromInt(metrics.ascent),
        .descent = @floatFromInt(@abs(metrics.descent)),
    };
}

fn isPrintableTextCodepoint(codepoint: u32) bool {
    if (codepoint > std.math.maxInt(u21)) return false;
    if (!std.unicode.utf8ValidCodepoint(@intCast(codepoint))) return false;
    if (codepoint < 0x20) return false;
    if (codepoint >= 0x7F and codepoint < 0xA0) return false;
    return true;
}

fn ensureAtlasForPaintList(text_atlas: *snail.TextAtlas, renderer: *render.Renderer, paint_list: goop.PaintList) !bool {
    var changed = false;
    for (paint_list.commands) |command| {
        if (command != .text) continue;
        const text = command.text.text;
        if (text.len == 0) continue;

        if (try text_atlas.ensureText(.{}, text)) |next_atlas| {
            text_atlas.deinit();
            text_atlas.* = next_atlas;
            changed = true;
        }
    }

    if (changed) renderer.uploadAtlas(text_atlas);
    return changed;
}

const BrowserSortColumn = enum(u8) {
    name = 0,
    modified = 1,
    kind = 2,
    size = 3,
};

const BrowserSortDirection = enum {
    ascending,
    descending,
};

const BrowserViewMode = enum {
    list,
    grid,
};

const BrowserCommand = enum {
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

const FileClipboardAction = enum {
    copy,
    cut,
};

const BrowserEntryKind = enum {
    directory,
    file,
    symlink,
    other,
};

const BrowserPlace = struct {
    label: []const u8,
    path: []u8,
};

const FolderTreeChild = struct {
    name: []u8,
    path: []u8,
};

const BrowserEntry = struct {
    name: []u8,
    path: []u8,
    kind: BrowserEntryKind,
    size_bytes: u64,
    modified_unix: i64,
    target_path: ?[]u8 = null,
    target_kind: ?BrowserEntryKind = null,

    fn typeLabel(self: *const BrowserEntry) []const u8 {
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

    fn isDirectory(self: *const BrowserEntry) bool {
        return self.kind == .directory or (self.kind == .symlink and self.target_kind == .directory);
    }

    fn isSymlinkToDirectory(self: *const BrowserEntry) bool {
        return self.kind == .symlink and self.target_kind == .directory;
    }

    fn canEnter(self: *const BrowserEntry) bool {
        return self.isDirectory();
    }

    fn navigationPath(self: *const BrowserEntry) []const u8 {
        if (self.isSymlinkToDirectory()) return self.target_path.?;
        return self.path;
    }

    fn previewPath(self: *const BrowserEntry) []const u8 {
        if (self.kind == .symlink and self.target_path != null) return self.target_path.?;
        return self.path;
    }
};

const ListVirtualWindow = struct {
    start: usize = 0,
    end: usize = 0,
    top_spacer: f32 = 0,
    bottom_spacer: f32 = 0,
    scroll_y: f32 = 0,
};

const GridVirtualWindow = struct {
    start: usize = 0,
    end: usize = 0,
    columns: usize = 1,
    top_spacer: f32 = 0,
    bottom_spacer: f32 = 0,
    scroll_y: f32 = 0,
};

const browser_grid_item_width: f32 = 132;
const browser_grid_item_height: f32 = 108;
const browser_grid_column_gap: f32 = 12;
const browser_grid_row_gap: f32 = 12;
const browser_grid_padding_h: f32 = 10;
const browser_grid_padding_v: f32 = 10;
const browser_overscan_rows: usize = 3;
const browser_virtual_chunk_rows_min: usize = 24;
const browser_double_click_time_ms: u64 = 400;
const browser_table_divider_width: f32 = 1;
const browser_name_icon_inset_left: f32 = 4;
const browser_name_text_inset_left: f32 = 28;
const folder_tree_max_visible_children: usize = 128;

const PopupSurface = struct {
    owner: *State,
    handle: goop.NodeHandle,
    surface: *wl.wl_surface,
    xdg_surface: *wl.xdg_surface,
    xdg_popup: *wl.xdg_popup,
    egl_window: *wl.wl_egl_window,
    egl_surface: egl.EGLSurface,
    rect: goop.draw.Rect,
    buffer_width: u32,
    buffer_height: u32,
    parent_popup: ?goop.NodeHandle,
    configured: bool = false,
    configured_width: u32 = 0,
    configured_height: u32 = 0,
    next: ?*PopupSurface = null,
};

fn envFlag(env: *const std.process.Environ.Map, name: []const u8) bool {
    const raw = env.get(name) orelse return false;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    if (std.ascii.eqlIgnoreCase(value, "off")) return false;
    if (std.ascii.eqlIgnoreCase(value, "no")) return false;
    return true;
}

fn envScale(env: *const std.process.Environ.Map, name: []const u8, fallback: f32) f32 {
    const raw = env.get(name) orelse return fallback;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return fallback;
    const parsed = std.fmt.parseFloat(f32, value) catch return fallback;
    if (!std.math.isFinite(parsed) or parsed <= 0) return fallback;
    return parsed;
}

const State = struct {
    running: bool = true,
    configured: bool = false,
    logical_width: u32 = 800,
    logical_height: u32 = 600,
    buffer_width: u32 = 800,
    buffer_height: u32 = 600,
    buffer_scale: u32 = 1,
    compositor_version: u32 = 0,
    surface_preferred_scale: ?u32 = null,
    needs_redraw: bool = true,
    frame_pending: bool = false,
    timeout_ns: ?u64 = null,
    start_time_ns: u64 = 0,
    io: ?std.Io = null,
    env: ?*const std.process.Environ.Map = null,
    ui_scale: f32 = 1,

    // Wayland globals
    display: ?*wl.wl_display = null,
    compositor: ?*wl.wl_compositor = null,
    wm_base: ?*wl.xdg_wm_base = null,
    seat: ?*wl.wl_seat = null,
    shm: ?*wl.wl_shm = null,
    data_device_manager: ?*wl.wl_data_device_manager = null,
    data_device_manager_version: u32 = 0,
    outputs: ?*OutputState = null,

    // Wayland surface chain
    surface: ?*wl.wl_surface = null,
    cursor_surface: ?*wl.wl_surface = null,
    xdg_surface: ?*wl.xdg_surface = null,
    xdg_toplevel: ?*wl.xdg_toplevel = null,
    egl_window: ?*wl.wl_egl_window = null,
    popup_surfaces: ?*PopupSurface = null,
    pointer: ?*wl.wl_pointer = null,
    cursor_theme: ?*wl.wl_cursor_theme = null,
    cursor_theme_scale: u32 = 0,
    pointer_enter_serial: u32 = 0,
    pointer_inside: bool = false,
    pointer_surface_offset_x: f32 = 0,
    pointer_surface_offset_y: f32 = 0,
    cursor_kind: CursorKind = .default,
    keyboard: ?*wl.wl_keyboard = null,
    data_device: ?*wl.wl_data_device = null,
    clipboard_source: ?*wl.wl_data_source = null,
    drag_source: ?*wl.wl_data_source = null,
    selection_offer: ?*DataOfferState = null,
    drag_offer: ?*DataOfferState = null,
    data_offers: ?*DataOfferState = null,
    last_input_serial: u32 = 0,
    last_pointer_button_serial: u32 = 0,

    // EGL
    egl_display: egl.EGLDisplay = egl.EGL_NO_DISPLAY,
    egl_config: egl.EGLConfig = null,
    egl_surface: egl.EGLSurface = egl.EGL_NO_SURFACE,
    egl_context: egl.EGLContext = egl.EGL_NO_CONTEXT,

    // goop
    ctx: ?*goop.Context = null,

    // File browser model
    current_dir: []u8 = &.{},
    history: std.ArrayListUnmanaged([]u8) = .empty,
    history_index: usize = 0,
    places: std.ArrayListUnmanaged(BrowserPlace) = .empty,
    entries: std.ArrayListUnmanaged(BrowserEntry) = .empty,
    selected_paths: std.ArrayListUnmanaged([]u8) = .empty,
    selected_path: ?[]u8 = null,
    last_click_path: ?[]u8 = null,
    last_click_ms: u64 = 0,
    selection_anchor_index: ?usize = null,
    sort_column: BrowserSortColumn = .name,
    sort_direction: BrowserSortDirection = .ascending,
    sort_directories_together: bool = true,
    view_mode: BrowserViewMode = .list,
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

    // Dynamic UI state
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
    menu_file_refresh: ?goop.NodeHandle = null,
    menu_file_button: ?goop.NodeHandle = null,
    menu_edit_button: ?goop.NodeHandle = null,
    menu_view_button: ?goop.NodeHandle = null,
    menu_go_button: ?goop.NodeHandle = null,
    menu_help_button: ?goop.NodeHandle = null,
    menu_file_popup: ?goop.NodeHandle = null,
    menu_edit_popup: ?goop.NodeHandle = null,
    menu_view_popup: ?goop.NodeHandle = null,
    menu_go_popup: ?goop.NodeHandle = null,
    menu_help_popup: ?goop.NodeHandle = null,
    menu_file_copy_path: ?goop.NodeHandle = null,
    menu_file_open_target: ?goop.NodeHandle = null,
    menu_file_quit: ?goop.NodeHandle = null,
    menu_edit_copy: ?goop.NodeHandle = null,
    menu_edit_cut: ?goop.NodeHandle = null,
    menu_edit_paste: ?goop.NodeHandle = null,
    menu_edit_delete: ?goop.NodeHandle = null,
    menu_edit_rename: ?goop.NodeHandle = null,
    menu_edit_move_parent: ?goop.NodeHandle = null,
    menu_edit_select_all: ?goop.NodeHandle = null,
    menu_edit_clear_selection: ?goop.NodeHandle = null,
    menu_view_sidebar: ?goop.NodeHandle = null,
    menu_view_preview: ?goop.NodeHandle = null,
    menu_view_info: ?goop.NodeHandle = null,
    menu_view_status_bar: ?goop.NodeHandle = null,
    menu_view_list: ?goop.NodeHandle = null,
    menu_view_grid: ?goop.NodeHandle = null,
    menu_view_sort_directories: ?goop.NodeHandle = null,
    menu_go_back: ?goop.NodeHandle = null,
    menu_go_forward: ?goop.NodeHandle = null,
    menu_go_up: ?goop.NodeHandle = null,
    menu_go_home: ?goop.NodeHandle = null,
    menu_help_about: ?goop.NodeHandle = null,
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
    row_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    name_cell_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    grid_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    ui_strings: std.ArrayListUnmanaged([]u8) = .empty,
    asset_ui_strings: std.ArrayListUnmanaged([]u8) = .empty,
    composed_paint_commands: std.ArrayListUnmanaged(goop.PaintCommand) = .empty,
    address_input: goop.widget.WidgetKind.TextInput = .{ .placeholder = "Path" },
    status_note: ?[]const u8 = null,
    pending_command: ?BrowserCommand = null,
    address_submit_requested: bool = false,

    // Last known mouse position from Wayland pointer events
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    left_ctrl_down: bool = false,
    right_ctrl_down: bool = false,
    left_shift_down: bool = false,
    right_shift_down: bool = false,
    ctrl_down: bool = false,
    shift_down: bool = false,
    text_measure_ctx: ?*const goop.TextMeasureCtx = null,

    // xkbcommon state for keymap → text conversion
    xkb_ctx: ?*xkb.xkb_context = null,
    xkb_keymap: ?*xkb.xkb_keymap = null,
    xkb_state: ?*xkb.xkb_state = null,

    // Clipboard text for self-owned selections and the most recent external paste.
    clipboard_buf: std.ArrayListUnmanaged(u8) = .empty,
    clipboard_uri_list_buf: std.ArrayListUnmanaged(u8) = .empty,
    clipboard_gnome_files_buf: std.ArrayListUnmanaged(u8) = .empty,
    clipboard_file_action: ?FileClipboardAction = null,
    drag_uri_list_buf: std.ArrayListUnmanaged(u8) = .empty,
    drag_plain_buf: std.ArrayListUnmanaged(u8) = .empty,
    drag_gnome_files_buf: std.ArrayListUnmanaged(u8) = .empty,

    fn clipboard(self: *State) goop.Clipboard {
        return .{
            .ptr = @ptrCast(self),
            .getTextFn = @ptrCast(&clipboardGetText),
            .setTextFn = @ptrCast(&clipboardSetText),
        };
    }

    fn clipboardGetText(ptr: *anyopaque) ?[]const u8 {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.clipboard_source != null) {
            if (self.clipboard_buf.items.len == 0) return null;
            return self.clipboard_buf.items;
        }
        self.fetchClipboardSelection(false) catch return null;
        if (self.clipboard_buf.items.len == 0) return null;
        return self.clipboard_buf.items;
    }

    fn clipboardSetText(ptr: *anyopaque, text: []const u8) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.setClipboardSelection(text) catch {};
    }

    fn setClipboardSelection(self: *State, text: []const u8) !void {
        self.clearClipboardFilePayload();
        try self.setClipboardBuffer(text);
        if (self.data_device_manager == null or self.data_device == null or self.last_input_serial == 0) return;

        self.destroyClipboardSource();

        const source = wl.wl_data_device_manager_create_data_source(self.data_device_manager) orelse return;
        self.clipboard_source = source;
        _ = wl.wl_data_source_add_listener(source, &data_source_listener, self);
        wl.wl_data_source_offer(source, clipboard_mime_utf8);
        wl.wl_data_source_offer(source, clipboard_mime_utf8_string);
        wl.wl_data_source_offer(source, clipboard_mime_text);
        wl.wl_data_device_set_selection(self.data_device, source, self.last_input_serial);
        if (self.display) |display| _ = wl.wl_display_flush(display);
    }

    fn setFileClipboardSelection(self: *State, paths: []const []const u8, action: FileClipboardAction) !void {
        if (paths.len == 0) return;
        try self.setClipboardFilePayload(paths, action);
        if (self.data_device_manager == null or self.data_device == null or self.last_input_serial == 0) return;

        self.destroyClipboardSource();

        const source = wl.wl_data_device_manager_create_data_source(self.data_device_manager) orelse return;
        self.clipboard_source = source;
        _ = wl.wl_data_source_add_listener(source, &data_source_listener, self);
        wl.wl_data_source_offer(source, dnd_mime_uri_list);
        wl.wl_data_source_offer(source, dnd_mime_gnome_copied_files);
        wl.wl_data_source_offer(source, clipboard_mime_utf8);
        wl.wl_data_source_offer(source, clipboard_mime_utf8_string);
        wl.wl_data_source_offer(source, clipboard_mime_text);
        wl.wl_data_device_set_selection(self.data_device, source, self.last_input_serial);
        if (self.display) |display| _ = wl.wl_display_flush(display);
    }

    fn fetchClipboardSelection(self: *State, prefer_files: bool) !void {
        const offer = self.selection_offer orelse return;
        const mime = (if (prefer_files) preferredFileOfferMime(offer) else preferredTextOfferMime(offer)) orelse return;

        var fds: [2]posix.fd_t = undefined;
        if (posix.system.pipe(&fds) != 0) return error.PipeFailed;
        errdefer closeFd(fds[0]);
        errdefer closeFd(fds[1]);

        wl.wl_data_offer_receive(offer.offer, mime, fds[1]);
        closeFd(fds[1]);
        if (self.display) |display| _ = wl.wl_display_flush(display);

        self.clipboard_buf.clearRetainingCapacity();
        var chunk: [4096]u8 = undefined;
        while (true) {
            const read_count = posix.read(fds[0], &chunk) catch break;
            if (read_count == 0) break;
            try self.clipboard_buf.appendSlice(allocator, chunk[0..read_count]);
        }
        closeFd(fds[0]);
    }

    fn setClipboardBuffer(self: *State, text: []const u8) !void {
        self.clipboard_buf.clearRetainingCapacity();
        try self.clipboard_buf.appendSlice(allocator, text);
    }

    fn clearClipboardFilePayload(self: *State) void {
        self.clipboard_uri_list_buf.clearRetainingCapacity();
        self.clipboard_gnome_files_buf.clearRetainingCapacity();
        self.clipboard_file_action = null;
    }

    fn setClipboardFilePayload(self: *State, paths: []const []const u8, action: FileClipboardAction) !void {
        self.clipboard_buf.clearRetainingCapacity();
        self.clipboard_uri_list_buf.clearRetainingCapacity();
        self.clipboard_gnome_files_buf.clearRetainingCapacity();
        self.clipboard_file_action = action;

        try self.clipboard_gnome_files_buf.appendSlice(allocator, if (action == .cut) "cut\n" else "copy\n");
        for (paths) |path| {
            try appendFileUri(&self.clipboard_uri_list_buf, path, "\r\n");
            try appendFileUri(&self.clipboard_gnome_files_buf, path, "\n");
            try self.clipboard_buf.appendSlice(allocator, path);
            try self.clipboard_buf.append(allocator, '\n');
        }
    }

    fn clearDragPayload(self: *State) void {
        self.drag_uri_list_buf.clearRetainingCapacity();
        self.drag_plain_buf.clearRetainingCapacity();
        self.drag_gnome_files_buf.clearRetainingCapacity();
    }

    fn setDragPayloadPaths(self: *State, paths: []const []const u8) !void {
        self.clearDragPayload();
        try self.drag_gnome_files_buf.appendSlice(allocator, "copy\n");
        for (paths) |path| {
            try appendFileUri(&self.drag_uri_list_buf, path, "\r\n");
            try appendFileUri(&self.drag_gnome_files_buf, path, "\n");
            try self.drag_plain_buf.appendSlice(allocator, path);
            try self.drag_plain_buf.append(allocator, '\n');
        }
    }

    fn destroyDragSource(self: *State) void {
        if (self.drag_source) |source| {
            wl.wl_data_source_destroy(source);
            self.drag_source = null;
        }
        self.clearDragPayload();
    }

    fn clearFinishedDragSource(self: *State, source: ?*wl.wl_data_source) void {
        if (self.drag_source != source) return;
        self.drag_source = null;
        self.clearDragPayload();
    }

    fn startWaylandFileDrag(self: *State, paths: []const []const u8) !bool {
        if (paths.len == 0) return false;
        if (self.drag_source != null) return false;
        if (self.data_device_manager == null or self.data_device == null or self.surface == null) return false;
        const serial = if (self.last_pointer_button_serial != 0) self.last_pointer_button_serial else self.last_input_serial;
        if (serial == 0) return false;

        try self.setDragPayloadPaths(paths);
        const source = wl.wl_data_device_manager_create_data_source(self.data_device_manager) orelse return false;
        errdefer wl.wl_data_source_destroy(source);

        self.drag_source = source;
        _ = wl.wl_data_source_add_listener(source, &data_source_listener, self);
        wl.wl_data_source_offer(source, dnd_mime_uri_list);
        wl.wl_data_source_offer(source, dnd_mime_gnome_copied_files);
        wl.wl_data_source_offer(source, clipboard_mime_text);
        if (self.data_device_manager_version >= 3) {
            wl.wl_data_source_set_actions(source, wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
        }
        wl.wl_data_device_start_drag(self.data_device, source, self.surface, null, serial);
        if (self.display) |display| _ = wl.wl_display_flush(display);
        return true;
    }

    fn addDataOffer(self: *State, offer: *wl.wl_data_offer) !void {
        const entry = try allocator.create(DataOfferState);
        entry.* = .{
            .owner = self,
            .offer = offer,
            .next = self.data_offers,
        };
        self.data_offers = entry;
        _ = wl.wl_data_offer_add_listener(offer, &data_offer_listener, entry);
    }

    fn findDataOffer(self: *State, offer: *wl.wl_data_offer) ?*DataOfferState {
        var it = self.data_offers;
        while (it) |entry| : (it = entry.next) {
            if (entry.offer == offer) return entry;
        }
        return null;
    }

    fn destroyDataOffer(self: *State, target: *DataOfferState) void {
        if (self.selection_offer == target) self.selection_offer = null;
        if (self.drag_offer == target) self.drag_offer = null;

        if (self.data_offers == target) {
            self.data_offers = target.next;
        } else {
            var it = self.data_offers;
            while (it) |entry| : (it = entry.next) {
                if (entry.next == target) {
                    entry.next = target.next;
                    break;
                }
            }
        }

        wl.wl_data_offer_destroy(target.offer);
        allocator.destroy(target);
    }

    fn destroyAllDataOffers(self: *State) void {
        while (self.data_offers) |entry| {
            self.destroyDataOffer(entry);
        }
    }

    fn destroyClipboardSource(self: *State) void {
        if (self.clipboard_source) |source| {
            wl.wl_data_source_destroy(source);
            self.clipboard_source = null;
        }
    }

    fn addOutput(self: *State, global_name: u32, output: *wl.wl_output) !void {
        const entry = try allocator.create(OutputState);
        entry.* = .{
            .global_name = global_name,
            .output = output,
            .next = self.outputs,
        };
        self.outputs = entry;
        _ = wl.wl_output_add_listener(output, &output_listener, self);
    }

    fn findOutput(self: *State, output: *wl.wl_output) ?*OutputState {
        var it = self.outputs;
        while (it) |entry| : (it = entry.next) {
            if (entry.output == output) return entry;
        }
        return null;
    }

    fn destroyOutputEntry(self: *State, target: *OutputState) void {
        if (self.outputs == target) {
            self.outputs = target.next;
        } else {
            var it = self.outputs;
            while (it) |entry| : (it = entry.next) {
                if (entry.next == target) {
                    entry.next = target.next;
                    break;
                }
            }
        }
        wl.wl_output_destroy(target.output);
        allocator.destroy(target);
    }

    fn removeOutputByGlobalName(self: *State, global_name: u32) void {
        var it = self.outputs;
        while (it) |entry| : (it = entry.next) {
            if (entry.global_name == global_name) {
                const was_entered = entry.entered;
                self.destroyOutputEntry(entry);
                if (was_entered and self.surface_preferred_scale == null) self.updateBufferMetrics();
                return;
            }
        }
    }

    fn destroyAllOutputs(self: *State) void {
        while (self.outputs) |entry| {
            self.destroyOutputEntry(entry);
        }
    }

    fn effectiveBufferScale(self: *const State) u32 {
        if (self.surface_preferred_scale) |preferred| return @max(preferred, 1);

        var scale: u32 = 1;
        var it = self.outputs;
        while (it) |entry| : (it = entry.next) {
            if (entry.entered) scale = @max(scale, entry.scale);
        }
        return scale;
    }

    fn setLogicalSize(self: *State, width: u32, height: u32) void {
        const previous_width = self.logical_width;
        const previous_height = self.logical_height;
        self.logical_width = @max(width, 1);
        self.logical_height = @max(height, 1);
        scrollDebug(self, "logical size {}x{} -> {}x{}", .{
            previous_width,
            previous_height,
            self.logical_width,
            self.logical_height,
        });
        if (self.ctx) |ctx| ctx.setDimensions(self.logical_width, self.logical_height);
        self.updateBufferMetrics();
    }

    fn updateBufferMetrics(self: *State) void {
        const next_scale = self.effectiveBufferScale();
        const next_width = self.logical_width * next_scale;
        const next_height = self.logical_height * next_scale;
        const changed = self.buffer_scale != next_scale or self.buffer_width != next_width or self.buffer_height != next_height;

        self.buffer_scale = next_scale;
        self.buffer_width = next_width;
        self.buffer_height = next_height;

        if (self.surface) |surface| {
            if (self.compositor_version >= 3) {
                wl.wl_surface_set_buffer_scale(surface, @intCast(self.buffer_scale));
            }
        }
        if (changed) {
            self.destroyAllPopupSurfaces();
            if (self.egl_window) |window| {
                wl.wl_egl_window_resize(window, @intCast(self.buffer_width), @intCast(self.buffer_height), 0, 0);
            }
            self.resetCursorTheme();
        }
        if (changed) self.needs_redraw = true;
    }

    fn ensureCursorSurface(self: *State) void {
        if (self.cursor_surface != null or self.compositor == null) return;
        self.cursor_surface = wl.wl_compositor_create_surface(self.compositor);
    }

    fn ensureCursorTheme(self: *State) void {
        if (self.shm == null) return;
        if (self.cursor_theme != null and self.cursor_theme_scale == self.buffer_scale) return;
        self.resetCursorTheme();
        const size = @as(c_int, @intCast(24 * @max(self.buffer_scale, 1)));
        self.cursor_theme = wl.wl_cursor_theme_load(null, size, self.shm);
        self.cursor_theme_scale = self.buffer_scale;
    }

    fn resetCursorTheme(self: *State) void {
        if (self.cursor_theme) |theme| wl.wl_cursor_theme_destroy(theme);
        self.cursor_theme = null;
        self.cursor_theme_scale = 0;
    }

    fn popupSurfaceForHandle(self: *State, handle: goop.NodeHandle) ?*PopupSurface {
        var it = self.popup_surfaces;
        while (it) |popup| : (it = popup.next) {
            if (popup.handle.eql(handle)) return popup;
        }
        return null;
    }

    fn popupSurfaceForWlSurface(self: *State, surface: ?*wl.wl_surface) ?*PopupSurface {
        const target = surface orelse return null;
        var it = self.popup_surfaces;
        while (it) |popup| : (it = popup.next) {
            if (popup.surface == target) return popup;
        }
        return null;
    }

    fn destroyPopupSurface(self: *State, target: *PopupSurface) void {
        var descendant_it = self.popup_surfaces;
        while (descendant_it) |popup| {
            const next = popup.next;
            if (popup != target and self.popupSurfaceDescendsFrom(popup, target.handle)) {
                self.destroyPopupSurface(popup);
            }
            descendant_it = next;
        }

        if (self.popup_surfaces == target) {
            self.popup_surfaces = target.next;
        } else {
            var it = self.popup_surfaces;
            while (it) |popup| : (it = popup.next) {
                if (popup.next == target) {
                    popup.next = target.next;
                    break;
                }
            }
        }

        if (self.egl_display != egl.EGL_NO_DISPLAY and self.egl_surface != egl.EGL_NO_SURFACE) {
            _ = egl.eglMakeCurrent(self.egl_display, self.egl_surface, self.egl_surface, self.egl_context);
        }
        if (target.egl_surface != egl.EGL_NO_SURFACE) _ = egl.eglDestroySurface(self.egl_display, target.egl_surface);
        wl.wl_egl_window_destroy(target.egl_window);
        wl.xdg_popup_destroy(target.xdg_popup);
        wl.xdg_surface_destroy(target.xdg_surface);
        wl.wl_surface_destroy(target.surface);
        allocator.destroy(target);
    }

    fn popupSurfaceDescendsFrom(self: *State, popup: *const PopupSurface, ancestor: goop.NodeHandle) bool {
        var current = popup.parent_popup;
        while (current) |handle| {
            if (handle.eql(ancestor)) return true;
            const parent = self.popupSurfaceForHandle(handle) orelse return false;
            current = parent.parent_popup;
        }
        return false;
    }

    fn destroyAllPopupSurfaces(self: *State) void {
        while (self.popup_surfaces) |popup| {
            self.destroyPopupSurface(popup);
        }
    }
};

fn browserViewModeLabel(mode: BrowserViewMode) []const u8 {
    return switch (mode) {
        .list => "list",
        .grid => "grid",
    };
}

fn scrollDebug(state: *const State, comptime fmt: []const u8, args: anytype) void {
    if (!state.scroll_debug_enabled) return;
    std.debug.print("scroll-debug: " ++ fmt ++ "\n", args);
}

fn layoutDebug(state: *const State, comptime fmt: []const u8, args: anytype) void {
    if (!state.layout_debug_enabled) return;
    std.debug.print("layout-debug: " ++ fmt ++ "\n", args);
}

fn uiScaleValue(scale: f32, value: f32) f32 {
    return value * scale;
}

fn uiPx(state: *const State, value: f32) f32 {
    return uiScaleValue(state.ui_scale, value);
}

fn uiEdgesAll(state: *const State, value: f32) goop.style.Edges {
    return goop.style.Edges.all(uiPx(state, value));
}

fn uiEdgesSymmetric(state: *const State, h: f32, v: f32) goop.style.Edges {
    return goop.style.Edges.symmetric(uiPx(state, h), uiPx(state, v));
}

fn fileManagerThemeForScale(ui_scale: f32) goop.Theme {
    return .{
        .bg = .rgb(243, 246, 251),
        .fg = .rgb(24, 29, 38),
        .accent = .rgb(58, 126, 219),
        .border = .rgb(203, 210, 223),
        .bg_hover = .rgb(231, 238, 248),
        .bg_active = .rgb(220, 229, 243),
        .focus_ring = .rgba(58, 126, 219, 210),
        .placeholder_fg = .rgb(123, 133, 148),
        .selection_bg = .rgba(58, 126, 219, 84),
        .tree_guide = .rgba(145, 152, 165, 180),
        .font_size = uiScaleValue(ui_scale, 14),
        .padding = goop.style.Edges.symmetric(uiScaleValue(ui_scale, 8), uiScaleValue(ui_scale, 6)),
        .border_radius = uiScaleValue(ui_scale, 6),
        .border_width = 1,
        .spacing = uiScaleValue(ui_scale, 6),
        .thumb_width = uiScaleValue(ui_scale, 14),
    };
}

fn fileManagerTheme(state: *const State) goop.Theme {
    return fileManagerThemeForScale(state.ui_scale);
}

fn browserGridItemWidthPx(state: *const State) f32 {
    return uiPx(state, browser_grid_item_width);
}

fn browserGridItemHeightPx(state: *const State) f32 {
    return uiPx(state, browser_grid_item_height);
}

fn browserGridColumnGapPx(state: *const State) f32 {
    return uiPx(state, browser_grid_column_gap);
}

fn browserGridRowGapPx(state: *const State) f32 {
    return uiPx(state, browser_grid_row_gap);
}

fn browserGridPaddingHPx(state: *const State) f32 {
    return uiPx(state, browser_grid_padding_h);
}

fn browserGridPaddingVPx(state: *const State) f32 {
    return uiPx(state, browser_grid_padding_v);
}

fn browserTableDividerWidthPx(state: *const State) f32 {
    _ = state;
    return browser_table_divider_width;
}

fn browserNameIconInsetLeftPx(state: *const State) f32 {
    return uiPx(state, browser_name_icon_inset_left);
}

fn browserNameTextInsetLeftPx(state: *const State) f32 {
    return uiPx(state, browser_name_text_inset_left);
}

const DataOfferState = struct {
    owner: *State,
    offer: *wl.wl_data_offer,
    next: ?*DataOfferState = null,
    offers_text_utf8: bool = false,
    offers_utf8_string: bool = false,
    offers_text_plain: bool = false,
    offers_uri_list: bool = false,
    offers_gnome_copied_files: bool = false,
};

fn offerSupportsMime(mime: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, mime, expected);
}

fn preferredFileOfferMime(offer: *const DataOfferState) ?[*:0]const u8 {
    if (offer.offers_gnome_copied_files) return dnd_mime_gnome_copied_files;
    if (offer.offers_uri_list) return dnd_mime_uri_list;
    return null;
}

fn preferredTextOfferMime(offer: *const DataOfferState) ?[*:0]const u8 {
    if (offer.offers_text_utf8) return clipboard_mime_utf8;
    if (offer.offers_utf8_string) return clipboard_mime_utf8_string;
    if (offer.offers_text_plain) return clipboard_mime_text;
    return null;
}

fn appendFileUri(buffer: *std.ArrayListUnmanaged(u8), path: []const u8, line_end: []const u8) !void {
    try buffer.appendSlice(allocator, "file://");
    for (path) |byte| {
        if (uriPathByteCanPass(byte)) {
            try buffer.append(allocator, byte);
        } else {
            const hex = "0123456789ABCDEF";
            try buffer.append(allocator, '%');
            try buffer.append(allocator, hex[byte >> 4]);
            try buffer.append(allocator, hex[byte & 0x0f]);
        }
    }
    try buffer.appendSlice(allocator, line_end);
}

fn uriPathByteCanPass(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '/', '-', '.', '_', '~' => true,
        else => false,
    };
}

fn appendClipboardPathFromFileUri(paths: *std.ArrayListUnmanaged([]u8), line: []const u8) !void {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return;
    if (!std.mem.startsWith(u8, trimmed, "file://")) return;

    var uri_path = trimmed["file://".len..];
    if (std.mem.startsWith(u8, uri_path, "localhost/")) {
        uri_path = uri_path["localhost".len..];
    }
    if (uri_path.len == 0 or uri_path[0] != '/') return;

    const decoded = try percentDecodeAlloc(allocator, uri_path);
    errdefer allocator.free(decoded);
    try paths.append(allocator, decoded);
}

fn percentDecodeAlloc(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = try std.ArrayListUnmanaged(u8).initCapacity(alloc, text.len);
    errdefer out.deinit(alloc);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '%' and index + 2 < text.len) {
            if (hexValue(text[index + 1])) |hi| {
                if (hexValue(text[index + 2])) |lo| {
                    try out.append(alloc, (hi << 4) | lo);
                    index += 3;
                    continue;
                }
            }
        }
        try out.append(alloc, text[index]);
        index += 1;
    }

    return out.toOwnedSlice(alloc);
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const chunk = posix.system.write(fd, bytes[written..].ptr, bytes.len - written);
        if (chunk <= 0) return;
        written += @intCast(chunk);
    }
}

fn cursorNames(kind: CursorKind) []const [:0]const u8 {
    return switch (kind) {
        .default => &[_][:0]const u8{"left_ptr"},
        .pointer => &[_][:0]const u8{ "pointer", "hand2", "left_ptr" },
        .text => &[_][:0]const u8{ "text", "xterm", "left_ptr" },
        .ew_resize => &[_][:0]const u8{ "col-resize", "sb_h_double_arrow", "left_ptr" },
        .ns_resize => &[_][:0]const u8{ "row-resize", "sb_v_double_arrow", "left_ptr" },
    };
}

fn lookupCursor(state: *State, kind: CursorKind) ?*wl.wl_cursor {
    state.ensureCursorTheme();
    const theme = state.cursor_theme orelse return null;
    for (cursorNames(kind)) |name| {
        if (wl.wl_cursor_theme_get_cursor(theme, name.ptr)) |cursor| return cursor;
    }
    return null;
}

fn desiredCursorKind(state: *State) CursorKind {
    if (!state.pointer_inside) return .default;
    const ctx = state.ctx orelse return .default;
    const handle = goop.hittest.hitTest(&ctx.tree, state.mouse_x, state.mouse_y) orelse return .default;
    const node = ctx.tree.getConst(handle);

    return switch (node.kind) {
        .splitter => switch (node.kind.splitter.direction) {
            .row => .ew_resize,
            .column => .ns_resize,
        },
        .table => blk: {
            if (goop.widget.tableResizeHandleIndexAtPoint(&ctx.tree, handle, state.mouse_x, state.mouse_y) != null) break :blk .ew_resize;
            if (goop.widget.tableHeaderCellIndexAtPoint(&ctx.tree, handle, state.mouse_x, state.mouse_y) != null) break :blk .pointer;
            break :blk .default;
        },
        .button,
        .selectable,
        .dropdown,
        .menu,
        .menu_item,
        .tab_item,
        => .pointer,
        .text_input => .text,
        else => .default,
    };
}

fn applyCursorKind(state: *State, kind: CursorKind) void {
    if (!state.pointer_inside or state.pointer == null or state.pointer_enter_serial == 0) return;

    state.ensureCursorSurface();
    const cursor_surface = state.cursor_surface orelse return;
    const cursor = lookupCursor(state, kind) orelse lookupCursor(state, .default) orelse return;
    if (cursor.image_count == 0) return;

    const image_ptr = cursor.images[0];
    const image = image_ptr.*;
    const buffer = wl.wl_cursor_image_get_buffer(image_ptr) orelse return;

    wl.wl_pointer_set_cursor(state.pointer, state.pointer_enter_serial, cursor_surface, @intCast(image.hotspot_x), @intCast(image.hotspot_y));
    wl.wl_surface_attach(cursor_surface, buffer, 0, 0);
    wl.wl_surface_damage_buffer(cursor_surface, 0, 0, @intCast(image.width), @intCast(image.height));
    wl.wl_surface_commit(cursor_surface);
    state.cursor_kind = kind;
}

fn updatePointerCursor(state: *State) void {
    const next = desiredCursorKind(state);
    if (next == state.cursor_kind and state.cursor_theme != null and state.cursor_theme_scale == state.buffer_scale) return;
    applyCursorKind(state, next);
}

// ── Wayland listeners ──

const registry_listener = wl.wl_registry_listener{
    .global = &registryGlobal,
    .global_remove = &registryGlobalRemove,
};

fn registryGlobal(data: ?*anyopaque, registry: ?*wl.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const iface = std.mem.span(@as([*:0]const u8, @ptrCast(interface)));

    if (std.mem.eql(u8, iface, "wl_compositor")) {
        state.compositor_version = @min(version, 6);
        state.compositor = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_compositor_interface, state.compositor_version));
    } else if (std.mem.eql(u8, iface, "wl_shm")) {
        state.shm = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_shm_interface, @min(version, 1)));
    } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        const xdg_wm_base_version: u32 = @intCast(wl.xdg_wm_base_interface.version);
        state.wm_base = @ptrCast(wl.wl_registry_bind(registry, name, &wl.xdg_wm_base_interface, @min(version, xdg_wm_base_version)));
        _ = wl.xdg_wm_base_add_listener(state.wm_base, &wm_base_listener, data);
    } else if (std.mem.eql(u8, iface, "wl_seat")) {
        state.seat = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_seat_interface, @min(version, 5)));
        _ = wl.wl_seat_add_listener(state.seat, &seat_listener, data);
        ensureDataDevice(state, data);
    } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
        state.data_device_manager_version = @min(version, 3);
        state.data_device_manager = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_data_device_manager_interface, state.data_device_manager_version));
        ensureDataDevice(state, data);
    } else if (std.mem.eql(u8, iface, "wl_output")) {
        const output = @as(?*wl.wl_output, @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_output_interface, @min(version, 4)))) orelse return;
        state.addOutput(name, output) catch wl.wl_output_destroy(output);
    }
}

fn registryGlobalRemove(data: ?*anyopaque, _: ?*wl.wl_registry, name: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.removeOutputByGlobalName(name);
}

const wm_base_listener = wl.xdg_wm_base_listener{
    .ping = &wmBasePing,
};

fn wmBasePing(_: ?*anyopaque, wm_base: ?*wl.xdg_wm_base, serial: u32) callconv(.c) void {
    wl.xdg_wm_base_pong(wm_base, serial);
}

const xdg_surface_listener = wl.xdg_surface_listener{
    .configure = &xdgSurfaceConfigure,
};

fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*wl.xdg_surface, serial: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    wl.xdg_surface_ack_configure(xdg_surface, serial);
    state.configured = true;
    state.needs_redraw = true;
}

const xdg_toplevel_listener = wl.xdg_toplevel_listener{
    .configure = &xdgToplevelConfigure,
    .close = &xdgToplevelClose,
    .configure_bounds = &noopConfigureBounds,
    .wm_capabilities = &noopWmCapabilities,
};

fn noopConfigureBounds(_: ?*anyopaque, _: ?*wl.xdg_toplevel, _: i32, _: i32) callconv(.c) void {}
fn noopWmCapabilities(_: ?*anyopaque, _: ?*wl.xdg_toplevel, _: ?*wl.wl_array) callconv(.c) void {}

fn xdgToplevelConfigure(data: ?*anyopaque, _: ?*wl.xdg_toplevel, width: i32, height: i32, _: ?[*]wl.wl_array) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    scrollDebug(state, "xdg_toplevel.configure width={} height={}", .{ width, height });
    if (width > 0 and height > 0) {
        state.setLogicalSize(@intCast(width), @intCast(height));
    }
    state.needs_redraw = true;
}

fn xdgToplevelClose(data: ?*anyopaque, _: ?*wl.xdg_toplevel) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.running = false;
}

const popup_xdg_surface_listener = wl.xdg_surface_listener{
    .configure = &popupXdgSurfaceConfigure,
};

const xdg_popup_listener = wl.xdg_popup_listener{
    .configure = &xdgPopupConfigure,
    .popup_done = &xdgPopupDone,
    .repositioned = &xdgPopupRepositioned,
};

fn popupXdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*wl.xdg_surface, serial: u32) callconv(.c) void {
    const popup: *PopupSurface = @ptrCast(@alignCast(data));
    wl.xdg_surface_ack_configure(xdg_surface, serial);
    popup.configured = true;
    popup.owner.needs_redraw = true;
}

fn xdgPopupConfigure(data: ?*anyopaque, _: ?*wl.xdg_popup, _: i32, _: i32, width: i32, height: i32) callconv(.c) void {
    const popup: *PopupSurface = @ptrCast(@alignCast(data));
    if (width > 0 and height > 0) {
        popup.configured_width = @intCast(width);
        popup.configured_height = @intCast(height);
        resizePopupBuffer(popup.owner, popup, popup.configured_width, popup.configured_height);
    }
    popup.owner.needs_redraw = true;
}

fn xdgPopupDone(data: ?*anyopaque, _: ?*wl.xdg_popup) callconv(.c) void {
    const popup: *PopupSurface = @ptrCast(@alignCast(data));
    const state = popup.owner;
    if (state.ctx) |ctx| {
        if (ctx.isAlive(popup.handle) and ctx.tree.getConst(popup.handle).kind == .popup) {
            ctx.tree.get(popup.handle).kind.popup.visible = false;
            ctx.invalidate();
        }
    }
    state.destroyPopupSurface(popup);
    state.needs_redraw = true;
}

fn xdgPopupRepositioned(_: ?*anyopaque, _: ?*wl.xdg_popup, _: u32) callconv(.c) void {}

const PopupParentInfo = struct {
    xdg_surface: *wl.xdg_surface,
    parent_popup: ?goop.NodeHandle,
    parent_origin_x: f32,
    parent_origin_y: f32,
    parent_width: f32,
    parent_height: f32,
    anchor_rect: goop.draw.Rect,
};

fn syncNativePopupSurfaces(state: *State, ctx: *goop.Context) !void {
    var it = state.popup_surfaces;
    while (it) |popup| {
        const next = popup.next;
        if (!popupNeedsNativeSurface(ctx, popup.handle)) {
            state.destroyPopupSurface(popup);
        }
        it = next;
    }

    for (ctx.tree.nodes.items, 0..) |node, i| {
        if (!node.alive or node.kind != .popup) continue;
        const handle = ctx.tree.handleFromIndex(@intCast(i));
        if (!popupNeedsNativeSurface(ctx, handle)) continue;
        const rect = ctx.tree.getConst(handle).layout_rect;
        const parent_info = popupParentInfo(state, ctx, handle) orelse continue;
        if (state.popupSurfaceForHandle(handle)) |popup| {
            if (!rectsNearlyEqual(popup.rect, rect) or optionalHandleChanged(popup.parent_popup, parent_info.parent_popup)) {
                state.destroyPopupSurface(popup);
                _ = try createNativePopupSurface(state, ctx, handle, parent_info);
            }
        } else {
            _ = try createNativePopupSurface(state, ctx, handle, parent_info);
        }
    }
}

fn popupNeedsNativeSurface(ctx: *const goop.Context, handle: goop.NodeHandle) bool {
    if (!ctx.isAlive(handle)) return false;
    const node = ctx.tree.getConst(handle);
    if (node.kind != .popup or !node.kind.popup.visible) return false;
    return node.layout_rect.w > 0 and node.layout_rect.h > 0;
}

fn popupParentInfo(state: *State, ctx: *goop.Context, popup_handle: goop.NodeHandle) ?PopupParentInfo {
    const popup_node = ctx.tree.getConst(popup_handle);
    const parent_xdg_surface = state.xdg_surface orelse return null;
    const owner_handle = popup_node.parent;

    var info = PopupParentInfo{
        .xdg_surface = parent_xdg_surface,
        .parent_popup = null,
        .parent_origin_x = 0,
        .parent_origin_y = 0,
        .parent_width = @floatFromInt(state.logical_width),
        .parent_height = @floatFromInt(state.logical_height),
        .anchor_rect = .{
            .x = popup_node.layout_rect.x,
            .y = popup_node.layout_rect.y,
            .w = 1,
            .h = 1,
        },
    };

    if (owner_handle) |owner| {
        if (ancestorPopupForOwner(&ctx.tree, owner)) |ancestor_popup| {
            const native_parent = state.popupSurfaceForHandle(ancestor_popup) orelse return null;
            if (!native_parent.configured) return null;
            const parent_rect = ctx.tree.getConst(ancestor_popup).layout_rect;
            info.xdg_surface = native_parent.xdg_surface;
            info.parent_popup = ancestor_popup;
            info.parent_origin_x = parent_rect.x;
            info.parent_origin_y = parent_rect.y;
            info.parent_width = parent_rect.w;
            info.parent_height = parent_rect.h;
        }

        const owner_rect = ctx.tree.getConst(owner).layout_rect;
        info.anchor_rect = .{
            .x = owner_rect.x - info.parent_origin_x,
            .y = owner_rect.y - info.parent_origin_y,
            .w = @max(owner_rect.w, 1),
            .h = @max(owner_rect.h, 1),
        };
    }

    return info;
}

fn ancestorPopupForOwner(tree: *const goop.Tree, owner: goop.NodeHandle) ?goop.NodeHandle {
    var current: ?goop.NodeHandle = owner;
    while (current) |handle| {
        const parent = tree.getConst(handle).parent orelse return null;
        if (tree.getConst(parent).kind == .popup) return parent;
        current = parent;
    }
    return null;
}

fn createNativePopupSurface(state: *State, ctx: *goop.Context, handle: goop.NodeHandle, parent_info: PopupParentInfo) !*PopupSurface {
    const compositor = state.compositor orelse return error.NoCompositor;
    const wm_base = state.wm_base orelse return error.NoXdgWmBase;
    const rect = ctx.tree.getConst(handle).layout_rect;
    const logical_width = ceilPositiveU32(rect.w);
    const logical_height = ceilPositiveU32(rect.h);
    const buffer_width = logical_width * state.buffer_scale;
    const buffer_height = logical_height * state.buffer_scale;

    const positioner = wl.xdg_wm_base_create_positioner(wm_base) orelse return error.NoPositioner;
    defer wl.xdg_positioner_destroy(positioner);
    wl.xdg_positioner_set_size(positioner, @intCast(logical_width), @intCast(logical_height));
    wl.xdg_positioner_set_anchor_rect(
        positioner,
        roundI32(parent_info.anchor_rect.x),
        roundI32(parent_info.anchor_rect.y),
        @intCast(ceilPositiveU32(parent_info.anchor_rect.w)),
        @intCast(ceilPositiveU32(parent_info.anchor_rect.h)),
    );
    setPopupPositionerPlacement(positioner, ctx.tree.getConst(handle).kind.popup);
    wl.xdg_positioner_set_parent_size(positioner, @intCast(ceilPositiveU32(parent_info.parent_width)), @intCast(ceilPositiveU32(parent_info.parent_height)));
    wl.xdg_positioner_set_constraint_adjustment(positioner, popupConstraintAdjustment());

    const surface = wl.wl_compositor_create_surface(compositor) orelse return error.NoSurface;
    errdefer wl.wl_surface_destroy(surface);
    if (state.compositor_version >= 3) {
        wl.wl_surface_set_buffer_scale(surface, @intCast(state.buffer_scale));
    }
    const xdg_surface = wl.xdg_wm_base_get_xdg_surface(wm_base, surface) orelse return error.NoXdgSurface;
    errdefer wl.xdg_surface_destroy(xdg_surface);

    const xdg_popup = wl.xdg_surface_get_popup(xdg_surface, parent_info.xdg_surface, positioner) orelse return error.NoXdgPopup;
    errdefer wl.xdg_popup_destroy(xdg_popup);

    const egl_window = wl.wl_egl_window_create(surface, @intCast(buffer_width), @intCast(buffer_height)) orelse return error.EglWindowCreateFailed;
    errdefer wl.wl_egl_window_destroy(egl_window);
    const egl_surface = egl.eglCreateWindowSurface(state.egl_display, state.egl_config, @intFromPtr(egl_window), null) orelse return error.EglCreateSurfaceFailed;
    errdefer _ = egl.eglDestroySurface(state.egl_display, egl_surface);

    const popup = try allocator.create(PopupSurface);
    popup.* = .{
        .owner = state,
        .handle = handle,
        .surface = surface,
        .xdg_surface = xdg_surface,
        .xdg_popup = xdg_popup,
        .egl_window = egl_window,
        .egl_surface = egl_surface,
        .rect = rect,
        .buffer_width = buffer_width,
        .buffer_height = buffer_height,
        .parent_popup = parent_info.parent_popup,
        .configured_width = logical_width,
        .configured_height = logical_height,
        .next = state.popup_surfaces,
    };
    state.popup_surfaces = popup;

    _ = wl.xdg_surface_add_listener(xdg_surface, &popup_xdg_surface_listener, popup);
    _ = wl.xdg_popup_add_listener(xdg_popup, &xdg_popup_listener, popup);
    wl.wl_surface_commit(surface);
    state.needs_redraw = true;
    return popup;
}

fn setPopupPositionerPlacement(positioner: *wl.xdg_positioner, popup: goop.widget.WidgetKind.Popup) void {
    const AnchorGravity = struct {
        anchor: u32,
        gravity: u32,
    };
    const anchor_gravity = switch (popup.placement) {
        .absolute => AnchorGravity{
            .anchor = wl.XDG_POSITIONER_ANCHOR_TOP_LEFT,
            .gravity = wl.XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT,
        },
        .below_start => AnchorGravity{
            .anchor = wl.XDG_POSITIONER_ANCHOR_BOTTOM_LEFT,
            .gravity = wl.XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT,
        },
        .below_end => AnchorGravity{
            .anchor = wl.XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT,
            .gravity = wl.XDG_POSITIONER_GRAVITY_BOTTOM_LEFT,
        },
        .right_start => AnchorGravity{
            .anchor = wl.XDG_POSITIONER_ANCHOR_TOP_RIGHT,
            .gravity = wl.XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT,
        },
    };
    wl.xdg_positioner_set_anchor(positioner, anchor_gravity.anchor);
    wl.xdg_positioner_set_gravity(positioner, anchor_gravity.gravity);
    if (popup.placement != .absolute and (popup.x != 0 or popup.y != 0)) {
        wl.xdg_positioner_set_offset(positioner, roundI32(popup.x), roundI32(popup.y));
    }
}

fn popupConstraintAdjustment() u32 {
    return @as(u32, @intCast(wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X)) |
        @as(u32, @intCast(wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y)) |
        @as(u32, @intCast(wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X)) |
        @as(u32, @intCast(wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y));
}

fn resizePopupBuffer(state: *State, popup: *PopupSurface, logical_width: u32, logical_height: u32) void {
    const buffer_width = logical_width * state.buffer_scale;
    const buffer_height = logical_height * state.buffer_scale;
    if (buffer_width == popup.buffer_width and buffer_height == popup.buffer_height) return;
    wl.wl_egl_window_resize(popup.egl_window, @intCast(buffer_width), @intCast(buffer_height), 0, 0);
    popup.buffer_width = buffer_width;
    popup.buffer_height = buffer_height;
}

fn renderNativePopupSurfaces(state: *State, renderer: *render.Renderer) !void {
    const ctx = state.ctx orelse return;
    var it = state.popup_surfaces;
    while (it) |popup| : (it = popup.next) {
        if (!popup.configured or !popupNeedsNativeSurface(ctx, popup.handle)) continue;

        var popup_paint_list = try goop.draw.generatePaintForPopup(&ctx.tree, popup.handle, ctx.theme, allocator, state.text_measure_ctx);
        defer goop.draw.freePaintList(&popup_paint_list, allocator);

        if (egl.eglMakeCurrent(state.egl_display, popup.egl_surface, popup.egl_surface, state.egl_context) == 0) return error.EglMakeCurrentFailed;
        const previous_clear = renderer.clear_color;
        renderer.clear_color = .{ 0, 0, 0, 0 };
        renderer.beginFrame(popup.buffer_width, popup.buffer_height, @floatFromInt(state.buffer_scale));
        renderer.renderPaintList(popup_paint_list);
        renderer.clear_color = previous_clear;
        _ = egl.eglSwapBuffers(state.egl_display, popup.egl_surface);
    }

    if (state.egl_surface != egl.EGL_NO_SURFACE) {
        if (egl.eglMakeCurrent(state.egl_display, state.egl_surface, state.egl_surface, state.egl_context) == 0) return error.EglMakeCurrentFailed;
    }
}

fn rootPointerX(state: *const State, sx: wl.wl_fixed_t) f32 {
    return state.pointer_surface_offset_x + fixedToF32(sx);
}

fn rootPointerY(state: *const State, sy: wl.wl_fixed_t) f32 {
    return state.pointer_surface_offset_y + fixedToF32(sy);
}

fn ceilPositiveU32(value: f32) u32 {
    if (!std.math.isFinite(value) or value <= 1) return 1;
    return @intFromFloat(@ceil(value));
}

fn roundI32(value: f32) i32 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(@round(value));
}

fn optionalHandleChanged(a: ?goop.NodeHandle, b: ?goop.NodeHandle) bool {
    if (a == null and b == null) return false;
    if (a == null or b == null) return true;
    return !a.?.eql(b.?);
}

fn rectsNearlyEqual(a: goop.draw.Rect, b: goop.draw.Rect) bool {
    return nearlyEqual(a.x, b.x) and nearlyEqual(a.y, b.y) and nearlyEqual(a.w, b.w) and nearlyEqual(a.h, b.h);
}

fn nearlyEqual(a: f32, b: f32) bool {
    return @abs(a - b) < 0.5;
}

fn ensureDataDevice(state: *State, data: ?*anyopaque) void {
    if (state.data_device != null) return;
    if (state.data_device_manager == null or state.seat == null) return;
    state.data_device = wl.wl_data_device_manager_get_data_device(state.data_device_manager, state.seat);
    if (state.data_device) |device| {
        _ = wl.wl_data_device_add_listener(device, &data_device_listener, data);
    }
}

const output_listener = wl.wl_output_listener{
    .geometry = &noopOutputGeometry,
    .mode = &noopOutputMode,
    .done = &noopOutputDone,
    .scale = &outputScale,
    .name = &noopOutputName,
    .description = &noopOutputDescription,
};

fn noopOutputGeometry(_: ?*anyopaque, _: ?*wl.wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, _: i32) callconv(.c) void {}
fn noopOutputMode(_: ?*anyopaque, _: ?*wl.wl_output, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}
fn noopOutputDone(_: ?*anyopaque, _: ?*wl.wl_output) callconv(.c) void {}
fn noopOutputName(_: ?*anyopaque, _: ?*wl.wl_output, _: [*c]const u8) callconv(.c) void {}
fn noopOutputDescription(_: ?*anyopaque, _: ?*wl.wl_output, _: [*c]const u8) callconv(.c) void {}

fn outputScale(data: ?*anyopaque, output: ?*wl.wl_output, factor: i32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const wl_output = output orelse return;
    const entry = state.findOutput(wl_output) orelse return;
    entry.scale = @intCast(@max(factor, 1));
    if (entry.entered and state.surface_preferred_scale == null) state.updateBufferMetrics();
}

const surface_listener = wl.wl_surface_listener{
    .enter = &surfaceEnter,
    .leave = &surfaceLeave,
    .preferred_buffer_scale = &surfacePreferredBufferScale,
    .preferred_buffer_transform = &noopSurfacePreferredBufferTransform,
};

fn surfaceEnter(data: ?*anyopaque, _: ?*wl.wl_surface, output: ?*wl.wl_output) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const wl_output = output orelse return;
    if (state.findOutput(wl_output)) |entry| {
        if (!entry.entered) {
            entry.entered = true;
            if (state.surface_preferred_scale == null) state.updateBufferMetrics();
        }
    }
}

fn surfaceLeave(data: ?*anyopaque, _: ?*wl.wl_surface, output: ?*wl.wl_output) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const wl_output = output orelse return;
    if (state.findOutput(wl_output)) |entry| {
        if (entry.entered) {
            entry.entered = false;
            if (state.surface_preferred_scale == null) state.updateBufferMetrics();
        }
    }
}

fn surfacePreferredBufferScale(data: ?*anyopaque, _: ?*wl.wl_surface, factor: i32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.surface_preferred_scale = @intCast(@max(factor, 1));
    state.updateBufferMetrics();
}

fn noopSurfacePreferredBufferTransform(_: ?*anyopaque, _: ?*wl.wl_surface, _: u32) callconv(.c) void {}

const seat_listener = wl.wl_seat_listener{
    .capabilities = &seatCapabilities,
    .name = &seatName,
};

fn seatName(_: ?*anyopaque, _: ?*wl.wl_seat, _: [*c]const u8) callconv(.c) void {}

fn seatCapabilities(data: ?*anyopaque, seat: ?*wl.wl_seat, caps: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const has_pointer = (caps & wl.WL_SEAT_CAPABILITY_POINTER) != 0;
    const has_keyboard = (caps & wl.WL_SEAT_CAPABILITY_KEYBOARD) != 0;

    if (has_pointer and state.pointer == null) {
        state.pointer = wl.wl_seat_get_pointer(seat);
        _ = wl.wl_pointer_add_listener(state.pointer, &pointer_listener, data);
    } else if (!has_pointer and state.pointer != null) {
        wl.wl_pointer_destroy(state.pointer);
        state.pointer = null;
        state.pointer_inside = false;
        state.pointer_enter_serial = 0;
        state.cursor_kind = .default;
    }

    if (has_keyboard and state.keyboard == null) {
        state.keyboard = wl.wl_seat_get_keyboard(seat);
        _ = wl.wl_keyboard_add_listener(state.keyboard, &keyboard_listener, data);
    } else if (!has_keyboard and state.keyboard != null) {
        wl.wl_keyboard_destroy(state.keyboard);
        state.keyboard = null;
    }

    ensureDataDevice(state, data);
}

const data_offer_listener = wl.wl_data_offer_listener{
    .offer = &dataOfferOffer,
    .source_actions = &noopDataOfferSourceActions,
    .action = &noopDataOfferAction,
};

fn dataOfferOffer(data: ?*anyopaque, _: ?*wl.wl_data_offer, mime_type: [*c]const u8) callconv(.c) void {
    const offer: *DataOfferState = @ptrCast(@alignCast(data));
    const mime = std.mem.span(@as([*:0]const u8, @ptrCast(mime_type)));
    if (offerSupportsMime(mime, clipboard_mime_utf8)) {
        offer.offers_text_utf8 = true;
    } else if (offerSupportsMime(mime, clipboard_mime_utf8_string)) {
        offer.offers_utf8_string = true;
    } else if (offerSupportsMime(mime, clipboard_mime_text)) {
        offer.offers_text_plain = true;
    } else if (offerSupportsMime(mime, dnd_mime_uri_list)) {
        offer.offers_uri_list = true;
    } else if (offerSupportsMime(mime, dnd_mime_gnome_copied_files)) {
        offer.offers_gnome_copied_files = true;
    }
}

fn noopDataOfferSourceActions(_: ?*anyopaque, _: ?*wl.wl_data_offer, _: u32) callconv(.c) void {}
fn noopDataOfferAction(_: ?*anyopaque, _: ?*wl.wl_data_offer, _: u32) callconv(.c) void {}

const data_source_listener = wl.wl_data_source_listener{
    .target = &noopDataSourceTarget,
    .send = &dataSourceSend,
    .cancelled = &dataSourceCancelled,
    .dnd_drop_performed = &noopDataSourceDropPerformed,
    .dnd_finished = &dataSourceFinished,
    .action = &noopDataSourceAction,
};

fn noopDataSourceTarget(_: ?*anyopaque, _: ?*wl.wl_data_source, _: [*c]const u8) callconv(.c) void {}
fn noopDataSourceDropPerformed(_: ?*anyopaque, _: ?*wl.wl_data_source) callconv(.c) void {}
fn dataSourceFinished(data: ?*anyopaque, source: ?*wl.wl_data_source) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const was_drag_source = state.drag_source == source;
    if (was_drag_source) {
        state.clearFinishedDragSource(source);
        if (state.ctx) |ctx| ctx.cancelPointerGesture();
        state.needs_redraw = true;
    }
    if (source) |finished_source| wl.wl_data_source_destroy(finished_source);
}
fn noopDataSourceAction(_: ?*anyopaque, _: ?*wl.wl_data_source, _: u32) callconv(.c) void {}

fn dataSourceSend(data: ?*anyopaque, source: ?*wl.wl_data_source, mime_type: [*c]const u8, fd: i32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    defer closeFd(fd);
    if (state.drag_source == source) {
        const mime = std.mem.span(@as([*:0]const u8, @ptrCast(mime_type)));
        if (std.mem.eql(u8, mime, dnd_mime_uri_list)) {
            writeAll(fd, state.drag_uri_list_buf.items);
        } else if (std.mem.eql(u8, mime, dnd_mime_gnome_copied_files)) {
            writeAll(fd, state.drag_gnome_files_buf.items);
        } else {
            writeAll(fd, state.drag_plain_buf.items);
        }
        return;
    }
    if (state.clipboard_source == source and state.clipboard_file_action != null) {
        const mime = std.mem.span(@as([*:0]const u8, @ptrCast(mime_type)));
        if (std.mem.eql(u8, mime, dnd_mime_uri_list)) {
            writeAll(fd, state.clipboard_uri_list_buf.items);
        } else if (std.mem.eql(u8, mime, dnd_mime_gnome_copied_files)) {
            writeAll(fd, state.clipboard_gnome_files_buf.items);
        } else {
            writeAll(fd, state.clipboard_buf.items);
        }
        return;
    }
    if (state.clipboard_buf.items.len == 0) return;
    writeAll(fd, state.clipboard_buf.items);
}

fn dataSourceCancelled(data: ?*anyopaque, source: ?*wl.wl_data_source) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    if (state.clipboard_source == source) {
        state.clipboard_source = null;
    } else if (state.drag_source == source) {
        state.clearFinishedDragSource(source);
        if (state.ctx) |ctx| ctx.cancelPointerGesture();
        state.needs_redraw = true;
    }
    if (source) |cancelled_source| wl.wl_data_source_destroy(cancelled_source);
}

const data_device_listener = wl.wl_data_device_listener{
    .data_offer = &dataDeviceDataOffer,
    .enter = &dataDeviceEnter,
    .leave = &dataDeviceLeave,
    .motion = &noopDataDeviceMotion,
    .drop = &noopDataDeviceDrop,
    .selection = &dataDeviceSelection,
};

fn dataDeviceDataOffer(data: ?*anyopaque, _: ?*wl.wl_data_device, offer: ?*wl.wl_data_offer) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const data_offer = offer orelse return;
    state.addDataOffer(data_offer) catch wl.wl_data_offer_destroy(data_offer);
}

fn dataDeviceEnter(data: ?*anyopaque, _: ?*wl.wl_data_device, _: u32, _: ?*wl.wl_surface, _: wl.wl_fixed_t, _: wl.wl_fixed_t, offer: ?*wl.wl_data_offer) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    if (state.drag_offer) |drag_offer| state.destroyDataOffer(drag_offer);
    if (offer) |drag_offer| {
        state.drag_offer = state.findDataOffer(drag_offer);
    }
}

fn dataDeviceLeave(data: ?*anyopaque, _: ?*wl.wl_data_device) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    if (state.drag_offer) |drag_offer| state.destroyDataOffer(drag_offer);
}

fn noopDataDeviceMotion(_: ?*anyopaque, _: ?*wl.wl_data_device, _: u32, _: wl.wl_fixed_t, _: wl.wl_fixed_t) callconv(.c) void {}
fn noopDataDeviceDrop(_: ?*anyopaque, _: ?*wl.wl_data_device) callconv(.c) void {}

fn dataDeviceSelection(data: ?*anyopaque, _: ?*wl.wl_data_device, offer: ?*wl.wl_data_offer) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    if (state.selection_offer) |selection_offer| {
        if (offer == null or selection_offer.offer != offer) {
            state.destroyDataOffer(selection_offer);
        }
    }
    if (offer) |selection_offer| {
        state.selection_offer = state.findDataOffer(selection_offer);
    }
}

const pointer_listener = wl.wl_pointer_listener{
    .enter = &pointerEnter,
    .leave = &pointerLeave,
    .motion = &pointerMotion,
    .button = &pointerButton,
    .axis = &pointerAxis,
    .frame = &noopPointerFrame,
    .axis_source = &noopAxisSource,
    .axis_stop = &noopAxisStop,
    .axis_discrete = &noopAxisDiscrete,
    .axis_value120 = &noopAxisValue120,
    .axis_relative_direction = &noopAxisRelDir,
};

fn noopPointerFrame(_: ?*anyopaque, _: ?*wl.wl_pointer) callconv(.c) void {}
fn noopAxisSource(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32) callconv(.c) void {}
fn noopAxisStop(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32) callconv(.c) void {}
fn noopAxisDiscrete(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: i32) callconv(.c) void {}
fn noopAxisValue120(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: i32) callconv(.c) void {}
fn noopAxisRelDir(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32) callconv(.c) void {}

// ── Keyboard listener ──

const keyboard_listener = wl.wl_keyboard_listener{
    .keymap = &keymapHandler,
    .enter = &noopKeyboardEnter,
    .leave = &noopKeyboardLeave,
    .key = &keyboardKey,
    .modifiers = &modifiersHandler,
    .repeat_info = &noopRepeatInfo,
};

fn keymapHandler(data: ?*anyopaque, _: ?*wl.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    defer closeFd(fd);

    if (format != wl.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;

    if (state.xkb_ctx == null) {
        state.xkb_ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS);
        if (state.xkb_ctx == null) return;
    }

    const mapped = posix.mmap(
        null,
        size,
        .{ .READ = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    ) catch return;
    defer posix.munmap(mapped);
    const map_str: [*]const u8 = @ptrCast(mapped.ptr);

    if (state.xkb_state) |s| xkb.xkb_state_unref(s);
    if (state.xkb_keymap) |k| xkb.xkb_keymap_unref(k);

    state.xkb_keymap = xkb.xkb_keymap_new_from_string(
        state.xkb_ctx,
        map_str,
        xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
        xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
    );
    if (state.xkb_keymap) |km| {
        state.xkb_state = xkb.xkb_state_new(km);
    }
}

fn noopKeyboardEnter(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface, _: ?*wl.wl_array) callconv(.c) void {}
fn noopKeyboardLeave(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.left_ctrl_down = false;
    state.right_ctrl_down = false;
    state.left_shift_down = false;
    state.right_shift_down = false;
    state.ctrl_down = false;
    state.shift_down = false;
}

fn modifiersHandler(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    if (state.xkb_state) |s| {
        _ = xkb.xkb_state_update_mask(s, mods_depressed, mods_latched, mods_locked, 0, 0, group);
    }
}
fn noopRepeatInfo(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: i32, _: i32) callconv(.c) void {}

fn evdevToKeycode(scancode: u32) goop.Event.Keycode {
    return switch (scancode) {
        14 => .backspace,
        111 => .delete,
        15 => .tab,
        28 => .enter,
        57 => .space,
        1 => .escape,
        42 => .left_shift,
        54 => .right_shift,
        29 => .left_ctrl,
        97 => .right_ctrl,
        30 => .a,
        46 => .c,
        47 => .v,
        45 => .x,
        102 => .home,
        105 => .left,
        106 => .right,
        103 => .up,
        108 => .down,
        107 => .end,
        else => .unknown,
    };
}

fn keyboardKey(data: ?*anyopaque, _: ?*wl.wl_keyboard, serial: u32, _: u32, key: u32, key_state: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const ctx = state.ctx orelse return;
    state.last_input_serial = serial;
    // Wayland delivers Linux evdev codes here. xkbcommon needs an extra +8,
    // but goop's logical-key mapping table is keyed by the raw evdev values.
    const scancode = key;
    const goop_state: goop.Event.Key.KeyState = if (key_state == 1) .pressed else .released;
    const down = key_state == 1;
    switch (scancode) {
        29 => state.left_ctrl_down = down,
        97 => state.right_ctrl_down = down,
        42 => state.left_shift_down = down,
        54 => state.right_shift_down = down,
        else => {},
    }
    state.ctrl_down = state.left_ctrl_down or state.right_ctrl_down;
    state.shift_down = state.left_shift_down or state.right_shift_down;
    ctx.pushEvent(.{ .key = .{
        .scancode = scancode,
        .keycode = evdevToKeycode(scancode),
        .state = goop_state,
    } }) catch {};

    if (key_state == 1) {
        const focused_handle = focusedNodeHandle(ctx);
        const focused_is_text_input = if (focused_handle) |handle|
            ctx.tree.getConst(handle).kind == .text_input
        else
            false;
        const focused_is_rename_input = if (focused_handle) |handle|
            if (state.rename_input_handle) |rename_handle| handle.eql(rename_handle) else false
        else
            false;

        switch (evdevToKeycode(scancode)) {
            .enter => {
                if (focused_is_rename_input) {
                    state.rename_commit_requested = true;
                } else if (state.address_input_handle) |handle| {
                    if (ctx.isAlive(handle) and ctx.tree.getConst(handle).interaction.focused) {
                        state.address_submit_requested = true;
                    }
                }
            },
            .a => {
                if (state.ctrl_down and !focused_is_text_input) {
                    state.pending_command = .select_all;
                }
            },
            .c => {
                if (state.ctrl_down and !focused_is_text_input) {
                    state.pending_command = .copy;
                }
            },
            .x => {
                if (state.ctrl_down and !focused_is_text_input) {
                    state.pending_command = .cut;
                }
            },
            .v => {
                if (state.ctrl_down and !focused_is_text_input) {
                    state.pending_command = .paste;
                }
            },
            .delete => {
                if (!focused_is_text_input) {
                    state.pending_command = .delete;
                }
            },
            .up => {
                if (state.ctrl_down and state.shift_down and !focused_is_text_input) {
                    state.pending_command = .move_parent;
                }
            },
            .escape => {
                if (state.rename_path != null) {
                    state.rename_cancel_requested = true;
                } else if (!focused_is_text_input) {
                    state.pending_command = .clear_selection;
                }
            },
            else => {},
        }
    }

    // On key press, use xkbcommon to produce a text event with the composed codepoint
    if (key_state == 1) {
        if (state.xkb_state) |xkb_st| {
            // xkb uses evdev keycodes (key + 8)
            const codepoint = xkb.xkb_state_key_get_utf32(xkb_st, key + 8);
            if (isPrintableTextCodepoint(codepoint)) {
                ctx.pushEvent(.{ .text = .{
                    .codepoint = @intCast(codepoint),
                } }) catch {};
            }
        }
    }
    state.needs_redraw = true;
}

fn pointerEnter(data: ?*anyopaque, _: ?*wl.wl_pointer, serial: u32, surface: ?*wl.wl_surface, sx: wl.wl_fixed_t, sy: wl.wl_fixed_t) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.pointer_enter_serial = serial;
    state.pointer_inside = true;
    if (state.popupSurfaceForWlSurface(surface)) |popup| {
        state.pointer_surface_offset_x = popup.rect.x;
        state.pointer_surface_offset_y = popup.rect.y;
    } else {
        state.pointer_surface_offset_x = 0;
        state.pointer_surface_offset_y = 0;
    }
    state.mouse_x = rootPointerX(state, sx);
    state.mouse_y = rootPointerY(state, sy);
    updatePointerCursor(state);
}

fn pointerLeave(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: ?*wl.wl_surface) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.pointer_inside = false;
    state.cursor_kind = .default;
}

fn pointerMotion(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, sx: wl.wl_fixed_t, sy: wl.wl_fixed_t) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const x = rootPointerX(state, sx);
    const y = rootPointerY(state, sy);
    state.mouse_x = x;
    state.mouse_y = y;
    if (state.ctx) |ctx| ctx.pushEvent(.{ .mouse_move = .{ .x = x, .y = y } }) catch {};
    state.needs_redraw = true;
}

fn pointerButton(data: ?*anyopaque, _: ?*wl.wl_pointer, serial: u32, time_ms: u32, button: u32, btn_state: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const ctx = state.ctx orelse return;
    state.last_input_serial = serial;
    const goop_button: goop.Event.MouseButton.Button = switch (button) {
        0x110 => .left, // BTN_LEFT
        0x111 => .right, // BTN_RIGHT
        0x112 => .middle, // BTN_MIDDLE
        else => return,
    };
    const goop_state: goop.Event.MouseButton.ButtonState = if (btn_state == 1) .pressed else .released;
    if (goop_button == .left and goop_state == .pressed) {
        state.last_pointer_button_serial = serial;
    }

    // Use last known mouse position from Wayland pointer events
    const mx = state.mouse_x;
    const my = state.mouse_y;
    if (goop_button == .left and goop_state == .released) {
        state.primary_release_pending = true;
        state.primary_release_x = mx;
        state.primary_release_y = my;
    }
    ctx.pushEvent(.{ .mouse_button = .{
        .button = goop_button,
        .state = goop_state,
        .x = mx,
        .y = my,
        .timestamp_ms = time_ms,
    } }) catch {};
    state.needs_redraw = true;
}

fn pointerAxis(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, axis: u32, value: wl.wl_fixed_t) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const v = fixedToF32(value);
    const dx: f32 = if (axis == 1) v else 0; // WL_POINTER_AXIS_HORIZONTAL_SCROLL
    const dy: f32 = if (axis == 0) v else 0; // WL_POINTER_AXIS_VERTICAL_SCROLL
    scrollDebug(state, "input axis={} dx={d:.2} dy={d:.2} mouse=({d:.1},{d:.1})", .{
        axis,
        dx,
        dy,
        state.mouse_x,
        state.mouse_y,
    });
    if (state.ctx) |ctx| ctx.pushEvent(.{ .mouse_scroll = .{ .dx = dx, .dy = dy } }) catch {};
    state.needs_redraw = true;
}

fn fixedToF32(fixed: wl.wl_fixed_t) f32 {
    return @as(f32, @floatFromInt(fixed)) / 256.0;
}

// ── Frame callback ──

const frame_listener = wl.wl_callback_listener{
    .done = &frameDone,
};

fn frameDone(data: ?*anyopaque, callback: ?*wl.wl_callback, _: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    wl.wl_callback_destroy(callback);
    state.frame_pending = false;
}

fn requestFrame(state: *State) void {
    if (state.frame_pending) return;
    const callback = wl.wl_surface_frame(state.surface) orelse return;
    _ = wl.wl_callback_add_listener(callback, &frame_listener, state);
    state.frame_pending = true;
}

// ── EGL setup ──

fn initEgl(state: *State, display: *wl.wl_display) !void {
    state.egl_display = egl.eglGetDisplay(@ptrCast(display)) orelse return error.EglNoDisplay;

    var major: egl.EGLint = 0;
    var minor: egl.EGLint = 0;
    if (egl.eglInitialize(state.egl_display, &major, &minor) == 0) return error.EglInitFailed;

    const attribs = [_]egl.EGLint{
        egl.EGL_SURFACE_TYPE,    egl.EGL_WINDOW_BIT,
        egl.EGL_RED_SIZE,        8,
        egl.EGL_GREEN_SIZE,      8,
        egl.EGL_BLUE_SIZE,       8,
        egl.EGL_ALPHA_SIZE,      8,
        egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_BIT,
        egl.EGL_SAMPLE_BUFFERS,  1,
        egl.EGL_SAMPLES,         4,
        egl.EGL_NONE,
    };
    var config: egl.EGLConfig = null;
    var num_configs: egl.EGLint = 0;
    if (egl.eglChooseConfig(state.egl_display, &attribs, &config, 1, &num_configs) == 0) return error.EglChooseConfigFailed;
    state.egl_config = config;

    if (egl.eglBindAPI(egl.EGL_OPENGL_API) == 0) return error.EglBindApiFailed;

    const ctx_attribs = [_]egl.EGLint{
        egl.EGL_CONTEXT_MAJOR_VERSION,       3,
        egl.EGL_CONTEXT_MINOR_VERSION,       3,
        egl.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        egl.EGL_NONE,
    };
    state.egl_context = egl.eglCreateContext(state.egl_display, config, egl.EGL_NO_CONTEXT, &ctx_attribs) orelse return error.EglCreateContextFailed;

    state.egl_window = wl.wl_egl_window_create(state.surface, @intCast(state.buffer_width), @intCast(state.buffer_height)) orelse return error.EglWindowCreateFailed;

    state.egl_surface = egl.eglCreateWindowSurface(state.egl_display, config, @intFromPtr(state.egl_window), null) orelse return error.EglCreateSurfaceFailed;

    if (egl.eglMakeCurrent(state.egl_display, state.egl_surface, state.egl_surface, state.egl_context) == 0) return error.EglMakeCurrentFailed;
}

fn deinitEgl(state: *State) void {
    _ = egl.eglMakeCurrent(state.egl_display, egl.EGL_NO_SURFACE, egl.EGL_NO_SURFACE, egl.EGL_NO_CONTEXT);
    if (state.egl_surface != egl.EGL_NO_SURFACE) _ = egl.eglDestroySurface(state.egl_display, state.egl_surface);
    if (state.egl_context != egl.EGL_NO_CONTEXT) _ = egl.eglDestroyContext(state.egl_display, state.egl_context);
    if (state.egl_window != null) wl.wl_egl_window_destroy(state.egl_window);
    if (state.egl_display != egl.EGL_NO_DISPLAY) _ = egl.eglTerminate(state.egl_display);
}

// ── Widget tree ──

fn freeOptionalOwnedSlice(buf: *?[]u8) void {
    if (buf.*) |slice| allocator.free(slice);
    buf.* = null;
}

fn clearUiStrings(state: *State) void {
    for (state.ui_strings.items) |text| allocator.free(text);
    state.ui_strings.clearRetainingCapacity();
}

fn clearAssetUiStrings(state: *State) void {
    for (state.asset_ui_strings.items) |text| allocator.free(text);
    state.asset_ui_strings.clearRetainingCapacity();
}

fn clearTrackedPaths(paths: *std.ArrayListUnmanaged([]u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.clearRetainingCapacity();
}

fn trackedPathIndex(paths: []const []u8, path: []const u8) ?usize {
    for (paths, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, path)) return index;
    }
    return null;
}

fn isFolderTreePathExpanded(state: *const State, path: []const u8) bool {
    return trackedPathIndex(state.folder_tree_expanded_paths.items, path) != null;
}

const FolderTreeExpansion = enum {
    collapsed,
    partial,
    expanded,
};

fn folderTreeExpansion(state: *const State, path: []const u8) FolderTreeExpansion {
    if (isFolderTreePathExpanded(state, path)) return .expanded;
    if (std.mem.eql(u8, path, state.current_dir)) return .expanded;
    if (pathHasDirectoryPrefix(state.current_dir, path)) return .partial;
    return .collapsed;
}

fn setFolderTreePathExpanded(state: *State, path: []const u8, expanded: bool) !bool {
    if (trackedPathIndex(state.folder_tree_expanded_paths.items, path)) |index| {
        if (expanded) return false;
        allocator.free(state.folder_tree_expanded_paths.swapRemove(index));
        return true;
    }
    if (!expanded) return false;
    try state.folder_tree_expanded_paths.append(allocator, try allocator.dupe(u8, path));
    return true;
}

fn preserveFolderTreeContextForNavigation(state: *State, next_dir: []const u8) !void {
    if (state.current_dir.len == 0) return;
    if (std.mem.eql(u8, state.current_dir, next_dir)) return;
    if (!pathHasDirectoryPrefix(state.current_dir, next_dir)) return;
    _ = try setFolderTreePathExpanded(state, state.current_dir, true);
}

fn shouldRenderFolderTreeChildForExpansion(
    state: *const State,
    parent_expansion: FolderTreeExpansion,
    index: usize,
    child_path: []const u8,
) bool {
    return switch (parent_expansion) {
        .collapsed => false,
        .partial => pathHasDirectoryPrefix(state.current_dir, child_path),
        .expanded => index < folder_tree_max_visible_children or
            pathHasDirectoryPrefix(state.current_dir, child_path) or
            isFolderTreePathExpanded(state, child_path),
    };
}

fn clearPlaces(state: *State) void {
    for (state.places.items) |place| allocator.free(place.path);
    state.places.clearRetainingCapacity();
}

fn clearSelectedPaths(state: *State) void {
    for (state.selected_paths.items) |path| allocator.free(path);
    state.selected_paths.clearRetainingCapacity();
}

fn clearEntries(state: *State) void {
    for (state.entries.items) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.path);
        if (entry.target_path) |target_path| allocator.free(target_path);
    }
    state.entries.clearRetainingCapacity();
}

fn clearAssetTracking(state: *State) void {
    state.asset_view_root = null;
    state.asset_table = null;
    state.asset_table_body = null;
    state.asset_grid = null;
    state.rename_input_handle = null;
    state.asset_visible_start = 0;
    state.asset_visible_end = 0;
    state.asset_visible_columns = 0;
    state.row_handles.clearRetainingCapacity();
    state.name_cell_handles.clearRetainingCapacity();
    state.grid_handles.clearRetainingCapacity();
    clearAssetUiStrings(state);
}

fn clearAssetBodyTracking(state: *State) void {
    state.asset_view_root = null;
    state.asset_table_body = null;
    state.asset_grid = null;
    state.rename_input_handle = null;
    state.asset_visible_start = 0;
    state.asset_visible_end = 0;
    state.asset_visible_columns = 0;
    state.row_handles.clearRetainingCapacity();
    state.name_cell_handles.clearRetainingCapacity();
    state.grid_handles.clearRetainingCapacity();
    clearAssetUiStrings(state);
}

fn clearUiTracking(state: *State) void {
    state.ui_root = null;
    state.btn_back = null;
    state.btn_forward = null;
    state.btn_up = null;
    state.btn_home = null;
    state.btn_refresh = null;
    state.btn_toggle_sidebar = null;
    state.btn_toggle_preview = null;
    state.btn_toggle_info = null;
    state.btn_list_view = null;
    state.btn_grid_view = null;
    state.btn_address_go = null;
    state.address_input_handle = null;
    state.nav_splitter = null;
    state.detail_splitter = null;
    state.preview_splitter = null;
    state.sidebar_scroll = null;
    state.file_panel_scroll = null;
    state.menu_file_refresh = null;
    state.menu_file_button = null;
    state.menu_edit_button = null;
    state.menu_view_button = null;
    state.menu_go_button = null;
    state.menu_help_button = null;
    state.menu_file_popup = null;
    state.menu_edit_popup = null;
    state.menu_view_popup = null;
    state.menu_go_popup = null;
    state.menu_help_popup = null;
    state.menu_file_copy_path = null;
    state.menu_file_open_target = null;
    state.menu_file_quit = null;
    state.menu_edit_copy = null;
    state.menu_edit_cut = null;
    state.menu_edit_paste = null;
    state.menu_edit_delete = null;
    state.menu_edit_rename = null;
    state.menu_edit_move_parent = null;
    state.menu_edit_select_all = null;
    state.menu_edit_clear_selection = null;
    state.menu_view_sidebar = null;
    state.menu_view_preview = null;
    state.menu_view_info = null;
    state.menu_view_status_bar = null;
    state.menu_view_list = null;
    state.menu_view_grid = null;
    state.menu_view_sort_directories = null;
    state.menu_go_back = null;
    state.menu_go_forward = null;
    state.menu_go_up = null;
    state.menu_go_home = null;
    state.menu_help_about = null;
    state.context_popup = null;
    state.context_open = null;
    state.context_copy = null;
    state.context_cut = null;
    state.context_paste = null;
    state.context_delete = null;
    state.context_rename = null;
    state.context_move_parent = null;
    state.context_copy_path = null;
    state.context_open_link_target = null;
    state.rename_input_handle = null;
    clearAssetTracking(state);
    state.place_handles.clearRetainingCapacity();
    state.folder_tree_handles.clearRetainingCapacity();
    state.breadcrumb_handles.clearRetainingCapacity();
    clearUiStrings(state);
    clearTrackedPaths(&state.folder_tree_paths);
    clearTrackedPaths(&state.breadcrumb_paths);
}

fn deinitBrowserState(state: *State) void {
    clearUiTracking(state);
    clearEntries(state);
    clearPlaces(state);
    clearSelectedPaths(state);
    for (state.history.items) |path| allocator.free(path);
    state.history.deinit(allocator);
    state.places.deinit(allocator);
    state.entries.deinit(allocator);
    state.selected_paths.deinit(allocator);
    state.place_handles.deinit(allocator);
    state.folder_tree_handles.deinit(allocator);
    state.breadcrumb_handles.deinit(allocator);
    state.folder_tree_paths.deinit(allocator);
    clearTrackedPaths(&state.folder_tree_expanded_paths);
    state.folder_tree_expanded_paths.deinit(allocator);
    state.breadcrumb_paths.deinit(allocator);
    state.row_handles.deinit(allocator);
    state.name_cell_handles.deinit(allocator);
    state.grid_handles.deinit(allocator);
    state.ui_strings.deinit(allocator);
    state.asset_ui_strings.deinit(allocator);
    state.composed_paint_commands.deinit(allocator);
    if (state.current_dir.len > 0) allocator.free(state.current_dir);
    state.current_dir = &.{};
    freeOptionalOwnedSlice(&state.selected_path);
    freeOptionalOwnedSlice(&state.last_click_path);
    freeOptionalOwnedSlice(&state.context_target_path);
    freeOptionalOwnedSlice(&state.rename_path);
}

fn trackUiString(state: *State, text: []u8) ![]const u8 {
    try state.ui_strings.append(allocator, text);
    return text;
}

fn trackAssetUiString(state: *State, text: []u8) ![]const u8 {
    try state.asset_ui_strings.append(allocator, text);
    return text;
}

fn allocUiString(state: *State, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return trackUiString(state, try std.fmt.allocPrint(allocator, fmt, args));
}

fn allocAssetUiString(state: *State, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return trackAssetUiString(state, try std.fmt.allocPrint(allocator, fmt, args));
}

fn allocUtf8LossyOwned(bytes: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.unicode.fmtUtf8(bytes)});
}

fn allocUiUtf8Lossy(state: *State, bytes: []const u8) ![]const u8 {
    return trackUiString(state, try allocUtf8LossyOwned(bytes));
}

fn allocAssetUiUtf8Lossy(state: *State, bytes: []const u8) ![]const u8 {
    return trackAssetUiString(state, try allocUtf8LossyOwned(bytes));
}

fn allocUiEllipsizedUtf8Lossy(state: *State, bytes: []const u8, max_width: f32, font_size: f32) ![]const u8 {
    const full = try allocUtf8LossyOwned(bytes);
    errdefer allocator.free(full);

    const text_ctx = state.text_measure_ctx;
    if (text_ctx == null or goop.layout.measureTextDimensions(full, font_size, text_ctx).width <= max_width) {
        return trackUiString(state, full);
    }

    const ellipsis = "...";
    const ellipsis_width = goop.layout.measureTextDimensions(ellipsis, font_size, text_ctx).width;
    if (ellipsis_width >= max_width) {
        allocator.free(full);
        return allocUiString(state, "{s}", .{ellipsis});
    }

    var codepoint_ends: std.ArrayListUnmanaged(usize) = .empty;
    defer codepoint_ends.deinit(allocator);

    var total_bytes: usize = 0;
    var view = std.unicode.Utf8View.init(full) catch unreachable;
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        total_bytes += slice.len;
        try codepoint_ends.append(allocator, total_bytes);
    }

    var keep = codepoint_ends.items.len;
    while (keep > 0) : (keep -= 1) {
        const prefix_len = codepoint_ends.items[keep - 1];
        const prefix_width = goop.layout.measureTextDimensions(full[0..prefix_len], font_size, text_ctx).width;
        if (prefix_width + ellipsis_width <= max_width) {
            const truncated = try std.fmt.allocPrint(allocator, "{s}{s}", .{ full[0..prefix_len], ellipsis });
            allocator.free(full);
            return trackUiString(state, truncated);
        }
    }

    allocator.free(full);
    return allocUiString(state, "{s}", .{ellipsis});
}

fn allocAssetUiEllipsizedUtf8Lossy(state: *State, bytes: []const u8, max_width: f32, font_size: f32) ![]const u8 {
    const full = try allocUtf8LossyOwned(bytes);
    errdefer allocator.free(full);

    const text_ctx = state.text_measure_ctx;
    if (text_ctx == null or goop.layout.measureTextDimensions(full, font_size, text_ctx).width <= max_width) {
        return trackAssetUiString(state, full);
    }

    const ellipsis = "...";
    const ellipsis_width = goop.layout.measureTextDimensions(ellipsis, font_size, text_ctx).width;
    if (ellipsis_width >= max_width) {
        allocator.free(full);
        return allocAssetUiString(state, "{s}", .{ellipsis});
    }

    var codepoint_ends: std.ArrayListUnmanaged(usize) = .empty;
    defer codepoint_ends.deinit(allocator);

    var total_bytes: usize = 0;
    var view = std.unicode.Utf8View.init(full) catch unreachable;
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        total_bytes += slice.len;
        try codepoint_ends.append(allocator, total_bytes);
    }

    var keep = codepoint_ends.items.len;
    while (keep > 0) : (keep -= 1) {
        const prefix_len = codepoint_ends.items[keep - 1];
        const prefix_width = goop.layout.measureTextDimensions(full[0..prefix_len], font_size, text_ctx).width;
        if (prefix_width + ellipsis_width <= max_width) {
            const truncated = try std.fmt.allocPrint(allocator, "{s}{s}", .{ full[0..prefix_len], ellipsis });
            allocator.free(full);
            return trackAssetUiString(state, truncated);
        }
    }

    allocator.free(full);
    return allocAssetUiString(state, "{s}", .{ellipsis});
}

fn stateIo(state: *const State) !std.Io {
    return state.io orelse error.IoUnavailable;
}

fn homePath(state: *const State) ?[]const u8 {
    const env = state.env orelse return null;
    return env.get("HOME");
}

fn currentWorkingDirectoryAlloc(alloc: std.mem.Allocator, io: std.Io) ![]u8 {
    return std.process.currentPathAlloc(io, alloc);
}

fn normalizeDirectoryPath(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return alloc.dupe(u8, "/");
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return alloc.dupe(u8, path[0..end]);
}

fn ensureDirectoryOpenable(io: std.Io, path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return error.NotDir;
    defer dir.close(io);
}

fn joinPath(alloc: std.mem.Allocator, dir_path: []const u8, name: []const u8) ![]u8 {
    if (std.mem.eql(u8, dir_path, "/")) return std.fmt.allocPrint(alloc, "/{s}", .{name});
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, name });
}

fn parentPathAlloc(alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
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

fn pathHasDirectoryPrefix(path: []const u8, prefix: []const u8) bool {
    if (std.mem.eql(u8, prefix, "/")) return path.len > 0 and path[0] == '/';
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

fn folderTreeChildLessThan(_: void, a: FolderTreeChild, b: FolderTreeChild) bool {
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn clearFolderTreeChildren(children: *std.ArrayListUnmanaged(FolderTreeChild)) void {
    for (children.items) |child| {
        allocator.free(child.name);
        allocator.free(child.path);
    }
    children.clearRetainingCapacity();
}

fn collectFolderTreeChildren(io: std.Io, dir_path: []const u8, children: *std.ArrayListUnmanaged(FolderTreeChild)) !void {
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

fn folderTreeDirectoryHasChildren(io: std.Io, dir_path: []const u8) bool {
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

fn setAddressInputText(state: *State, text: []const u8) void {
    state.address_input = .{ .placeholder = "Path" };
    state.address_input.insertSlice(text);
    state.address_input.cursor = state.address_input.len;
}

fn syncAddressInputToCurrentDir(state: *State) void {
    setAddressInputText(state, state.current_dir);
}

fn syncAddressInputFromWidget(state: *State, ctx: *goop.Context) void {
    const handle = state.address_input_handle orelse return;
    if (!ctx.isAlive(handle)) return;
    if (ctx.tree.getConst(handle).kind != .text_input) return;
    state.address_input = ctx.tree.getConst(handle).kind.text_input;
}

fn syncRenameInputFromWidget(state: *State, ctx: *goop.Context) void {
    const handle = state.rename_input_handle orelse return;
    if (!ctx.isAlive(handle)) return;
    if (ctx.tree.getConst(handle).kind != .text_input) return;
    state.rename_input = ctx.tree.getConst(handle).kind.text_input;
}

fn addressInputPathAlloc(state: *const State) ![]u8 {
    const typed = std.mem.trim(u8, state.address_input.content(), " \t\r\n");
    if (typed.len == 0) return allocator.dupe(u8, state.current_dir);

    if (typed[0] == '~') {
        if (typed.len == 1 or typed[1] == '/') {
            if (homePath(state)) |home| {
                if (typed.len == 1) return normalizeDirectoryPath(allocator, home);
                const joined = try std.fs.path.resolve(allocator, &.{ home, typed[2..] });
                defer allocator.free(joined);
                return normalizeDirectoryPath(allocator, joined);
            }
        }
    }

    if (std.fs.path.isAbsolute(typed)) return normalizeDirectoryPath(allocator, typed);
    const joined = try std.fs.path.resolve(allocator, &.{ state.current_dir, typed });
    defer allocator.free(joined);
    return normalizeDirectoryPath(allocator, joined);
}

fn resolveSymlinkTargetAlloc(io: std.Io, alloc: std.mem.Allocator, link_path: []const u8) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const read_len = try std.Io.Dir.readLinkAbsolute(io, link_path, &buf);
    const target = buf[0..read_len];
    if (std.fs.path.isAbsolute(target)) return alloc.dupe(u8, target);

    const parent = std.fs.path.dirname(link_path) orelse "/";
    return std.fs.path.resolve(alloc, &.{ parent, target });
}

fn selectedPathForClipboard(state: *const State) []const u8 {
    if (state.selected_path) |selected_path| return selected_path;
    return state.current_dir;
}

fn fileTypeLabel(name: []const u8) []const u8 {
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

fn browserEntryKind(kind: std.Io.File.Kind) BrowserEntryKind {
    return switch (kind) {
        .directory => .directory,
        .file => .file,
        .sym_link => .symlink,
        else => .other,
    };
}

fn unixSecondsFromTimestamp(timestamp: std.Io.Timestamp) i64 {
    const seconds = @divFloor(timestamp.nanoseconds, std.time.ns_per_s);
    return std.math.cast(i64, seconds) orelse if (seconds < 0)
        std.math.minInt(i64)
    else
        std.math.maxInt(i64);
}

const DecodedTimestamp = struct {
    year: u16,
    yday: u16,
    month_index: u8,
    day: u8,
    hour: u8,
    minute: u8,
};

fn decodeUnixSecondsUtc(unix_seconds: i64) ?DecodedTimestamp {
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

fn timestampMonthAbbrev(index: usize) []const u8 {
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

fn formatTimestampCompactText(buffer: []u8, unix_seconds: i64, now_seconds: ?i64) []const u8 {
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

fn formatTimestampDetailText(buffer: []u8, unix_seconds: i64) []const u8 {
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

fn formatSizeText(buffer: []u8, kind: BrowserEntryKind, size_bytes: u64, target_kind: ?BrowserEntryKind) []const u8 {
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

fn sortColumnLabel(column: BrowserSortColumn) []const u8 {
    return switch (column) {
        .name => "name",
        .modified => "modified time",
        .kind => "type",
        .size => "size",
    };
}

fn sortDirectionLabel(direction: BrowserSortDirection) []const u8 {
    return switch (direction) {
        .ascending => "ascending",
        .descending => "descending",
    };
}

fn allocAssetEntryNameText(state: *State, entry: BrowserEntry) ![]const u8 {
    return allocAssetUiString(state, "{f}", .{
        std.unicode.fmtUtf8(entry.name),
    });
}

fn currentUnixSeconds(state: *const State) ?i64 {
    const io = state.io orelse return null;
    const ns = std.Io.Clock.real.now(io).nanoseconds;
    const seconds = @divFloor(ns, std.time.ns_per_s);
    return std.math.cast(i64, seconds);
}

fn allocFormattedTimestamp(state: *State, unix_seconds: i64) ![]const u8 {
    var buf: [40]u8 = undefined;
    const text = formatTimestampCompactText(buf[0..], unix_seconds, currentUnixSeconds(state));
    return allocUiString(state, "{s}", .{text});
}

fn allocAssetFormattedTimestamp(state: *State, unix_seconds: i64) ![]const u8 {
    var buf: [40]u8 = undefined;
    const text = formatTimestampCompactText(buf[0..], unix_seconds, currentUnixSeconds(state));
    return allocAssetUiString(state, "{s}", .{text});
}

fn allocFormattedTimestampDetail(state: *State, unix_seconds: i64) ![]const u8 {
    var buf: [48]u8 = undefined;
    const text = formatTimestampDetailText(buf[0..], unix_seconds);
    return allocUiString(state, "{s}", .{text});
}

fn allocFormattedSize(state: *State, kind: BrowserEntryKind, size_bytes: u64, target_kind: ?BrowserEntryKind) ![]const u8 {
    var buf: [24]u8 = undefined;
    const text = formatSizeText(buf[0..], kind, size_bytes, target_kind);
    return allocUiString(state, "{s}", .{text});
}

fn allocAssetFormattedSize(state: *State, kind: BrowserEntryKind, size_bytes: u64, target_kind: ?BrowserEntryKind) ![]const u8 {
    var buf: [24]u8 = undefined;
    const text = formatSizeText(buf[0..], kind, size_bytes, target_kind);
    return allocAssetUiString(state, "{s}", .{text});
}

fn appendPlaceIfDirectory(state: *State, label: []const u8, path: []const u8) !void {
    const normalized = try normalizeDirectoryPath(allocator, path);
    errdefer allocator.free(normalized);
    ensureDirectoryOpenable(try stateIo(state), normalized) catch return;

    for (state.places.items) |existing| {
        if (std.mem.eql(u8, existing.path, normalized)) return;
    }

    try state.places.append(allocator, .{ .label = label, .path = normalized });
}

fn refreshPlaces(state: *State) !void {
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

fn sortFieldLess(state: *const State, a: BrowserEntry, b: BrowserEntry) bool {
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

fn browserEntryLessThan(state: *const State, a: BrowserEntry, b: BrowserEntry) bool {
    if (state.sort_directories_together and a.isDirectory() != b.isDirectory()) return a.isDirectory();
    if (sortFieldLess(state, a, b)) return true;
    if (sortFieldLess(state, b, a)) return false;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn sortDirectoryEntries(state: *State) void {
    std.mem.sort(BrowserEntry, state.entries.items, state, browserEntryLessThan);
}

fn isPathSelected(state: *const State, path: []const u8) bool {
    for (state.selected_paths.items) |selected| {
        if (std.mem.eql(u8, selected, path)) return true;
    }
    return false;
}

fn selectedPathCount(state: *const State) usize {
    return state.selected_paths.items.len;
}

fn selectedEntryExists(state: *const State, path: []const u8) bool {
    for (state.entries.items) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return true;
    }
    return false;
}

fn setSelectedPath(state: *State, path: ?[]const u8) !void {
    freeOptionalOwnedSlice(&state.selected_path);
    if (path) |value| state.selected_path = try allocator.dupe(u8, value);
}

fn setContextTargetPath(state: *State, path: ?[]const u8) !void {
    freeOptionalOwnedSlice(&state.context_target_path);
    if (path) |value| state.context_target_path = try allocator.dupe(u8, value);
}

fn setLastClickPath(state: *State, path: ?[]const u8) !void {
    freeOptionalOwnedSlice(&state.last_click_path);
    if (path) |value| state.last_click_path = try allocator.dupe(u8, value);
}

fn clearRenameState(state: *State) void {
    freeOptionalOwnedSlice(&state.rename_path);
    state.rename_input = .{};
    state.rename_input_handle = null;
    state.rename_commit_requested = false;
    state.rename_cancel_requested = false;
}

fn isRenamingPath(state: *const State, path: []const u8) bool {
    const rename_path = state.rename_path orelse return false;
    return std.mem.eql(u8, rename_path, path);
}

fn beginRenameEntry(state: *State, ctx: *goop.Context, entry: BrowserEntry) !void {
    clearRenameState(state);
    state.rename_path = try allocator.dupe(u8, entry.path);
    state.rename_input = .{};
    state.rename_input.insertSlice(entry.name);
    state.rename_input.selection_anchor = 0;
    state.rename_input.cursor = state.rename_input.len;
    state.status_note = null;
    ctx.invalidate();
}

fn cancelActiveRename(state: *State) bool {
    if (state.rename_path == null) return false;
    clearRenameState(state);
    state.status_note = null;
    return true;
}

const RenameFinish = enum {
    inactive,
    closed,
    blocked,
};

fn validRenameFileName(name: []const u8) bool {
    return name.len > 0 and
        std.mem.indexOfScalar(u8, name, '/') == null and
        std.mem.indexOfScalar(u8, name, 0) == null;
}

fn commitActiveRename(state: *State) !RenameFinish {
    const old_path = state.rename_path orelse return .inactive;
    const new_name = state.rename_input.content();
    if (!validRenameFileName(new_name)) {
        state.status_note = "File names cannot be empty or contain '/'.";
        return .blocked;
    }

    if (std.mem.eql(u8, new_name, std.fs.path.basename(old_path))) {
        clearRenameState(state);
        state.status_note = null;
        return .closed;
    }

    const new_path = try joinPath(allocator, state.current_dir, new_name);
    defer allocator.free(new_path);

    const io = state.io orelse {
        state.status_note = "Unable to rename this file.";
        return .blocked;
    };
    if (std.Io.Dir.cwd().statFile(io, new_path, .{ .follow_symlinks = false })) |_| {
        state.status_note = "A file with that name already exists.";
        return .blocked;
    } else |_| {}

    std.Io.Dir.renameAbsolute(old_path, new_path, io) catch {
        state.status_note = "Unable to rename this file.";
        return .blocked;
    };

    clearSelectedPaths(state);
    try appendSelectedPathIfMissing(state, new_path);
    try setSelectedPath(state, new_path);
    freeOptionalOwnedSlice(&state.last_click_path);
    state.last_click_ms = 0;
    clearRenameState(state);
    try loadDirectoryEntries(state);
    state.status_note = "Renamed file.";
    return .closed;
}

fn currentPrimaryClickTimestampMs(ctx: *const goop.Context, io: std.Io) u64 {
    const event_ms = ctx.lastPrimaryPressTimestampMs();
    if (event_ms != 0) return event_ms;
    return getMonotonicNs(io) / std.time.ns_per_ms;
}

fn isRepeatedEntryClick(state: *const State, entry: *const BrowserEntry, click_ms: u64) bool {
    const last_path = state.last_click_path orelse return false;
    if (state.last_click_ms == 0 or click_ms < state.last_click_ms) return false;
    if (!std.mem.eql(u8, last_path, entry.path)) return false;
    return click_ms - state.last_click_ms <= browser_double_click_time_ms;
}

fn syncPrimarySelection(state: *State) !void {
    if (state.selected_path) |selected_path| {
        if (isPathSelected(state, selected_path)) return;
        freeOptionalOwnedSlice(&state.selected_path);
    }

    if (state.selected_paths.items.len > 0) {
        try setSelectedPath(state, state.selected_paths.items[0]);
    }
}

fn selectedPathIndex(state: *const State, path: []const u8) ?usize {
    for (state.selected_paths.items, 0..) |selected, index| {
        if (std.mem.eql(u8, selected, path)) return index;
    }
    return null;
}

fn appendSelectedPathIfMissing(state: *State, path: []const u8) !void {
    if (selectedPathIndex(state, path) != null) return;
    try state.selected_paths.append(allocator, try allocator.dupe(u8, path));
}

fn removeSelectedPath(state: *State, path: []const u8) bool {
    const index = selectedPathIndex(state, path) orelse return false;
    allocator.free(state.selected_paths.orderedRemove(index));
    return true;
}

fn syncSelectionAnchor(state: *State) void {
    state.selection_anchor_index = selectedEntryIndex(state);
}

fn applyEntrySelectionClick(state: *State, entry_index: usize) !void {
    if (entry_index >= state.entries.items.len) return;
    const entry = state.entries.items[entry_index];

    if (state.shift_down) {
        const anchor = state.selection_anchor_index orelse entry_index;
        if (!state.ctrl_down) clearSelectedPaths(state);

        const start = @min(anchor, entry_index);
        const end = @max(anchor, entry_index);
        for (start..end + 1) |index| {
            try appendSelectedPathIfMissing(state, state.entries.items[index].path);
        }
        state.selection_anchor_index = anchor;
    } else if (state.ctrl_down) {
        state.selection_anchor_index = entry_index;
        if (!removeSelectedPath(state, entry.path)) {
            try appendSelectedPathIfMissing(state, entry.path);
        }
    } else {
        clearSelectedPaths(state);
        try appendSelectedPathIfMissing(state, entry.path);
        state.selection_anchor_index = entry_index;
    }

    if (isPathSelected(state, entry.path)) {
        try setSelectedPath(state, entry.path);
    } else {
        try syncPrimarySelection(state);
    }
}

fn syncSelectedPathsFromTable(state: *State, ctx: *goop.Context, handle: goop.NodeHandle) !void {
    clearSelectedPaths(state);

    var row_index: usize = 0;
    var iter = ctx.tree.children(handle);
    while (iter.next()) |child| {
        const node = ctx.tree.getConst(child);
        if (node.kind != .table_row or node.kind.table_row.header) continue;
        const entry_index = state.asset_visible_start + row_index;
        if (entry_index >= state.entries.items.len) break;
        if (node.kind.table_row.selected) {
            try state.selected_paths.append(allocator, try allocator.dupe(u8, state.entries.items[entry_index].path));
        }
        row_index += 1;
    }

    try syncPrimarySelection(state);
}

fn syncSelectedPathsFromGrid(state: *State, ctx: *goop.Context, handle: goop.NodeHandle) !void {
    clearSelectedPaths(state);

    var item_index: usize = 0;
    var iter = ctx.tree.children(handle);
    while (iter.next()) |child| {
        const node = ctx.tree.getConst(child);
        if (node.kind != .grid_item) continue;
        const entry_index = state.asset_visible_start + item_index;
        if (entry_index >= state.entries.items.len) break;
        if (node.kind.grid_item.selected) {
            try state.selected_paths.append(allocator, try allocator.dupe(u8, state.entries.items[entry_index].path));
        }
        item_index += 1;
    }

    try syncPrimarySelection(state);
}

fn visibleEntryIndexForHandle(handles: []const goop.NodeHandle, handle: goop.NodeHandle, visible_start: usize, entry_count: usize) ?usize {
    for (handles, 0..) |candidate, visible_index| {
        if (!candidate.eql(handle)) continue;
        const entry_index = visible_start + visible_index;
        if (entry_index >= entry_count) return null;
        return entry_index;
    }
    return null;
}

fn pathIsSameOrInside(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    if (parent.len == 0 or child.len <= parent.len) return false;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return if (std.mem.eql(u8, parent, "/"))
        child[0] == '/'
    else
        child[parent.len] == '/';
}

fn moveDestinationPath(source_path: []const u8, target_dir: []const u8) ![]u8 {
    return joinPath(allocator, target_dir, std.fs.path.basename(source_path));
}

const MovePreflight = enum {
    movable,
    noop,
    blocked,
};

fn preflightMovePathToDirectory(state: *State, source_path: []const u8, target_dir: []const u8) !MovePreflight {
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

fn renamePathIntoDirectory(state: *State, source_path: []const u8, target_dir: []const u8) !bool {
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

fn movePathsToDirectory(state: *State, paths: []const []const u8, target_dir: []const u8) !bool {
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

fn moveDropPathsToDirectory(state: *State, source_path: []const u8, target_dir: []const u8) !bool {
    if (isPathSelected(state, source_path) and state.selected_paths.items.len > 0) {
        return movePathsToDirectory(state, state.selected_paths.items, target_dir);
    }

    const single_path = [_][]const u8{source_path};
    return movePathsToDirectory(state, single_path[0..], target_dir);
}

fn preflightCopyPathToDirectory(state: *State, source_path: []const u8, target_dir: []const u8) !bool {
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

fn copyPathToDirectory(state: *State, source_path: []const u8, target_dir: []const u8) ![]u8 {
    const destination = try moveDestinationPath(source_path, target_dir);
    errdefer allocator.free(destination);

    const io = state.io orelse {
        state.status_note = "Unable to copy files.";
        return error.IoUnavailable;
    };
    try copyPathAbsolute(io, source_path, destination);
    return destination;
}

fn copyPathAbsolute(io: std.Io, source_path: []const u8, destination: []const u8) anyerror!void {
    const stat = try std.Io.Dir.cwd().statFile(io, source_path, .{ .follow_symlinks = false });
    switch (stat.kind) {
        .directory => try copyDirectoryAbsolute(io, source_path, destination),
        .sym_link => try copySymlinkAbsolute(io, source_path, destination),
        else => try std.Io.Dir.copyFileAbsolute(source_path, destination, io, .{ .replace = false }),
    }
}

fn copyDirectoryAbsolute(io: std.Io, source_path: []const u8, destination: []const u8) anyerror!void {
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

fn copySymlinkAbsolute(io: std.Io, source_path: []const u8, destination: []const u8) anyerror!void {
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

fn copyPathsToDirectory(state: *State, paths: []const []const u8, target_dir: []const u8) !bool {
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

fn deletePaths(state: *State, paths: []const []const u8) !bool {
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

fn handleAssetTableDrop(state: *State, drop: goop.TableDrop) !bool {
    if (drop.position != .row) return false;
    const source_index = visibleEntryIndexForHandle(state.row_handles.items, drop.source, state.asset_visible_start, state.entries.items.len) orelse return false;
    const target_index = visibleEntryIndexForHandle(state.row_handles.items, drop.target, state.asset_visible_start, state.entries.items.len) orelse return false;
    if (source_index == target_index) return false;

    const source_path = state.entries.items[source_index].path;
    const target_entry = state.entries.items[target_index];
    if (!target_entry.canEnter()) {
        state.status_note = "Drop files on a directory.";
        return true;
    }

    return moveDropPathsToDirectory(state, source_path, target_entry.navigationPath());
}

fn handleAssetGridDrop(state: *State, drop: goop.GridDrop) !bool {
    if (drop.position != .item) return false;
    const source_index = visibleEntryIndexForHandle(state.grid_handles.items, drop.source, state.asset_visible_start, state.entries.items.len) orelse return false;
    const target_index = visibleEntryIndexForHandle(state.grid_handles.items, drop.target, state.asset_visible_start, state.entries.items.len) orelse return false;
    if (source_index == target_index) return false;

    const source_path = state.entries.items[source_index].path;
    const target_entry = state.entries.items[target_index];
    if (!target_entry.canEnter()) {
        state.status_note = "Drop files on a directory.";
        return true;
    }

    return moveDropPathsToDirectory(state, source_path, target_entry.navigationPath());
}

fn assetPathForDragSource(state: *const State, source: goop.NodeHandle) ?[]const u8 {
    if (visibleEntryIndexForHandle(state.row_handles.items, source, state.asset_visible_start, state.entries.items.len)) |index| {
        return state.entries.items[index].path;
    }
    if (visibleEntryIndexForHandle(state.grid_handles.items, source, state.asset_visible_start, state.entries.items.len)) |index| {
        return state.entries.items[index].path;
    }
    return null;
}

fn borrowedDropDestinationPath(state: *const State, target: goop.NodeHandle) ?[]const u8 {
    for (state.place_handles.items, 0..) |handle, index| {
        if (handle.eql(target) and index < state.places.items.len) return state.places.items[index].path;
    }
    for (state.folder_tree_handles.items, 0..) |handle, index| {
        if (handle.eql(target) and index < state.folder_tree_paths.items.len) return state.folder_tree_paths.items[index];
    }
    for (state.breadcrumb_handles.items, 0..) |handle, index| {
        if (handle.eql(target) and index < state.breadcrumb_paths.items.len) return state.breadcrumb_paths.items[index];
    }
    return null;
}

fn handleAssetWidgetDrop(state: *State, drop: goop.WidgetDrop) !bool {
    const source_path = assetPathForDragSource(state, drop.source) orelse return false;

    if (state.btn_up) |up| {
        if (up.eql(drop.target)) {
            const parent = try parentPathAlloc(allocator, state.current_dir);
            defer if (parent) |path| allocator.free(path);
            const parent_path = parent orelse return false;
            return moveDropPathsToDirectory(state, source_path, parent_path);
        }
    }

    const target_dir = borrowedDropDestinationPath(state, drop.target) orelse return false;
    return moveDropPathsToDirectory(state, source_path, target_dir);
}

fn maybeStartWaylandAssetDrag(state: *State, ctx: *goop.Context) !bool {
    if (state.drag_source != null) return false;
    if (!ctx.runtime.mouse.left_down) return false;
    const drag_target = ctx.runtime.mouse.drag_target orelse return false;
    const pointer_outside_window = !state.pointer_inside or
        ctx.runtime.mouse.x < 0 or
        ctx.runtime.mouse.y < 0 or
        ctx.runtime.mouse.x >= @as(f32, @floatFromInt(state.logical_width)) or
        ctx.runtime.mouse.y >= @as(f32, @floatFromInt(state.logical_height));
    if (!pointer_outside_window) return false;

    const entry_index = switch (state.view_mode) {
        .list => visibleEntryIndexForHandle(state.row_handles.items, drag_target, state.asset_visible_start, state.entries.items.len),
        .grid => visibleEntryIndexForHandle(state.grid_handles.items, drag_target, state.asset_visible_start, state.entries.items.len),
    } orelse return false;

    const source_path = state.entries.items[entry_index].path;
    const started = if (isPathSelected(state, source_path) and state.selected_paths.items.len > 0)
        try state.startWaylandFileDrag(state.selected_paths.items)
    else blk: {
        const single_path = [_][]const u8{source_path};
        break :blk try state.startWaylandFileDrag(single_path[0..]);
    };

    if (started) {
        ctx.cancelPointerGesture();
        state.asset_selection_rebuild_pending = false;
        state.needs_redraw = true;
    }
    return started;
}

fn loadDirectoryEntries(state: *State) !void {
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

fn selectedEntryIndex(state: *const State) ?usize {
    const selected_path = state.selected_path orelse return null;
    for (state.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.path, selected_path)) return index;
    }
    return null;
}

fn selectedEntry(state: *const State) ?*const BrowserEntry {
    const index = selectedEntryIndex(state) orelse return null;
    return &state.entries.items[index];
}

fn setCurrentDirectory(state: *State, path: []const u8, push_history: bool) !bool {
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

fn navigateBack(state: *State) !bool {
    if (state.history_index == 0 or state.history.items.len == 0) return false;
    state.history_index -= 1;
    return setCurrentDirectory(state, state.history.items[state.history_index], false);
}

fn navigateForward(state: *State) !bool {
    if (state.history.items.len == 0 or state.history_index + 1 >= state.history.items.len) return false;
    state.history_index += 1;
    return setCurrentDirectory(state, state.history.items[state.history_index], false);
}

fn navigateUp(state: *State) !bool {
    const parent = try parentPathAlloc(allocator, state.current_dir);
    defer if (parent) |path| allocator.free(path);
    const parent_path = parent orelse return false;
    return setCurrentDirectory(state, parent_path, true);
}

fn refreshCurrentDirectory(state: *State) !void {
    freeOptionalOwnedSlice(&state.last_click_path);
    state.last_click_ms = 0;
    syncAddressInputToCurrentDir(state);
    try loadDirectoryEntries(state);
}

fn clearSelectionState(state: *State) bool {
    if (state.selected_paths.items.len == 0 and state.selected_path == null) return false;
    clearSelectedPaths(state);
    freeOptionalOwnedSlice(&state.selected_path);
    freeOptionalOwnedSlice(&state.last_click_path);
    state.last_click_ms = 0;
    state.selection_anchor_index = null;
    return true;
}

fn selectAllEntries(state: *State) !bool {
    if (state.entries.items.len == 0) return false;
    if (state.selected_paths.items.len == state.entries.items.len) return false;

    clearSelectedPaths(state);
    for (state.entries.items) |entry| {
        try state.selected_paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    try setSelectedPath(state, state.entries.items[0].path);
    syncSelectionAnchor(state);
    freeOptionalOwnedSlice(&state.last_click_path);
    state.last_click_ms = 0;
    return true;
}

fn selectedSymlinkDirectoryEntry(state: *const State) ?*const BrowserEntry {
    const entry = selectedEntry(state) orelse return null;
    return if (entry.isSymlinkToDirectory()) entry else null;
}

fn entryForPath(state: *const State, path: []const u8) ?*const BrowserEntry {
    for (state.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}

fn entryIndexForPath(state: *const State, path: []const u8) ?usize {
    for (state.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.path, path)) return index;
    }
    return null;
}

fn contextTargetEntry(state: *const State) ?*const BrowserEntry {
    const path = state.context_target_path orelse return null;
    return entryForPath(state, path);
}

fn contextOpenEnabled(state: *const State) bool {
    const path = state.context_target_path orelse return false;
    const entry = entryForPath(state, path) orelse return true;
    return entry.canEnter();
}

fn contextCopyPathEnabled(state: *const State) bool {
    return state.context_target_path != null;
}

fn contextOpenLinkTargetEnabled(state: *const State) bool {
    const entry = contextTargetEntry(state) orelse return false;
    return entry.isSymlinkToDirectory();
}

fn contextClickPosition(state: *const State, ctx: *const goop.Context) struct { x: f32, y: f32 } {
    if (ctx.lastSecondaryClick()) |click| {
        return .{ .x = click.x, .y = click.y };
    }
    return .{ .x = state.mouse_x, .y = state.mouse_y };
}

fn showContextMenuForPath(state: *State, ctx: *goop.Context, path: []const u8) !void {
    setTopMenuPopupVisible(state, ctx, null);
    try setContextTargetPath(state, path);
    const position = contextClickPosition(state, ctx);
    state.context_x = position.x;
    state.context_y = position.y;
    state.context_visible = true;
    ctx.invalidate();
}

fn hideContextMenu(state: *State, ctx: *goop.Context) void {
    state.context_visible = false;
    if (state.context_popup) |popup| {
        if (ctx.isAlive(popup) and ctx.tree.getConst(popup).kind == .popup) {
            ctx.tree.get(popup).kind.popup.visible = false;
        }
    }
    ctx.invalidate();
}

fn syncContextPopupVisibleFromWidget(state: *State, ctx: *const goop.Context) void {
    const popup = state.context_popup orelse return;
    if (!ctx.isAlive(popup) or ctx.tree.getConst(popup).kind != .popup) return;
    state.context_visible = ctx.tree.getConst(popup).kind.popup.visible;
}

fn selectEntryForContextMenu(state: *State, entry_index: usize) !void {
    if (entry_index >= state.entries.items.len) return;
    const entry = state.entries.items[entry_index];
    if (!isPathSelected(state, entry.path)) {
        clearSelectedPaths(state);
        try appendSelectedPathIfMissing(state, entry.path);
    }
    try setSelectedPath(state, entry.path);
    state.selection_anchor_index = entry_index;
}

fn openContextTarget(state: *State) !bool {
    const path = state.context_target_path orelse return false;
    if (entryForPath(state, path)) |entry| {
        if (!entry.canEnter()) return false;
        state.status_note = null;
        return setCurrentDirectory(state, entry.navigationPath(), true);
    }
    state.status_note = null;
    return setCurrentDirectory(state, path, true);
}

fn copyContextTargetPath(state: *State) !bool {
    const path = state.context_target_path orelse return false;
    try state.setClipboardSelection(path);
    state.status_note = "Copied path to clipboard.";
    return false;
}

fn openContextLinkTarget(state: *State) !bool {
    const entry = contextTargetEntry(state) orelse return false;
    if (!entry.isSymlinkToDirectory()) return false;
    state.status_note = null;
    return setCurrentDirectory(state, entry.target_path.?, true);
}

fn selectionFileCommandEnabled(state: *const State) bool {
    return state.selected_paths.items.len > 0;
}

fn renameSelectionEnabled(state: *const State) bool {
    return state.selected_paths.items.len == 1 and selectedEntry(state) != null;
}

fn moveSelectionToParentEnabled(state: *const State) bool {
    return selectionFileCommandEnabled(state) and !std.mem.eql(u8, state.current_dir, "/");
}

fn fileClipboardAvailable(state: *const State) bool {
    if (state.clipboard_file_action != null and state.clipboard_buf.items.len > 0) return true;
    const offer = state.selection_offer orelse return false;
    return preferredFileOfferMime(offer) != null;
}

fn targetPathCanAcceptPaste(state: *const State, path: []const u8) bool {
    if (!fileClipboardAvailable(state)) return false;
    if (entryForPath(state, path)) |entry| return entry.canEnter();
    const io = state.io orelse return false;
    ensureDirectoryOpenable(io, path) catch return false;
    return true;
}

fn contextSelectionCommandEnabled(state: *const State) bool {
    const path = state.context_target_path orelse return false;
    return entryForPath(state, path) != null and state.selected_paths.items.len > 0;
}

fn contextRenameEnabled(state: *const State) bool {
    const path = state.context_target_path orelse return false;
    return entryForPath(state, path) != null and renameSelectionEnabled(state);
}

fn contextMoveParentEnabled(state: *const State) bool {
    const path = state.context_target_path orelse return false;
    return entryForPath(state, path) != null and moveSelectionToParentEnabled(state);
}

fn contextPasteEnabled(state: *const State) bool {
    const path = state.context_target_path orelse return false;
    return targetPathCanAcceptPaste(state, path);
}

fn copyOrCutSelection(state: *State, action: FileClipboardAction) !bool {
    if (state.selected_paths.items.len == 0) return false;
    try state.setFileClipboardSelection(state.selected_paths.items, action);
    state.status_note = if (action == .cut) "Cut files to clipboard." else "Copied files to clipboard.";
    return false;
}

fn collectClipboardFilePaths(state: *State, paths: *std.ArrayListUnmanaged([]u8)) !?FileClipboardAction {
    clearTrackedPaths(paths);

    if (state.clipboard_file_action) |action| {
        var lines = std.mem.splitScalar(u8, state.clipboard_buf.items, '\n');
        while (lines.next()) |line| {
            const path = std.mem.trimEnd(u8, line, "\r");
            if (path.len == 0) continue;
            try paths.append(allocator, try allocator.dupe(u8, path));
        }
        return if (paths.items.len > 0) action else null;
    }

    const offer = state.selection_offer orelse return null;
    const mime = preferredFileOfferMime(offer) orelse return null;
    try state.fetchClipboardSelection(true);

    var action: FileClipboardAction = .copy;
    var lines = std.mem.splitScalar(u8, state.clipboard_buf.items, '\n');
    if (std.mem.eql(u8, std.mem.span(mime), dnd_mime_gnome_copied_files)) {
        const first = lines.next() orelse return null;
        const command = std.mem.trimEnd(u8, first, "\r");
        action = if (std.mem.eql(u8, command, "cut")) .cut else .copy;
    }

    while (lines.next()) |line| {
        try appendClipboardPathFromFileUri(paths, line);
    }

    return if (paths.items.len > 0) action else null;
}

fn pasteFilesToDirectory(state: *State, target_dir: []const u8) !bool {
    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        clearTrackedPaths(&paths);
        paths.deinit(allocator);
    }

    const action = (try collectClipboardFilePaths(state, &paths)) orelse {
        state.status_note = "Clipboard does not contain files.";
        return false;
    };

    const changed = switch (action) {
        .copy => try copyPathsToDirectory(state, paths.items, target_dir),
        .cut => try movePathsToDirectory(state, paths.items, target_dir),
    };
    if (changed and action == .cut and state.clipboard_file_action != null) {
        state.destroyClipboardSource();
        state.clearClipboardFilePayload();
    }
    return changed;
}

fn pasteContextTarget(state: *State) !bool {
    const path = state.context_target_path orelse return false;
    const target_dir = if (entryForPath(state, path)) |entry| blk: {
        if (!entry.canEnter()) return false;
        break :blk entry.navigationPath();
    } else path;
    return pasteFilesToDirectory(state, target_dir);
}

fn deleteSelection(state: *State) !bool {
    if (state.selected_paths.items.len == 0) return false;
    return deletePaths(state, state.selected_paths.items);
}

fn moveSelectionToParent(state: *State) !bool {
    if (!moveSelectionToParentEnabled(state)) return false;
    const parent = try parentPathAlloc(allocator, state.current_dir);
    defer if (parent) |path| allocator.free(path);
    const parent_path = parent orelse return false;
    return movePathsToDirectory(state, state.selected_paths.items, parent_path);
}

fn beginRenameSelection(state: *State, ctx: *goop.Context) !bool {
    if (!renameSelectionEnabled(state)) return false;
    const entry = selectedEntry(state) orelse return false;
    try beginRenameEntry(state, ctx, entry.*);
    return true;
}

fn browserCommandChecked(state: *const State, command: BrowserCommand) bool {
    return switch (command) {
        .toggle_sidebar => state.show_sidebar,
        .toggle_preview => state.show_preview,
        .toggle_info => state.show_info,
        .toggle_status_bar => state.show_status_bar,
        .view_list => state.view_mode == .list,
        .view_grid => state.view_mode == .grid,
        .toggle_sort_directories => state.sort_directories_together,
        else => false,
    };
}

fn browserCommandEnabled(state: *const State, command: BrowserCommand) bool {
    return switch (command) {
        .back => state.history_index > 0 and state.history.items.len > 0,
        .forward => state.history.items.len > 0 and state.history_index + 1 < state.history.items.len,
        .up => !std.mem.eql(u8, state.current_dir, "/"),
        .home => homePath(state) != null,
        .refresh => true,
        .copy, .cut, .delete => selectionFileCommandEnabled(state),
        .paste => fileClipboardAvailable(state),
        .rename => renameSelectionEnabled(state),
        .move_parent => moveSelectionToParentEnabled(state),
        .copy_path => true,
        .open_link_target => selectedSymlinkDirectoryEntry(state) != null,
        .quit => true,
        .select_all => state.entries.items.len > 0,
        .clear_selection => state.selected_paths.items.len > 0,
        .toggle_sidebar,
        .toggle_preview,
        .toggle_info,
        .toggle_status_bar,
        .view_list,
        .view_grid,
        .toggle_sort_directories,
        .about,
        => true,
    };
}

fn runBrowserCommand(state: *State, command: BrowserCommand) !bool {
    switch (command) {
        .back => {
            state.status_note = null;
            return navigateBack(state);
        },
        .forward => {
            state.status_note = null;
            return navigateForward(state);
        },
        .up => {
            state.status_note = null;
            return navigateUp(state);
        },
        .home => {
            if (homePath(state)) |home| {
                state.status_note = null;
                return setCurrentDirectory(state, home, true);
            }
            return false;
        },
        .refresh => {
            state.status_note = null;
            try refreshCurrentDirectory(state);
            return true;
        },
        .copy => return copyOrCutSelection(state, .copy),
        .cut => return copyOrCutSelection(state, .cut),
        .paste => return pasteFilesToDirectory(state, state.current_dir),
        .delete => return deleteSelection(state),
        .rename => return false,
        .move_parent => return moveSelectionToParent(state),
        .copy_path => {
            try state.setClipboardSelection(selectedPathForClipboard(state));
            state.status_note = "Copied path to clipboard.";
            return false;
        },
        .open_link_target => {
            const entry = selectedSymlinkDirectoryEntry(state) orelse return false;
            state.status_note = null;
            return setCurrentDirectory(state, entry.target_path.?, true);
        },
        .quit => {
            state.running = false;
            return false;
        },
        .select_all => {
            state.status_note = null;
            return selectAllEntries(state);
        },
        .clear_selection => {
            state.status_note = null;
            return clearSelectionState(state);
        },
        .toggle_sidebar => {
            state.show_sidebar = !state.show_sidebar;
            return true;
        },
        .toggle_preview => {
            state.show_preview = !state.show_preview;
            return true;
        },
        .toggle_info => {
            state.show_info = !state.show_info;
            return true;
        },
        .toggle_status_bar => {
            state.show_status_bar = !state.show_status_bar;
            return true;
        },
        .view_list => {
            if (state.view_mode == .list) return false;
            state.view_mode = .list;
            return true;
        },
        .view_grid => {
            if (state.view_mode == .grid) return false;
            state.view_mode = .grid;
            return true;
        },
        .toggle_sort_directories => {
            state.sort_directories_together = !state.sort_directories_together;
            sortDirectoryEntries(state);
            syncSelectionAnchor(state);
            return true;
        },
        .about => {
            state.status_note = "goop files: a Wayland/EGL/snail file manager demo.";
            return false;
        },
    }
}

fn setTopMenuPopupVisible(state: *const State, ctx: *goop.Context, target: ?goop.NodeHandle) void {
    const popups = [_]?goop.NodeHandle{
        state.menu_file_popup,
        state.menu_edit_popup,
        state.menu_view_popup,
        state.menu_go_popup,
        state.menu_help_popup,
    };

    var changed = false;
    for (popups) |popup_handle| {
        const popup = popup_handle orelse continue;
        if (!ctx.isAlive(popup) or ctx.tree.getConst(popup).kind != .popup) continue;
        const visible = if (target) |selected| selected.eql(popup) else false;
        if (ctx.tree.getConst(popup).kind.popup.visible == visible) continue;
        ctx.tree.get(popup).kind.popup.visible = visible;
        changed = true;
    }
    if (changed) ctx.invalidate();
}

fn toggleTopMenuPopup(state: *const State, ctx: *goop.Context, popup: ?goop.NodeHandle) void {
    const target = popup orelse {
        setTopMenuPopupVisible(state, ctx, null);
        return;
    };
    if (!ctx.isAlive(target) or ctx.tree.getConst(target).kind != .popup) return;
    const should_open = !ctx.tree.getConst(target).kind.popup.visible;
    setTopMenuPopupVisible(state, ctx, if (should_open) target else null);
}

fn initializeBrowserState(state: *State) !void {
    const cwd = try currentWorkingDirectoryAlloc(allocator, try stateIo(state));
    defer allocator.free(cwd);
    _ = try setCurrentDirectory(state, cwd, true);
    try refreshPlaces(state);
}

fn captureFilePanelViewport(state: *State, ctx: *goop.Context) void {
    const handle = state.file_panel_scroll orelse return;
    if (!ctx.isAlive(handle)) return;
    const node = ctx.tree.getConst(handle);
    state.file_panel_scroll_y = node.kind.scroll_area.scroll_y;
    state.file_panel_viewport_width = node.layout_rect.w;
    state.file_panel_viewport_height = node.layout_rect.h;
}

fn captureSidebarScroll(state: *State, ctx: *goop.Context) void {
    const handle = state.sidebar_scroll orelse return;
    if (!ctx.isAlive(handle)) return;
    const node = ctx.tree.getConst(handle);
    if (node.kind != .scroll_area) return;
    state.sidebar_scroll_x = node.kind.scroll_area.scroll_x;
    state.sidebar_scroll_y = node.kind.scroll_area.scroll_y;
}

fn browserViewportWidthEstimate(state: *const State) f32 {
    if (state.file_panel_viewport_width > 0) return state.file_panel_viewport_width;
    return @as(f32, @floatFromInt(state.logical_width));
}

fn browserViewportHeightEstimate(state: *const State) f32 {
    if (state.file_panel_viewport_height > 0) return state.file_panel_viewport_height;
    return @as(f32, @floatFromInt(state.logical_height));
}

fn browserVirtualGap(state: *const State) f32 {
    if (state.ctx) |ctx| return ctx.theme.spacing;
    return goop.Theme.default.spacing;
}

fn browserListRowHeight(state: *const State) f32 {
    const ctx = state.ctx orelse return uiPx(state, 26);
    const text_metrics = goop.layout.textMetrics(ctx.theme.font_size, state.text_measure_ctx);
    return text_metrics.height + ctx.theme.padding.top + ctx.theme.padding.bottom;
}

fn browserGridColumnsForViewport(state: *const State, viewport_width: f32) usize {
    const grid_padding_h = browserGridPaddingHPx(state);
    const grid_item_width = browserGridItemWidthPx(state);
    const grid_column_gap = browserGridColumnGapPx(state);
    const inner_width = @max(viewport_width - grid_padding_h * 2, grid_item_width);
    const slot_width = grid_item_width + grid_column_gap;
    return @max(@as(usize, @intFromFloat(@floor((inner_width + grid_column_gap) / slot_width))), 1);
}

fn browserVisibleCount(viewport_extent: f32, slot_extent: f32) usize {
    return @max(@as(usize, @intFromFloat(@ceil(viewport_extent / slot_extent))), 1);
}

fn browserVirtualChunkRows(visible_count: usize) usize {
    return @max(visible_count, browser_virtual_chunk_rows_min);
}

fn browserVirtualRange(total_items: usize, visible_start: usize, visible_count: usize) struct { start: usize, end: usize } {
    if (total_items == 0) return .{ .start = 0, .end = 0 };

    const chunk_rows = browserVirtualChunkRows(visible_count);
    const render_count = @min(total_items, visible_count + chunk_rows + browser_overscan_rows * 2);
    if (render_count >= total_items) return .{ .start = 0, .end = total_items };

    const chunk_origin = (visible_start / chunk_rows) * chunk_rows;
    var start = chunk_origin -| browser_overscan_rows;
    if (start + render_count > total_items) start = total_items - render_count;
    return .{
        .start = start,
        .end = start + render_count,
    };
}

fn browserListWindow(state: *const State, viewport_height: f32) ListVirtualWindow {
    const total_entries = state.entries.items.len;
    if (total_entries == 0) return .{};

    const row_height = browserListRowHeight(state);
    const virtual_gap = browserVirtualGap(state);
    const total_height = row_height * @as(f32, @floatFromInt(total_entries));
    const scroll_y = std.math.clamp(state.file_panel_scroll_y, 0, @max(total_height - viewport_height, 0));
    const visible_start = @min(total_entries, @as(usize, @intFromFloat(@floor(scroll_y / row_height))));
    const visible_count = browserVisibleCount(viewport_height, row_height);
    const range = browserVirtualRange(total_entries, visible_start, visible_count);
    const start = range.start;
    const end = range.end;
    const top_spacer = if (start > 0)
        @max(row_height * @as(f32, @floatFromInt(start)) - virtual_gap, 0)
    else
        0;
    const bottom_spacer = if (end < total_entries)
        @max(row_height * @as(f32, @floatFromInt(total_entries - end)) - virtual_gap, 0)
    else
        0;

    return .{
        .start = start,
        .end = end,
        .top_spacer = top_spacer,
        .bottom_spacer = bottom_spacer,
        .scroll_y = scroll_y,
    };
}

fn browserGridWindow(state: *const State, viewport_width: f32, viewport_height: f32) GridVirtualWindow {
    const columns = browserGridColumnsForViewport(state, viewport_width);
    const total_entries = state.entries.items.len;
    if (total_entries == 0) return .{ .columns = columns };

    const virtual_gap = browserVirtualGap(state);
    const grid_padding_v = browserGridPaddingVPx(state);
    const grid_item_height = browserGridItemHeightPx(state);
    const grid_row_gap = browserGridRowGapPx(state);
    const total_rows = std.math.divCeil(usize, total_entries, columns) catch unreachable;
    const total_height = grid_padding_v * 2 +
        grid_item_height * @as(f32, @floatFromInt(total_rows)) +
        grid_row_gap * @as(f32, @floatFromInt(total_rows - 1));
    const scroll_y = std.math.clamp(state.file_panel_scroll_y, 0, @max(total_height - viewport_height, 0));
    const slot_height = grid_item_height + grid_row_gap;
    const content_scroll_y = @max(scroll_y - grid_padding_v, 0);
    const visible_start_row = @min(total_rows, @as(usize, @intFromFloat(@floor(content_scroll_y / slot_height))));
    const inner_viewport_height = @max(viewport_height - grid_padding_v * 2, grid_item_height);
    const visible_row_count = browserVisibleCount(inner_viewport_height + grid_row_gap, slot_height);
    const row_range = browserVirtualRange(total_rows, visible_start_row, visible_row_count);
    const start_row = row_range.start;
    const end_row = row_range.end;
    const start = @min(total_entries, start_row * columns);
    const end = @min(total_entries, end_row * columns);
    const rendered_rows = end_row - start_row;
    const visible_height = grid_item_height * @as(f32, @floatFromInt(rendered_rows)) +
        grid_row_gap * @as(f32, @floatFromInt(if (rendered_rows > 0) rendered_rows - 1 else 0));
    const body_y = grid_padding_v + @as(f32, @floatFromInt(start_row)) * slot_height;
    const remaining_height = @max(total_height - body_y - visible_height, 0);
    const top_spacer = if (body_y > 0)
        @max(body_y - virtual_gap, 0)
    else
        0;
    const bottom_spacer = if (remaining_height > 0)
        @max(remaining_height - virtual_gap, 0)
    else
        0;

    return .{
        .start = start,
        .end = end,
        .columns = columns,
        .top_spacer = top_spacer,
        .bottom_spacer = bottom_spacer,
        .scroll_y = scroll_y,
    };
}

fn addTextCell(state: *const State, ctx: *goop.Context, row: goop.NodeHandle, text: []const u8) !void {
    const cell = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    ctx.tree.get(cell).style_override = .{
        .border_width = browserTableDividerWidthPx(state),
    };
    _ = try ctx.tree.addChild(cell, .{ .text = .{ .content = text, .overflow = .ellipsis } });
}

fn addNameHeaderCell(state: *const State, ctx: *goop.Context, row: goop.NodeHandle, text: []const u8) !void {
    const cell = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    ctx.tree.get(cell).style_override = .{
        .border_width = browserTableDividerWidthPx(state),
        .padding = .{
            .top = uiPx(state, 6),
            .right = uiPx(state, 8),
            .bottom = uiPx(state, 6),
            .left = browserNameIconInsetLeftPx(state),
        },
    };
    _ = try ctx.tree.addChild(cell, .{ .text = .{ .content = text, .overflow = .ellipsis } });
}

fn addNameCell(state: *State, ctx: *goop.Context, row: goop.NodeHandle, entry: BrowserEntry) !goop.NodeHandle {
    const cell = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    ctx.tree.get(cell).style_override = .{
        .border_width = browserTableDividerWidthPx(state),
        .padding = .{
            .top = uiPx(state, 6),
            .right = uiPx(state, 8),
            .bottom = uiPx(state, 6),
            .left = browserNameTextInsetLeftPx(state),
        },
    };
    ctx.tree.get(cell).custom_draw = true;
    if (isRenamingPath(state, entry.path)) {
        const input = try ctx.tree.addChild(cell, .{ .text_input = state.rename_input });
        ctx.tree.get(input).style_override = fileManagerRenameInputStyle(state);
        state.rename_input_handle = input;
        focusWidget(ctx, input);
    } else {
        _ = try ctx.tree.addChild(cell, .{ .text = .{
            .content = try allocAssetEntryNameText(state, entry),
            .overflow = .ellipsis,
        } });
    }
    return cell;
}

fn detailTitleFontSizePx(state: *const State) f32 {
    return uiPx(state, 16);
}

fn detailCaptionFontSizePx(state: *const State) f32 {
    return uiPx(state, 13);
}

fn previewBodyFontSizePx(state: *const State) f32 {
    return uiPx(state, 13);
}

fn clampDetailSplitterRatio(raw: f32, available: f32, min_first: f32, min_second: f32) f32 {
    const clamped = std.math.clamp(raw, 0, 1);
    if (available <= 0) return clamped;

    const min_ratio = std.math.clamp(min_first / available, 0, 1);
    const max_ratio = std.math.clamp(1 - min_second / available, 0, 1);
    if (min_ratio > max_ratio) return clamped;
    return std.math.clamp(clamped, min_ratio, max_ratio);
}

fn browserBodyWidthPx(state: *const State) f32 {
    var width = @max(@as(f32, @floatFromInt(@max(state.logical_width, @as(u32, 1)))) - 1, 1);
    if (state.show_sidebar) {
        const nav_ratio = clampDetailSplitterRatio(state.nav_ratio, width, uiPx(state, 220), uiPx(state, 420));
        width *= 1 - nav_ratio;
    }
    return @max(width, 1);
}

fn inspectorPanelWidthPx(state: *const State) f32 {
    var width = browserBodyWidthPx(state);
    if (state.show_preview or state.show_info) {
        const detail_ratio = clampDetailSplitterRatio(state.detail_ratio, width, uiPx(state, 360), uiPx(state, 300));
        width *= 1 - detail_ratio;
    }
    return @max(width, uiPx(state, 200));
}

fn detailTextWrapWidthPx(state: *const State) f32 {
    // Reserve the scroll + panel padding so wrapped inspector text stays inside the pane body.
    return @max(inspectorPanelWidthPx(state) - uiPx(state, 44), uiPx(state, 156));
}

fn measureDetailTextWidth(text: []const u8, font_size: f32, text_ctx: *const goop.TextMeasureCtx) f32 {
    return goop.layout.measureTextDimensions(text, font_size, text_ctx).width;
}

fn isDetailWrapBoundary(codepoint: u21) bool {
    return switch (codepoint) {
        ' ', '\t', '/', '\\', '-', '_', '.' => true,
        else => false,
    };
}

fn flushDetailWrappedLine(out: *std.ArrayListUnmanaged(u8), line: *std.ArrayListUnmanaged(u8)) !void {
    if (line.items.len == 0) return;
    if (out.items.len > 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, line.items);
    line.clearRetainingCapacity();
}

fn appendDetailForcedWrappedToken(
    out: *std.ArrayListUnmanaged(u8),
    line: *std.ArrayListUnmanaged(u8),
    token: []const u8,
    max_width: f32,
    font_size: f32,
    text_ctx: *const goop.TextMeasureCtx,
) !void {
    var view = std.unicode.Utf8View.init(token) catch unreachable;
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const previous_len = line.items.len;
        try line.appendSlice(allocator, slice);
        if (previous_len == 0 or measureDetailTextWidth(line.items, font_size, text_ctx) <= max_width) continue;

        line.items.len = previous_len;
        try flushDetailWrappedLine(out, line);
        try line.appendSlice(allocator, slice);
    }
}

fn appendDetailWrappedToken(
    out: *std.ArrayListUnmanaged(u8),
    line: *std.ArrayListUnmanaged(u8),
    token: []const u8,
    max_width: f32,
    font_size: f32,
    text_ctx: *const goop.TextMeasureCtx,
) !void {
    if (token.len == 0) return;

    const previous_len = line.items.len;
    try line.appendSlice(allocator, token);
    if (measureDetailTextWidth(line.items, font_size, text_ctx) <= max_width) return;

    line.items.len = previous_len;
    if (previous_len > 0) {
        try flushDetailWrappedLine(out, line);
    }

    try appendDetailForcedWrappedToken(out, line, token, max_width, font_size, text_ctx);
}

fn wrapTextOwnedForWidth(state: *const State, text: []u8, font_size: f32, max_width: f32) ![]u8 {
    const text_ctx = state.text_measure_ctx orelse return text;
    if (std.mem.indexOfScalar(u8, text, '\n') == null and measureDetailTextWidth(text, font_size, text_ctx) <= max_width) {
        return text;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(allocator);
    var token: std.ArrayListUnmanaged(u8) = .empty;
    defer token.deinit(allocator);

    var view = std.unicode.Utf8View.init(text) catch unreachable;
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const codepoint = std.unicode.utf8Decode(slice) catch unreachable;
        if (codepoint == '\n') {
            try appendDetailWrappedToken(&out, &line, token.items, max_width, font_size, text_ctx);
            token.clearRetainingCapacity();
            try flushDetailWrappedLine(&out, &line);
            continue;
        }

        try token.appendSlice(allocator, slice);
        if (isDetailWrapBoundary(codepoint)) {
            try appendDetailWrappedToken(&out, &line, token.items, max_width, font_size, text_ctx);
            token.clearRetainingCapacity();
        }
    }

    try appendDetailWrappedToken(&out, &line, token.items, max_width, font_size, text_ctx);
    try flushDetailWrappedLine(&out, &line);

    if (out.items.len == 0 or std.mem.eql(u8, out.items, text)) return text;

    const wrapped = try allocator.dupe(u8, out.items);
    allocator.free(text);
    return wrapped;
}

fn wrapDetailTextOwned(state: *const State, text: []u8, font_size: f32) ![]u8 {
    return wrapTextOwnedForWidth(state, text, font_size, detailTextWrapWidthPx(state));
}

fn allocUiDetailWrappedUtf8Lossy(state: *State, bytes: []const u8, font_size: f32) ![]const u8 {
    return trackUiString(state, try wrapDetailTextOwned(state, try allocUtf8LossyOwned(bytes), font_size));
}

fn allocUiWrappedOwnedText(state: *State, text: []u8, font_size: f32) ![]const u8 {
    return trackUiString(state, try wrapTextOwnedForWidth(state, text, font_size, detailTextWrapWidthPx(state)));
}

fn addDetailText(
    ctx: *goop.Context,
    parent: goop.NodeHandle,
    text: []const u8,
    overflow: goop.TextOverflow,
) !goop.NodeHandle {
    return ctx.tree.addChild(parent, .{ .text = .{
        .content = text,
        .overflow = overflow,
    } });
}

fn addStyledDetailText(
    ctx: *goop.Context,
    parent: goop.NodeHandle,
    text: []const u8,
    overflow: goop.TextOverflow,
    style_override: goop.Style,
) !goop.NodeHandle {
    const handle = try addDetailText(ctx, parent, text, overflow);
    ctx.tree.get(handle).style_override = style_override;
    return handle;
}

fn applyAssetTableColumns(table: *goop.widget.WidgetKind.Table, state: *const State) void {
    table.column_weights[0] = state.table_column_weights[0];
    table.column_weights[1] = state.table_column_weights[1];
    table.column_weights[2] = state.table_column_weights[2];
    table.column_weights[3] = state.table_column_weights[3];
}

fn buildListHeaderTable(state: *State, ctx: *goop.Context, parent: goop.NodeHandle) !void {
    state.asset_table = try ctx.tree.addChild(parent, .{ .table = .{
        .columns = 4,
        .striped = false,
        .resizable = true,
        .sortable = true,
        .selection_mode = .none,
        .min_column_width = uiPx(state, 96),
    } });
    ctx.tree.get(state.asset_table.?).style_override = .{
        .bg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .border = .{ .r = 214, .g = 220, .b = 228, .a = 255 },
        .border_width = 0,
        .padding = goop.style.Edges.all(0),
        .border_radius = 0,
    };
    {
        const table = &ctx.tree.get(state.asset_table.?).kind.table;
        applyAssetTableColumns(table, state);
        table.sorted_column = @intFromEnum(state.sort_column);
        table.sort_direction = switch (state.sort_direction) {
            .ascending => .ascending,
            .descending => .descending,
        };
    }

    const header_row = try ctx.tree.addChild(state.asset_table.?, .{ .table_row = .{ .header = true } });
    ctx.tree.get(header_row).style_override = .{
        .border_width = browserTableDividerWidthPx(state),
    };
    try addNameHeaderCell(state, ctx, header_row, "Name");
    try addTextCell(state, ctx, header_row, "Modified");
    try addTextCell(state, ctx, header_row, "Type");
    try addTextCell(state, ctx, header_row, "Size");
}

fn buildListAssetView(state: *State, ctx: *goop.Context, scroll_handle: goop.NodeHandle, viewport_height: f32) !void {
    const window = browserListWindow(state, viewport_height);
    state.file_panel_scroll_y = window.scroll_y;
    ctx.tree.get(scroll_handle).kind.scroll_area.scroll_y = window.scroll_y;
    state.asset_visible_start = window.start;
    state.asset_visible_end = window.end;
    state.asset_visible_columns = 0;

    state.asset_table_body = try ctx.tree.addChild(scroll_handle, .{ .table = .{
        .columns = 4,
        .striped = false,
        .selection_mode = .multiple,
        .min_column_width = uiPx(state, 96),
    } });
    state.asset_view_root = state.asset_table_body;
    ctx.tree.get(state.asset_table_body.?).style_override = .{
        .bg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .border_width = 0,
        .padding = blk: {
            const gap = ctx.theme.spacing;
            const top = if (window.top_spacer > 0) window.top_spacer + gap else 0;
            const bottom = if (window.bottom_spacer > 0) window.bottom_spacer + gap else 0;
            const rendered_height = browserListRowHeight(state) * @as(f32, @floatFromInt(window.end - window.start));
            const filler = @max(viewport_height - top - rendered_height - bottom, 0);
            break :blk goop.style.Edges{
                .top = top,
                .right = 0,
                .bottom = bottom + filler,
                .left = 0,
            };
        },
        .border_radius = 0,
    };
    applyAssetTableColumns(&ctx.tree.get(state.asset_table_body.?).kind.table, state);

    for (state.entries.items[window.start..window.end]) |entry| {
        const row = try ctx.tree.addChild(state.asset_table_body.?, .{ .table_row = .{
            .selected = isPathSelected(state, entry.path),
        } });
        ctx.tree.get(row).style_override = .{
            .border_width = browserTableDividerWidthPx(state),
        };
        try state.row_handles.append(allocator, row);
        try state.name_cell_handles.append(allocator, try addNameCell(state, ctx, row, entry));
        try addTextCell(state, ctx, row, try allocAssetFormattedTimestamp(state, entry.modified_unix));
        try addTextCell(state, ctx, row, entry.typeLabel());
        try addTextCell(state, ctx, row, try allocAssetFormattedSize(state, entry.kind, entry.size_bytes, entry.target_kind));
    }

    scrollDebug(state, "build list scroll={d:.2} viewport_h={d:.2} window=[{}..{}) rows={} spacers=({d:.2},{d:.2})", .{
        window.scroll_y,
        viewport_height,
        window.start,
        window.end,
        window.end - window.start,
        window.top_spacer,
        window.bottom_spacer,
    });
}

fn buildGridAssetView(state: *State, ctx: *goop.Context, scroll_handle: goop.NodeHandle, viewport_width: f32, viewport_height: f32) !void {
    const window = browserGridWindow(state, viewport_width, viewport_height);
    state.file_panel_scroll_y = window.scroll_y;
    ctx.tree.get(scroll_handle).kind.scroll_area.scroll_y = window.scroll_y;
    state.asset_visible_start = window.start;
    state.asset_visible_end = window.end;
    state.asset_visible_columns = window.columns;

    state.asset_view_root = try ctx.tree.addChild(scroll_handle, .{ .container = .{ .direction = .column } });
    ctx.tree.get(state.asset_view_root.?).style_override = .{
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border_width = 0,
        .padding = goop.style.Edges.all(0),
        .spacing = 0,
        .border_radius = 0,
    };

    state.asset_grid = try ctx.tree.addChild(state.asset_view_root.?, .{ .grid_selector = .{
        .selection_mode = .multiple,
        .item_width = browserGridItemWidthPx(state),
        .item_height = browserGridItemHeightPx(state),
        .column_gap = browserGridColumnGapPx(state),
        .row_gap = browserGridRowGapPx(state),
    } });
    ctx.tree.get(state.asset_grid.?).style_override = .{
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border_width = 0,
        .padding = .{
            .top = blk: {
                const gap = ctx.theme.spacing;
                break :blk if (window.top_spacer > 0) window.top_spacer + gap else 0;
            },
            .right = browserGridPaddingHPx(state),
            .bottom = blk: {
                const gap = ctx.theme.spacing;
                const bottom = if (window.bottom_spacer > 0) window.bottom_spacer + gap else 0;
                const rendered_count = window.end - window.start;
                const rendered_rows = if (rendered_count == 0)
                    @as(usize, 0)
                else
                    (rendered_count + window.columns - 1) / window.columns;
                const rendered_height = if (rendered_rows == 0)
                    @as(f32, 0)
                else
                    browserGridItemHeightPx(state) * @as(f32, @floatFromInt(rendered_rows)) +
                        browserGridRowGapPx(state) * @as(f32, @floatFromInt(rendered_rows - 1));
                const top = if (window.top_spacer > 0) window.top_spacer + gap else 0;
                const filler = @max(viewport_height - top - rendered_height - bottom, 0);
                break :blk bottom + filler;
            },
            .left = browserGridPaddingHPx(state),
        },
        .border_radius = 0,
    };

    for (state.entries.items[window.start..window.end]) |entry| {
        const item = try ctx.tree.addChild(state.asset_grid.?, .{ .grid_item = .{
            .label = try allocAssetUiEllipsizedUtf8Lossy(state, entry.name, uiPx(state, 104), ctx.theme.font_size),
            .selected = isPathSelected(state, entry.path),
        } });
        ctx.tree.get(item).custom_draw = true;
        ctx.tree.get(item).style_override = .{
            .bg = if (entry.isDirectory())
                .{ .r = 243, .g = 247, .b = 255, .a = 255 }
            else
                .{ .r = 252, .g = 252, .b = 253, .a = 255 },
            .border = if (entry.isDirectory())
                .{ .r = 184, .g = 204, .b = 233, .a = 255 }
            else
                .{ .r = 214, .g = 220, .b = 228, .a = 255 },
            .border_width = 0,
            .padding = uiEdgesSymmetric(state, 10, 10),
            .border_radius = uiPx(state, 10),
        };
        try state.grid_handles.append(allocator, item);
    }

    scrollDebug(state, "build grid scroll={d:.2} viewport=({d:.2},{d:.2}) window=[{}..{}) cols={} spacers=({d:.2},{d:.2})", .{
        window.scroll_y,
        viewport_width,
        viewport_height,
        window.start,
        window.end,
        window.columns,
        window.top_spacer,
        window.bottom_spacer,
    });
}

fn buildAssetView(state: *State, ctx: *goop.Context, scroll_handle: goop.NodeHandle) !void {
    const viewport_width = browserViewportWidthEstimate(state);
    const viewport_height = browserViewportHeightEstimate(state);

    if (state.entries.items.len == 0) {
        state.file_panel_scroll_y = 0;
        ctx.tree.get(scroll_handle).kind.scroll_area.scroll_y = 0;
        state.asset_visible_start = 0;
        state.asset_visible_end = 0;
        state.asset_visible_columns = 0;
        state.asset_view_root = try ctx.tree.addChild(scroll_handle, .{ .text = .{ .content = "This directory is empty." } });
        return;
    }

    switch (state.view_mode) {
        .list => try buildListAssetView(state, ctx, scroll_handle, viewport_height),
        .grid => try buildGridAssetView(state, ctx, scroll_handle, viewport_width, viewport_height),
    }
}

fn rebuildAssetView(state: *State) !void {
    const ctx = state.ctx orelse return error.NoContext;
    const scroll_handle = state.file_panel_scroll orelse return error.NoContext;

    scrollDebug(state, "rebuild begin mode={s} prev_window=[{}..{}) scroll={d:.2}", .{
        browserViewModeLabel(state.view_mode),
        state.asset_visible_start,
        state.asset_visible_end,
        state.file_panel_scroll_y,
    });

    while (ctx.tree.getConst(scroll_handle).first_child) |child| {
        try ctx.removeWidget(child);
    }
    clearAssetBodyTracking(state);
    try buildAssetView(state, ctx, scroll_handle);

    scrollDebug(state, "rebuild end mode={s} next_window=[{}..{})", .{
        browserViewModeLabel(state.view_mode),
        state.asset_visible_start,
        state.asset_visible_end,
    });
}

fn refreshAssetViewportIfNeeded(state: *State) !bool {
    const ctx = state.ctx orelse return false;
    const scroll_handle = state.file_panel_scroll orelse return false;
    if (!ctx.isAlive(scroll_handle)) return false;

    const previous_scroll_y = state.file_panel_scroll_y;
    const previous_viewport_height = state.file_panel_viewport_height;
    const previous_visible_start = state.asset_visible_start;
    const previous_visible_end = state.asset_visible_end;
    const previous_visible_columns = state.asset_visible_columns;
    const scroll_node = ctx.tree.getConst(scroll_handle);
    const viewport_width = scroll_node.layout_rect.w;
    const viewport_height = scroll_node.layout_rect.h;
    const current_scroll_y = scroll_node.kind.scroll_area.scroll_y;
    state.file_panel_viewport_width = viewport_width;
    state.file_panel_viewport_height = viewport_height;
    state.file_panel_scroll_y = current_scroll_y;

    if (state.entries.items.len == 0) {
        return false;
    }

    switch (state.view_mode) {
        .list => {
            const asset_alive = if (state.asset_table_body) |body| ctx.isAlive(body) else false;
            const window = browserListWindow(state, viewport_height);
            const viewport_height_changed = @abs(previous_viewport_height - viewport_height) > 0.01;
            const scroll_clamped = @abs(current_scroll_y - window.scroll_y) > 0.01;
            if (scroll_clamped) {
                ctx.tree.get(scroll_handle).kind.scroll_area.scroll_y = window.scroll_y;
                state.file_panel_scroll_y = window.scroll_y;
            }
            const needs_rebuild = !asset_alive or viewport_height_changed or state.asset_visible_start != window.start or state.asset_visible_end != window.end;
            if (needs_rebuild or scroll_clamped or @abs(previous_scroll_y - current_scroll_y) > 0.01) {
                scrollDebug(state, "refresh list viewport_h={d:.2}->{d:.2} scroll={d:.2}->{d:.2} prev_window=[{}..{}) next_window=[{}..{}) alive={} rebuild={} clamp={}", .{
                    previous_viewport_height,
                    viewport_height,
                    previous_scroll_y,
                    current_scroll_y,
                    previous_visible_start,
                    previous_visible_end,
                    window.start,
                    window.end,
                    asset_alive,
                    needs_rebuild,
                    scroll_clamped,
                });
            }
            if (needs_rebuild) {
                try rebuildAssetView(state);
                return true;
            }
            return scroll_clamped;
        },
        .grid => {
            const asset_alive = if (state.asset_view_root) |root| ctx.isAlive(root) else false;
            const window = browserGridWindow(state, viewport_width, viewport_height);
            const viewport_height_changed = @abs(previous_viewport_height - viewport_height) > 0.01;
            const scroll_clamped = @abs(current_scroll_y - window.scroll_y) > 0.01;
            if (scroll_clamped) {
                ctx.tree.get(scroll_handle).kind.scroll_area.scroll_y = window.scroll_y;
                state.file_panel_scroll_y = window.scroll_y;
            }
            const needs_rebuild = !asset_alive or viewport_height_changed or state.asset_visible_start != window.start or state.asset_visible_end != window.end or state.asset_visible_columns != window.columns;
            if (needs_rebuild or scroll_clamped or @abs(previous_scroll_y - current_scroll_y) > 0.01) {
                scrollDebug(state, "refresh grid viewport=({d:.2},{d:.2}->{d:.2}) scroll={d:.2}->{d:.2} prev_window=[{}..{})/{} next_window=[{}..{})/{} alive={} rebuild={} clamp={}", .{
                    viewport_width,
                    previous_viewport_height,
                    viewport_height,
                    previous_scroll_y,
                    current_scroll_y,
                    previous_visible_start,
                    previous_visible_end,
                    previous_visible_columns,
                    window.start,
                    window.end,
                    window.columns,
                    asset_alive,
                    needs_rebuild,
                    scroll_clamped,
                });
            }
            if (needs_rebuild) {
                try rebuildAssetView(state);
                return true;
            }
            return scroll_clamped;
        },
    }

    return false;
}

fn browserEntryIconKind(entry: BrowserEntry) goop.IconKind {
    return switch (entry.kind) {
        .directory => .folder,
        .symlink => if (entry.target_kind == .directory) .folder else .file,
        else => .file,
    };
}

fn browserEntryIconColor(theme: goop.Theme, entry: BrowserEntry, selected: bool) goop.Color {
    if (selected) return theme.accent;
    return switch (entry.kind) {
        .directory => .rgb(74, 120, 201),
        .symlink => if (entry.target_kind == .directory) .rgb(74, 120, 201) else .rgb(118, 127, 141),
        else => .rgb(118, 127, 141),
    };
}

fn browserEntryLinkBadgeColor(theme: goop.Theme, selected: bool) goop.Color {
    return if (selected) theme.accent else .rgb(44, 140, 134);
}

fn iconRectInTableCell(state: *const State, cell_rect: goop.draw.Rect) goop.draw.Rect {
    const size = @min(@max(cell_rect.h - uiPx(state, 10), uiPx(state, 14)), uiPx(state, 18));
    return .{
        .x = cell_rect.x + browserNameIconInsetLeftPx(state),
        .y = cell_rect.y + (cell_rect.h - size) * 0.5,
        .w = size,
        .h = size,
    };
}

fn iconRectInGridItem(ctx: *goop.Context, handle: goop.NodeHandle) goop.draw.Rect {
    const node = ctx.tree.getConst(handle);
    const resolved = node.style_override.resolve(ctx.theme);
    const rect = node.layout_rect;
    const inner = goop.draw.Rect{
        .x = rect.x + resolved.padding.left,
        .y = rect.y + resolved.padding.top,
        .w = @max(rect.w - resolved.padding.left - resolved.padding.right, 0),
        .h = @max(rect.h - resolved.padding.top - resolved.padding.bottom, 0),
    };
    const icon_size = @max(@min(inner.w, inner.h - resolved.font_size - ctx.theme.spacing), 0);
    return .{
        .x = inner.x + (inner.w - icon_size) * 0.5,
        .y = inner.y,
        .w = icon_size,
        .h = @min(icon_size, inner.h - resolved.font_size - ctx.theme.spacing),
    };
}

fn symlinkBadgeRect(base: goop.draw.Rect) goop.draw.Rect {
    const size = @max(@min(base.w, base.h) * 0.42, 7);
    return .{
        .x = base.x + base.w - size * 0.82,
        .y = base.y + base.h - size * 0.82,
        .w = size,
        .h = size,
    };
}

fn appendEntryIconCommands(
    state: *State,
    ctx: *goop.Context,
    entry: BrowserEntry,
    bounds: goop.draw.Rect,
) !void {
    const selected = isPathSelected(state, entry.path);
    try state.composed_paint_commands.append(allocator, .{ .icon = .{
        .bounds = bounds,
        .kind = browserEntryIconKind(entry),
        .color = browserEntryIconColor(ctx.theme, entry, selected),
    } });
    if (entry.kind == .symlink) {
        try state.composed_paint_commands.append(allocator, .{ .icon = .{
            .bounds = symlinkBadgeRect(bounds),
            .kind = .symlink,
            .color = browserEntryLinkBadgeColor(ctx.theme, selected),
        } });
    }
}

fn composeFileBrowserPaintList(state: *State, base: goop.PaintList) !goop.PaintList {
    const ctx = state.ctx orelse return base;

    state.composed_paint_commands.clearRetainingCapacity();
    try state.composed_paint_commands.ensureTotalCapacity(allocator, base.commands.len + state.name_cell_handles.items.len * 2 + state.grid_handles.items.len * 2);

    for (base.commands) |command| {
        switch (command) {
            .custom => |custom| {
                var matched_index: ?usize = null;
                for (state.name_cell_handles.items, 0..) |handle, index| {
                    if (handle.eql(custom.handle)) {
                        matched_index = index;
                        break;
                    }
                }
                if (matched_index) |index| {
                    const entry_index = state.asset_visible_start + index;
                    if (entry_index < state.entries.items.len) {
                        const entry = state.entries.items[entry_index];
                        try appendEntryIconCommands(state, ctx, entry, iconRectInTableCell(state, custom.bounds));
                    }
                    continue;
                }

                matched_index = null;
                for (state.grid_handles.items, 0..) |handle, index| {
                    if (handle.eql(custom.handle)) {
                        matched_index = index;
                        break;
                    }
                }
                if (matched_index) |index| {
                    const entry_index = state.asset_visible_start + index;
                    if (entry_index < state.entries.items.len) {
                        const entry = state.entries.items[entry_index];
                        try appendEntryIconCommands(state, ctx, entry, iconRectInGridItem(ctx, custom.handle));
                    }
                    continue;
                }
            },
            else => {},
        }
        try state.composed_paint_commands.append(allocator, command);
    }

    return .{ .commands = state.composed_paint_commands.items };
}

fn debugWidgetKindName(kind: goop.widget.WidgetKind) []const u8 {
    return switch (kind) {
        .container => "container",
        .text => "text",
        .button => "button",
        .checkbox => "checkbox",
        .radio_button => "radio_button",
        .tree_item => "tree_item",
        .dropdown => "dropdown",
        .list_box => "list_box",
        .selectable => "selectable",
        .grid_selector => "grid_selector",
        .grid_item => "grid_item",
        .table => "table",
        .table_row => "table_row",
        .table_cell => "table_cell",
        .toolbar => "toolbar",
        .status_bar => "status_bar",
        .menu_bar => "menu_bar",
        .menu => "menu",
        .popup => "popup",
        .tooltip => "tooltip",
        .menu_item => "menu_item",
        .drag_value => "drag_value",
        .spinbox => "spinbox",
        .tab_bar => "tab_bar",
        .tab_item => "tab_item",
        .splitter => "splitter",
        .slider => "slider",
        .spacer => "spacer",
        .scroll_area => "scroll_area",
        .text_input => "text_input",
    };
}

fn focusWidget(ctx: *goop.Context, handle: goop.NodeHandle) void {
    for (ctx.tree.nodes.items) |*node| {
        if (node.alive) node.interaction.focused = false;
    }
    if (ctx.isAlive(handle)) {
        ctx.tree.get(handle).interaction.focused = true;
        ctx.runtime.mouse.focused = handle;
    } else {
        ctx.runtime.mouse.focused = null;
    }
}

fn focusedNodeHandle(ctx: *const goop.Context) ?goop.NodeHandle {
    for (ctx.tree.nodes.items, 0..) |node, index| {
        if (!node.alive or !node.interaction.focused) continue;
        return ctx.tree.handleFromIndex(@intCast(index));
    }
    return null;
}

fn entryNameTextRect(state: *const State, ctx: *const goop.Context, visible_index: usize, entry: BrowserEntry) ?goop.draw.Rect {
    if (visible_index >= state.name_cell_handles.items.len) return null;
    const cell = state.name_cell_handles.items[visible_index];
    if (!ctx.isAlive(cell)) return null;

    const node = ctx.tree.getConst(cell);
    const resolved = node.style_override.resolve(ctx.theme);
    const rect = node.layout_rect;
    const x = rect.x + resolved.padding.left;
    const available_w = @max(rect.w - resolved.padding.left - resolved.padding.right, 0);
    const measured_w = goop.layout.measureTextDimensions(entry.name, ctx.theme.font_size, state.text_measure_ctx).width;
    return .{
        .x = x,
        .y = rect.y + resolved.padding.top,
        .w = @min(measured_w, available_w),
        .h = @max(rect.h - resolved.padding.top - resolved.padding.bottom, 0),
    };
}

fn pointInRect(x: f32, y: f32, rect: goop.draw.Rect) bool {
    return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h;
}

fn pointHitsEntryNameText(state: *const State, ctx: *const goop.Context, visible_index: usize, entry: BrowserEntry, x: f32, y: f32) bool {
    const rect = entryNameTextRect(state, ctx, visible_index, entry) orelse return false;
    return pointInRect(x, y, rect);
}

fn pointHitsVisibleAssetItem(state: *const State, ctx: *const goop.Context, x: f32, y: f32) bool {
    for (state.row_handles.items) |handle| {
        if (!ctx.isAlive(handle)) continue;
        if (pointInRect(x, y, ctx.tree.getConst(handle).layout_rect)) return true;
    }
    for (state.grid_handles.items) |handle| {
        if (!ctx.isAlive(handle)) continue;
        if (pointInRect(x, y, ctx.tree.getConst(handle).layout_rect)) return true;
    }
    return false;
}

fn pointInFilePanelBlankSpace(state: *const State, ctx: *const goop.Context, x: f32, y: f32) bool {
    const scroll_handle = state.file_panel_scroll orelse return false;
    if (!ctx.isAlive(scroll_handle)) return false;
    const rect = ctx.tree.getConst(scroll_handle).layout_rect;
    if (!pointInRect(x, y, rect)) return false;

    const scrollbar_reserve = @max(ctx.theme.thumb_width, uiPx(state, 16));
    if (x >= rect.x + rect.w - scrollbar_reserve) return false;
    if (y >= rect.y + rect.h - scrollbar_reserve) return false;
    return !pointHitsVisibleAssetItem(state, ctx, x, y);
}

fn collectRowCellWidths(ctx: *const goop.Context, row_handle: ?goop.NodeHandle) [4]f32 {
    var widths: [4]f32 = .{ -1, -1, -1, -1 };
    const row = row_handle orelse return widths;
    if (!ctx.isAlive(row)) return widths;

    var cell_index: usize = 0;
    var iter = ctx.tree.children(row);
    while (iter.next()) |child| {
        if (ctx.tree.getConst(child).kind != .table_cell) continue;
        if (cell_index >= widths.len) break;
        widths[cell_index] = ctx.tree.getConst(child).layout_rect.w;
        cell_index += 1;
    }
    return widths;
}

fn sameWidths(a: [4]f32, b: [4]f32) bool {
    for (a, b) |left, right| {
        if (@abs(left - right) > 0.01) return false;
    }
    return true;
}

fn debugLogFilePanelLayout(state: *State) void {
    if (!state.scroll_debug_enabled and !state.layout_debug_enabled) return;

    const ctx = state.ctx orelse return;
    const root_handle = state.ui_root orelse return;
    const scroll_handle = state.file_panel_scroll orelse return;
    if (!ctx.isAlive(root_handle) or !ctx.isAlive(scroll_handle)) return;

    const root_rect = ctx.tree.getConst(root_handle).layout_rect;
    const scroll_node = ctx.tree.getConst(scroll_handle);
    const scroll_y = scroll_node.kind.scroll_area.scroll_y;
    const scroll_state_unchanged = @abs(scroll_y - state.scroll_debug_last_scroll_y) <= 0.01 and
        state.scroll_debug_last_visible_start == state.asset_visible_start and
        state.scroll_debug_last_visible_end == state.asset_visible_end;

    const scroll_rect = scroll_node.layout_rect;
    const body_handle = switch (state.view_mode) {
        .list => state.asset_table_body,
        .grid => state.asset_view_root,
    };
    const body_alive = if (body_handle) |handle| ctx.isAlive(handle) else false;
    const body_y = if (body_alive) ctx.tree.getConst(body_handle.?).layout_rect.y else -1.0;
    const body_h = if (body_alive) ctx.tree.getConst(body_handle.?).layout_rect.h else -1.0;
    const first_row_alive = switch (state.view_mode) {
        .list => state.row_handles.items.len > 0 and ctx.isAlive(state.row_handles.items[0]),
        .grid => state.grid_handles.items.len > 0 and ctx.isAlive(state.grid_handles.items[0]),
    };
    const first_row_y = switch (state.view_mode) {
        .list => if (first_row_alive) ctx.tree.getConst(state.row_handles.items[0]).layout_rect.y else -1.0,
        .grid => if (first_row_alive) ctx.tree.getConst(state.grid_handles.items[0]).layout_rect.y else -1.0,
    };

    if (!scroll_state_unchanged) {
        state.scroll_debug_last_scroll_y = scroll_y;
        state.scroll_debug_last_visible_start = state.asset_visible_start;
        state.scroll_debug_last_visible_end = state.asset_visible_end;

        scrollDebug(state, "layout mode={s} scroll={d:.2} scroll_rect=({d:.1},{d:.1},{d:.1},{d:.1}) body_alive={} body_y={d:.1} body_h={d:.1} first_row_y={d:.1} window=[{}..{})", .{
            browserViewModeLabel(state.view_mode),
            scroll_y,
            scroll_rect.x,
            scroll_rect.y,
            scroll_rect.w,
            scroll_rect.h,
            body_alive,
            body_y,
            body_h,
            first_row_y,
            state.asset_visible_start,
            state.asset_visible_end,
        });
        scrollDebug(state, "layout root logical={}x{} root_rect=({d:.1},{d:.1},{d:.1},{d:.1})", .{
            state.logical_width,
            state.logical_height,
            root_rect.x,
            root_rect.y,
            root_rect.w,
            root_rect.h,
        });
    }

    if (state.layout_debug_enabled and state.view_mode == .list) {
        const header_table_handle = state.asset_table;
        const body_table_handle = state.asset_table_body;
        const header_alive = if (header_table_handle) |handle| ctx.isAlive(handle) else false;
        const body_table_alive = if (body_table_handle) |handle| ctx.isAlive(handle) else false;
        const header_rect = if (header_alive) ctx.tree.getConst(header_table_handle.?).layout_rect else goop.draw.Rect{ .x = -1, .y = -1, .w = -1, .h = -1 };
        const body_rect = if (body_table_alive) ctx.tree.getConst(body_table_handle.?).layout_rect else goop.draw.Rect{ .x = -1, .y = -1, .w = -1, .h = -1 };
        const header_row = if (header_alive) goop.widget.tableHeaderRow(&ctx.tree, header_table_handle.?) else null;
        const body_row = if (state.row_handles.items.len > 0) state.row_handles.items[0] else null;
        const header_widths = collectRowCellWidths(ctx, header_row);
        const body_widths = collectRowCellWidths(ctx, body_row);
        const focused_handle = focusedNodeHandle(ctx);
        const focused_index = if (focused_handle) |handle| handle.index else std.math.maxInt(u32);

        const layout_state_unchanged = focused_index == state.layout_debug_last_focus_index and
            @abs(header_rect.x - state.layout_debug_last_header_x) <= 0.01 and
            @abs(header_rect.w - state.layout_debug_last_header_w) <= 0.01 and
            @abs(body_rect.x - state.layout_debug_last_body_x) <= 0.01 and
            @abs(body_rect.w - state.layout_debug_last_body_w) <= 0.01 and
            sameWidths(header_widths, state.layout_debug_last_header_widths) and
            sameWidths(body_widths, state.layout_debug_last_body_widths);

        if (!layout_state_unchanged) {
            state.layout_debug_last_focus_index = focused_index;
            state.layout_debug_last_header_x = header_rect.x;
            state.layout_debug_last_header_w = header_rect.w;
            state.layout_debug_last_body_x = body_rect.x;
            state.layout_debug_last_body_w = body_rect.w;
            state.layout_debug_last_header_widths = header_widths;
            state.layout_debug_last_body_widths = body_widths;

            const focused_kind = if (focused_handle) |handle|
                debugWidgetKindName(ctx.tree.getConst(handle).kind)
            else
                "none";
            layoutDebug(state, "list columns focus={s}#{} header_rect=({d:.1},{d:.1}) body_rect=({d:.1},{d:.1}) weights=({d:.3},{d:.3},{d:.3},{d:.3}) header=({d:.1},{d:.1},{d:.1},{d:.1}) body=({d:.1},{d:.1},{d:.1},{d:.1})", .{
                focused_kind,
                focused_index,
                header_rect.x,
                header_rect.w,
                body_rect.x,
                body_rect.w,
                state.table_column_weights[0],
                state.table_column_weights[1],
                state.table_column_weights[2],
                state.table_column_weights[3],
                header_widths[0],
                header_widths[1],
                header_widths[2],
                header_widths[3],
                body_widths[0],
                body_widths[1],
                body_widths[2],
                body_widths[3],
            });
        }
    }
}

fn browserTestMeasureText(text: []const u8, font_size: f32, _: ?*anyopaque) goop.TextDimensions {
    if (std.mem.eql(u8, text, "Mg")) {
        return .{
            .width = font_size,
            .height = 20,
            .ascent = 14,
            .descent = 6,
        };
    }

    var line_count: usize = 1;
    var current_line_len: usize = 0;
    var max_line_len: usize = 0;
    for (text) |byte| {
        if (byte == '\n') {
            max_line_len = @max(max_line_len, current_line_len);
            current_line_len = 0;
            line_count += 1;
            continue;
        }
        current_line_len += 1;
    }
    max_line_len = @max(max_line_len, current_line_len);

    return .{
        .width = @as(f32, @floatFromInt(max_line_len)) * font_size * 0.5,
        .height = @as(f32, @floatFromInt(line_count)) * 20,
        .ascent = 14,
        .descent = 6,
    };
}

fn browserTestTheme() goop.Theme {
    return fileManagerThemeForScale(1);
}

fn appendBrowserTestEntries(state: *State, count: usize) !void {
    for (0..count) |index| {
        try state.entries.append(allocator, .{
            .name = try std.fmt.allocPrint(allocator, "entry-{d:03}.txt", .{index}),
            .path = try std.fmt.allocPrint(allocator, "/tmp/entry-{d:03}.txt", .{index}),
            .kind = .file,
            .size_bytes = @intCast(index * 1024),
            .modified_unix = 0,
        });
    }
}

fn syncBrowserTestScrollFrame(state: *State, ctx: *goop.Context, text_measure_ctx: *const goop.TextMeasureCtx) !bool {
    ctx.invalidate();
    ctx.doLayout(text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(state)) {
        ctx.doLayout(text_measure_ctx);
        return true;
    }
    return false;
}

fn initBrowserListTestState(state: *State, ctx: *goop.Context, text_measure_ctx: *const goop.TextMeasureCtx) !void {
    state.current_dir = try allocator.dupe(u8, "/tmp");
    state.text_measure_ctx = text_measure_ctx;
    state.ctx = ctx;
    try appendBrowserTestEntries(state, 256);
    try buildWidgetTree(state);
    ctx.doLayout(text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(state)) {
        ctx.doLayout(text_measure_ctx);
    }
}

test "file browser formats file sizes with correct units" {
    var buf: [24]u8 = undefined;

    try std.testing.expectEqualStrings("0 B", formatSizeText(buf[0..], .file, 0, null));
    try std.testing.expectEqualStrings("1023 B", formatSizeText(buf[0..], .file, 1023, null));
    try std.testing.expectEqualStrings("1.0 KB", formatSizeText(buf[0..], .file, 1024, null));
    try std.testing.expectEqualStrings("1.5 KB", formatSizeText(buf[0..], .file, 1536, null));
    try std.testing.expectEqualStrings("1.0 MB", formatSizeText(buf[0..], .file, 1024 * 1024, null));
    try std.testing.expectEqualStrings("", formatSizeText(buf[0..], .directory, 4096, null));
    try std.testing.expectEqualStrings("", formatSizeText(buf[0..], .symlink, 4096, .directory));
}

test "file browser can sort directories with the active field" {
    var state = State{
        .sort_column = .modified,
        .sort_direction = .descending,
        .sort_directories_together = false,
    };
    const older_dir_name = try allocator.dupe(u8, "older-dir");
    defer allocator.free(older_dir_name);
    const older_dir_path = try allocator.dupe(u8, "/tmp/older-dir");
    defer allocator.free(older_dir_path);
    const newer_file_name = try allocator.dupe(u8, "newer.txt");
    defer allocator.free(newer_file_name);
    const newer_file_path = try allocator.dupe(u8, "/tmp/newer.txt");
    defer allocator.free(newer_file_path);
    const older_dir = BrowserEntry{
        .name = older_dir_name,
        .path = older_dir_path,
        .kind = .directory,
        .size_bytes = 0,
        .modified_unix = 10,
    };
    const newer_file = BrowserEntry{
        .name = newer_file_name,
        .path = newer_file_path,
        .kind = .file,
        .size_bytes = 0,
        .modified_unix = 20,
    };

    try std.testing.expect(browserEntryLessThan(&state, newer_file, older_dir));

    state.sort_directories_together = true;
    try std.testing.expect(browserEntryLessThan(&state, older_dir, newer_file));
}

test "file browser directory preview separates contents onto new lines" {
    var state = State{};
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);

    const folder_name = try allocator.dupe(u8, "folder");
    defer allocator.free(folder_name);
    const folder_path = try allocator.dupe(u8, "/tmp/folder");
    defer allocator.free(folder_path);
    const file_name = try allocator.dupe(u8, "file.txt");
    defer allocator.free(file_name);
    const file_path = try allocator.dupe(u8, "/tmp/file.txt");
    defer allocator.free(file_path);
    const entries = [_]BrowserEntry{
        .{
            .name = folder_name,
            .path = folder_path,
            .kind = .directory,
            .size_bytes = 0,
            .modified_unix = 0,
        },
        .{
            .name = file_name,
            .path = file_path,
            .kind = .file,
            .size_bytes = 0,
            .modified_unix = 0,
        },
    };

    try appendDirectoryPreviewSummary(&state, &buffer, "/tmp", entries[0..]);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Contents:\n- folder/") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\n- file.txt") != null);
}

test "file browser directory preview is not framed like file content" {
    var state = State{};
    defer deinitBrowserState(&state);

    state.current_dir = try allocator.dupe(u8, "/tmp");
    const preview = try allocSelectionPreview(&state);
    try std.testing.expect(!preview.framed);
}

test "file browser detects text preview content without an extension" {
    try std.testing.expect(bytesLookLikeTextPreview("KEY=value\n  indented\n"));
    try std.testing.expect(!bytesLookLikeTextPreview("prefix\x00suffix"));
}

test "file browser formats drag paths as file URIs" {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);

    try appendFileUri(&buffer, "/tmp/a file#1.txt", "\r\n");
    try std.testing.expectEqualStrings("file:///tmp/a%20file%231.txt\r\n", buffer.items);
}

test "file browser detail wrapper inserts line breaks for long names" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    state.ui_scale = 2;
    state.logical_width = 800;
    state.text_measure_ctx = &text_measure_ctx;

    const wrapped = try allocUiDetailWrappedUtf8Lossy(
        &state,
        "this-is-a-very-long-file-name-without-natural-break-points-to-force-detail-panel-overflow.txt",
        detailTitleFontSizePx(&state),
    );
    try std.testing.expect(std.mem.indexOfScalar(u8, wrapped, '\n') != null);
}

test "file browser detail wrapper preserves leading whitespace" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };
    state.text_measure_ctx = &text_measure_ctx;

    const wrapped = try wrapTextOwnedForWidth(
        &state,
        try allocator.dupe(u8, "first\n    second"),
        14,
        400,
    );
    defer allocator.free(wrapped);

    try std.testing.expect(std.mem.indexOf(u8, wrapped, "\n    second") != null);
}

test "file browser selected name text click starts inline rename" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 960,
        .height = 720,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    state.logical_width = 960;
    state.logical_height = 720;
    state.current_dir = try allocator.dupe(u8, "/tmp");
    state.text_measure_ctx = &text_measure_ctx;
    state.ctx = &ctx;
    try state.entries.append(allocator, .{
        .name = try allocator.dupe(u8, "rename-me"),
        .path = try allocator.dupe(u8, "/tmp/rename-me"),
        .kind = .file,
        .size_bytes = 12,
        .modified_unix = 0,
    });
    try appendSelectedPathIfMissing(&state, state.entries.items[0].path);
    try setSelectedPath(&state, state.entries.items[0].path);

    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(&state)) ctx.doLayout(&text_measure_ctx);

    const name_rect = entryNameTextRect(&state, &ctx, 0, state.entries.items[0]).?;
    try std.testing.expect(pointHitsEntryNameText(&state, &ctx, 0, state.entries.items[0], name_rect.x + 1, name_rect.y + name_rect.h * 0.5));
    try beginRenameEntry(&state, &ctx, state.entries.items[0]);
    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);

    const input = state.rename_input_handle orelse return error.TestUnexpectedResult;
    try std.testing.expect(ctx.tree.getConst(input).interaction.focused);
    try std.testing.expectEqualStrings("rename-me", ctx.tree.getConst(input).kind.text_input.content());
}

test "file browser blank asset space can clear selection" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 960,
        .height = 720,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    state.logical_width = 960;
    state.logical_height = 720;
    state.current_dir = try allocator.dupe(u8, "/tmp");
    state.text_measure_ctx = &text_measure_ctx;
    state.ctx = &ctx;
    try state.entries.append(allocator, .{
        .name = try allocator.dupe(u8, "only-file"),
        .path = try allocator.dupe(u8, "/tmp/only-file"),
        .kind = .file,
        .size_bytes = 12,
        .modified_unix = 0,
    });
    try appendSelectedPathIfMissing(&state, state.entries.items[0].path);
    try setSelectedPath(&state, state.entries.items[0].path);

    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(&state)) ctx.doLayout(&text_measure_ctx);

    const scroll_rect = ctx.tree.getConst(state.file_panel_scroll.?).layout_rect;
    const row_rect = ctx.tree.getConst(state.row_handles.items[0]).layout_rect;
    const blank_x = scroll_rect.x + 24;
    const blank_y = row_rect.y + row_rect.h + 24;

    const body_rect = ctx.tree.getConst(state.asset_table_body.?).layout_rect;
    try std.testing.expect(pointInRect(blank_x, blank_y, body_rect));
    try std.testing.expect(pointInFilePanelBlankSpace(&state, &ctx, blank_x, blank_y));
    try std.testing.expect(clearSelectionState(&state));
    try std.testing.expectEqual(@as(usize, 0), state.selected_paths.items.len);
}

test "file browser blank asset space starts marquee before any selection" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 960,
        .height = 720,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    state.logical_width = 960;
    state.logical_height = 720;
    state.current_dir = try allocator.dupe(u8, "/tmp");
    state.text_measure_ctx = &text_measure_ctx;
    state.ctx = &ctx;
    try state.entries.append(allocator, .{
        .name = try allocator.dupe(u8, "only-file"),
        .path = try allocator.dupe(u8, "/tmp/only-file"),
        .kind = .file,
        .size_bytes = 12,
        .modified_unix = 0,
    });

    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(&state)) ctx.doLayout(&text_measure_ctx);

    const scroll_rect = ctx.tree.getConst(state.file_panel_scroll.?).layout_rect;
    const row_rect = ctx.tree.getConst(state.row_handles.items[0]).layout_rect;
    const blank_x = scroll_rect.x + 24;
    const blank_y = row_rect.y + row_rect.h + 24;
    const row_x = row_rect.x + 24;
    const row_y = row_rect.y + row_rect.h * 0.5;

    const body_rect = ctx.tree.getConst(state.asset_table_body.?).layout_rect;
    try std.testing.expect(pointInRect(blank_x, blank_y, body_rect));
    try std.testing.expect(pointInFilePanelBlankSpace(&state, &ctx, blank_x, blank_y));

    try ctx.pushEvent(.{ .mouse_button = .{ .button = .left, .state = .pressed, .x = blank_x, .y = blank_y } });
    try ctx.pushEvent(.{ .mouse_move = .{ .x = row_x, .y = row_y } });
    ctx.processEvents();

    try std.testing.expect(ctx.tree.getConst(state.asset_table_body.?).kind.table.marquee_active);
    try std.testing.expect(ctx.tree.getConst(state.row_handles.items[0]).kind.table_row.selected);
}

test "file browser list refresh grows blank marquee hit area with viewport" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 960,
        .height = 360,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    state.logical_width = 960;
    state.logical_height = 360;
    state.current_dir = try allocator.dupe(u8, "/tmp");
    state.text_measure_ctx = &text_measure_ctx;
    state.ctx = &ctx;
    try state.entries.append(allocator, .{
        .name = try allocator.dupe(u8, "only-file"),
        .path = try allocator.dupe(u8, "/tmp/only-file"),
        .kind = .file,
        .size_bytes = 12,
        .modified_unix = 0,
    });

    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(&state)) ctx.doLayout(&text_measure_ctx);

    state.logical_height = 720;
    ctx.setDimensions(960, 720);
    ctx.doLayout(&text_measure_ctx);

    try std.testing.expect(try refreshAssetViewportIfNeeded(&state));
    ctx.doLayout(&text_measure_ctx);

    const scroll_rect = ctx.tree.getConst(state.file_panel_scroll.?).layout_rect;
    const body_rect = ctx.tree.getConst(state.asset_table_body.?).layout_rect;
    const blank_x = scroll_rect.x + 24;
    const blank_y = scroll_rect.y + scroll_rect.h - 48;
    try std.testing.expect(pointInRect(blank_x, blank_y, body_rect));
    try std.testing.expect(pointInFilePanelBlankSpace(&state, &ctx, blank_x, blank_y));
}

test "file browser syncs toolkit selection from visible entry window" {
    var state = State{};
    defer deinitBrowserState(&state);
    try appendBrowserTestEntries(&state, 8);
    state.asset_visible_start = 3;

    var ctx = try goop.Context.init(allocator, .{
        .width = 640,
        .height = 480,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    const root = try ctx.tree.addRoot(.{ .container = .{} });
    const table = try ctx.tree.addChild(root, .{ .table = .{ .selection_mode = .multiple } });
    _ = try ctx.tree.addChild(table, .{ .table_row = .{} });
    _ = try ctx.tree.addChild(table, .{ .table_row = .{ .selected = true } });
    try syncSelectedPathsFromTable(&state, &ctx, table);
    try std.testing.expectEqual(@as(usize, 1), state.selected_paths.items.len);
    try std.testing.expectEqualStrings("/tmp/entry-004.txt", state.selected_paths.items[0]);

    clearSelectedPaths(&state);
    const grid = try ctx.tree.addChild(root, .{ .grid_selector = .{ .selection_mode = .multiple } });
    _ = try ctx.tree.addChild(grid, .{ .grid_item = .{ .label = "a" } });
    _ = try ctx.tree.addChild(grid, .{ .grid_item = .{ .label = "b", .selected = true } });
    try syncSelectedPathsFromGrid(&state, &ctx, grid);
    try std.testing.expectEqual(@as(usize, 1), state.selected_paths.items.len);
    try std.testing.expectEqualStrings("/tmp/entry-004.txt", state.selected_paths.items[0]);
}

test "file browser selection detail does not resize the list at ui scale 2" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 1600,
        .height = 960,
        .theme = fileManagerThemeForScale(2),
    });
    defer ctx.deinit();

    state.ui_scale = 2;
    state.current_dir = try allocator.dupe(u8, "/tmp");
    state.text_measure_ctx = &text_measure_ctx;
    state.ctx = &ctx;

    const long_name = "this-is-a-very-long-file-name-without-natural-break-points-to-force-detail-panel-overflow.txt";
    const long_path = "/tmp/this-is-a-very-long-file-name-without-natural-break-points-to-force-detail-panel-overflow.txt";
    try state.entries.append(allocator, .{
        .name = try allocator.dupe(u8, long_name),
        .path = try allocator.dupe(u8, long_path),
        .kind = .file,
        .size_bytes = 1024,
        .modified_unix = 0,
    });
    try appendBrowserTestEntries(&state, 48);

    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(&state)) {
        ctx.doLayout(&text_measure_ctx);
    }
    const width_before = ctx.tree.getConst(state.asset_table.?).layout_rect.w;
    try appendSelectedPathIfMissing(&state, state.entries.items[0].path);
    try setSelectedPath(&state, state.entries.items[0].path);
    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(&state)) {
        ctx.doLayout(&text_measure_ctx);
    }
    const width_after = ctx.tree.getConst(state.asset_table.?).layout_rect.w;
    try std.testing.expect(@abs(width_before - width_after) < 4);
}

test "folder tree derives partial ancestors and expanded current directory" {
    var state = State{};
    state.current_dir = try allocator.dupe(u8, "/home/user/project");
    defer {
        allocator.free(state.current_dir);
        clearTrackedPaths(&state.folder_tree_expanded_paths);
        state.folder_tree_expanded_paths.deinit(allocator);
    }

    try std.testing.expectEqual(FolderTreeExpansion.partial, folderTreeExpansion(&state, "/"));
    try std.testing.expectEqual(FolderTreeExpansion.partial, folderTreeExpansion(&state, "/home"));
    try std.testing.expectEqual(FolderTreeExpansion.partial, folderTreeExpansion(&state, "/home/user"));
    try std.testing.expectEqual(FolderTreeExpansion.expanded, folderTreeExpansion(&state, "/home/user/project"));
    try std.testing.expectEqual(FolderTreeExpansion.collapsed, folderTreeExpansion(&state, "/tmp"));

    try std.testing.expect(shouldRenderFolderTreeChildForExpansion(&state, .partial, 900, "/home"));
    try std.testing.expect(!shouldRenderFolderTreeChildForExpansion(&state, .partial, 0, "/tmp"));

    try std.testing.expect(try setFolderTreePathExpanded(&state, "/tmp", true));
    try std.testing.expectEqual(FolderTreeExpansion.expanded, folderTreeExpansion(&state, "/tmp"));
    try std.testing.expect(shouldRenderFolderTreeChildForExpansion(&state, .expanded, 900, "/tmp"));
}

test "folder tree preserves previous current branch when navigating to ancestor" {
    var state = State{};
    state.current_dir = try allocator.dupe(u8, "/home/user/project/goop");
    defer {
        allocator.free(state.current_dir);
        clearTrackedPaths(&state.folder_tree_expanded_paths);
        state.folder_tree_expanded_paths.deinit(allocator);
    }

    try preserveFolderTreeContextForNavigation(&state, "/home/user/project");
    try std.testing.expect(isFolderTreePathExpanded(&state, "/home/user/project/goop"));

    allocator.free(state.current_dir);
    state.current_dir = try allocator.dupe(u8, "/home/user/project");

    try std.testing.expectEqual(FolderTreeExpansion.expanded, folderTreeExpansion(&state, "/home/user/project"));
    try std.testing.expectEqual(FolderTreeExpansion.expanded, folderTreeExpansion(&state, "/home/user/project/goop"));
    try std.testing.expect(shouldRenderFolderTreeChildForExpansion(&state, .expanded, 900, "/home/user/project/goop"));
}

test "sidebar scroll survives widget tree rebuild" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 960,
        .height = 720,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    state.current_dir = try allocator.dupe(u8, "/tmp");
    state.text_measure_ctx = &text_measure_ctx;
    state.ctx = &ctx;

    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);
    const first_scroll = state.sidebar_scroll.?;
    ctx.tree.get(first_scroll).kind.scroll_area.scroll_y = 73;

    try buildWidgetTree(&state);
    ctx.doLayout(&text_measure_ctx);
    const second_scroll = state.sidebar_scroll.?;
    try std.testing.expectApproxEqAbs(@as(f32, 73), ctx.tree.getConst(second_scroll).kind.scroll_area.scroll_y, 0.01);
}

test "browser list window keeps rendered body aligned with logical row offset" {
    var state = State{};
    defer state.entries.deinit(allocator);

    for (0..64) |_| {
        try state.entries.append(allocator, .{
            .name = @constCast(""[0..]),
            .path = @constCast(""[0..]),
            .kind = .file,
            .size_bytes = 0,
            .modified_unix = 0,
        });
    }

    state.file_panel_scroll_y = 104;
    const window = browserListWindow(&state, 120);
    const row_height = browserListRowHeight(&state);
    const gap = browserVirtualGap(&state);
    const visible_start = @as(usize, @intFromFloat(@floor(window.scroll_y / row_height)));
    const visible_count = browserVisibleCount(120, row_height);
    const expected_range = browserVirtualRange(state.entries.items.len, visible_start, visible_count);
    const body_y = if (window.top_spacer > 0) window.top_spacer + gap else 0;
    const visible_height = row_height * @as(f32, @floatFromInt(window.end - window.start));
    const trailing = if (window.bottom_spacer > 0) window.bottom_spacer + gap else 0;
    const total_height = row_height * @as(f32, @floatFromInt(state.entries.items.len));

    try std.testing.expectEqual(expected_range.start, window.start);
    try std.testing.expectEqual(expected_range.end, window.end);
    try std.testing.expectApproxEqAbs(row_height * @as(f32, @floatFromInt(window.start)), body_y, 0.01);
    try std.testing.expectApproxEqAbs(total_height, body_y + visible_height + trailing, 0.01);
}

test "browser grid window keeps rendered body aligned with logical row offset" {
    var state = State{};
    defer state.entries.deinit(allocator);

    for (0..80) |_| {
        try state.entries.append(allocator, .{
            .name = @constCast(""[0..]),
            .path = @constCast(""[0..]),
            .kind = .file,
            .size_bytes = 0,
            .modified_unix = 0,
        });
    }

    state.logical_width = 800;
    state.file_panel_scroll_y = 640;
    const viewport_width: f32 = 480;
    const viewport_height: f32 = 220;
    const window = browserGridWindow(&state, viewport_width, viewport_height);
    const gap = browserVirtualGap(&state);
    const slot_height = browser_grid_item_height + browser_grid_row_gap;
    const content_scroll_y = @max(window.scroll_y - browser_grid_padding_v, 0);
    const visible_start_row = @as(usize, @intFromFloat(@floor(content_scroll_y / slot_height)));
    const visible_row_count = browserVisibleCount(@max(viewport_height - browser_grid_padding_v * 2, browser_grid_item_height) + browser_grid_row_gap, slot_height);
    const total_rows = std.math.divCeil(usize, state.entries.items.len, window.columns) catch unreachable;
    const expected_range = browserVirtualRange(total_rows, visible_start_row, visible_row_count);
    const start_row = window.start / window.columns;
    const desired_body_y = browser_grid_padding_v + @as(f32, @floatFromInt(start_row)) * slot_height;
    const body_y = if (window.top_spacer > 0) window.top_spacer + gap else 0;
    const visible_rows = std.math.divCeil(usize, window.end - window.start, window.columns) catch unreachable;
    const visible_height = browser_grid_item_height * @as(f32, @floatFromInt(visible_rows)) +
        browser_grid_row_gap * @as(f32, @floatFromInt(if (visible_rows > 0) visible_rows - 1 else 0));
    const trailing = if (window.bottom_spacer > 0) window.bottom_spacer + gap else 0;
    const total_height = browser_grid_padding_v * 2 +
        browser_grid_item_height * @as(f32, @floatFromInt(total_rows)) +
        browser_grid_row_gap * @as(f32, @floatFromInt(total_rows - 1));

    try std.testing.expectEqual(expected_range.start * window.columns, window.start);
    try std.testing.expectApproxEqAbs(desired_body_y, body_y, 0.01);
    try std.testing.expectApproxEqAbs(total_height, body_y + visible_height + trailing, 0.01);
}

test "file browser list scroll keeps existing window until the render range changes" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 960,
        .height = 720,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    try initBrowserListTestState(&state, &ctx, &text_measure_ctx);

    const scroll_handle = state.file_panel_scroll.?;
    const row_height = browserListRowHeight(&state);
    const visible_count = browserVisibleCount(state.file_panel_viewport_height, row_height);
    const chunk_rows = browserVirtualChunkRows(visible_count);
    const target_scroll = row_height * @as(f32, @floatFromInt(chunk_rows - 1)) + row_height * 0.5;
    const start_before = state.asset_visible_start;
    const end_before = state.asset_visible_end;

    ctx.tree.get(scroll_handle).kind.scroll_area.scroll_y = target_scroll;
    const rebuilt = try syncBrowserTestScrollFrame(&state, &ctx, &text_measure_ctx);

    try std.testing.expect(!rebuilt);
    try std.testing.expectEqual(start_before, state.asset_visible_start);
    try std.testing.expectEqual(end_before, state.asset_visible_end);
    try std.testing.expectApproxEqAbs(target_scroll, ctx.tree.getConst(scroll_handle).kind.scroll_area.scroll_y, 0.01);
}

test "file browser list preserves row continuity across virtualization boundaries" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 960,
        .height = 720,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    try initBrowserListTestState(&state, &ctx, &text_measure_ctx);

    const scroll_handle = state.file_panel_scroll.?;
    const row_height = browserListRowHeight(&state);
    const visible_count = browserVisibleCount(state.file_panel_viewport_height, row_height);
    const chunk_rows = browserVirtualChunkRows(visible_count);
    const boundary_scroll = row_height * @as(f32, @floatFromInt(chunk_rows));
    const logical_entry_index = chunk_rows + browser_overscan_rows;

    ctx.tree.get(scroll_handle).kind.scroll_area.scroll_y = boundary_scroll - 1;
    _ = try syncBrowserTestScrollFrame(&state, &ctx, &text_measure_ctx);
    const first_row = state.row_handles.items[logical_entry_index - state.asset_visible_start];
    const first_y = ctx.tree.getConst(first_row).layout_rect.y;

    ctx.tree.get(scroll_handle).kind.scroll_area.scroll_y = boundary_scroll;
    const rebuilt = try syncBrowserTestScrollFrame(&state, &ctx, &text_measure_ctx);
    const second_row = state.row_handles.items[logical_entry_index - state.asset_visible_start];
    const second_y = ctx.tree.getConst(second_row).layout_rect.y;

    try std.testing.expect(rebuilt);
    try std.testing.expectEqual(chunk_rows - browser_overscan_rows, state.asset_visible_start);
    try std.testing.expectApproxEqAbs(first_y - 1, second_y, 0.01);
}

test "file browser list covers the viewport after a large scroll jump" {
    var state = State{};
    defer deinitBrowserState(&state);

    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &browserTestMeasureText,
    };

    var ctx = try goop.Context.init(allocator, .{
        .width = 960,
        .height = 720,
        .theme = browserTestTheme(),
    });
    defer ctx.deinit();

    try initBrowserListTestState(&state, &ctx, &text_measure_ctx);

    const scroll_handle = state.file_panel_scroll.?;
    const row_height = browserListRowHeight(&state);
    const target_row: usize = 120;
    const target_scroll = row_height * @as(f32, @floatFromInt(target_row)) + row_height * 0.25;
    const visible_count = browserVisibleCount(state.file_panel_viewport_height, row_height);

    ctx.tree.get(scroll_handle).kind.scroll_area.scroll_y = target_scroll;
    const rebuilt = try syncBrowserTestScrollFrame(&state, &ctx, &text_measure_ctx);

    try std.testing.expect(rebuilt);
    try std.testing.expect(state.asset_visible_start <= target_row);
    try std.testing.expect(state.asset_visible_end >= target_row + visible_count);
}

fn appendPreviewLine(buffer: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    if (buffer.items.len > 0) try buffer.append(allocator, '\n');
    try buffer.appendSlice(allocator, text);
}

fn appendPreviewPrintLine(buffer: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(line);
    try appendPreviewLine(buffer, line);
}

fn isPreviewTextControlByte(byte: u8) bool {
    return switch (byte) {
        '\t', '\n', '\r', 0x0c, 0x1b => true,
        else => false,
    };
}

fn bytesLookLikeTextPreview(bytes: []const u8) bool {
    if (bytes.len == 0) return true;

    for (bytes) |byte| {
        if (byte == 0) return false;
        if (byte < 0x20 and !isPreviewTextControlByte(byte)) return false;
        if (byte == 0x7f) return false;
    }
    return true;
}

fn readFilePreviewBytesAlloc(io: std.Io, alloc: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
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

fn appendPreviewEntryName(buffer: *std.ArrayListUnmanaged(u8), name: []const u8, is_directory: bool) !void {
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

fn appendDirectoryPreviewSummary(
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

const SelectionPreview = struct {
    text: []const u8,
    framed: bool = false,
};

fn allocSelectionPreview(state: *State) !SelectionPreview {
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

fn addToolbarButton(state: *const State, ctx: *goop.Context, parent: goop.NodeHandle, label: []const u8, active: bool, enabled: bool) !goop.NodeHandle {
    const handle = try ctx.tree.addChild(parent, .{ .button = .{ .label = label } });
    ctx.tree.get(handle).style_override = fileManagerToolbarButtonStyle(state, active, enabled);
    return handle;
}

fn addToolbarCommandButton(state: *const State, ctx: *goop.Context, parent: goop.NodeHandle, label: []const u8, command: BrowserCommand) !goop.NodeHandle {
    return addToolbarButton(state, ctx, parent, label, browserCommandChecked(state, command), browserCommandEnabled(state, command));
}

fn addMenuCommandItem(
    state: *const State,
    ctx: *goop.Context,
    parent: goop.NodeHandle,
    label: []const u8,
    command: BrowserCommand,
    shortcut: []const u8,
) !goop.NodeHandle {
    const handle = try ctx.tree.addChild(parent, .{ .menu_item = .{
        .label = label,
        .shortcut = shortcut,
        .checked = browserCommandChecked(state, command),
        .enabled = browserCommandEnabled(state, command),
    } });
    ctx.tree.get(handle).style_override = fileManagerMenuItemStyle(state);
    return handle;
}

fn addContextMenuItem(
    state: *const State,
    ctx: *goop.Context,
    parent: goop.NodeHandle,
    label: []const u8,
    enabled: bool,
) !goop.NodeHandle {
    const handle = try ctx.tree.addChild(parent, .{ .menu_item = .{
        .label = label,
        .enabled = enabled,
    } });
    ctx.tree.get(handle).style_override = fileManagerMenuItemStyle(state);
    return handle;
}

fn buildContextPopup(state: *State, ctx: *goop.Context) !void {
    if (!state.context_visible) return;

    const popup = try ctx.tree.addRoot(.{ .popup = .{
        .placement = .absolute,
        .x = state.context_x,
        .y = state.context_y,
        .visible = true,
        .close_on_outside_click = true,
        .z_index = 140,
    } });
    state.context_popup = popup;
    ctx.tree.get(popup).style_override = fileManagerMenuPopupStyle(state);

    state.context_open = try addContextMenuItem(state, ctx, popup, "Open", contextOpenEnabled(state));
    state.context_copy = try addContextMenuItem(state, ctx, popup, "Copy", contextSelectionCommandEnabled(state));
    state.context_cut = try addContextMenuItem(state, ctx, popup, "Cut", contextSelectionCommandEnabled(state));
    state.context_paste = try addContextMenuItem(state, ctx, popup, "Paste", contextPasteEnabled(state));
    state.context_delete = try addContextMenuItem(state, ctx, popup, "Delete", contextSelectionCommandEnabled(state));
    state.context_rename = try addContextMenuItem(state, ctx, popup, "Rename", contextRenameEnabled(state));
    state.context_move_parent = try addContextMenuItem(state, ctx, popup, "Move to Parent Directory", contextMoveParentEnabled(state));
    state.context_copy_path = try addContextMenuItem(state, ctx, popup, "Copy Path", contextCopyPathEnabled(state));
    state.context_open_link_target = try addContextMenuItem(state, ctx, popup, "Open Link Target", contextOpenLinkTargetEnabled(state));
}

fn fileManagerShellColor() goop.Color {
    return .rgb(240, 243, 247);
}

fn fileManagerChromeColor() goop.Color {
    return .rgb(232, 236, 241);
}

fn fileManagerSurfaceColor() goop.Color {
    return .rgb(255, 255, 255);
}

fn fileManagerPanelHeaderColor() goop.Color {
    return .rgb(246, 248, 251);
}

fn fileManagerSidebarColor() goop.Color {
    return .rgb(245, 247, 250);
}

fn fileManagerMutedTextColor() goop.Color {
    return .rgb(100, 109, 123);
}

fn fileManagerToolbarButtonStyle(state: *const State, active: bool, enabled: bool) goop.Style {
    return .{
        .bg = if (active)
            .rgb(222, 233, 249)
        else if (enabled)
            .rgb(247, 249, 252)
        else
            .rgb(240, 243, 247),
        .fg = if (enabled) fileManagerTheme(state).fg else fileManagerMutedTextColor(),
        .border = if (active)
            fileManagerTheme(state).accent
        else
            .rgb(209, 216, 226),
        .border_width = uiPx(state, 1),
        .padding = uiEdgesSymmetric(state, 10, 6),
        .border_radius = uiPx(state, 5),
    };
}

fn fileManagerTextInputStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgb(255, 255, 255),
        .border = .rgb(203, 210, 223),
        .border_width = uiPx(state, 1),
        .padding = uiEdgesSymmetric(state, 10, 6),
        .border_radius = uiPx(state, 5),
    };
}

fn fileManagerRenameInputStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgb(255, 255, 255),
        .fg = fileManagerTheme(state).fg,
        .border = fileManagerTheme(state).accent,
        .border_width = uiPx(state, 1),
        .padding = uiEdgesSymmetric(state, 4, 1),
        .border_radius = uiPx(state, 3),
    };
}

fn fileManagerMenuBarStyle(state: *const State) goop.Style {
    return .{
        .bg = fileManagerChromeColor(),
        .border_width = 0,
        .padding = uiEdgesSymmetric(state, 6, 2),
        .spacing = uiPx(state, 0),
        .border_radius = 0,
    };
}

fn fileManagerMenuStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .padding = uiEdgesSymmetric(state, 6, 2),
        .border_radius = uiPx(state, 2),
    };
}

fn fileManagerMenuRootButtonStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .padding = uiEdgesSymmetric(state, 6, 2),
        .border_radius = uiPx(state, 2),
    };
}

fn fileManagerMenuPopupStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgb(255, 255, 255),
        .border = .rgb(203, 210, 223),
        .border_width = uiPx(state, 1),
        .padding = uiEdgesSymmetric(state, 6, 6),
        .spacing = 0,
        .border_radius = uiPx(state, 8),
    };
}

fn fileManagerMenuItemStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .padding = uiEdgesSymmetric(state, 10, 6),
        .border_radius = uiPx(state, 4),
    };
}

fn fileManagerSectionLabelStyle(state: *const State) goop.Style {
    return .{
        .fg = fileManagerMutedTextColor(),
        .font_size = uiPx(state, 13),
    };
}

fn fileManagerFolderTreeStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .padding = uiEdgesAll(state, 0),
        .spacing = 0,
        .border_radius = 0,
    };
}

fn fileManagerFolderTreeItemStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .font_size = uiPx(state, 14.5),
        .padding = .{
            .top = uiPx(state, 3),
            .right = uiPx(state, 6),
            .bottom = uiPx(state, 3),
            .left = 0,
        },
        .border_radius = uiPx(state, 3),
    };
}

fn fileManagerPlaceItemStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .font_size = uiPx(state, 14.5),
        .padding = uiEdgesSymmetric(state, 6, 4),
        .border_radius = uiPx(state, 3),
    };
}

fn fileManagerStatusTextStyle(state: *const State) goop.Style {
    return .{
        .fg = fileManagerMutedTextColor(),
        .font_size = uiPx(state, 12.5),
    };
}

fn fileManagerShellStyle(state: *const State) goop.Style {
    return .{
        .bg = fileManagerShellColor(),
        .border_width = 0,
        .padding = uiEdgesAll(state, 0),
        .spacing = 0,
        .border_radius = 0,
    };
}

fn fileManagerToolbarStyle(state: *const State) goop.Style {
    return .{
        .bg = fileManagerChromeColor(),
        .border_width = 0,
        .padding = uiEdgesSymmetric(state, 10, 9),
        .spacing = uiPx(state, 8),
        .border_radius = 0,
    };
}

fn fileManagerPaneStyle(state: *const State, bg: goop.Color) goop.Style {
    return .{
        .bg = bg,
        .border_width = 0,
        .padding = uiEdgesAll(state, 0),
        .spacing = 0,
        .border_radius = 0,
    };
}

fn fileManagerPaneHeaderStyle(state: *const State) goop.Style {
    return .{
        .bg = fileManagerPanelHeaderColor(),
        .border_width = 0,
        .padding = uiEdgesSymmetric(state, 12, 8),
        .spacing = uiPx(state, 6),
        .border_radius = 0,
    };
}

fn fileManagerDetailContentStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .padding = uiEdgesAll(state, 0),
        .spacing = uiPx(state, 8),
        .border_radius = 0,
    };
}

fn fileManagerPreviewFrameStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgb(255, 255, 255),
        .border = .rgb(214, 220, 228),
        .border_width = 1,
        .padding = uiEdgesSymmetric(state, 12, 10),
        .spacing = 0,
        .border_radius = uiPx(state, 6),
    };
}

fn fileManagerDetailTitleStyle(state: *const State) goop.Style {
    return .{
        .fg = .rgb(20, 25, 33),
        .font_size = detailTitleFontSizePx(state),
    };
}

fn fileManagerDetailMetaStyle(state: *const State) goop.Style {
    return .{
        .fg = fileManagerMutedTextColor(),
        .font_size = detailCaptionFontSizePx(state),
    };
}

fn fileManagerDetailHintStyle(state: *const State) goop.Style {
    return .{
        .fg = fileManagerMutedTextColor(),
        .font_size = detailCaptionFontSizePx(state),
    };
}

fn fileManagerPreviewBodyStyle(state: *const State) goop.Style {
    return .{
        .fg = .rgb(34, 40, 48),
        .font_size = previewBodyFontSizePx(state),
    };
}

fn fileManagerGutterStyle(state: *const State) goop.Style {
    return .{
        .bg = fileManagerShellColor(),
        .border_width = 0,
        .padding = uiEdgesAll(state, 0),
        .spacing = 0,
        .border_radius = 0,
    };
}

fn folderTreeLabel(state: *State, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "/")) return "/";
    return allocUiUtf8Lossy(state, std.fs.path.basename(path));
}

fn addFolderTreeItem(
    state: *State,
    ctx: *goop.Context,
    parent: goop.NodeHandle,
    path: []const u8,
    label: []const u8,
    expanded: bool,
    selected: bool,
    has_children: bool,
) !goop.NodeHandle {
    const handle = try ctx.tree.addChild(parent, .{ .tree_item = .{
        .label = label,
        .group = 91,
        .icon = .folder,
        .icon_color = .rgb(74, 120, 201),
        .has_children = has_children,
        .expanded = expanded,
        .selected = selected,
    } });
    ctx.tree.get(handle).style_override = fileManagerFolderTreeItemStyle(state);
    ctx.setDropTarget(handle, true);
    try state.folder_tree_handles.append(allocator, handle);
    try state.folder_tree_paths.append(allocator, try allocator.dupe(u8, path));
    return handle;
}

fn buildFolderTreeBranch(
    state: *State,
    ctx: *goop.Context,
    parent: goop.NodeHandle,
    dir_path: []const u8,
    parent_expansion: FolderTreeExpansion,
) !void {
    var children: std.ArrayListUnmanaged(FolderTreeChild) = .empty;
    defer {
        clearFolderTreeChildren(&children);
        children.deinit(allocator);
    }

    const io = state.io orelse return;
    try collectFolderTreeChildren(io, dir_path, &children);

    for (children.items, 0..) |child, index| {
        if (!shouldRenderFolderTreeChildForExpansion(state, parent_expansion, index, child.path)) continue;

        const selected = std.mem.eql(u8, child.path, state.current_dir);
        const expansion = folderTreeExpansion(state, child.path);
        const expanded = expansion != .collapsed;
        const has_children = folderTreeDirectoryHasChildren(io, child.path);
        const handle = try addFolderTreeItem(
            state,
            ctx,
            parent,
            child.path,
            try allocUiUtf8Lossy(state, child.name),
            expanded,
            selected,
            has_children,
        );
        if (expanded) try buildFolderTreeBranch(state, ctx, handle, child.path, expansion);
    }
}

fn buildFolderTree(state: *State, ctx: *goop.Context, parent: goop.NodeHandle) !void {
    const tree_root = try ctx.tree.addChild(parent, .{ .container = .{ .direction = .column } });
    ctx.tree.get(tree_root).style_override = fileManagerFolderTreeStyle(state);

    const root_expansion = folderTreeExpansion(state, "/");
    const root = try addFolderTreeItem(
        state,
        ctx,
        tree_root,
        "/",
        try folderTreeLabel(state, "/"),
        root_expansion != .collapsed,
        std.mem.eql(u8, state.current_dir, "/"),
        if (state.io) |io| folderTreeDirectoryHasChildren(io, "/") else false,
    );
    if (root_expansion != .collapsed) try buildFolderTreeBranch(state, ctx, root, "/", root_expansion);
}

fn buildWidgetTree(state: *State) !void {
    const ctx = state.ctx orelse return error.NoContext;
    const transparent = goop.Color.rgba(0, 0, 0, 0);

    captureFilePanelViewport(state, ctx);
    captureSidebarScroll(state, ctx);
    if (state.ui_root) |root| {
        if (ctx.isAlive(root)) try ctx.removeWidget(root);
    }
    if (state.context_popup) |popup| {
        if (ctx.isAlive(popup)) try ctx.removeWidget(popup);
    }
    clearUiTracking(state);

    state.ui_root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    const root = state.ui_root.?;
    ctx.tree.get(root).style_override = fileManagerShellStyle(state);

    var directory_count: usize = 0;
    for (state.entries.items) |entry| {
        if (entry.isDirectory()) directory_count += 1;
    }
    const file_count = state.entries.items.len - directory_count;

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

    const selected_count = selectedPathCount(state);

    {
        const menu_bar = try ctx.tree.addChild(root, .{ .menu_bar = .{} });
        ctx.tree.get(menu_bar).style_override = fileManagerMenuBarStyle(state);
        {
            state.menu_file_button = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "File" } });
            ctx.tree.get(state.menu_file_button.?).style_override = fileManagerMenuStyle(state);
            const popup = try ctx.tree.addChild(state.menu_file_button.?, .{ .popup = .{ .placement = .below_start, .visible = false } });
            state.menu_file_popup = popup;
            ctx.tree.get(popup).style_override = fileManagerMenuPopupStyle(state);
            state.menu_file_refresh = try addMenuCommandItem(state, ctx, popup, "Refresh", .refresh, "");
            state.menu_file_copy_path = try addMenuCommandItem(state, ctx, popup, "Copy Path", .copy_path, "");
            state.menu_file_open_target = try addMenuCommandItem(state, ctx, popup, "Open Link Target", .open_link_target, "");
            state.menu_file_quit = try addMenuCommandItem(state, ctx, popup, "Quit", .quit, "");
        }
        {
            state.menu_edit_button = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "Edit" } });
            ctx.tree.get(state.menu_edit_button.?).style_override = fileManagerMenuStyle(state);
            const popup = try ctx.tree.addChild(state.menu_edit_button.?, .{ .popup = .{ .placement = .below_start, .visible = false } });
            state.menu_edit_popup = popup;
            ctx.tree.get(popup).style_override = fileManagerMenuPopupStyle(state);
            state.menu_edit_copy = try addMenuCommandItem(state, ctx, popup, "Copy", .copy, "Ctrl+C");
            state.menu_edit_cut = try addMenuCommandItem(state, ctx, popup, "Cut", .cut, "Ctrl+X");
            state.menu_edit_paste = try addMenuCommandItem(state, ctx, popup, "Paste", .paste, "Ctrl+V");
            state.menu_edit_delete = try addMenuCommandItem(state, ctx, popup, "Delete", .delete, "Del");
            state.menu_edit_rename = try addMenuCommandItem(state, ctx, popup, "Rename", .rename, "");
            state.menu_edit_move_parent = try addMenuCommandItem(state, ctx, popup, "Move to Parent Directory", .move_parent, "Ctrl+Shift+Up");
            state.menu_edit_select_all = try addMenuCommandItem(state, ctx, popup, "Select All", .select_all, "Ctrl+A");
            state.menu_edit_clear_selection = try addMenuCommandItem(state, ctx, popup, "Clear Selection", .clear_selection, "Esc");
        }
        {
            state.menu_view_button = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "View" } });
            ctx.tree.get(state.menu_view_button.?).style_override = fileManagerMenuStyle(state);
            const popup = try ctx.tree.addChild(state.menu_view_button.?, .{ .popup = .{ .placement = .below_start, .visible = false } });
            state.menu_view_popup = popup;
            ctx.tree.get(popup).style_override = fileManagerMenuPopupStyle(state);
            state.menu_view_sidebar = try addMenuCommandItem(state, ctx, popup, "Sidebar", .toggle_sidebar, "");
            state.menu_view_preview = try addMenuCommandItem(state, ctx, popup, "Preview", .toggle_preview, "");
            state.menu_view_info = try addMenuCommandItem(state, ctx, popup, "Details", .toggle_info, "");
            state.menu_view_status_bar = try addMenuCommandItem(state, ctx, popup, "Status Bar", .toggle_status_bar, "");
            state.menu_view_list = try addMenuCommandItem(state, ctx, popup, "List View", .view_list, "");
            state.menu_view_grid = try addMenuCommandItem(state, ctx, popup, "Grid View", .view_grid, "");
            state.menu_view_sort_directories = try addMenuCommandItem(state, ctx, popup, "Sort Directories Together", .toggle_sort_directories, "");
        }
        {
            state.menu_go_button = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "Go" } });
            ctx.tree.get(state.menu_go_button.?).style_override = fileManagerMenuStyle(state);
            const popup = try ctx.tree.addChild(state.menu_go_button.?, .{ .popup = .{ .placement = .below_start, .visible = false } });
            state.menu_go_popup = popup;
            ctx.tree.get(popup).style_override = fileManagerMenuPopupStyle(state);
            state.menu_go_back = try addMenuCommandItem(state, ctx, popup, "Back", .back, "");
            state.menu_go_forward = try addMenuCommandItem(state, ctx, popup, "Forward", .forward, "");
            state.menu_go_up = try addMenuCommandItem(state, ctx, popup, "Up", .up, "");
            state.menu_go_home = try addMenuCommandItem(state, ctx, popup, "Home", .home, "");
        }
        {
            state.menu_help_button = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "Help" } });
            ctx.tree.get(state.menu_help_button.?).style_override = fileManagerMenuStyle(state);
            const popup = try ctx.tree.addChild(state.menu_help_button.?, .{ .popup = .{ .placement = .below_start, .visible = false } });
            state.menu_help_popup = popup;
            ctx.tree.get(popup).style_override = fileManagerMenuPopupStyle(state);
            state.menu_help_about = try addMenuCommandItem(state, ctx, popup, "About goop files", .about, "");
        }
    }

    const toolbar = try ctx.tree.addChild(root, .{ .toolbar = .{} });
    ctx.tree.get(toolbar).style_override = fileManagerToolbarStyle(state);
    state.btn_back = try addToolbarCommandButton(state, ctx, toolbar, "Back", .back);
    state.btn_forward = try addToolbarCommandButton(state, ctx, toolbar, "Forward", .forward);
    state.btn_up = try addToolbarCommandButton(state, ctx, toolbar, "Up", .up);
    if (browserCommandEnabled(state, .up)) ctx.setDropTarget(state.btn_up.?, true);
    state.btn_home = try addToolbarCommandButton(state, ctx, toolbar, "Home", .home);
    state.btn_refresh = try addToolbarCommandButton(state, ctx, toolbar, "Refresh", .refresh);
    _ = try ctx.tree.addChild(toolbar, .{ .spacer = .{ .width = uiPx(state, 6) } });
    state.btn_toggle_sidebar = try addToolbarCommandButton(state, ctx, toolbar, "Sidebar", .toggle_sidebar);
    state.btn_toggle_preview = try addToolbarCommandButton(state, ctx, toolbar, "Preview", .toggle_preview);
    state.btn_toggle_info = try addToolbarCommandButton(state, ctx, toolbar, "Details", .toggle_info);
    _ = try ctx.tree.addChild(toolbar, .{ .spacer = .{ .width = uiPx(state, 8) } });
    state.address_input_handle = try ctx.tree.addChild(toolbar, .{ .text_input = state.address_input });
    ctx.tree.get(state.address_input_handle.?).style_override = fileManagerTextInputStyle(state);
    state.btn_address_go = try addToolbarButton(state, ctx, toolbar, "Go", false, true);
    _ = try ctx.tree.addChild(toolbar, .{ .spacer = .{ .width = uiPx(state, 8) } });
    state.btn_list_view = try addToolbarCommandButton(state, ctx, toolbar, "List", .view_list);
    state.btn_grid_view = try addToolbarCommandButton(state, ctx, toolbar, "Grid", .view_grid);

    var content_host: goop.NodeHandle = undefined;
    if (state.show_sidebar) {
        state.nav_splitter = try ctx.tree.addChild(root, .{ .splitter = .{
            .direction = .row,
            .ratio = state.nav_ratio,
            .min_first = uiPx(state, 220),
            .min_second = uiPx(state, 420),
            .thickness = uiPx(state, 8),
            .gap_thickness = 1,
        } });
        ctx.tree.get(state.nav_splitter.?).style_override = fileManagerGutterStyle(state);

        const sidebar = try ctx.tree.addChild(state.nav_splitter.?, .{ .container = .{ .direction = .column } });
        ctx.tree.get(sidebar).style_override = fileManagerPaneStyle(state, fileManagerSidebarColor());
        const sidebar_header = try ctx.tree.addChild(sidebar, .{ .toolbar = .{} });
        ctx.tree.get(sidebar_header).style_override = fileManagerPaneHeaderStyle(state);
        _ = try ctx.tree.addChild(sidebar_header, .{ .text = .{ .content = "Browse" } });

        const sidebar_scroll = try ctx.tree.addChild(sidebar, .{ .scroll_area = .{
            .scroll_x = state.sidebar_scroll_x,
            .scroll_y = state.sidebar_scroll_y,
        } });
        state.sidebar_scroll = sidebar_scroll;
        ctx.tree.get(sidebar_scroll).style_override = .{
            .bg = transparent,
            .border_width = 0,
            .padding = uiEdgesSymmetric(state, 12, 12),
            .border_radius = 0,
        };
        const sidebar_content = try ctx.tree.addChild(sidebar_scroll, .{ .container = .{ .direction = .column } });
        ctx.tree.get(sidebar_content).style_override = .{
            .bg = transparent,
            .border_width = 0,
            .padding = uiEdgesAll(state, 0),
            .spacing = uiPx(state, 14),
            .border_radius = 0,
        };

        const places_label = try ctx.tree.addChild(sidebar_content, .{ .text = .{ .content = "Places" } });
        ctx.tree.get(places_label).style_override = fileManagerSectionLabelStyle(state);
        const places_list = try ctx.tree.addChild(sidebar_content, .{ .list_box = .{ .selection_mode = .single } });
        for (state.places.items) |place| {
            const handle = try ctx.tree.addChild(places_list, .{ .selectable = .{
                .label = place.label,
                .selected = std.mem.eql(u8, place.path, state.current_dir),
            } });
            ctx.tree.get(handle).style_override = fileManagerPlaceItemStyle(state);
            ctx.setDropTarget(handle, true);
            try state.place_handles.append(allocator, handle);
        }

        const folders_label = try ctx.tree.addChild(sidebar_content, .{ .text = .{ .content = "Folders" } });
        ctx.tree.get(folders_label).style_override = fileManagerSectionLabelStyle(state);
        try buildFolderTree(state, ctx, sidebar_content);

        content_host = try ctx.tree.addChild(state.nav_splitter.?, .{ .container = .{ .direction = .column } });
        ctx.tree.get(content_host).style_override = fileManagerPaneStyle(state, transparent);
    } else {
        content_host = try ctx.tree.addChild(root, .{ .container = .{ .direction = .column } });
        ctx.tree.get(content_host).style_override = fileManagerPaneStyle(state, transparent);
    }

    var file_panel: goop.NodeHandle = undefined;
    var preview_panel: ?goop.NodeHandle = null;
    var detail_panel: ?goop.NodeHandle = null;
    if (state.show_preview or state.show_info) {
        state.detail_splitter = try ctx.tree.addChild(content_host, .{ .splitter = .{
            .direction = .row,
            .ratio = state.detail_ratio,
            .min_first = uiPx(state, 360),
            .min_second = uiPx(state, 300),
            .thickness = uiPx(state, 8),
            .gap_thickness = 1,
        } });
        ctx.tree.get(state.detail_splitter.?).style_override = fileManagerGutterStyle(state);

        file_panel = try ctx.tree.addChild(state.detail_splitter.?, .{ .container = .{ .direction = .column } });
        ctx.tree.get(file_panel).style_override = fileManagerPaneStyle(state, fileManagerSurfaceColor());
        const inspector_host = try ctx.tree.addChild(state.detail_splitter.?, .{ .container = .{ .direction = .column } });
        ctx.tree.get(inspector_host).style_override = fileManagerPaneStyle(state, fileManagerSidebarColor());

        if (state.show_preview and state.show_info) {
            state.preview_splitter = try ctx.tree.addChild(inspector_host, .{ .splitter = .{
                .direction = .column,
                .ratio = state.preview_ratio,
                .min_first = uiPx(state, 180),
                .min_second = uiPx(state, 180),
                .thickness = uiPx(state, 8),
                .gap_thickness = 1,
            } });
            ctx.tree.get(state.preview_splitter.?).style_override = fileManagerGutterStyle(state);
            preview_panel = try ctx.tree.addChild(state.preview_splitter.?, .{ .container = .{ .direction = .column } });
            ctx.tree.get(preview_panel.?).style_override = fileManagerPaneStyle(state, fileManagerSidebarColor());
            detail_panel = try ctx.tree.addChild(state.preview_splitter.?, .{ .container = .{ .direction = .column } });
            ctx.tree.get(detail_panel.?).style_override = fileManagerPaneStyle(state, fileManagerSidebarColor());
        } else if (state.show_preview) {
            preview_panel = inspector_host;
        } else if (state.show_info) {
            detail_panel = inspector_host;
        }
    } else {
        file_panel = try ctx.tree.addChild(content_host, .{ .container = .{ .direction = .column } });
        ctx.tree.get(file_panel).style_override = fileManagerPaneStyle(state, fileManagerSurfaceColor());
    }

    const breadcrumb_bar = try ctx.tree.addChild(file_panel, .{ .toolbar = .{} });
    ctx.tree.get(breadcrumb_bar).style_override = fileManagerPaneHeaderStyle(state);
    const root_button = try ctx.tree.addChild(breadcrumb_bar, .{ .button = .{ .label = "/" } });
    ctx.tree.get(root_button).style_override = fileManagerToolbarButtonStyle(state, false, true);
    ctx.setDropTarget(root_button, true);
    try state.breadcrumb_handles.append(allocator, root_button);
    try state.breadcrumb_paths.append(allocator, try allocator.dupe(u8, "/"));
    if (!std.mem.eql(u8, state.current_dir, "/")) {
        var start: usize = 1;
        while (start < state.current_dir.len) {
            const end = std.mem.indexOfScalarPos(u8, state.current_dir, start, '/') orelse state.current_dir.len;
            _ = try ctx.tree.addChild(breadcrumb_bar, .{ .text = .{ .content = "/" } });
            const segment = state.current_dir[start..end];
            const handle = try ctx.tree.addChild(breadcrumb_bar, .{ .button = .{ .label = try allocUiUtf8Lossy(state, segment) } });
            ctx.tree.get(handle).style_override = fileManagerToolbarButtonStyle(state, false, true);
            ctx.setDropTarget(handle, true);
            try state.breadcrumb_handles.append(allocator, handle);
            try state.breadcrumb_paths.append(allocator, try allocator.dupe(u8, state.current_dir[0..end]));
            start = end + 1;
        }
    }

    if (state.view_mode == .list) {
        try buildListHeaderTable(state, ctx, file_panel);
    }

    state.file_panel_scroll = try ctx.tree.addChild(file_panel, .{ .scroll_area = .{ .scroll_y = state.file_panel_scroll_y } });
    ctx.tree.get(state.file_panel_scroll.?).style_override = .{
        .bg = transparent,
        .border_width = 0,
        .padding = uiEdgesAll(state, 0),
        .border_radius = 0,
    };
    try buildAssetView(state, ctx, state.file_panel_scroll.?);

    if (preview_panel) |panel| {
        const preview_header = try ctx.tree.addChild(panel, .{ .toolbar = .{} });
        ctx.tree.get(preview_header).style_override = fileManagerPaneHeaderStyle(state);
        _ = try ctx.tree.addChild(preview_header, .{ .text = .{ .content = "Preview" } });

        const preview_scroll = try ctx.tree.addChild(panel, .{ .scroll_area = .{ .allow_horizontal_scroll = false } });
        ctx.tree.get(preview_scroll).style_override = .{
            .bg = transparent,
            .border_width = 0,
            .padding = uiEdgesSymmetric(state, 12, 12),
            .border_radius = 0,
        };
        const preview_content = try ctx.tree.addChild(preview_scroll, .{ .container = .{ .direction = .column } });
        ctx.tree.get(preview_content).style_override = fileManagerDetailContentStyle(state);
        const preview = try allocSelectionPreview(state);
        const preview_text_parent = if (preview.framed) blk: {
            const preview_frame = try ctx.tree.addChild(preview_content, .{ .container = .{ .direction = .column } });
            ctx.tree.get(preview_frame).style_override = fileManagerPreviewFrameStyle(state);
            break :blk preview_frame;
        } else preview_content;
        _ = try addStyledDetailText(
            ctx,
            preview_text_parent,
            preview.text,
            .wrap,
            fileManagerPreviewBodyStyle(state),
        );
    }

    if (detail_panel) |panel| {
        const detail_header = try ctx.tree.addChild(panel, .{ .toolbar = .{} });
        ctx.tree.get(detail_header).style_override = fileManagerPaneHeaderStyle(state);
        _ = try ctx.tree.addChild(detail_header, .{ .text = .{ .content = "Details" } });
        const detail_scroll = try ctx.tree.addChild(panel, .{ .scroll_area = .{ .allow_horizontal_scroll = false } });
        ctx.tree.get(detail_scroll).style_override = .{
            .bg = transparent,
            .border_width = 0,
            .padding = uiEdgesSymmetric(state, 12, 12),
            .border_radius = 0,
        };
        const detail_content = try ctx.tree.addChild(detail_scroll, .{ .container = .{ .direction = .column } });
        ctx.tree.get(detail_content).style_override = fileManagerDetailContentStyle(state);

        if (selected_count == 1 and selectedEntry(state) != null) {
            const entry = selectedEntry(state).?;
            const modified_text = try allocFormattedTimestampDetail(state, entry.modified_unix);
            const size_text = try allocFormattedSize(state, entry.kind, entry.size_bytes, entry.target_kind);
            const meta_text = if (size_text.len > 0)
                try allocUiString(state, "{s} · {s} · {s}", .{
                    entry.typeLabel(),
                    size_text,
                    modified_text,
                })
            else
                try allocUiString(state, "{s} · {s}", .{
                    entry.typeLabel(),
                    modified_text,
                });
            _ = try addStyledDetailText(
                ctx,
                detail_content,
                try allocUiDetailWrappedUtf8Lossy(state, entry.name, detailTitleFontSizePx(state)),
                .wrap,
                fileManagerDetailTitleStyle(state),
            );
            _ = try addStyledDetailText(ctx, detail_content, meta_text, .wrap, fileManagerDetailMetaStyle(state));

            const path_line = try std.fmt.allocPrint(allocator, "Path: {f}", .{std.unicode.fmtUtf8(entry.path)});
            defer allocator.free(path_line);
            _ = try addStyledDetailText(
                ctx,
                detail_content,
                try allocUiDetailWrappedUtf8Lossy(state, path_line, detailCaptionFontSizePx(state)),
                .wrap,
                fileManagerDetailMetaStyle(state),
            );
            if (entry.target_path) |target_path| {
                const target_line = try std.fmt.allocPrint(allocator, "Target: {f}", .{std.unicode.fmtUtf8(target_path)});
                defer allocator.free(target_line);
                _ = try addStyledDetailText(
                    ctx,
                    detail_content,
                    try allocUiDetailWrappedUtf8Lossy(state, target_line, detailCaptionFontSizePx(state)),
                    .wrap,
                    fileManagerDetailMetaStyle(state),
                );
            }
            _ = try addStyledDetailText(
                ctx,
                detail_content,
                if (entry.canEnter())
                    "Double-click to enter this folder."
                else if (entry.kind == .symlink)
                    "Use Go or Open Link Target to follow this symbolic link."
                else
                    "Text files preview inline here; other file types show a summary.",
                .wrap,
                fileManagerDetailHintStyle(state),
            );
        } else if (selected_count > 1) {
            const selected_size_text = try allocFormattedSize(state, .file, selected_file_bytes, null);
            _ = try addStyledDetailText(
                ctx,
                detail_content,
                try allocUiString(state, "{d} items selected", .{selected_count}),
                .wrap,
                fileManagerDetailTitleStyle(state),
            );
            const summary_text = if (selected_file_count > 0)
                try allocUiString(state, "{d} directories · {d} files · {s}", .{
                    selected_directory_count,
                    selected_file_count,
                    selected_size_text,
                })
            else
                try allocUiString(state, "{d} directories · {d} files", .{
                    selected_directory_count,
                    selected_file_count,
                });
            _ = try addStyledDetailText(ctx, detail_content, summary_text, .wrap, fileManagerDetailMetaStyle(state));

            if (state.selected_path) |selected_path| {
                const active_line = try std.fmt.allocPrint(allocator, "Active: {f}", .{
                    std.unicode.fmtUtf8(std.fs.path.basename(selected_path)),
                });
                defer allocator.free(active_line);
                _ = try addStyledDetailText(
                    ctx,
                    detail_content,
                    try allocUiDetailWrappedUtf8Lossy(state, active_line, detailCaptionFontSizePx(state)),
                    .wrap,
                    fileManagerDetailMetaStyle(state),
                );
            }

            _ = try addStyledDetailText(
                ctx,
                detail_content,
                "Ctrl-click and Shift-click extend the current selection.",
                .wrap,
                fileManagerDetailHintStyle(state),
            );
        } else {
            const directory_name = if (std.mem.eql(u8, state.current_dir, "/")) "/" else std.fs.path.basename(state.current_dir);
            _ = try addStyledDetailText(
                ctx,
                detail_content,
                try allocUiDetailWrappedUtf8Lossy(state, directory_name, detailTitleFontSizePx(state)),
                .wrap,
                fileManagerDetailTitleStyle(state),
            );
            _ = try addStyledDetailText(
                ctx,
                detail_content,
                try allocUiString(state, "{d} items · {d} directories · {d} files", .{
                    state.entries.items.len,
                    directory_count,
                    file_count,
                }),
                .wrap,
                fileManagerDetailMetaStyle(state),
            );
            _ = try addStyledDetailText(
                ctx,
                detail_content,
                try allocUiString(state, "Sort: {s}, {s}{s} · View: {s}", .{
                    sortColumnLabel(state.sort_column),
                    sortDirectionLabel(state.sort_direction),
                    if (state.sort_directories_together) ", directories together" else "",
                    browserViewModeLabel(state.view_mode),
                }),
                .wrap,
                fileManagerDetailMetaStyle(state),
            );
            const current_path_line = try std.fmt.allocPrint(allocator, "Path: {f}", .{std.unicode.fmtUtf8(state.current_dir)});
            defer allocator.free(current_path_line);
            _ = try addStyledDetailText(
                ctx,
                detail_content,
                try allocUiDetailWrappedUtf8Lossy(state, current_path_line, detailCaptionFontSizePx(state)),
                .wrap,
                fileManagerDetailMetaStyle(state),
            );
            _ = try addStyledDetailText(
                ctx,
                detail_content,
                "Select a file to inspect it, or use Preview to skim folders and text files inline.",
                .wrap,
                fileManagerDetailHintStyle(state),
            );
        }
    }

    if (state.show_status_bar) {
        const status_bar = try ctx.tree.addChild(root, .{ .status_bar = .{} });
        ctx.tree.get(status_bar).style_override = fileManagerToolbarStyle(state);
        if (state.status_note) |note| {
            const handle = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = note } });
            ctx.tree.get(handle).style_override = fileManagerStatusTextStyle(state);
        }
        {
            const handle = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "{d} items", .{state.entries.items.len}) } });
            ctx.tree.get(handle).style_override = fileManagerStatusTextStyle(state);
        }
        {
            const handle = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "{d} selected", .{selected_count}) } });
            ctx.tree.get(handle).style_override = fileManagerStatusTextStyle(state);
        }
        {
            const handle = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "View: {s}", .{browserViewModeLabel(state.view_mode)}) } });
            ctx.tree.get(handle).style_override = fileManagerStatusTextStyle(state);
        }
        {
            const handle = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = try allocUiString(state, "Path: {f}", .{std.unicode.fmtUtf8(state.current_dir)}) } });
            ctx.tree.get(handle).style_override = fileManagerStatusTextStyle(state);
        }
    }

    try buildContextPopup(state, ctx);
}

// ── Font loading ──

fn loadFont(alloc: std.mem.Allocator, env: *const std.process.Environ.Map, io: std.Io) ![]u8 {
    if (fontPathFromEnv(env)) |path| {
        return readFile(alloc, io, path);
    }

    if (try fontPathFromFontconfig(alloc, io)) |path| {
        defer alloc.free(path);
        if (readFile(alloc, io, path)) |font_data| {
            return font_data;
        } else |_| {}
    }

    const fallback_paths = [_][]const u8{
        "/run/current-system/sw/share/X11/fonts/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
    };
    for (fallback_paths) |path| {
        return readFile(alloc, io, path) catch continue;
    }

    std.debug.print("font not found; set GOOP_DEMO_FONT_PATH to a TTF file\n", .{});
    return error.FontNotFound;
}

fn fontPathFromEnv(env: *const std.process.Environ.Map) ?[]const u8 {
    return env.get("GOOP_DEMO_FONT_PATH");
}

fn fontPathFromFontconfig(alloc: std.mem.Allocator, io: std.Io) !?[]u8 {
    const patterns = [_][]const u8{
        "Noto Sans:style=Regular",
        "sans-serif:style=Regular",
    };

    for (patterns) |pattern| {
        const result = std.process.run(alloc, io, .{
            .argv = &.{ "fc-match", "-f", "%{file}\n", pattern },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        }) catch continue;
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) continue,
            else => continue,
        }

        const line = std.mem.trimEnd(u8, result.stdout, "\r\n");
        if (line.len == 0) continue;
        return @as(?[]u8, try alloc.dupe(u8, line));
    }

    return null;
}

fn readFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const buf = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(256 * 1024 * 1024));
    std.debug.print("loaded font: {s} ({} bytes)\n", .{ path, buf.len });
    return buf;
}

// ── Main ──

fn parseTimeout(env: *const std.process.Environ.Map) ?u64 {
    const val = env.get("GOOP_DEMO_TIMEOUT") orelse return null;
    const secs = std.fmt.parseFloat(f64, val) catch return null;
    if (secs <= 0) return null;
    return @intFromFloat(secs * @as(f64, @floatFromInt(std.time.ns_per_s)));
}

fn getMonotonicNs(io: std.Io) u64 {
    const ns = std.Io.Clock.awake.now(io).nanoseconds;
    return if (ns <= 0) 0 else @intCast(ns);
}

pub fn main(init: std.process.Init) !void {
    // Connect to Wayland
    const display = wl.wl_display_connect(null) orelse {
        std.debug.print("failed to connect to wayland display\n", .{});
        return error.NoDisplay;
    };
    defer wl.wl_display_disconnect(display);

    var state = State{};
    state.display = display;
    state.io = init.io;
    state.env = init.environ_map;
    state.timeout_ns = parseTimeout(init.environ_map);
    state.ui_scale = envScale(init.environ_map, "GOOP_FILE_MANAGER_UI_SCALE", 1);
    state.scroll_debug_enabled = envFlag(init.environ_map, "GOOP_FILE_BROWSER_SCROLL_DEBUG");
    state.layout_debug_enabled = envFlag(init.environ_map, "GOOP_FILE_BROWSER_LAYOUT_DEBUG");
    if (state.timeout_ns) |t| {
        std.debug.print("demo will exit after {d:.1}s\n", .{@as(f64, @floatFromInt(t)) / std.time.ns_per_s});
    }
    if (state.scroll_debug_enabled) {
        std.debug.print("scroll-debug enabled via GOOP_FILE_BROWSER_SCROLL_DEBUG\n", .{});
    }
    if (state.layout_debug_enabled) {
        std.debug.print("layout-debug enabled via GOOP_FILE_BROWSER_LAYOUT_DEBUG\n", .{});
    }
    if (@abs(state.ui_scale - 1) > 0.001) {
        std.debug.print("ui-scale enabled via GOOP_FILE_MANAGER_UI_SCALE={d:.2}\n", .{state.ui_scale});
    }
    if (state.timeout_ns != null) {
        state.start_time_ns = getMonotonicNs(init.io);
    }

    // Bind globals
    const registry = wl.wl_display_get_registry(display) orelse return error.NoRegistry;
    _ = wl.wl_registry_add_listener(registry, &registry_listener, &state);
    _ = wl.wl_display_roundtrip(display);

    if (state.compositor == null) return error.NoCompositor;
    if (state.wm_base == null) return error.NoXdgWmBase;

    // Create surface
    state.surface = wl.wl_compositor_create_surface(state.compositor) orelse return error.NoSurface;
    _ = wl.wl_surface_add_listener(state.surface, &surface_listener, &state);
    state.xdg_surface = wl.xdg_wm_base_get_xdg_surface(state.wm_base, state.surface) orelse return error.NoXdgSurface;
    _ = wl.xdg_surface_add_listener(state.xdg_surface, &xdg_surface_listener, &state);
    state.xdg_toplevel = wl.xdg_surface_get_toplevel(state.xdg_surface) orelse return error.NoToplevel;
    _ = wl.xdg_toplevel_add_listener(state.xdg_toplevel, &xdg_toplevel_listener, &state);
    wl.xdg_toplevel_set_title(state.xdg_toplevel, "goop files");
    wl.xdg_toplevel_set_app_id(state.xdg_toplevel, "goop-files");
    wl.wl_surface_commit(state.surface.?);
    _ = wl.wl_display_roundtrip(display);

    // EGL + OpenGL
    try initEgl(&state, display);
    defer deinitEgl(&state);

    // Load font
    const font_data = loadFont(allocator, init.environ_map, init.io) catch |err| {
        std.debug.print("failed to load font: {}\n", .{err});
        return err;
    };
    defer allocator.free(font_data);

    var text_atlas = try snail.TextAtlas.init(allocator, &.{.{ .data = font_data }});
    defer text_atlas.deinit();

    const line_metrics = fontLineMetrics(&text_atlas);
    var text_measure = SnailTextCtx{
        .allocator = allocator,
        .text_atlas = &text_atlas,
        .scratch_buf = try allocator.alloc(u8, 64),
        .ascent_units = line_metrics.ascent,
        .descent_units = line_metrics.descent,
    };
    defer allocator.free(text_measure.scratch_buf);
    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &snailMeasureText,
        .user_data = @ptrCast(&text_measure),
    };
    state.text_measure_ctx = &text_measure_ctx;

    // goop context + widget tree
    var ctx = try goop.Context.init(allocator, .{
        .width = state.logical_width,
        .height = state.logical_height,
        .theme = fileManagerTheme(&state),
    });
    defer ctx.deinit();
    state.ctx = &ctx;
    ctx.clipboard = state.clipboard();
    try initializeBrowserState(&state);
    try buildWidgetTree(&state);

    // GL renderer (with snail text support)
    var renderer = try render.Renderer.init(state.buffer_width, state.buffer_height, &text_atlas);
    defer renderer.deinit();
    renderer.clear_color = .{ 0.95, 0.96, 0.97, 1.0 };

    std.debug.print("goop file manager running (logical {}x{}, scale {}, ui-scale {d:.2}, buffer {}x{})\n", .{
        state.logical_width,
        state.logical_height,
        state.buffer_scale,
        state.ui_scale,
        state.buffer_width,
        state.buffer_height,
    });

    // Wayland dispatch/render loop. Redraws are paced by frame callbacks.
    while (state.running) {
        // Check timeout
        if (state.timeout_ns) |t| {
            const now = getMonotonicNs(init.io);
            const elapsed = now - state.start_time_ns;
            if (elapsed >= t) {
                std.debug.print("demo timeout reached, exiting\n", .{});
                break;
            }
        }

        // Dispatch events. Pending redraws must not block here; the first
        // frame callback is only requested after the first render below.
        if (state.needs_redraw and !state.frame_pending) {
            _ = wl.wl_display_dispatch_pending(display);
            _ = wl.wl_display_flush(display);
        } else if (state.timeout_ns != null) {
            // Non-blocking: flush + prepare read, poll with 100ms timeout, then read
            while (wl.wl_display_prepare_read(display) != 0)
                _ = wl.wl_display_dispatch_pending(display);
            _ = wl.wl_display_flush(display);

            var pfd = [_]posix.pollfd{.{
                .fd = wl.wl_display_get_fd(display),
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const poll_ret = posix.poll(&pfd, 100) catch break;
            if (poll_ret > 0) {
                _ = wl.wl_display_read_events(display);
                _ = wl.wl_display_dispatch_pending(display);
            } else {
                wl.wl_display_cancel_read(display);
            }
        } else {
            // No timeout — block until events arrive
            if (wl.wl_display_dispatch(display) == -1) break;
        }

        if (!state.configured or !state.needs_redraw or state.frame_pending) continue;
        state.needs_redraw = false;

        // Process frame
        ctx.clearClickedFlags();
        ctx.doLayout(&text_measure_ctx);

        ctx.processEvents();
        syncContextPopupVisibleFromWidget(&state, &ctx);
        syncAddressInputFromWidget(&state, &ctx);
        syncRenameInputFromWidget(&state, &ctx);
        _ = try maybeStartWaylandAssetDrag(&state, &ctx);

        var rebuild_ui = false;

        if (state.rename_cancel_requested) {
            state.rename_cancel_requested = false;
            rebuild_ui = cancelActiveRename(&state) or rebuild_ui;
        }
        if (state.rename_commit_requested) {
            state.rename_commit_requested = false;
            switch (try commitActiveRename(&state)) {
                .inactive => {},
                .closed, .blocked => rebuild_ui = true,
            }
        }

        if (state.nav_splitter) |h| if (ctx.splitterChanged(h)) {
            state.nav_ratio = ctx.splitterRatio(h);
        };
        if (state.detail_splitter) |h| if (ctx.splitterChanged(h)) {
            state.detail_ratio = ctx.splitterRatio(h);
        };
        if (state.preview_splitter) |h| if (ctx.splitterChanged(h)) {
            state.preview_ratio = ctx.splitterRatio(h);
        };

        if (state.asset_table) |h| if (ctx.tableChanged(h)) {
            state.table_column_weights[0] = ctx.tableColumnFraction(h, 0) orelse state.table_column_weights[0];
            state.table_column_weights[1] = ctx.tableColumnFraction(h, 1) orelse state.table_column_weights[1];
            state.table_column_weights[2] = ctx.tableColumnFraction(h, 2) orelse state.table_column_weights[2];
            state.table_column_weights[3] = ctx.tableColumnFraction(h, 3) orelse state.table_column_weights[3];
            if (state.asset_table_body) |body| {
                if (ctx.isAlive(body)) {
                    applyAssetTableColumns(&ctx.tree.get(body).kind.table, &state);
                    ctx.invalidate();
                }
            }
        };

        if (state.asset_table) |h| if (ctx.tableSortChanged(h)) {
            if (ctx.tableSortedColumn(h)) |sorted_column| {
                const previous_sort_column = state.sort_column;
                state.sort_column = @enumFromInt(sorted_column);
                state.sort_direction = switch (ctx.tableSortDirection(h).?) {
                    .ascending => .ascending,
                    .descending => .descending,
                };
                if (previous_sort_column != state.sort_column and state.sort_column == .modified) {
                    state.sort_direction = .descending;
                }
                sortDirectoryEntries(&state);
                syncSelectionAnchor(&state);
                rebuild_ui = true;
            }
        };

        if (state.menu_file_refresh) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .refresh) or rebuild_ui;
        };
        if (state.menu_file_copy_path) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .copy_path) or rebuild_ui;
        };
        if (state.menu_file_open_target) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .open_link_target) or rebuild_ui;
        };
        if (state.menu_file_quit) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .quit) or rebuild_ui;
        };
        if (state.menu_edit_copy) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .copy) or rebuild_ui;
        };
        if (state.menu_edit_cut) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .cut) or rebuild_ui;
        };
        if (state.menu_edit_paste) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .paste) or rebuild_ui;
        };
        if (state.menu_edit_delete) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .delete) or rebuild_ui;
        };
        if (state.menu_edit_rename) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try beginRenameSelection(&state, &ctx) or rebuild_ui;
        };
        if (state.menu_edit_move_parent) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .move_parent) or rebuild_ui;
        };
        if (state.menu_edit_select_all) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .select_all) or rebuild_ui;
        };
        if (state.menu_edit_clear_selection) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .clear_selection) or rebuild_ui;
        };
        if (state.menu_view_sidebar) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .toggle_sidebar) or rebuild_ui;
        };
        if (state.menu_view_preview) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .toggle_preview) or rebuild_ui;
        };
        if (state.menu_view_info) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .toggle_info) or rebuild_ui;
        };
        if (state.menu_view_status_bar) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .toggle_status_bar) or rebuild_ui;
        };
        if (state.menu_view_list) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .view_list) or rebuild_ui;
        };
        if (state.menu_view_grid) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .view_grid) or rebuild_ui;
        };
        if (state.menu_view_sort_directories) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .toggle_sort_directories) or rebuild_ui;
        };
        if (state.menu_go_back) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .back) or rebuild_ui;
        };
        if (state.menu_go_forward) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .forward) or rebuild_ui;
        };
        if (state.menu_go_up) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .up) or rebuild_ui;
        };
        if (state.menu_go_home) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .home) or rebuild_ui;
        };
        if (state.menu_help_about) |h| if (ctx.wasClicked(h)) {
            setTopMenuPopupVisible(&state, &ctx, null);
            rebuild_ui = try runBrowserCommand(&state, .about) or rebuild_ui;
        };

        if (state.context_open) |h| if (ctx.wasClicked(h)) {
            hideContextMenu(&state, &ctx);
            rebuild_ui = try openContextTarget(&state) or rebuild_ui;
        };
        if (state.context_copy) |h| if (ctx.wasClicked(h)) {
            hideContextMenu(&state, &ctx);
            rebuild_ui = try runBrowserCommand(&state, .copy) or rebuild_ui;
        };
        if (state.context_cut) |h| if (ctx.wasClicked(h)) {
            hideContextMenu(&state, &ctx);
            rebuild_ui = try runBrowserCommand(&state, .cut) or rebuild_ui;
        };
        if (state.context_paste) |h| if (ctx.wasClicked(h)) {
            hideContextMenu(&state, &ctx);
            rebuild_ui = try pasteContextTarget(&state) or rebuild_ui;
        };
        if (state.context_delete) |h| if (ctx.wasClicked(h)) {
            hideContextMenu(&state, &ctx);
            rebuild_ui = try runBrowserCommand(&state, .delete) or rebuild_ui;
        };
        if (state.context_rename) |h| if (ctx.wasClicked(h)) {
            hideContextMenu(&state, &ctx);
            rebuild_ui = try beginRenameSelection(&state, &ctx) or rebuild_ui;
        };
        if (state.context_move_parent) |h| if (ctx.wasClicked(h)) {
            hideContextMenu(&state, &ctx);
            rebuild_ui = try runBrowserCommand(&state, .move_parent) or rebuild_ui;
        };
        if (state.context_copy_path) |h| if (ctx.wasClicked(h)) {
            hideContextMenu(&state, &ctx);
            rebuild_ui = try copyContextTargetPath(&state) or rebuild_ui;
        };
        if (state.context_open_link_target) |h| if (ctx.wasClicked(h)) {
            hideContextMenu(&state, &ctx);
            rebuild_ui = try openContextLinkTarget(&state) or rebuild_ui;
        };

        if (state.btn_back) |h| if (ctx.wasClicked(h)) {
            rebuild_ui = try runBrowserCommand(&state, .back) or rebuild_ui;
        };
        if (state.btn_forward) |h| if (ctx.wasClicked(h)) {
            rebuild_ui = try runBrowserCommand(&state, .forward) or rebuild_ui;
        };
        if (state.btn_up) |h| if (ctx.wasClicked(h)) {
            rebuild_ui = try runBrowserCommand(&state, .up) or rebuild_ui;
        };
        if (state.btn_home) |h| if (ctx.wasClicked(h)) {
            rebuild_ui = try runBrowserCommand(&state, .home) or rebuild_ui;
        };
        if (state.btn_refresh) |h| if (ctx.wasClicked(h)) {
            rebuild_ui = try runBrowserCommand(&state, .refresh) or rebuild_ui;
        };
        if (state.btn_toggle_sidebar) |h| if (ctx.wasClicked(h)) {
            rebuild_ui = try runBrowserCommand(&state, .toggle_sidebar) or rebuild_ui;
        };
        if (state.btn_toggle_preview) |h| if (ctx.wasClicked(h)) {
            rebuild_ui = try runBrowserCommand(&state, .toggle_preview) or rebuild_ui;
        };
        if (state.btn_toggle_info) |h| if (ctx.wasClicked(h)) {
            rebuild_ui = try runBrowserCommand(&state, .toggle_info) or rebuild_ui;
        };
        if (state.btn_address_go) |h| if (ctx.wasClicked(h)) {
            state.address_submit_requested = true;
        };
        if (state.btn_list_view) |h| if (ctx.wasClicked(h) and state.view_mode != .list) {
            rebuild_ui = try runBrowserCommand(&state, .view_list) or rebuild_ui;
        };
        if (state.btn_grid_view) |h| if (ctx.wasClicked(h) and state.view_mode != .grid) {
            rebuild_ui = try runBrowserCommand(&state, .view_grid) or rebuild_ui;
        };

        if (state.pending_command) |command| {
            state.pending_command = null;
            rebuild_ui = try runBrowserCommand(&state, command) or rebuild_ui;
        }
        if (state.address_submit_requested) {
            state.address_submit_requested = false;
            const path = try addressInputPathAlloc(&state);
            defer allocator.free(path);
            rebuild_ui = try setCurrentDirectory(&state, path, true) or rebuild_ui;
        }

        var context_menu_opened = false;
        for (state.place_handles.items, 0..) |handle, index| {
            if (!ctx.wasSecondaryClicked(handle)) continue;
            if (index >= state.places.items.len) continue;
            try showContextMenuForPath(&state, &ctx, state.places.items[index].path);
            context_menu_opened = true;
            rebuild_ui = true;
            break;
        }

        if (!context_menu_opened) {
            for (state.folder_tree_handles.items, 0..) |handle, index| {
                if (!ctx.wasSecondaryClicked(handle)) continue;
                if (index >= state.folder_tree_paths.items.len) continue;
                try showContextMenuForPath(&state, &ctx, state.folder_tree_paths.items[index]);
                context_menu_opened = true;
                rebuild_ui = true;
                break;
            }
        }

        if (!context_menu_opened) {
            for (state.breadcrumb_handles.items, 0..) |handle, index| {
                if (!ctx.wasSecondaryClicked(handle)) continue;
                if (index >= state.breadcrumb_paths.items.len) continue;
                try showContextMenuForPath(&state, &ctx, state.breadcrumb_paths.items[index]);
                context_menu_opened = true;
                rebuild_ui = true;
                break;
            }
        }

        if (!context_menu_opened) {
            for (state.row_handles.items, 0..) |handle, index| {
                if (!ctx.wasSecondaryClicked(handle)) continue;
                const entry_index = state.asset_visible_start + index;
                if (entry_index >= state.entries.items.len) continue;
                try selectEntryForContextMenu(&state, entry_index);
                try showContextMenuForPath(&state, &ctx, state.entries.items[entry_index].path);
                context_menu_opened = true;
                rebuild_ui = true;
                break;
            }
        }

        if (!context_menu_opened) {
            for (state.grid_handles.items, 0..) |handle, index| {
                if (!ctx.wasSecondaryClicked(handle)) continue;
                const entry_index = state.asset_visible_start + index;
                if (entry_index >= state.entries.items.len) continue;
                try selectEntryForContextMenu(&state, entry_index);
                try showContextMenuForPath(&state, &ctx, state.entries.items[entry_index].path);
                context_menu_opened = true;
                rebuild_ui = true;
                break;
            }
        }

        if (!context_menu_opened) {
            if (state.file_panel_scroll) |handle| {
                if (ctx.wasSecondaryClicked(handle)) {
                    try showContextMenuForPath(&state, &ctx, state.current_dir);
                    rebuild_ui = true;
                }
            }
        }

        var asset_primary_handled = false;
        if (ctx.lastWidgetDrop()) |drop| {
            asset_primary_handled = true;
            if (state.rename_path != null) {
                switch (try commitActiveRename(&state)) {
                    .inactive => {},
                    .closed => rebuild_ui = true,
                    .blocked => rebuild_ui = true,
                }
            }
            if (state.rename_path == null) {
                rebuild_ui = try handleAssetWidgetDrop(&state, drop) or rebuild_ui;
            }
        }

        if (ctx.lastTableDrop()) |drop| {
            asset_primary_handled = true;
            if (state.rename_path != null) {
                switch (try commitActiveRename(&state)) {
                    .inactive => {},
                    .closed => rebuild_ui = true,
                    .blocked => rebuild_ui = true,
                }
            }
            if (state.rename_path == null) {
                rebuild_ui = try handleAssetTableDrop(&state, drop) or rebuild_ui;
            }
        }

        if (ctx.lastGridDrop()) |drop| {
            asset_primary_handled = true;
            if (state.rename_path != null) {
                switch (try commitActiveRename(&state)) {
                    .inactive => {},
                    .closed => rebuild_ui = true,
                    .blocked => rebuild_ui = true,
                }
            }
            if (state.rename_path == null) {
                rebuild_ui = try handleAssetGridDrop(&state, drop) or rebuild_ui;
            }
        }

        for (state.place_handles.items, 0..) |handle, index| {
            if (!ctx.wasClicked(handle)) continue;
            if (index >= state.places.items.len) continue;
            rebuild_ui = try setCurrentDirectory(&state, state.places.items[index].path, true) or rebuild_ui;
            break;
        }

        for (state.folder_tree_handles.items, 0..) |handle, index| {
            if (!ctx.treeItemToggled(handle)) continue;
            if (index >= state.folder_tree_paths.items.len) continue;
            const path = state.folder_tree_paths.items[index];
            const previous_expansion = folderTreeExpansion(&state, path);
            if (previous_expansion == .partial) {
                rebuild_ui = try setFolderTreePathExpanded(&state, path, true) or rebuild_ui;
            } else {
                const expanded = ctx.isExpanded(handle);
                rebuild_ui = try setFolderTreePathExpanded(&state, path, expanded) or rebuild_ui;
                if (!expanded and std.mem.eql(u8, path, state.current_dir)) rebuild_ui = true;
            }
        }

        for (state.folder_tree_handles.items, 0..) |handle, index| {
            if (!ctx.wasClicked(handle) or ctx.treeItemToggled(handle)) continue;
            if (index >= state.folder_tree_paths.items.len) continue;
            rebuild_ui = try setCurrentDirectory(&state, state.folder_tree_paths.items[index], true) or rebuild_ui;
            break;
        }

        for (state.breadcrumb_handles.items, 0..) |handle, index| {
            if (!ctx.wasClicked(handle)) continue;
            if (index >= state.breadcrumb_paths.items.len) continue;
            rebuild_ui = try setCurrentDirectory(&state, state.breadcrumb_paths.items[index], true) or rebuild_ui;
            break;
        }

        for (state.row_handles.items, 0..) |handle, index| {
            if (!ctx.wasClicked(handle)) continue;
            asset_primary_handled = true;
            var entry_index = state.asset_visible_start + index;
            if (entry_index >= state.entries.items.len) continue;

            const entry = state.entries.items[entry_index];
            if (!state.ctrl_down and !state.shift_down and isPathSelected(&state, entry.path) and
                pointHitsEntryNameText(&state, &ctx, index, entry, state.primary_release_x, state.primary_release_y))
            {
                try beginRenameEntry(&state, &ctx, entry);
                rebuild_ui = true;
                break;
            }

            const clicked_path = try allocator.dupe(u8, entry.path);
            defer allocator.free(clicked_path);
            if (state.rename_path != null) {
                switch (try commitActiveRename(&state)) {
                    .inactive => {},
                    .closed => {
                        rebuild_ui = true;
                        entry_index = entryIndexForPath(&state, clicked_path) orelse break;
                    },
                    .blocked => {
                        rebuild_ui = true;
                        break;
                    },
                }
            }

            const selected_entry = state.entries.items[entry_index];
            const click_ms = currentPrimaryClickTimestampMs(&ctx, init.io);
            const repeated_click = isRepeatedEntryClick(&state, &selected_entry, click_ms);

            try applyEntrySelectionClick(&state, entry_index);
            try setLastClickPath(&state, selected_entry.path);
            state.last_click_ms = click_ms;
            rebuild_ui = true;

            if (repeated_click and selected_entry.canEnter()) {
                rebuild_ui = try setCurrentDirectory(&state, selected_entry.navigationPath(), true) or rebuild_ui;
            }
            break;
        }

        for (state.grid_handles.items, 0..) |handle, index| {
            if (!ctx.wasClicked(handle)) continue;
            asset_primary_handled = true;
            var entry_index = state.asset_visible_start + index;
            if (entry_index >= state.entries.items.len) continue;

            const entry = state.entries.items[entry_index];
            const clicked_path = try allocator.dupe(u8, entry.path);
            defer allocator.free(clicked_path);
            if (state.rename_path != null) {
                switch (try commitActiveRename(&state)) {
                    .inactive => {},
                    .closed => {
                        rebuild_ui = true;
                        entry_index = entryIndexForPath(&state, clicked_path) orelse break;
                    },
                    .blocked => {
                        rebuild_ui = true;
                        break;
                    },
                }
            }

            const selected_entry = state.entries.items[entry_index];
            const click_ms = currentPrimaryClickTimestampMs(&ctx, init.io);
            const repeated_click = isRepeatedEntryClick(&state, &selected_entry, click_ms);

            try applyEntrySelectionClick(&state, entry_index);
            try setLastClickPath(&state, selected_entry.path);
            state.last_click_ms = click_ms;
            rebuild_ui = true;

            if (repeated_click and selected_entry.canEnter()) {
                rebuild_ui = try setCurrentDirectory(&state, selected_entry.navigationPath(), true) or rebuild_ui;
            }
            break;
        }

        if (!asset_primary_handled) {
            var selection_widget_changed = false;
            const selection_drag_active = ctx.runtime.mouse.left_down;
            if (state.view_mode == .list) {
                if (state.asset_table_body) |table| {
                    if (ctx.isAlive(table) and ctx.tableSelectionChanged(table)) {
                        selection_widget_changed = true;
                        if (state.rename_path != null) {
                            switch (try commitActiveRename(&state)) {
                                .inactive => {},
                                .closed => rebuild_ui = true,
                                .blocked => {
                                    rebuild_ui = true;
                                    selection_widget_changed = false;
                                },
                            }
                        }
                        if (selection_widget_changed) {
                            try syncSelectedPathsFromTable(&state, &ctx, table);
                            if (selection_drag_active) {
                                state.asset_selection_rebuild_pending = true;
                            } else {
                                rebuild_ui = true;
                            }
                        }
                    }
                }
            } else if (state.view_mode == .grid) {
                if (state.asset_grid) |grid| {
                    if (ctx.isAlive(grid) and ctx.gridSelectorChanged(grid)) {
                        selection_widget_changed = true;
                        if (state.rename_path != null) {
                            switch (try commitActiveRename(&state)) {
                                .inactive => {},
                                .closed => rebuild_ui = true,
                                .blocked => {
                                    rebuild_ui = true;
                                    selection_widget_changed = false;
                                },
                            }
                        }
                        if (selection_widget_changed) {
                            try syncSelectedPathsFromGrid(&state, &ctx, grid);
                            if (selection_drag_active) {
                                state.asset_selection_rebuild_pending = true;
                            } else {
                                rebuild_ui = true;
                            }
                        }
                    }
                }
            }
            if (selection_widget_changed) asset_primary_handled = true;
        }

        if (!ctx.runtime.mouse.left_down and state.asset_selection_rebuild_pending) {
            state.asset_selection_rebuild_pending = false;
            rebuild_ui = true;
        }

        if (state.primary_release_pending) {
            defer state.primary_release_pending = false;
            if (!asset_primary_handled and pointInFilePanelBlankSpace(&state, &ctx, state.primary_release_x, state.primary_release_y)) {
                var rename_blocks_deselect = false;
                if (state.rename_path != null) {
                    switch (try commitActiveRename(&state)) {
                        .inactive => {},
                        .closed => rebuild_ui = true,
                        .blocked => {
                            rebuild_ui = true;
                            rename_blocks_deselect = true;
                        },
                    }
                }
                if (!rename_blocks_deselect) {
                    rebuild_ui = clearSelectionState(&state) or rebuild_ui;
                }
            }
        }

        if (rebuild_ui) {
            try buildWidgetTree(&state);
        }

        // Render
        // Event handlers can rebuild the widget tree after the initial hit-test
        // layout pass above, so run layout again if the tree became dirty.
        ctx.doLayout(&text_measure_ctx);
        if (try refreshAssetViewportIfNeeded(&state)) {
            ctx.doLayout(&text_measure_ctx);
        }
        debugLogFilePanelLayout(&state);
        updatePointerCursor(&state);
        var atlas_paint_list = try goop.draw.generatePaint(&ctx.tree, ctx.theme, allocator, state.text_measure_ctx);
        defer goop.draw.freePaintList(&atlas_paint_list, allocator);
        if (try ensureAtlasForPaintList(&text_atlas, &renderer, atlas_paint_list)) {
            const updated_metrics = fontLineMetrics(&text_atlas);
            text_measure.ascent_units = updated_metrics.ascent;
            text_measure.descent_units = updated_metrics.descent;
            ctx.setDimensions(state.logical_width, state.logical_height);
            ctx.doLayout(&text_measure_ctx);
        }
        try syncNativePopupSurfaces(&state, &ctx);
        var base_paint_list = try goop.draw.generatePaintWithoutFloating(&ctx.tree, ctx.theme, allocator, state.text_measure_ctx);
        defer goop.draw.freePaintList(&base_paint_list, allocator);
        const paint_list = try composeFileBrowserPaintList(&state, base_paint_list);

        renderer.beginFrame(state.buffer_width, state.buffer_height, @floatFromInt(state.buffer_scale));
        renderer.renderPaintList(paint_list);

        // Request frame callback BEFORE swap — the callback must be
        // registered before the surface commit that eglSwapBuffers triggers.
        requestFrame(&state);
        _ = egl.eglSwapBuffers(state.egl_display, state.egl_surface);
        try renderNativePopupSurfaces(&state, &renderer);
    }

    // Clean up xkb state
    state.destroyAllPopupSurfaces();
    state.destroyAllDataOffers();
    state.destroyAllOutputs();
    state.destroyDragSource();
    state.destroyClipboardSource();
    deinitBrowserState(&state);
    state.clipboard_buf.deinit(allocator);
    state.clipboard_uri_list_buf.deinit(allocator);
    state.clipboard_gnome_files_buf.deinit(allocator);
    state.drag_uri_list_buf.deinit(allocator);
    state.drag_plain_buf.deinit(allocator);
    state.drag_gnome_files_buf.deinit(allocator);
    if (state.data_device) |data_device| wl.wl_data_device_release(data_device);
    if (state.data_device_manager) |manager| wl.wl_data_device_manager_destroy(manager);
    state.resetCursorTheme();
    if (state.cursor_surface) |cursor_surface| wl.wl_surface_destroy(cursor_surface);
    if (state.shm) |shm| wl.wl_shm_destroy(shm);
    if (state.xkb_state) |s| xkb.xkb_state_unref(s);
    if (state.xkb_keymap) |k| xkb.xkb_keymap_unref(k);
    if (state.xkb_ctx) |c| xkb.xkb_context_unref(c);

    std.debug.print("goop file manager exiting\n", .{});
}
