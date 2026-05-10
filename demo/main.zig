const std = @import("std");
const goop = @import("goop");
const snail = @import("snail");
const render = @import("goop_demo_render");
const posix = std.posix;

const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-egl.h");
    @cInclude("xdg-shell-client-protocol.h");
});

const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

const egl = @cImport({
    @cInclude("EGL/egl.h");
});

const allocator = std.heap.smp_allocator;
const clipboard_mime_utf8 = "text/plain;charset=utf-8";

// Demo-side selection helpers built on top of the read-only WidgetView.
// goop intentionally does not provide these — embedders fold their own
// over the primitive child iterator.
fn countSelectedSelectables(ctx: *const goop.Context, parent: goop.NodeHandle) u16 {
    var count: u16 = 0;
    var iter = ctx.tree.children(parent);
    while (iter.next()) |child| {
        const v = ctx.widget(child) orelse continue;
        if (v == .selectable and v.selectable.selected) count += 1;
    }
    return count;
}

fn countSelectedGridItems(ctx: *const goop.Context, parent: goop.NodeHandle) u16 {
    var count: u16 = 0;
    var iter = ctx.tree.children(parent);
    while (iter.next()) |child| {
        const v = ctx.widget(child) orelse continue;
        if (v == .grid_item and v.grid_item.selected) count += 1;
    }
    return count;
}

fn countSelectedDataRows(ctx: *const goop.Context, parent: goop.NodeHandle) u16 {
    var count: u16 = 0;
    var iter = ctx.tree.children(parent);
    while (iter.next()) |child| {
        const v = ctx.widget(child) orelse continue;
        if (v == .table_row and !v.table_row.header and v.table_row.selected) count += 1;
    }
    return count;
}

fn firstSelectedDataRowIndex(ctx: *const goop.Context, parent: goop.NodeHandle) ?u16 {
    var index: u16 = 0;
    var iter = ctx.tree.children(parent);
    while (iter.next()) |child| {
        const v = ctx.widget(child) orelse continue;
        if (v != .table_row or v.table_row.header) continue;
        if (v.table_row.selected) return index;
        index += 1;
    }
    return null;
}
const clipboard_mime_utf8_string = "UTF8_STRING";
const clipboard_mime_text = "text/plain";

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

fn ensureAtlasForPaintList(ensured_text: *std.BufSet, text_atlas: *snail.TextAtlas, renderer: *render.Renderer, paint_list: goop.PaintList) !bool {
    var changed = false;
    for (paint_list.commands) |command| {
        if (command != .text) continue;
        const text = command.text.text;
        if (text.len == 0) continue;
        if (ensured_text.contains(text)) continue;

        if (try text_atlas.ensureText(.{}, text)) |next_atlas| {
            text_atlas.deinit();
            text_atlas.* = next_atlas;
            changed = true;
        }
        try ensured_text.insert(text);
    }

    if (changed) renderer.uploadAtlas(text_atlas);
    return changed;
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

    // Wayland globals
    display: ?*wl.wl_display = null,
    compositor: ?*wl.wl_compositor = null,
    wm_base: ?*wl.xdg_wm_base = null,
    seat: ?*wl.wl_seat = null,
    data_device_manager: ?*wl.wl_data_device_manager = null,
    outputs: ?*OutputState = null,

    // Wayland surface chain
    surface: ?*wl.wl_surface = null,
    xdg_surface: ?*wl.xdg_surface = null,
    xdg_toplevel: ?*wl.xdg_toplevel = null,
    egl_window: ?*wl.wl_egl_window = null,
    pointer: ?*wl.wl_pointer = null,
    keyboard: ?*wl.wl_keyboard = null,
    data_device: ?*wl.wl_data_device = null,
    clipboard_source: ?*wl.wl_data_source = null,
    selection_offer: ?*DataOfferState = null,
    drag_offer: ?*DataOfferState = null,
    data_offers: ?*DataOfferState = null,
    last_input_serial: u32 = 0,

    // EGL
    egl_display: egl.EGLDisplay = egl.EGL_NO_DISPLAY,
    egl_surface: egl.EGLSurface = egl.EGL_NO_SURFACE,
    egl_context: egl.EGLContext = egl.EGL_NO_CONTEXT,

    // goop
    ctx: ?*goop.Context = null,

    // Widget handles for querying state
    btn_a: ?goop.NodeHandle = null,
    btn_b: ?goop.NodeHandle = null,
    btn_c: ?goop.NodeHandle = null,
    checkbox: ?goop.NodeHandle = null,
    radio_a: ?goop.NodeHandle = null,
    radio_b: ?goop.NodeHandle = null,
    radio_c: ?goop.NodeHandle = null,
    tree_parent: ?goop.NodeHandle = null,
    tree_child_a: ?goop.NodeHandle = null,
    tree_child_b: ?goop.NodeHandle = null,
    list_box: ?goop.NodeHandle = null,
    selectable_scene: ?goop.NodeHandle = null,
    selectable_camera: ?goop.NodeHandle = null,
    selectable_light: ?goop.NodeHandle = null,
    grid_selector: ?goop.NodeHandle = null,
    grid_item_a: ?goop.NodeHandle = null,
    grid_item_b: ?goop.NodeHandle = null,
    grid_item_c: ?goop.NodeHandle = null,
    grid_item_d: ?goop.NodeHandle = null,
    asset_table: ?goop.NodeHandle = null,
    asset_row_a: ?goop.NodeHandle = null,
    asset_row_b: ?goop.NodeHandle = null,
    asset_row_c: ?goop.NodeHandle = null,
    dropdown: ?goop.NodeHandle = null,
    menu_file: ?goop.NodeHandle = null,
    menu_edit: ?goop.NodeHandle = null,
    menu_open_recent: ?goop.NodeHandle = null,
    menu_recent_a: ?goop.NodeHandle = null,
    menu_recent_b: ?goop.NodeHandle = null,
    menu_quit: ?goop.NodeHandle = null,
    menu_copy: ?goop.NodeHandle = null,
    menu_paste: ?goop.NodeHandle = null,
    drag_value: ?goop.NodeHandle = null,
    spinbox: ?goop.NodeHandle = null,
    tab_scene: ?goop.NodeHandle = null,
    tab_render: ?goop.NodeHandle = null,
    splitter: ?goop.NodeHandle = null,
    context_popup: ?goop.NodeHandle = null,
    context_action_a: ?goop.NodeHandle = null,
    context_action_b: ?goop.NodeHandle = null,
    click_count: u32 = 0,

    // Last known mouse position from Wayland pointer events
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,

    // xkbcommon state for keymap → text conversion
    xkb_ctx: ?*xkb.xkb_context = null,
    xkb_keymap: ?*xkb.xkb_keymap = null,
    xkb_state: ?*xkb.xkb_state = null,

    // Clipboard text for self-owned selections and the most recent external paste.
    clipboard_buf: std.ArrayListUnmanaged(u8) = .empty,

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
        self.fetchClipboardSelection() catch return null;
        if (self.clipboard_buf.items.len == 0) return null;
        return self.clipboard_buf.items;
    }

    fn clipboardSetText(ptr: *anyopaque, text: []const u8) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.setClipboardSelection(text) catch {};
    }

    fn setClipboardSelection(self: *State, text: []const u8) !void {
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

    fn fetchClipboardSelection(self: *State) !void {
        const offer = self.selection_offer orelse return;
        const mime = preferredOfferMime(offer) orelse return;

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
        self.logical_width = @max(width, 1);
        self.logical_height = @max(height, 1);
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
            if (self.egl_window) |window| {
                wl.wl_egl_window_resize(window, @intCast(self.buffer_width), @intCast(self.buffer_height), 0, 0);
            }
        }
        if (changed) self.needs_redraw = true;
    }
};

const DataOfferState = struct {
    owner: *State,
    offer: *wl.wl_data_offer,
    next: ?*DataOfferState = null,
    offers_text_utf8: bool = false,
    offers_utf8_string: bool = false,
    offers_text_plain: bool = false,
};

fn offerSupportsMime(mime: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, mime, expected);
}

fn preferredOfferMime(offer: *const DataOfferState) ?[*:0]const u8 {
    if (offer.offers_text_utf8) return clipboard_mime_utf8;
    if (offer.offers_utf8_string) return clipboard_mime_utf8_string;
    if (offer.offers_text_plain) return clipboard_mime_text;
    return null;
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
    } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        const xdg_wm_base_version: u32 = @intCast(wl.xdg_wm_base_interface.version);
        state.wm_base = @ptrCast(wl.wl_registry_bind(registry, name, &wl.xdg_wm_base_interface, @min(version, xdg_wm_base_version)));
        _ = wl.xdg_wm_base_add_listener(state.wm_base, &wm_base_listener, data);
    } else if (std.mem.eql(u8, iface, "wl_seat")) {
        state.seat = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_seat_interface, @min(version, 5)));
        _ = wl.wl_seat_add_listener(state.seat, &seat_listener, data);
        ensureDataDevice(state, data);
    } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
        state.data_device_manager = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_data_device_manager_interface, @min(version, 3)));
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
    if (width > 0 and height > 0) {
        state.setLogicalSize(@intCast(width), @intCast(height));
    }
    state.needs_redraw = true;
}

fn xdgToplevelClose(data: ?*anyopaque, _: ?*wl.xdg_toplevel) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.running = false;
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
    }
}

fn noopDataOfferSourceActions(_: ?*anyopaque, _: ?*wl.wl_data_offer, _: u32) callconv(.c) void {}
fn noopDataOfferAction(_: ?*anyopaque, _: ?*wl.wl_data_offer, _: u32) callconv(.c) void {}

const data_source_listener = wl.wl_data_source_listener{
    .target = &noopDataSourceTarget,
    .send = &dataSourceSend,
    .cancelled = &dataSourceCancelled,
    .dnd_drop_performed = &noopDataSourceDropPerformed,
    .dnd_finished = &noopDataSourceFinished,
    .action = &noopDataSourceAction,
};

fn noopDataSourceTarget(_: ?*anyopaque, _: ?*wl.wl_data_source, _: [*c]const u8) callconv(.c) void {}
fn noopDataSourceDropPerformed(_: ?*anyopaque, _: ?*wl.wl_data_source) callconv(.c) void {}
fn noopDataSourceFinished(_: ?*anyopaque, _: ?*wl.wl_data_source) callconv(.c) void {}
fn noopDataSourceAction(_: ?*anyopaque, _: ?*wl.wl_data_source, _: u32) callconv(.c) void {}

fn dataSourceSend(data: ?*anyopaque, _: ?*wl.wl_data_source, _: [*c]const u8, fd: i32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    defer closeFd(fd);
    if (state.clipboard_buf.items.len == 0) return;
    writeAll(fd, state.clipboard_buf.items);
}

fn dataSourceCancelled(data: ?*anyopaque, source: ?*wl.wl_data_source) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    if (state.clipboard_source == source) state.clipboard_source = null;
    if (source) |clipboard_source| wl.wl_data_source_destroy(clipboard_source);
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
fn noopKeyboardLeave(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface) callconv(.c) void {}

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
    ctx.pushEvent(.{ .key = .{
        .scancode = scancode,
        .keycode = evdevToKeycode(scancode),
        .state = goop_state,
    } }) catch {};

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

fn pointerEnter(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: ?*wl.wl_surface, sx: wl.wl_fixed_t, sy: wl.wl_fixed_t) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.mouse_x = fixedToF32(sx);
    state.mouse_y = fixedToF32(sy);
}

fn pointerLeave(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: ?*wl.wl_surface) callconv(.c) void {}

fn pointerMotion(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, sx: wl.wl_fixed_t, sy: wl.wl_fixed_t) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const x = fixedToF32(sx);
    const y = fixedToF32(sy);
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

    // Use last known mouse position from Wayland pointer events
    const mx = state.mouse_x;
    const my = state.mouse_y;
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

fn buildWidgetTree(state: *State) !void {
    const ctx = state.ctx.?;

    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });

    // Menu bar with a nested submenu.
    const menu_bar = try ctx.tree.addChild(root, .{ .menu_bar = .{} });
    state.menu_file = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "File" } });
    const file_popup = try ctx.tree.addChild(state.menu_file.?, .{ .popup = .{
        .placement = .below_start,
        .visible = false,
    } });
    state.menu_open_recent = try ctx.tree.addChild(file_popup, .{ .menu_item = .{ .label = "Open Recent" } });
    const recent_popup = try ctx.tree.addChild(state.menu_open_recent.?, .{ .popup = .{
        .placement = .right_start,
        .visible = false,
    } });
    state.menu_recent_a = try ctx.tree.addChild(recent_popup, .{ .menu_item = .{ .label = "shot_v014.blend" } });
    state.menu_recent_b = try ctx.tree.addChild(recent_popup, .{ .menu_item = .{ .label = "layout_blockout.blend" } });
    state.menu_quit = try ctx.tree.addChild(file_popup, .{ .menu_item = .{ .label = "Quit" } });

    state.menu_edit = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "Edit" } });
    const edit_popup = try ctx.tree.addChild(state.menu_edit.?, .{ .popup = .{
        .placement = .below_start,
        .visible = false,
    } });
    state.menu_copy = try ctx.tree.addChild(edit_popup, .{ .menu_item = .{ .label = "Copy" } });
    state.menu_paste = try ctx.tree.addChild(edit_popup, .{ .menu_item = .{ .label = "Paste" } });

    // Toolbar chrome with common actions.
    const toolbar = try ctx.tree.addChild(root, .{ .toolbar = .{} });
    _ = ctx.setStyle(toolbar, .{
        .bg = .{ .r = 36, .g = 36, .b = 36, .a = 255 },
        .border = .{ .r = 68, .g = 68, .b = 68, .a = 255 },
        .padding = goop.style.Edges.symmetric(8, 6),
        .border_radius = 0,
    });
    state.btn_a = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "Translate" } });
    state.btn_b = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "Rotate" } });
    state.btn_c = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "Scale" } });

    // Text label
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "goop demo - click the buttons" } });

    // Simple outline/tree
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Outline" } });
    state.tree_parent = try ctx.tree.addChild(root, .{ .tree_item = .{
        .label = "Scene",
        .group = 10,
        .selected = true,
        .editable = true,
        .rename_trigger = .selected_click,
    } });
    state.tree_child_a = try ctx.tree.addChild(state.tree_parent.?, .{ .tree_item = .{
        .label = "Camera",
        .group = 10,
        .editable = true,
        .rename_trigger = .selected_click,
    } });
    state.tree_child_b = try ctx.tree.addChild(state.tree_parent.?, .{ .tree_item = .{
        .label = "Directional Light",
        .group = 10,
        .editable = true,
        .rename_trigger = .selected_click,
    } });
    const outline_tooltip = try ctx.tree.addChild(state.tree_parent.?, .{ .tooltip = .{
        .placement = .below_start,
        .y = 4,
    } });
    _ = try ctx.tree.addChild(outline_tooltip, .{ .text = .{ .content = "Click again while selected to rename." } });

    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "List Box" } });
    state.list_box = try ctx.tree.addChild(root, .{ .list_box = .{ .selection_mode = .multiple } });
    state.selectable_scene = try ctx.tree.addChild(state.list_box.?, .{ .selectable = .{
        .label = "Scene Collection",
        .selected = true,
    } });
    state.selectable_camera = try ctx.tree.addChild(state.list_box.?, .{ .selectable = .{
        .label = "Camera Rig",
    } });
    state.selectable_light = try ctx.tree.addChild(state.list_box.?, .{ .selectable = .{
        .label = "Lighting Set",
    } });

    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Grid Selector" } });
    state.grid_selector = try ctx.tree.addChild(root, .{ .grid_selector = .{
        .selection_mode = .multiple,
        .item_width = 104,
        .item_height = 96,
        .column_gap = 8,
        .row_gap = 8,
    } });
    state.grid_item_a = try ctx.tree.addChild(state.grid_selector.?, .{ .grid_item = .{
        .label = "Brick",
        .selected = true,
    } });
    state.grid_item_b = try ctx.tree.addChild(state.grid_selector.?, .{ .grid_item = .{
        .label = "Metal",
    } });
    state.grid_item_c = try ctx.tree.addChild(state.grid_selector.?, .{ .grid_item = .{
        .label = "Leaves",
    } });
    state.grid_item_d = try ctx.tree.addChild(state.grid_selector.?, .{ .grid_item = .{
        .label = "UI Icons",
    } });

    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Asset Table" } });
    state.asset_table = try ctx.tree.addChild(root, .{ .table = .{
        .columns = 3,
        .resizable = true,
        .sortable = true,
        .selection_mode = .multiple,
        .min_column_width = 96,
    } });
    {
        const table = &ctx.mutateKind(state.asset_table.?).?.table;
        table.column_weights[0] = 0.56;
        table.column_weights[1] = 0.24;
        table.column_weights[2] = 0.20;
    }
    const asset_header = try ctx.tree.addChild(state.asset_table.?, .{ .table_row = .{ .header = true } });
    const asset_header_name = try ctx.tree.addChild(asset_header, .{ .table_cell = .{} });
    const asset_header_type = try ctx.tree.addChild(asset_header, .{ .table_cell = .{} });
    const asset_header_vis = try ctx.tree.addChild(asset_header, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(asset_header_name, .{ .text = .{ .content = "Name" } });
    _ = try ctx.tree.addChild(asset_header_type, .{ .text = .{ .content = "Type" } });
    _ = try ctx.tree.addChild(asset_header_vis, .{ .text = .{ .content = "Visible" } });

    state.asset_row_a = try ctx.tree.addChild(state.asset_table.?, .{ .table_row = .{ .selected = true } });
    const asset_row_a_name = try ctx.tree.addChild(state.asset_row_a.?, .{ .table_cell = .{} });
    const asset_row_a_type = try ctx.tree.addChild(state.asset_row_a.?, .{ .table_cell = .{} });
    const asset_row_a_vis = try ctx.tree.addChild(state.asset_row_a.?, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(asset_row_a_name, .{ .text = .{ .content = "SceneRoot" } });
    _ = try ctx.tree.addChild(asset_row_a_type, .{ .text = .{ .content = "Collection" } });
    _ = try ctx.tree.addChild(asset_row_a_vis, .{ .text = .{ .content = "Yes" } });

    state.asset_row_b = try ctx.tree.addChild(state.asset_table.?, .{ .table_row = .{} });
    const asset_row_b_name = try ctx.tree.addChild(state.asset_row_b.?, .{ .table_cell = .{} });
    const asset_row_b_type = try ctx.tree.addChild(state.asset_row_b.?, .{ .table_cell = .{} });
    const asset_row_b_vis = try ctx.tree.addChild(state.asset_row_b.?, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(asset_row_b_name, .{ .text = .{ .content = "CameraRig" } });
    _ = try ctx.tree.addChild(asset_row_b_type, .{ .text = .{ .content = "Object" } });
    _ = try ctx.tree.addChild(asset_row_b_vis, .{ .text = .{ .content = "Yes" } });

    state.asset_row_c = try ctx.tree.addChild(state.asset_table.?, .{ .table_row = .{} });
    const asset_row_c_name = try ctx.tree.addChild(state.asset_row_c.?, .{ .table_cell = .{} });
    const asset_row_c_type = try ctx.tree.addChild(state.asset_row_c.?, .{ .table_cell = .{} });
    const asset_row_c_vis = try ctx.tree.addChild(state.asset_row_c.?, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(asset_row_c_name, .{ .text = .{ .content = "KeyLight" } });
    _ = try ctx.tree.addChild(asset_row_c_type, .{ .text = .{ .content = "Light" } });
    _ = try ctx.tree.addChild(asset_row_c_vis, .{ .text = .{ .content = "No" } });

    // Dropdown composed from a header + popup menu
    state.dropdown = try ctx.tree.addChild(root, .{ .dropdown = .{ .placeholder = "Viewport mode" } });
    const dropdown_popup = try ctx.tree.addChild(state.dropdown.?, .{ .popup = .{ .placement = .below_start } });
    _ = try ctx.tree.addChild(dropdown_popup, .{ .menu_item = .{ .label = "Solid" } });
    _ = try ctx.tree.addChild(dropdown_popup, .{ .menu_item = .{ .label = "Wireframe" } });
    _ = try ctx.tree.addChild(dropdown_popup, .{ .menu_item = .{ .label = "Material Preview" } });

    // Numeric editing widgets
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Numbers" } });
    const exposure_row = try ctx.tree.addChild(root, .{ .container = .{ .direction = .row } });
    _ = try ctx.tree.addChild(exposure_row, .{ .text = .{ .content = "Exposure" } });
    state.drag_value = try ctx.tree.addChild(exposure_row, .{ .drag_value = .{
        .value = 1.25,
        .min = -4,
        .max = 8,
        .speed = 0.02,
        .precision = 2,
    } });
    const samples_row = try ctx.tree.addChild(root, .{ .container = .{ .direction = .row } });
    _ = try ctx.tree.addChild(samples_row, .{ .text = .{ .content = "Samples" } });
    state.spinbox = try ctx.tree.addChild(samples_row, .{ .spinbox = .{
        .value = 64,
        .min = 1,
        .max = 512,
        .step = 1,
        .precision = 0,
    } });

    // Tabbed container
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Editor Tabs" } });
    const tab_bar = try ctx.tree.addChild(root, .{ .tab_bar = .{} });
    state.tab_scene = try ctx.tree.addChild(tab_bar, .{ .tab_item = .{
        .label = "Scene",
        .selected = true,
    } });
    _ = try ctx.tree.addChild(state.tab_scene.?, .{ .text = .{ .content = "Scene tools: hierarchy, transforms, visibility." } });
    state.tab_render = try ctx.tree.addChild(tab_bar, .{ .tab_item = .{
        .label = "Render",
    } });
    _ = try ctx.tree.addChild(state.tab_render.?, .{ .text = .{ .content = "Render settings: samples, output, color management." } });

    // Checkbox
    state.checkbox = try ctx.tree.addChild(root, .{ .checkbox = .{ .label = "Enable option" } });

    // Radio buttons
    state.radio_a = try ctx.tree.addChild(root, .{ .radio_button = .{ .label = "Option A", .group = 1, .selected = true } });
    state.radio_b = try ctx.tree.addChild(root, .{ .radio_button = .{ .label = "Option B", .group = 1 } });
    state.radio_c = try ctx.tree.addChild(root, .{ .radio_button = .{ .label = "Option C", .group = 1 } });

    // Text input
    _ = try ctx.tree.addChild(root, .{ .text_input = .{ .placeholder = "Type here..." } });

    // Slider
    _ = try ctx.tree.addChild(root, .{ .slider = .{ .value = 0.5, .min = 0, .max = 1 } });

    // Split view for editor-style panes.
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Split View" } });
    state.splitter = try ctx.tree.addChild(root, .{ .splitter = .{
        .direction = .row,
        .ratio = 0.56,
        .min_first = 150,
        .min_second = 140,
        .thickness = 8,
    } });
    const inspector = try ctx.tree.addChild(state.splitter.?, .{ .container = .{ .direction = .column } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Inspector" } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Transform" } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Location  0.00  1.50  6.20" } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Rotation  0.00  0.00  0.00" } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Scale     1.00  1.00  1.00" } });

    const viewport = try ctx.tree.addChild(state.splitter.?, .{ .container = .{ .direction = .column } });
    _ = try ctx.tree.addChild(viewport, .{ .text = .{ .content = "Viewport Notes" } });
    const scroll = try ctx.tree.addChild(viewport, .{ .scroll_area = .{} });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 1" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 2" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 3" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 4" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 5" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 6" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 7" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 8" } });

    const status_bar = try ctx.tree.addChild(root, .{ .status_bar = .{} });
    _ = ctx.setStyle(status_bar, .{
        .bg = .{ .r = 34, .g = 34, .b = 34, .a = 255 },
        .border = .{ .r = 68, .g = 68, .b = 68, .a = 255 },
        .padding = goop.style.Edges.symmetric(8, 5),
        .border_radius = 0,
    });
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = "Scene: 3 items" } });
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = "Render: Preview" } });
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = "Status: Ready" } });

    // Context menu popup. The demo opens it on secondary click, but callers
    // can instead use ctx.lastSecondaryClick() to trigger a native popup.
    state.context_popup = try ctx.tree.addRoot(.{ .popup = .{ .placement = .absolute, .visible = false } });
    state.context_action_a = try ctx.tree.addChild(state.context_popup.?, .{ .menu_item = .{ .label = "Rename" } });
    state.context_action_b = try ctx.tree.addChild(state.context_popup.?, .{ .menu_item = .{ .label = "Delete" } });
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
    state.timeout_ns = parseTimeout(init.environ_map);
    if (state.timeout_ns) |t| {
        std.debug.print("demo will exit after {d:.1}s\n", .{@as(f64, @floatFromInt(t)) / std.time.ns_per_s});
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
    wl.xdg_toplevel_set_title(state.xdg_toplevel, "goop demo");
    wl.xdg_toplevel_set_app_id(state.xdg_toplevel, "goop-demo");
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
    var ensured_text = std.BufSet.init(allocator);
    defer ensured_text.deinit();

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

    // goop context + widget tree
    var ctx = try goop.Context.init(allocator, .{ .width = state.logical_width, .height = state.logical_height });
    defer ctx.deinit();
    state.ctx = &ctx;
    ctx.clipboard = state.clipboard();
    try buildWidgetTree(&state);

    // GL renderer (with snail text support)
    var renderer = try render.Renderer.init(state.buffer_width, state.buffer_height, &text_atlas);
    defer renderer.deinit();

    std.debug.print("goop demo running (logical {}x{}, scale {}, buffer {}x{})\n", .{
        state.logical_width,
        state.logical_height,
        state.buffer_scale,
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

        // Dispatch events — use poll with timeout when --timeout is set
        if (state.timeout_ns != null) {
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

        if (ctx.lastSecondaryClick()) |click| {
            if (state.context_popup) |popup| {
                const popup_node = ctx.tree.get(popup);
                popup_node.kind.popup.x = click.x;
                popup_node.kind.popup.y = click.y;
                popup_node.kind.popup.visible = true;
                std.debug.print("Secondary click on widget {} at ({d:.1}, {d:.1})\n", .{
                    click.target.index,
                    click.x,
                    click.y,
                });
            }
        }

        // Check clicks
        if (state.btn_a) |h| if (ctx.wasClicked(h)) {
            state.click_count += 1;
            std.debug.print("Toolbar action: Translate (total: {})\n", .{state.click_count});
        };
        if (state.btn_b) |h| if (ctx.wasClicked(h)) {
            state.click_count += 1;
            std.debug.print("Toolbar action: Rotate (total: {})\n", .{state.click_count});
        };
        if (state.btn_c) |h| if (ctx.wasClicked(h)) {
            state.click_count += 1;
            std.debug.print("Toolbar action: Scale (total: {})\n", .{state.click_count});
        };

        // Log checkbox state changes (checkbox toggles itself on click)
        if (state.checkbox) |h| if (ctx.wasClicked(h)) {
            std.debug.print("Checkbox toggled: {}\n", .{ctx.widget(h).?.checkbox.checked});
        };

        // Log radio button selection
        if (state.radio_a) |h| if (ctx.wasClicked(h)) std.debug.print("Radio: Option A selected\n", .{});
        if (state.radio_b) |h| if (ctx.wasClicked(h)) std.debug.print("Radio: Option B selected\n", .{});
        if (state.radio_c) |h| if (ctx.wasClicked(h)) std.debug.print("Radio: Option C selected\n", .{});
        if (state.tree_parent) |h| {
            if (ctx.widget(h).?.tree_item.toggled) std.debug.print("Outline root expanded: {}\n", .{ctx.widget(h).?.tree_item.expanded});
            if (ctx.wasClicked(h)) std.debug.print("Outline selected: Scene\n", .{});
            if (ctx.widget(h).?.tree_item.rename_committed) std.debug.print("Outline renamed: {s}\n", .{ctx.widget(h).?.tree_item.label});
        }
        if (state.tree_child_a) |h| {
            if (ctx.wasClicked(h)) std.debug.print("Outline selected: Camera\n", .{});
            if (ctx.widget(h).?.tree_item.rename_committed) std.debug.print("Outline renamed: {s}\n", .{ctx.widget(h).?.tree_item.label});
        }
        if (state.tree_child_b) |h| {
            if (ctx.wasClicked(h)) std.debug.print("Outline selected: Directional Light\n", .{});
            if (ctx.widget(h).?.tree_item.rename_committed) std.debug.print("Outline renamed: {s}\n", .{ctx.widget(h).?.tree_item.label});
        }
        if (ctx.lastDrop()) |last| switch (last) {
            .tree => |drop| {
                const position_name = switch (drop.position) {
                    .before => "before",
                    .into => "into",
                    .after => "after",
                };
                std.debug.print("Outline drop: {s} -> {s} ({s})\n", .{
                    ctx.widget(drop.source).?.tree_item.label,
                    ctx.widget(drop.target).?.tree_item.label,
                    position_name,
                });
            },
            .grid => |drop| switch (drop.position) {
                .item => std.debug.print("Grid drop: {s} -> {s} (item)\n", .{
                    ctx.tree.getConst(drop.source).kind.grid_item.label,
                    ctx.tree.getConst(drop.target).kind.grid_item.label,
                }),
                .background => std.debug.print("Grid drop: {s} -> background\n", .{
                    ctx.tree.getConst(drop.source).kind.grid_item.label,
                }),
            },
            else => {},
        };
        if (state.list_box) |h| if (ctx.widget(h).?.list_box.changed) {
            std.debug.print("List box selection count: {}\n", .{countSelectedSelectables(&ctx, h)});
        };
        if (state.selectable_scene) |h| if (ctx.wasClicked(h)) std.debug.print("List row selected: Scene Collection\n", .{});
        if (state.selectable_camera) |h| if (ctx.wasClicked(h)) std.debug.print("List row selected: Camera Rig\n", .{});
        if (state.selectable_light) |h| if (ctx.wasClicked(h)) std.debug.print("List row selected: Lighting Set\n", .{});
        if (state.grid_selector) |h| if (ctx.widget(h).?.grid_selector.changed) {
            std.debug.print("Grid selection count: {}\n", .{countSelectedGridItems(&ctx, h)});
        };
        if (state.grid_item_a) |h| if (ctx.wasClicked(h)) std.debug.print("Grid tile selected: Brick\n", .{});
        if (state.grid_item_b) |h| if (ctx.wasClicked(h)) std.debug.print("Grid tile selected: Metal\n", .{});
        if (state.grid_item_c) |h| if (ctx.wasClicked(h)) std.debug.print("Grid tile selected: Leaves\n", .{});
        if (state.grid_item_d) |h| if (ctx.wasClicked(h)) std.debug.print("Grid tile selected: UI Icons\n", .{});
        if (state.asset_table) |h| if (ctx.widget(h).?.table.changed) {
            std.debug.print("Asset table divider {} resized: [{d:.2}, {d:.2}, {d:.2}]\n", .{
                ctx.widget(h).?.table.resized_column.?,
                ctx.tableColumnFraction(h, 0).?,
                ctx.tableColumnFraction(h, 1).?,
                ctx.tableColumnFraction(h, 2).?,
            });
        };
        if (state.asset_table) |h| if (ctx.widget(h).?.table.sort_changed) {
            const column_name = switch (ctx.widget(h).?.table.sorted_column.?) {
                0 => "Name",
                1 => "Type",
                2 => "Visible",
                else => "Unknown",
            };
            const direction_name = switch (ctx.widget(h).?.table.sort_direction) {
                .ascending => "ascending",
                .descending => "descending",
            };
            std.debug.print("Asset table sort: {s} {s}\n", .{ column_name, direction_name });
        };
        if (state.asset_table) |h| if (ctx.widget(h).?.table.selection_changed) {
            std.debug.print("Asset table selection count: {}, first row: {?}\n", .{
                countSelectedDataRows(&ctx, h),
                firstSelectedDataRowIndex(&ctx, h),
            });
        };
        if (state.asset_row_a) |h| if (ctx.wasClicked(h)) std.debug.print("Asset row clicked: SceneRoot\n", .{});
        if (state.asset_row_b) |h| if (ctx.wasClicked(h)) std.debug.print("Asset row clicked: CameraRig\n", .{});
        if (state.asset_row_c) |h| if (ctx.wasClicked(h)) std.debug.print("Asset row clicked: KeyLight\n", .{});
        if (state.dropdown) |h| if (ctx.widget(h).?.dropdown.changed) {
            std.debug.print("Dropdown selected: {s}\n", .{ctx.widget(h).?.dropdown.selected_text});
        };
        if (state.menu_file) |h| if (ctx.wasClicked(h)) std.debug.print("Menu toggled: File\n", .{});
        if (state.menu_edit) |h| if (ctx.wasClicked(h)) std.debug.print("Menu toggled: Edit\n", .{});
        if (state.menu_recent_a) |h| if (ctx.wasClicked(h)) std.debug.print("Recent file: shot_v014.blend\n", .{});
        if (state.menu_recent_b) |h| if (ctx.wasClicked(h)) std.debug.print("Recent file: layout_blockout.blend\n", .{});
        if (state.menu_quit) |h| if (ctx.wasClicked(h)) std.debug.print("Menu action: Quit\n", .{});
        if (state.menu_copy) |h| if (ctx.wasClicked(h)) std.debug.print("Menu action: Copy\n", .{});
        if (state.menu_paste) |h| if (ctx.wasClicked(h)) std.debug.print("Menu action: Paste\n", .{});
        if (state.drag_value) |h| if (ctx.widget(h).?.drag_value.changed) {
            std.debug.print("Exposure changed: {d:.2}\n", .{ctx.widget(h).?.drag_value.value});
        };
        if (state.spinbox) |h| if (ctx.widget(h).?.spinbox.changed) {
            std.debug.print("Samples changed: {d:.0}\n", .{ctx.widget(h).?.spinbox.value});
        };
        if (state.tab_scene) |h| if (ctx.wasClicked(h)) {
            std.debug.print("Tab selected: Scene\n", .{});
        };
        if (state.tab_render) |h| if (ctx.wasClicked(h)) {
            std.debug.print("Tab selected: Render\n", .{});
        };
        if (state.splitter) |h| if (ctx.widget(h).?.splitter.changed) {
            std.debug.print("Splitter ratio: {d:.2}\n", .{ctx.widget(h).?.splitter.ratio});
        };
        if (state.context_action_a) |h| if (ctx.wasClicked(h)) std.debug.print("Context action: Rename\n", .{});
        if (state.context_action_b) |h| if (ctx.wasClicked(h)) std.debug.print("Context action: Delete\n", .{});

        // Render
        var paint_list = try ctx.generatePaintList();
        if (try ensureAtlasForPaintList(&ensured_text, &text_atlas, &renderer, paint_list)) {
            const updated_metrics = fontLineMetrics(&text_atlas);
            text_measure.ascent_units = updated_metrics.ascent;
            text_measure.descent_units = updated_metrics.descent;
            ctx.setDimensions(state.logical_width, state.logical_height);
            ctx.doLayout(&text_measure_ctx);
            paint_list = try ctx.generatePaintList();
        }

        renderer.beginFrame(state.buffer_width, state.buffer_height, @floatFromInt(state.buffer_scale));
        renderer.renderPaintList(paint_list);

        // Request frame callback BEFORE swap — the callback must be
        // registered before the surface commit that eglSwapBuffers triggers.
        requestFrame(&state);
        _ = egl.eglSwapBuffers(state.egl_display, state.egl_surface);
    }

    // Clean up xkb state
    state.destroyAllDataOffers();
    state.destroyAllOutputs();
    state.destroyClipboardSource();
    state.clipboard_buf.deinit(allocator);
    if (state.data_device) |data_device| wl.wl_data_device_release(data_device);
    if (state.data_device_manager) |manager| wl.wl_data_device_manager_destroy(manager);
    if (state.xkb_state) |s| xkb.xkb_state_unref(s);
    if (state.xkb_keymap) |k| xkb.xkb_keymap_unref(k);
    if (state.xkb_ctx) |c| xkb.xkb_context_unref(c);

    std.debug.print("goop demo exiting\n", .{});
}
