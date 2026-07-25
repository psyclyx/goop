//! Wayland window and input ownership.
//!
//! This module deliberately knows nothing about UI trees, rendering, Vulkan, or
//! application state.  It translates Wayland callbacks into a small queue of
//! backend-neutral window/input events and exposes the two raw handles required
//! by a WSI bridge.

const std = @import("std");

pub const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("xkbcommon/xkbcommon.h");
});

pub const Error = error{
    ConnectionFailed,
    RegistryFailed,
    MissingCompositor,
    MissingShell,
    SurfaceCreationFailed,
    ShellSurfaceCreationFailed,
    ToplevelCreationFailed,
    DispatchFailed,
    FlushFailed,
};

pub const ButtonState = enum {
    released,
    pressed,
};

pub const KeyState = enum {
    released,
    pressed,
};

pub const Axis = enum {
    horizontal,
    vertical,
};

pub const Modifiers = packed struct {
    control: bool = false,
    shift: bool = false,
    alt: bool = false,
    logo: bool = false,
};

pub const Size = struct {
    width: u32,
    height: u32,
};

pub const PointerPosition = struct {
    x: f64,
    y: f64,
};

pub const PointerButton = struct {
    serial: u32,
    time_ms: u32,
    button: u32,
    state: ButtonState,
    position: PointerPosition,
};

pub const Scroll = struct {
    time_ms: u32,
    axis: Axis,
    delta: f64,
    position: PointerPosition,
};

pub const Key = struct {
    serial: u32,
    time_ms: u32,
    /// Linux evdev code, exactly as delivered by Wayland.
    scancode: u32,
    state: KeyState,
    modifiers: Modifiers,
    /// A Unicode scalar when xkbcommon can translate this key press.
    codepoint: ?u21,
};

pub const Event = union(enum) {
    close,
    configured: Size,
    resized: Size,
    frame_ready,
    pointer_enter: PointerPosition,
    pointer_leave,
    pointer_motion: PointerPosition,
    pointer_button: PointerButton,
    scroll: Scroll,
    key: Key,
    keyboard_leave,
};

pub const Options = struct {
    width: u32 = 1280,
    height: u32 = 720,
    title: [*:0]const u8 = "goop",
    application_id: [*:0]const u8 = "dev.goop.application",
};

pub const WsiHandles = struct {
    display: *wl.wl_display,
    surface: *wl.wl_surface,
};

const EventQueue = struct {
    const capacity = 128;

    items: [capacity]Event = undefined,
    head: usize = 0,
    len: usize = 0,
    overflowed: bool = false,

    fn push(self: *EventQueue, event: Event) void {
        if (self.len == capacity) {
            self.overflowed = true;
            return;
        }
        self.items[(self.head + self.len) % capacity] = event;
        self.len += 1;
    }

    fn pop(self: *EventQueue) ?Event {
        if (self.len == 0) return null;
        const event = self.items[self.head];
        self.head = (self.head + 1) % capacity;
        self.len -= 1;
        return event;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    display: *wl.wl_display,
    registry: *wl.wl_registry,
    compositor: ?*wl.wl_compositor = null,
    wm_base: ?*wl.xdg_wm_base = null,
    surface: ?*wl.wl_surface = null,
    xdg_surface: ?*wl.xdg_surface = null,
    toplevel: ?*wl.xdg_toplevel = null,
    seat: ?*wl.wl_seat = null,
    pointer: ?*wl.wl_pointer = null,
    keyboard: ?*wl.wl_keyboard = null,
    frame_callback: ?*wl.wl_callback = null,
    xkb_context: ?*wl.xkb_context = null,
    xkb_keymap: ?*wl.xkb_keymap = null,
    xkb_state: ?*wl.xkb_state = null,
    size: Size,
    pending_size: Size,
    pointer_position: PointerPosition = .{ .x = 0, .y = 0 },
    modifiers: Modifiers = .{},
    queue: EventQueue = .{},
};

/// A small owning handle whose callback state remains heap-stable.
pub const Window = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator, options: Options) (Error || std.mem.Allocator.Error)!Window {
        const display = wl.wl_display_connect(null) orelse return error.ConnectionFailed;
        errdefer wl.wl_display_disconnect(display);

        const registry = wl.wl_display_get_registry(display) orelse return error.RegistryFailed;
        errdefer wl.wl_registry_destroy(registry);

        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{
            .allocator = allocator,
            .display = display,
            .registry = registry,
            .size = .{ .width = options.width, .height = options.height },
            .pending_size = .{ .width = options.width, .height = options.height },
        };

        _ = wl.wl_registry_add_listener(registry, &registry_listener, state);
        if (wl.wl_display_roundtrip(display) < 0) return error.DispatchFailed;

        const compositor = state.compositor orelse return error.MissingCompositor;
        const wm_base = state.wm_base orelse return error.MissingShell;
        const surface = wl.wl_compositor_create_surface(compositor) orelse
            return error.SurfaceCreationFailed;
        state.surface = surface;
        errdefer {
            wl.wl_surface_destroy(surface);
            state.surface = null;
        }

        const xdg_surface = wl.xdg_wm_base_get_xdg_surface(wm_base, surface) orelse
            return error.ShellSurfaceCreationFailed;
        state.xdg_surface = xdg_surface;
        errdefer {
            wl.xdg_surface_destroy(xdg_surface);
            state.xdg_surface = null;
        }
        _ = wl.xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, state);

        const toplevel = wl.xdg_surface_get_toplevel(xdg_surface) orelse
            return error.ToplevelCreationFailed;
        state.toplevel = toplevel;
        errdefer {
            wl.xdg_toplevel_destroy(toplevel);
            state.toplevel = null;
        }
        _ = wl.xdg_toplevel_add_listener(toplevel, &toplevel_listener, state);
        wl.xdg_toplevel_set_title(toplevel, options.title);
        wl.xdg_toplevel_set_app_id(toplevel, options.application_id);

        // The empty initial commit asks the compositor for the first configure.
        wl.wl_surface_commit(surface);
        return .{ .state = state };
    }

    pub fn deinit(self: *Window) void {
        const state = self.state;
        if (state.frame_callback) |callback| wl.wl_callback_destroy(callback);
        if (state.xkb_state) |xkb_state| wl.xkb_state_unref(xkb_state);
        if (state.xkb_keymap) |keymap| wl.xkb_keymap_unref(keymap);
        if (state.xkb_context) |context| wl.xkb_context_unref(context);
        if (state.keyboard) |keyboard| wl.wl_keyboard_destroy(keyboard);
        if (state.pointer) |pointer| wl.wl_pointer_destroy(pointer);
        if (state.seat) |seat| wl.wl_seat_destroy(seat);
        if (state.toplevel) |toplevel| wl.xdg_toplevel_destroy(toplevel);
        if (state.xdg_surface) |xdg_surface| wl.xdg_surface_destroy(xdg_surface);
        if (state.surface) |surface| wl.wl_surface_destroy(surface);
        if (state.wm_base) |wm_base| wl.xdg_wm_base_destroy(wm_base);
        if (state.compositor) |compositor| wl.wl_compositor_destroy(compositor);
        wl.wl_registry_destroy(state.registry);
        wl.wl_display_disconnect(state.display);
        const allocator = state.allocator;
        allocator.destroy(state);
        self.* = undefined;
    }

    pub fn dispatch(self: *Window) Error!void {
        if (wl.wl_display_dispatch(self.state.display) < 0) return error.DispatchFailed;
    }

    pub fn dispatchPending(self: *Window) Error!void {
        if (wl.wl_display_dispatch_pending(self.state.display) < 0) return error.DispatchFailed;
    }

    /// Read and dispatch events, waiting at most `timeout_ms`. This preserves
    /// the prepare-read protocol and lets applications service timers without
    /// embedding Wayland mechanics in their composition root.
    pub fn dispatchTimeout(self: *Window, timeout_ms: i32) Error!void {
        while (wl.wl_display_prepare_read(self.state.display) != 0) {
            try self.dispatchPending();
        }
        _ = wl.wl_display_flush(self.state.display);

        var descriptors = [_]std.posix.pollfd{.{
            .fd = self.fileDescriptor(),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&descriptors, timeout_ms) catch {
            wl.wl_display_cancel_read(self.state.display);
            return error.DispatchFailed;
        };
        if (ready == 0) {
            wl.wl_display_cancel_read(self.state.display);
            return;
        }
        if (wl.wl_display_read_events(self.state.display) < 0) {
            return error.DispatchFailed;
        }
        try self.dispatchPending();
    }

    pub fn flush(self: *Window) Error!void {
        if (wl.wl_display_flush(self.state.display) < 0) return error.FlushFailed;
    }

    pub fn pollEvent(self: *Window) ?Event {
        return self.state.queue.pop();
    }

    pub fn eventQueueOverflowed(self: *const Window) bool {
        return self.state.queue.overflowed;
    }

    pub fn clearEventQueueOverflow(self: *Window) void {
        self.state.queue.overflowed = false;
    }

    pub fn size(self: *const Window) Size {
        return self.state.size;
    }

    pub fn fileDescriptor(self: *const Window) i32 {
        return wl.wl_display_get_fd(self.state.display);
    }

    pub fn wsiHandles(self: *const Window) WsiHandles {
        return .{
            .display = self.state.display,
            .surface = self.state.surface.?,
        };
    }

    /// Schedule at most one callback for the next compositor frame. The caller
    /// still decides whether damage warrants acquiring and presenting an image.
    pub fn requestFrame(self: *Window) void {
        if (self.state.frame_callback != null) return;
        const callback = wl.wl_surface_frame(self.state.surface) orelse return;
        self.state.frame_callback = callback;
        _ = wl.wl_callback_add_listener(callback, &frame_listener, self.state);
    }
};

const registry_listener = wl.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

fn registryGlobal(
    data: ?*anyopaque,
    registry: ?*wl.wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    const state = stateFrom(data);
    const interface_name = std.mem.span(@as([*:0]const u8, @ptrCast(interface)));
    if (std.mem.eql(u8, interface_name, "wl_compositor")) {
        state.compositor = @ptrCast(wl.wl_registry_bind(
            registry,
            name,
            &wl.wl_compositor_interface,
            @min(version, 6),
        ));
    } else if (std.mem.eql(u8, interface_name, "xdg_wm_base")) {
        const supported: u32 = @intCast(wl.xdg_wm_base_interface.version);
        state.wm_base = @ptrCast(wl.wl_registry_bind(
            registry,
            name,
            &wl.xdg_wm_base_interface,
            @min(version, supported),
        ));
        _ = wl.xdg_wm_base_add_listener(state.wm_base, &wm_base_listener, state);
    } else if (std.mem.eql(u8, interface_name, "wl_seat")) {
        state.seat = @ptrCast(wl.wl_registry_bind(
            registry,
            name,
            &wl.wl_seat_interface,
            @min(version, 8),
        ));
        _ = wl.wl_seat_add_listener(state.seat, &seat_listener, state);
    }
}

fn registryGlobalRemove(_: ?*anyopaque, _: ?*wl.wl_registry, _: u32) callconv(.c) void {}

const wm_base_listener = wl.xdg_wm_base_listener{ .ping = wmBasePing };

fn wmBasePing(_: ?*anyopaque, wm_base: ?*wl.xdg_wm_base, serial: u32) callconv(.c) void {
    wl.xdg_wm_base_pong(wm_base, serial);
}

const xdg_surface_listener = wl.xdg_surface_listener{ .configure = xdgSurfaceConfigure };

fn xdgSurfaceConfigure(data: ?*anyopaque, surface: ?*wl.xdg_surface, serial: u32) callconv(.c) void {
    const state = stateFrom(data);
    wl.xdg_surface_ack_configure(surface, serial);
    state.size = state.pending_size;
    state.queue.push(.{ .configured = state.size });
}

const toplevel_listener = wl.xdg_toplevel_listener{
    .configure = toplevelConfigure,
    .close = toplevelClose,
    .configure_bounds = toplevelConfigureBounds,
    .wm_capabilities = toplevelWmCapabilities,
};

fn toplevelConfigure(
    data: ?*anyopaque,
    _: ?*wl.xdg_toplevel,
    width: i32,
    height: i32,
    _: ?*wl.wl_array,
) callconv(.c) void {
    if (width <= 0 or height <= 0) return;
    const state = stateFrom(data);
    const next = Size{ .width = @intCast(width), .height = @intCast(height) };
    if (next.width == state.pending_size.width and next.height == state.pending_size.height) return;
    state.pending_size = next;
    state.queue.push(.{ .resized = next });
}

fn toplevelClose(data: ?*anyopaque, _: ?*wl.xdg_toplevel) callconv(.c) void {
    stateFrom(data).queue.push(.close);
}

fn toplevelConfigureBounds(_: ?*anyopaque, _: ?*wl.xdg_toplevel, _: i32, _: i32) callconv(.c) void {}
fn toplevelWmCapabilities(_: ?*anyopaque, _: ?*wl.xdg_toplevel, _: ?*wl.wl_array) callconv(.c) void {}

const seat_listener = wl.wl_seat_listener{
    .capabilities = seatCapabilities,
    .name = seatName,
};

fn seatName(_: ?*anyopaque, _: ?*wl.wl_seat, _: [*c]const u8) callconv(.c) void {}

fn seatCapabilities(data: ?*anyopaque, seat: ?*wl.wl_seat, capabilities: u32) callconv(.c) void {
    const state = stateFrom(data);
    const has_pointer = capabilities & wl.WL_SEAT_CAPABILITY_POINTER != 0;
    const has_keyboard = capabilities & wl.WL_SEAT_CAPABILITY_KEYBOARD != 0;

    if (has_pointer and state.pointer == null) {
        state.pointer = wl.wl_seat_get_pointer(seat);
        _ = wl.wl_pointer_add_listener(state.pointer, &pointer_listener, state);
    } else if (!has_pointer and state.pointer != null) {
        wl.wl_pointer_destroy(state.pointer);
        state.pointer = null;
    }

    if (has_keyboard and state.keyboard == null) {
        state.keyboard = wl.wl_seat_get_keyboard(seat);
        _ = wl.wl_keyboard_add_listener(state.keyboard, &keyboard_listener, state);
    } else if (!has_keyboard and state.keyboard != null) {
        wl.wl_keyboard_destroy(state.keyboard);
        state.keyboard = null;
    }
}

const pointer_listener = wl.wl_pointer_listener{
    .enter = pointerEnter,
    .leave = pointerLeave,
    .motion = pointerMotion,
    .button = pointerButton,
    .axis = pointerAxis,
    .frame = pointerFrame,
    .axis_source = pointerAxisSource,
    .axis_stop = pointerAxisStop,
    .axis_discrete = pointerAxisDiscrete,
    .axis_value120 = pointerAxisValue120,
    .axis_relative_direction = pointerAxisRelativeDirection,
};

fn pointerEnter(
    data: ?*anyopaque,
    _: ?*wl.wl_pointer,
    _: u32,
    _: ?*wl.wl_surface,
    x: wl.wl_fixed_t,
    y: wl.wl_fixed_t,
) callconv(.c) void {
    const state = stateFrom(data);
    state.pointer_position = fixedPosition(x, y);
    state.queue.push(.{ .pointer_enter = state.pointer_position });
}

fn pointerLeave(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: ?*wl.wl_surface) callconv(.c) void {
    stateFrom(data).queue.push(.pointer_leave);
}

fn pointerMotion(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, x: wl.wl_fixed_t, y: wl.wl_fixed_t) callconv(.c) void {
    const state = stateFrom(data);
    state.pointer_position = fixedPosition(x, y);
    state.queue.push(.{ .pointer_motion = state.pointer_position });
}

fn pointerButton(
    data: ?*anyopaque,
    _: ?*wl.wl_pointer,
    serial: u32,
    time_ms: u32,
    button: u32,
    raw_state: u32,
) callconv(.c) void {
    const state = stateFrom(data);
    state.queue.push(.{ .pointer_button = .{
        .serial = serial,
        .time_ms = time_ms,
        .button = button,
        .state = if (raw_state == wl.WL_POINTER_BUTTON_STATE_PRESSED) .pressed else .released,
        .position = state.pointer_position,
    } });
}

fn pointerAxis(data: ?*anyopaque, _: ?*wl.wl_pointer, time_ms: u32, raw_axis: u32, value: wl.wl_fixed_t) callconv(.c) void {
    const state = stateFrom(data);
    state.queue.push(.{ .scroll = .{
        .time_ms = time_ms,
        .axis = if (raw_axis == wl.WL_POINTER_AXIS_HORIZONTAL_SCROLL) .horizontal else .vertical,
        .delta = wl.wl_fixed_to_double(value),
        .position = state.pointer_position,
    } });
}

fn pointerFrame(_: ?*anyopaque, _: ?*wl.wl_pointer) callconv(.c) void {}
fn pointerAxisSource(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32) callconv(.c) void {}
fn pointerAxisStop(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32) callconv(.c) void {}
fn pointerAxisDiscrete(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: i32) callconv(.c) void {}
fn pointerAxisValue120(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: i32) callconv(.c) void {}
fn pointerAxisRelativeDirection(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32) callconv(.c) void {}

const keyboard_listener = wl.wl_keyboard_listener{
    .keymap = keyboardKeymap,
    .enter = keyboardEnter,
    .leave = keyboardLeave,
    .key = keyboardKey,
    .modifiers = keyboardModifiers,
    .repeat_info = keyboardRepeatInfo,
};

fn keyboardKeymap(
    data: ?*anyopaque,
    _: ?*wl.wl_keyboard,
    format: u32,
    fd: i32,
    size: u32,
) callconv(.c) void {
    defer _ = std.posix.system.close(fd);
    if (format != wl.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 or size == 0) return;
    const state = stateFrom(data);
    const mapped = std.posix.mmap(
        null,
        size,
        .{ .READ = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    ) catch return;
    defer std.posix.munmap(mapped);

    if (state.xkb_context == null) {
        state.xkb_context = wl.xkb_context_new(wl.XKB_CONTEXT_NO_FLAGS);
    }
    const context = state.xkb_context orelse return;
    const keymap = wl.xkb_keymap_new_from_string(
        context,
        @ptrCast(mapped.ptr),
        wl.XKB_KEYMAP_FORMAT_TEXT_V1,
        wl.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return;
    const xkb_state = wl.xkb_state_new(keymap) orelse {
        wl.xkb_keymap_unref(keymap);
        return;
    };

    if (state.xkb_state) |old_state| wl.xkb_state_unref(old_state);
    if (state.xkb_keymap) |old_keymap| wl.xkb_keymap_unref(old_keymap);
    state.xkb_keymap = keymap;
    state.xkb_state = xkb_state;
}

fn keyboardEnter(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface, _: ?*wl.wl_array) callconv(.c) void {}

fn keyboardLeave(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface) callconv(.c) void {
    const state = stateFrom(data);
    state.modifiers = .{};
    state.queue.push(.keyboard_leave);
}

fn keyboardKey(
    data: ?*anyopaque,
    _: ?*wl.wl_keyboard,
    serial: u32,
    time_ms: u32,
    scancode: u32,
    raw_state: u32,
) callconv(.c) void {
    const state = stateFrom(data);
    const pressed = raw_state == wl.WL_KEYBOARD_KEY_STATE_PRESSED;
    setRawModifier(&state.modifiers, scancode, pressed);

    var codepoint: ?u21 = null;
    if (pressed) {
        if (state.xkb_state) |xkb_state| {
            const value = wl.xkb_state_key_get_utf32(xkb_state, scancode + 8);
            if (value > 0 and value <= std.math.maxInt(u21)) codepoint = @intCast(value);
        }
    }
    state.queue.push(.{ .key = .{
        .serial = serial,
        .time_ms = time_ms,
        .scancode = scancode,
        .state = if (pressed) .pressed else .released,
        .modifiers = state.modifiers,
        .codepoint = codepoint,
    } });
}

fn keyboardModifiers(
    data: ?*anyopaque,
    _: ?*wl.wl_keyboard,
    _: u32,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) callconv(.c) void {
    if (stateFrom(data).xkb_state) |xkb_state| {
        _ = wl.xkb_state_update_mask(xkb_state, depressed, latched, locked, 0, 0, group);
    }
}

fn keyboardRepeatInfo(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: i32, _: i32) callconv(.c) void {}

const frame_listener = wl.wl_callback_listener{ .done = frameDone };

fn frameDone(data: ?*anyopaque, callback: ?*wl.wl_callback, _: u32) callconv(.c) void {
    const state = stateFrom(data);
    wl.wl_callback_destroy(callback);
    state.frame_callback = null;
    state.queue.push(.frame_ready);
}

fn stateFrom(data: ?*anyopaque) *State {
    return @ptrCast(@alignCast(data.?));
}

fn fixedPosition(x: wl.wl_fixed_t, y: wl.wl_fixed_t) PointerPosition {
    return .{ .x = wl.wl_fixed_to_double(x), .y = wl.wl_fixed_to_double(y) };
}

fn setRawModifier(modifiers: *Modifiers, scancode: u32, pressed: bool) void {
    switch (scancode) {
        29, 97 => modifiers.control = pressed,
        42, 54 => modifiers.shift = pressed,
        56, 100 => modifiers.alt = pressed,
        125, 126 => modifiers.logo = pressed,
        else => {},
    }
}

test "the platform event vocabulary has no UI or renderer payloads" {
    var queue: EventQueue = .{};
    queue.push(.{ .resized = .{ .width = 800, .height = 600 } });
    queue.push(.frame_ready);
    try std.testing.expectEqual(@as(usize, 2), queue.len);
    try std.testing.expectEqual(@as(u32, 800), queue.pop().?.resized.width);
    try std.testing.expect(queue.pop().? == .frame_ready);
}

test "the bounded callback queue reports overflow without allocating" {
    var queue: EventQueue = .{};
    for (0..EventQueue.capacity + 1) |_| queue.push(.close);
    try std.testing.expect(queue.overflowed);
    try std.testing.expectEqual(EventQueue.capacity, queue.len);
}
