//! Private storage shared by the core and optional Chrome C composition roots.
//!
//! This is not a public ABI. Public layouts live in `include/goop.h` and
//! `include/goop_chrome.h` and are checked by each C root's tests.

const std = @import("std");
const goop = @import("goop");

pub const String = extern struct {
    ptr: [*c]const u8 = null,
    len: usize = 0,
};

pub const TextDimensions = extern struct {
    width: f32 = 0,
    height: f32 = 0,
    ascent: f32 = 0,
    descent: f32 = 0,
};

pub const MeasureTextFn = *const fn (text: String, font_size: f32, user_data: ?*anyopaque) callconv(.c) TextDimensions;

pub const TextMeasureContext = extern struct {
    measure_fn: ?MeasureTextFn = null,
    user_data: ?*anyopaque = null,
};

pub const ClipboardGetTextFn = *const fn (ptr: ?*anyopaque) callconv(.c) String;
pub const ClipboardSetTextFn = *const fn (ptr: ?*anyopaque, text: String) callconv(.c) void;

pub const Clipboard = extern struct {
    ptr: ?*anyopaque = null,
    get_text_fn: ?ClipboardGetTextFn = null,
    set_text_fn: ?ClipboardSetTextFn = null,
};

pub const Context = struct {
    ctx: goop.Context,
    clipboard_provider: Clipboard = .{},
    clipboard_enabled: bool = false,
    measure_provider: TextMeasureContext = .{},
    measure_enabled: bool = false,
    measure_bridge: goop.layout.TextMeasureCtx = .{
        .measureFn = &measureTextBridge,
        .user_data = null,
    },
    /// Aligned raw backing for converted `goop_control_event_t` values.
    /// The core C root owns the interpretation and count.
    control_event_words: std.ArrayListUnmanaged(u64) = .empty,
    selection_ids: std.ArrayListUnmanaged(u64) = .empty,

    pub fn deinitAdapters(self: *Context, allocator: std.mem.Allocator) void {
        self.selection_ids.deinit(allocator);
        self.control_event_words.deinit(allocator);
    }

    pub fn setClipboard(self: *Context, provider: ?*const Clipboard) void {
        if (provider) |value| {
            self.clipboard_provider = value.*;
            self.clipboard_enabled = value.get_text_fn != null and value.set_text_fn != null;
        } else {
            self.clipboard_provider = .{};
            self.clipboard_enabled = false;
        }

        self.ctx.setClipboard(if (self.clipboard_enabled) .{
            .ptr = @ptrCast(self),
            .getTextFn = &clipboardGet,
            .setTextFn = &clipboardSet,
        } else null);
    }

    pub fn textMeasure(self: *Context, measure: ?*const TextMeasureContext) ?*const goop.layout.TextMeasureCtx {
        if (measure == null) {
            self.measure_enabled = false;
            self.measure_bridge.user_data = null;
            return null;
        }
        self.measure_provider = measure.?.*;
        self.measure_enabled = true;
        self.measure_bridge.user_data = @ptrCast(&self.measure_provider);
        return &self.measure_bridge;
    }
};

pub fn fromString(str: String) []const u8 {
    if (str.ptr == null or str.len == 0) return "";
    const ptr = str.ptr orelse return "";
    return @as([*]const u8, @ptrCast(ptr))[0..str.len];
}

pub fn toString(str: []const u8) String {
    if (str.len == 0) return .{};
    return .{ .ptr = @ptrCast(str.ptr), .len = str.len };
}

fn clipboardGet(ptr: *anyopaque) ?[]const u8 {
    const context: *Context = @ptrCast(@alignCast(ptr));
    if (!context.clipboard_enabled or context.clipboard_provider.get_text_fn == null) return null;
    const text = context.clipboard_provider.get_text_fn.?(context.clipboard_provider.ptr);
    if (text.ptr == null or text.len == 0) return null;
    return fromString(text);
}

fn clipboardSet(ptr: *anyopaque, text: []const u8) void {
    const context: *Context = @ptrCast(@alignCast(ptr));
    if (!context.clipboard_enabled or context.clipboard_provider.set_text_fn == null) return;
    context.clipboard_provider.set_text_fn.?(context.clipboard_provider.ptr, toString(text));
}

fn measureTextBridge(text: []const u8, font_size: f32, user_data: ?*anyopaque) goop.layout.TextDimensions {
    const raw: *const TextMeasureContext = @ptrCast(@alignCast(user_data));
    if (raw.measure_fn == null) return .{ .width = 0, .height = font_size };
    const dims = raw.measure_fn.?(toString(text), font_size, raw.user_data);
    return .{
        .width = dims.width,
        .height = dims.height,
        .ascent = dims.ascent,
        .descent = dims.descent,
    };
}
