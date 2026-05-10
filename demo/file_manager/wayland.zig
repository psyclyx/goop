const std = @import("std");
const goop = @import("goop");
const snail = @import("snail");
const render = @import("goop_demo_render");
const posix = std.posix;

const fm = @import("../file_manager_main.zig");
const wl = fm.wl;
const xkb = fm.xkb;
const egl = fm.egl;
const State = fm.State;
const allocator = fm.allocator;

// MIME constants for clipboard / DnD payloads.
pub const clipboard_mime_utf8 = "text/plain;charset=utf-8";
pub const clipboard_mime_utf8_string = "UTF8_STRING";
pub const clipboard_mime_text = "text/plain";
pub const dnd_mime_uri_list = "text/uri-list";
pub const dnd_mime_gnome_copied_files = "x-special/gnome-copied-files";

// ── Atlas / text measurement ──

/// Snail-based text measurement adapter for goop.
pub const SnailTextCtx = struct {
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

pub fn snailMeasureText(text: []const u8, font_size: f32, user_data: ?*anyopaque) goop.TextDimensions {
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

pub fn fontLineMetrics(text_atlas: *const snail.TextAtlas) struct { ascent: f32, descent: f32 } {
    const metrics = text_atlas.lineMetrics() catch {
        const units_per_em = text_atlas.unitsPerEm() catch 1000;
        return .{ .ascent = @floatFromInt(units_per_em), .descent = 0 };
    };
    return .{
        .ascent = @floatFromInt(metrics.ascent),
        .descent = @floatFromInt(@abs(metrics.descent)),
    };
}

pub fn isPrintableTextCodepoint(codepoint: u32) bool {
    if (codepoint > std.math.maxInt(u21)) return false;
    if (!std.unicode.utf8ValidCodepoint(@intCast(codepoint))) return false;
    if (codepoint < 0x20) return false;
    if (codepoint >= 0x7F and codepoint < 0xA0) return false;
    return true;
}

pub fn ensureAtlasForPaintList(ensured_text: *std.BufSet, text_atlas: *snail.TextAtlas, renderer: *render.Renderer, paint_list: goop.PaintList) !bool {
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

// ── Output / cursor / popup types ──

pub const OutputState = struct {
    global_name: u32,
    output: *wl.wl_output,
    scale: u32 = 1,
    entered: bool = false,
    next: ?*OutputState = null,
};

pub const CursorKind = enum {
    default,
    pointer,
    text,
    ew_resize,
    ns_resize,
};

pub const PopupSurface = struct {
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

pub const DataOfferState = struct {
    owner: *State,
    offer: *wl.wl_data_offer,
    next: ?*DataOfferState = null,
    offers_text_utf8: bool = false,
    offers_utf8_string: bool = false,
    offers_text_plain: bool = false,
    offers_uri_list: bool = false,
    offers_gnome_copied_files: bool = false,
};

pub const PopupParentInfo = struct {
    xdg_surface: *wl.xdg_surface,
    parent_popup: ?goop.NodeHandle,
    parent_origin_x: f32,
    parent_origin_y: f32,
    parent_width: f32,
    parent_height: f32,
    anchor_rect: goop.draw.Rect,
};

// ── MIME helpers ──

pub fn offerSupportsMime(mime: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, mime, expected);
}

pub fn preferredFileOfferMime(offer: *const DataOfferState) ?[*:0]const u8 {
    if (offer.offers_gnome_copied_files) return dnd_mime_gnome_copied_files;
    if (offer.offers_uri_list) return dnd_mime_uri_list;
    return null;
}

pub fn preferredTextOfferMime(offer: *const DataOfferState) ?[*:0]const u8 {
    if (offer.offers_text_utf8) return clipboard_mime_utf8;
    if (offer.offers_utf8_string) return clipboard_mime_utf8_string;
    if (offer.offers_text_plain) return clipboard_mime_text;
    return null;
}

pub fn appendFileUri(buffer: *std.ArrayListUnmanaged(u8), path: []const u8, line_end: []const u8) !void {
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

pub fn uriPathByteCanPass(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '/', '-', '.', '_', '~' => true,
        else => false,
    };
}

pub fn appendClipboardPathFromFileUri(paths: *std.ArrayListUnmanaged([]u8), line: []const u8) !void {
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

pub fn percentDecodeAlloc(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
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

pub fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

pub fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

pub fn writeAll(fd: posix.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const chunk = posix.system.write(fd, bytes[written..].ptr, bytes.len - written);
        if (chunk <= 0) return;
        written += @intCast(chunk);
    }
}

// ── Cursor handling ──

pub fn cursorNames(kind: CursorKind) []const [:0]const u8 {
    return switch (kind) {
        .default => &[_][:0]const u8{"left_ptr"},
        .pointer => &[_][:0]const u8{ "pointer", "hand2", "left_ptr" },
        .text => &[_][:0]const u8{ "text", "xterm", "left_ptr" },
        .ew_resize => &[_][:0]const u8{ "col-resize", "sb_h_double_arrow", "left_ptr" },
        .ns_resize => &[_][:0]const u8{ "row-resize", "sb_v_double_arrow", "left_ptr" },
    };
}

pub fn lookupCursor(state: *State, kind: CursorKind) ?*wl.wl_cursor {
    state.ensureCursorTheme();
    const theme = state.cursor_theme orelse return null;
    for (cursorNames(kind)) |name| {
        if (wl.wl_cursor_theme_get_cursor(theme, name.ptr)) |cursor| return cursor;
    }
    return null;
}

pub fn desiredCursorKind(state: *State) CursorKind {
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

pub fn applyCursorKind(state: *State, kind: CursorKind) void {
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

pub fn updatePointerCursor(state: *State) void {
    const next = desiredCursorKind(state);
    if (next == state.cursor_kind and state.cursor_theme != null and state.cursor_theme_scale == state.buffer_scale) return;
    applyCursorKind(state, next);
}

// ── Wayland listeners ──

pub const registry_listener = wl.wl_registry_listener{
    .global = &registryGlobal,
    .global_remove = &registryGlobalRemove,
};

pub fn registryGlobal(data: ?*anyopaque, registry: ?*wl.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
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

pub fn registryGlobalRemove(data: ?*anyopaque, _: ?*wl.wl_registry, name: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.removeOutputByGlobalName(name);
}

pub const wm_base_listener = wl.xdg_wm_base_listener{
    .ping = &wmBasePing,
};

pub fn wmBasePing(_: ?*anyopaque, wm_base: ?*wl.xdg_wm_base, serial: u32) callconv(.c) void {
    wl.xdg_wm_base_pong(wm_base, serial);
}

pub const xdg_surface_listener = wl.xdg_surface_listener{
    .configure = &xdgSurfaceConfigure,
};

pub fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*wl.xdg_surface, serial: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    wl.xdg_surface_ack_configure(xdg_surface, serial);
    state.configured = true;
    state.needs_redraw = true;
}

pub const xdg_toplevel_listener = wl.xdg_toplevel_listener{
    .configure = &xdgToplevelConfigure,
    .close = &xdgToplevelClose,
    .configure_bounds = &noopConfigureBounds,
    .wm_capabilities = &noopWmCapabilities,
};

pub fn noopConfigureBounds(_: ?*anyopaque, _: ?*wl.xdg_toplevel, _: i32, _: i32) callconv(.c) void {}
pub fn noopWmCapabilities(_: ?*anyopaque, _: ?*wl.xdg_toplevel, _: ?*wl.wl_array) callconv(.c) void {}

pub fn xdgToplevelConfigure(data: ?*anyopaque, _: ?*wl.xdg_toplevel, width: i32, height: i32, _: ?[*]wl.wl_array) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    fm.scrollDebug(state, "xdg_toplevel.configure width={} height={}", .{ width, height });
    if (width > 0 and height > 0) {
        state.setLogicalSize(@intCast(width), @intCast(height));
    }
    state.needs_redraw = true;
}

pub fn xdgToplevelClose(data: ?*anyopaque, _: ?*wl.xdg_toplevel) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.running = false;
}

pub const popup_xdg_surface_listener = wl.xdg_surface_listener{
    .configure = &popupXdgSurfaceConfigure,
};

pub const xdg_popup_listener = wl.xdg_popup_listener{
    .configure = &xdgPopupConfigure,
    .popup_done = &xdgPopupDone,
    .repositioned = &xdgPopupRepositioned,
};

pub fn popupXdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*wl.xdg_surface, serial: u32) callconv(.c) void {
    const popup: *PopupSurface = @ptrCast(@alignCast(data));
    wl.xdg_surface_ack_configure(xdg_surface, serial);
    popup.configured = true;
    popup.owner.needs_redraw = true;
}

pub fn xdgPopupConfigure(data: ?*anyopaque, _: ?*wl.xdg_popup, _: i32, _: i32, width: i32, height: i32) callconv(.c) void {
    const popup: *PopupSurface = @ptrCast(@alignCast(data));
    if (width > 0 and height > 0) {
        popup.configured_width = @intCast(width);
        popup.configured_height = @intCast(height);
        resizePopupBuffer(popup.owner, popup, popup.configured_width, popup.configured_height);
    }
    popup.owner.needs_redraw = true;
}

pub fn xdgPopupDone(data: ?*anyopaque, _: ?*wl.xdg_popup) callconv(.c) void {
    const popup: *PopupSurface = @ptrCast(@alignCast(data));
    const state = popup.owner;
    if (state.ctx) |ctx| {
        if (ctx.isAlive(popup.handle) and ctx.tree.getConst(popup.handle).kind == .popup) {
            if (ctx.mutateKind(popup.handle)) |__k| {
                __k.popup.visible = false;
            }
            ctx.invalidate();
        }
    }
    state.destroyPopupSurface(popup);
    state.needs_redraw = true;
}

pub fn xdgPopupRepositioned(_: ?*anyopaque, _: ?*wl.xdg_popup, _: u32) callconv(.c) void {}

// ── Popup surface management ──

pub fn syncNativePopupSurfaces(state: *State, ctx: *goop.Context) !void {
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

pub fn popupNeedsNativeSurface(ctx: *const goop.Context, handle: goop.NodeHandle) bool {
    if (!ctx.isAlive(handle)) return false;
    const node = ctx.tree.getConst(handle);
    if (node.kind != .popup or !node.kind.popup.visible) return false;
    return node.layout_rect.w > 0 and node.layout_rect.h > 0;
}

pub fn popupParentInfo(state: *State, ctx: *goop.Context, popup_handle: goop.NodeHandle) ?PopupParentInfo {
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

pub fn ancestorPopupForOwner(tree: *const goop.Tree, owner: goop.NodeHandle) ?goop.NodeHandle {
    var current: ?goop.NodeHandle = owner;
    while (current) |handle| {
        const parent = tree.getConst(handle).parent orelse return null;
        if (tree.getConst(parent).kind == .popup) return parent;
        current = parent;
    }
    return null;
}

pub fn createNativePopupSurface(state: *State, ctx: *goop.Context, handle: goop.NodeHandle, parent_info: PopupParentInfo) !*PopupSurface {
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

pub fn setPopupPositionerPlacement(positioner: *wl.xdg_positioner, popup: goop.widget.WidgetKind.Popup) void {
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

pub fn popupConstraintAdjustment() u32 {
    return @as(u32, @intCast(wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X)) |
        @as(u32, @intCast(wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y)) |
        @as(u32, @intCast(wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X)) |
        @as(u32, @intCast(wl.XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y));
}

pub fn resizePopupBuffer(state: *State, popup: *PopupSurface, logical_width: u32, logical_height: u32) void {
    const buffer_width = logical_width * state.buffer_scale;
    const buffer_height = logical_height * state.buffer_scale;
    if (buffer_width == popup.buffer_width and buffer_height == popup.buffer_height) return;
    wl.wl_egl_window_resize(popup.egl_window, @intCast(buffer_width), @intCast(buffer_height), 0, 0);
    popup.buffer_width = buffer_width;
    popup.buffer_height = buffer_height;
}

pub fn renderNativePopupSurfaces(state: *State, renderer: *render.Renderer) !void {
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

// ── Pointer / output / surface helpers ──

pub fn rootPointerX(state: *const State, sx: wl.wl_fixed_t) f32 {
    return state.pointer_surface_offset_x + fixedToF32(sx);
}

pub fn rootPointerY(state: *const State, sy: wl.wl_fixed_t) f32 {
    return state.pointer_surface_offset_y + fixedToF32(sy);
}

pub fn ceilPositiveU32(value: f32) u32 {
    if (!std.math.isFinite(value) or value <= 1) return 1;
    return @intFromFloat(@ceil(value));
}

pub fn roundI32(value: f32) i32 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(@round(value));
}

pub fn optionalHandleChanged(a: ?goop.NodeHandle, b: ?goop.NodeHandle) bool {
    if (a == null and b == null) return false;
    if (a == null or b == null) return true;
    return !a.?.eql(b.?);
}

pub fn rectsNearlyEqual(a: goop.draw.Rect, b: goop.draw.Rect) bool {
    return nearlyEqual(a.x, b.x) and nearlyEqual(a.y, b.y) and nearlyEqual(a.w, b.w) and nearlyEqual(a.h, b.h);
}

pub fn nearlyEqual(a: f32, b: f32) bool {
    return @abs(a - b) < 0.5;
}

pub fn ensureDataDevice(state: *State, data: ?*anyopaque) void {
    if (state.data_device != null) return;
    if (state.data_device_manager == null or state.seat == null) return;
    state.data_device = wl.wl_data_device_manager_get_data_device(state.data_device_manager, state.seat);
    if (state.data_device) |device| {
        _ = wl.wl_data_device_add_listener(device, &data_device_listener, data);
    }
}

pub const output_listener = wl.wl_output_listener{
    .geometry = &noopOutputGeometry,
    .mode = &noopOutputMode,
    .done = &noopOutputDone,
    .scale = &outputScale,
    .name = &noopOutputName,
    .description = &noopOutputDescription,
};

pub fn noopOutputGeometry(_: ?*anyopaque, _: ?*wl.wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, _: i32) callconv(.c) void {}
pub fn noopOutputMode(_: ?*anyopaque, _: ?*wl.wl_output, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}
pub fn noopOutputDone(_: ?*anyopaque, _: ?*wl.wl_output) callconv(.c) void {}
pub fn noopOutputName(_: ?*anyopaque, _: ?*wl.wl_output, _: [*c]const u8) callconv(.c) void {}
pub fn noopOutputDescription(_: ?*anyopaque, _: ?*wl.wl_output, _: [*c]const u8) callconv(.c) void {}

pub fn outputScale(data: ?*anyopaque, output: ?*wl.wl_output, factor: i32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const wl_output = output orelse return;
    const entry = state.findOutput(wl_output) orelse return;
    entry.scale = @intCast(@max(factor, 1));
    if (entry.entered and state.surface_preferred_scale == null) state.updateBufferMetrics();
}

pub const surface_listener = wl.wl_surface_listener{
    .enter = &surfaceEnter,
    .leave = &surfaceLeave,
    .preferred_buffer_scale = &surfacePreferredBufferScale,
    .preferred_buffer_transform = &noopSurfacePreferredBufferTransform,
};

pub fn surfaceEnter(data: ?*anyopaque, _: ?*wl.wl_surface, output: ?*wl.wl_output) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const wl_output = output orelse return;
    if (state.findOutput(wl_output)) |entry| {
        if (!entry.entered) {
            entry.entered = true;
            if (state.surface_preferred_scale == null) state.updateBufferMetrics();
        }
    }
}

pub fn surfaceLeave(data: ?*anyopaque, _: ?*wl.wl_surface, output: ?*wl.wl_output) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const wl_output = output orelse return;
    if (state.findOutput(wl_output)) |entry| {
        if (entry.entered) {
            entry.entered = false;
            if (state.surface_preferred_scale == null) state.updateBufferMetrics();
        }
    }
}

pub fn surfacePreferredBufferScale(data: ?*anyopaque, _: ?*wl.wl_surface, factor: i32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.surface_preferred_scale = @intCast(@max(factor, 1));
    state.updateBufferMetrics();
}

pub fn noopSurfacePreferredBufferTransform(_: ?*anyopaque, _: ?*wl.wl_surface, _: u32) callconv(.c) void {}

pub const seat_listener = wl.wl_seat_listener{
    .capabilities = &seatCapabilities,
    .name = &seatName,
};

pub fn seatName(_: ?*anyopaque, _: ?*wl.wl_seat, _: [*c]const u8) callconv(.c) void {}

pub fn seatCapabilities(data: ?*anyopaque, seat: ?*wl.wl_seat, caps: u32) callconv(.c) void {
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

pub const data_offer_listener = wl.wl_data_offer_listener{
    .offer = &dataOfferOffer,
    .source_actions = &noopDataOfferSourceActions,
    .action = &noopDataOfferAction,
};

pub fn dataOfferOffer(data: ?*anyopaque, _: ?*wl.wl_data_offer, mime_type: [*c]const u8) callconv(.c) void {
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

pub fn noopDataOfferSourceActions(_: ?*anyopaque, _: ?*wl.wl_data_offer, _: u32) callconv(.c) void {}
pub fn noopDataOfferAction(_: ?*anyopaque, _: ?*wl.wl_data_offer, _: u32) callconv(.c) void {}

pub const data_source_listener = wl.wl_data_source_listener{
    .target = &noopDataSourceTarget,
    .send = &dataSourceSend,
    .cancelled = &dataSourceCancelled,
    .dnd_drop_performed = &noopDataSourceDropPerformed,
    .dnd_finished = &dataSourceFinished,
    .action = &noopDataSourceAction,
};

pub fn noopDataSourceTarget(_: ?*anyopaque, _: ?*wl.wl_data_source, _: [*c]const u8) callconv(.c) void {}
pub fn noopDataSourceDropPerformed(_: ?*anyopaque, _: ?*wl.wl_data_source) callconv(.c) void {}
pub fn dataSourceFinished(data: ?*anyopaque, source: ?*wl.wl_data_source) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const was_drag_source = state.drag_source == source;
    if (was_drag_source) {
        state.clearFinishedDragSource(source);
        if (state.ctx) |ctx| ctx.cancelPointerGesture();
        state.needs_redraw = true;
    }
    if (source) |finished_source| wl.wl_data_source_destroy(finished_source);
}
pub fn noopDataSourceAction(_: ?*anyopaque, _: ?*wl.wl_data_source, _: u32) callconv(.c) void {}

pub fn dataSourceSend(data: ?*anyopaque, source: ?*wl.wl_data_source, mime_type: [*c]const u8, fd: i32) callconv(.c) void {
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

pub fn dataSourceCancelled(data: ?*anyopaque, source: ?*wl.wl_data_source) callconv(.c) void {
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

pub const data_device_listener = wl.wl_data_device_listener{
    .data_offer = &dataDeviceDataOffer,
    .enter = &dataDeviceEnter,
    .leave = &dataDeviceLeave,
    .motion = &noopDataDeviceMotion,
    .drop = &noopDataDeviceDrop,
    .selection = &dataDeviceSelection,
};

pub fn dataDeviceDataOffer(data: ?*anyopaque, _: ?*wl.wl_data_device, offer: ?*wl.wl_data_offer) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const data_offer = offer orelse return;
    state.addDataOffer(data_offer) catch wl.wl_data_offer_destroy(data_offer);
}

pub fn dataDeviceEnter(data: ?*anyopaque, _: ?*wl.wl_data_device, _: u32, _: ?*wl.wl_surface, _: wl.wl_fixed_t, _: wl.wl_fixed_t, offer: ?*wl.wl_data_offer) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    if (state.drag_offer) |drag_offer| state.destroyDataOffer(drag_offer);
    if (offer) |drag_offer| {
        state.drag_offer = state.findDataOffer(drag_offer);
    }
}

pub fn dataDeviceLeave(data: ?*anyopaque, _: ?*wl.wl_data_device) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    if (state.drag_offer) |drag_offer| state.destroyDataOffer(drag_offer);
}

pub fn noopDataDeviceMotion(_: ?*anyopaque, _: ?*wl.wl_data_device, _: u32, _: wl.wl_fixed_t, _: wl.wl_fixed_t) callconv(.c) void {}
pub fn noopDataDeviceDrop(_: ?*anyopaque, _: ?*wl.wl_data_device) callconv(.c) void {}

pub fn dataDeviceSelection(data: ?*anyopaque, _: ?*wl.wl_data_device, offer: ?*wl.wl_data_offer) callconv(.c) void {
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

pub const pointer_listener = wl.wl_pointer_listener{
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

pub fn noopPointerFrame(_: ?*anyopaque, _: ?*wl.wl_pointer) callconv(.c) void {}
pub fn noopAxisSource(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32) callconv(.c) void {}
pub fn noopAxisStop(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32) callconv(.c) void {}
pub fn noopAxisDiscrete(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: i32) callconv(.c) void {}
pub fn noopAxisValue120(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: i32) callconv(.c) void {}
pub fn noopAxisRelDir(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32) callconv(.c) void {}

// ── Keyboard listener ──

pub const keyboard_listener = wl.wl_keyboard_listener{
    .keymap = &keymapHandler,
    .enter = &noopKeyboardEnter,
    .leave = &noopKeyboardLeave,
    .key = &keyboardKey,
    .modifiers = &modifiersHandler,
    .repeat_info = &noopRepeatInfo,
};

pub fn keymapHandler(data: ?*anyopaque, _: ?*wl.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
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

pub fn noopKeyboardEnter(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface, _: ?*wl.wl_array) callconv(.c) void {}
pub fn noopKeyboardLeave(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.left_ctrl_down = false;
    state.right_ctrl_down = false;
    state.left_shift_down = false;
    state.right_shift_down = false;
    state.ctrl_down = false;
    state.shift_down = false;
}

pub fn modifiersHandler(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    if (state.xkb_state) |s| {
        _ = xkb.xkb_state_update_mask(s, mods_depressed, mods_latched, mods_locked, 0, 0, group);
    }
}
pub fn noopRepeatInfo(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: i32, _: i32) callconv(.c) void {}

pub fn evdevToKeycode(scancode: u32) goop.Event.Keycode {
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

pub fn keyboardKey(data: ?*anyopaque, _: ?*wl.wl_keyboard, serial: u32, _: u32, key: u32, key_state: u32) callconv(.c) void {
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
        const focused_handle = ctx.focusedWidget();
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

pub fn pointerEnter(data: ?*anyopaque, _: ?*wl.wl_pointer, serial: u32, surface: ?*wl.wl_surface, sx: wl.wl_fixed_t, sy: wl.wl_fixed_t) callconv(.c) void {
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

pub fn pointerLeave(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: ?*wl.wl_surface) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    state.pointer_inside = false;
    state.cursor_kind = .default;
}

pub fn pointerMotion(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, sx: wl.wl_fixed_t, sy: wl.wl_fixed_t) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const x = rootPointerX(state, sx);
    const y = rootPointerY(state, sy);
    state.mouse_x = x;
    state.mouse_y = y;
    if (state.ctx) |ctx| ctx.pushEvent(.{ .mouse_move = .{ .x = x, .y = y } }) catch {};
    state.needs_redraw = true;
}

pub fn pointerButton(data: ?*anyopaque, _: ?*wl.wl_pointer, serial: u32, time_ms: u32, button: u32, btn_state: u32) callconv(.c) void {
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

pub fn pointerAxis(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, axis: u32, value: wl.wl_fixed_t) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    const v = fixedToF32(value);
    const dx: f32 = if (axis == 1) v else 0; // WL_POINTER_AXIS_HORIZONTAL_SCROLL
    const dy: f32 = if (axis == 0) v else 0; // WL_POINTER_AXIS_VERTICAL_SCROLL
    fm.scrollDebug(state, "input axis={} dx={d:.2} dy={d:.2} mouse=({d:.1},{d:.1})", .{
        axis,
        dx,
        dy,
        state.mouse_x,
        state.mouse_y,
    });
    if (state.ctx) |ctx| ctx.pushEvent(.{ .mouse_scroll = .{ .dx = dx, .dy = dy } }) catch {};
    state.needs_redraw = true;
}

pub fn fixedToF32(fixed: wl.wl_fixed_t) f32 {
    return @as(f32, @floatFromInt(fixed)) / 256.0;
}

// ── Frame callback ──

pub const frame_listener = wl.wl_callback_listener{
    .done = &frameDone,
};

pub fn frameDone(data: ?*anyopaque, callback: ?*wl.wl_callback, _: u32) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(data));
    wl.wl_callback_destroy(callback);
    state.frame_pending = false;
}

pub fn requestFrame(state: *State) void {
    if (state.frame_pending) return;
    const callback = wl.wl_surface_frame(state.surface) orelse return;
    _ = wl.wl_callback_add_listener(callback, &frame_listener, state);
    state.frame_pending = true;
}

// ── EGL setup ──

pub fn initEgl(state: *State, display: *wl.wl_display) !void {
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

pub fn deinitEgl(state: *State) void {
    _ = egl.eglMakeCurrent(state.egl_display, egl.EGL_NO_SURFACE, egl.EGL_NO_SURFACE, egl.EGL_NO_CONTEXT);
    if (state.egl_surface != egl.EGL_NO_SURFACE) _ = egl.eglDestroySurface(state.egl_display, state.egl_surface);
    if (state.egl_context != egl.EGL_NO_CONTEXT) _ = egl.eglDestroyContext(state.egl_display, state.egl_context);
    if (state.egl_window != null) wl.wl_egl_window_destroy(state.egl_window);
    if (state.egl_display != egl.EGL_NO_DISPLAY) _ = egl.eglTerminate(state.egl_display);
}
