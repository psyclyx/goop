//! Optional stock Chrome C composition root.
//!
//! The core C context owns no Chrome state. Applications opt in by creating
//! this separate cache and may otherwise link only the core C library.

const std = @import("std");
const goop = @import("goop");
const chrome_module = @import("goop_chrome");
const visual = @import("goop_visual");
const shared = @import("c_api/context.zig");

const allocator = std.heap.c_allocator;

const CStr = shared.String;

const CRect = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

const CColor = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,
};

const CVisualOperationKind = enum(c_int) {
    surface = 0,
    text = 1,
    push_clip = 2,
    pop_clip = 3,
    icon = 4,
    custom = 5,
    image = 6,
};

const CTextAlign = enum(c_int) {
    start = 0,
    center = 1,
    end = 2,
};

const CTextOverflow = enum(c_int) {
    visible = 0,
    clip = 1,
    ellipsis = 2,
    wrap = 3,
};

const CVisualSurface = extern struct {
    bounds: CRect = .{},
    color: CColor = .{},
    border_color: CColor = .{},
    border_width: f32 = 0,
    corner_radius: f32 = 0,
};

const CVisualText = extern struct {
    bounds: CRect = .{},
    text: CStr = .{},
    color: CColor = .{},
    font_size: f32 = 0,
    text_align: CTextAlign = .start,
    overflow: CTextOverflow = .visible,
};

const CVisualIcon = extern struct {
    bounds: CRect = .{},
    kind: u32 = 0,
    color: CColor = .{},
};

const CImageFit = enum(c_int) { contain = 0, cover = 1, stretch = 2 };

const CVisualImage = extern struct {
    bounds: CRect = .{},
    resource_id: u64 = 0,
    revision: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    rgba: [*c]const u8 = null,
    rgba_len: usize = 0,
    fit: CImageFit = .contain,
};

const CCustomNamespace = enum(c_int) {
    element = 0,
    visual = 1,
};

const CVisualCustom = extern struct {
    id_namespace: CCustomNamespace = .element,
    value: u64 = 0,
    bounds: CRect = .{},
};

const CVisualOperation = extern struct {
    kind: CVisualOperationKind = .surface,
    data: extern union {
        surface: CVisualSurface,
        text: CVisualText,
        push_clip: CRect,
        icon: CVisualIcon,
        image: CVisualImage,
        custom: CVisualCustom,
    } = .{ .surface = .{} },
};

const CVisualList = extern struct {
    operations: [*c]const CVisualOperation = null,
    len: usize = 0,
};

const CChromeScopeKind = enum(c_int) {
    full = 0,
    popup = 1,
};

const CChromeOptions = extern struct {
    kind: CChromeScopeKind = .full,
    include_floating: bool = true,
    popup_element: u64 = 0,
};

const CChromeResult = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    out_of_memory = 2,
    unknown_popup_element = 3,
    missing_custom_visual_id = 4,
};

const CChrome = struct {
    chrome: chrome_module.Chrome,
    operations: std.ArrayListUnmanaged(CVisualOperation) = .empty,
};

fn rectToC(rect: visual.Rect) CRect {
    return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
}

fn colorToC(color: visual.Color) CColor {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

fn operationToC(operation: visual.Operation) CVisualOperation {
    return switch (operation) {
        .surface => |surface| .{
            .kind = .surface,
            .data = .{ .surface = .{
                .bounds = rectToC(surface.bounds),
                .color = colorToC(surface.color),
                .border_color = colorToC(surface.border_color),
                .border_width = surface.border_width,
                .corner_radius = surface.corner_radius,
            } },
        },
        .text => |text| .{
            .kind = .text,
            .data = .{ .text = .{
                .bounds = rectToC(text.bounds),
                .text = shared.toString(text.text),
                .color = colorToC(text.color),
                .font_size = text.font_size,
                .text_align = switch (text.text_align) {
                    .start => .start,
                    .center => .center,
                    .end => .end,
                },
                .overflow = switch (text.overflow) {
                    .visible => .visible,
                    .clip => .clip,
                    .ellipsis => .ellipsis,
                    .wrap => .wrap,
                },
            } },
        },
        .push_clip => |bounds| .{
            .kind = .push_clip,
            .data = .{ .push_clip = rectToC(bounds) },
        },
        .pop_clip => .{ .kind = .pop_clip },
        .icon => |icon| .{
            .kind = .icon,
            .data = .{ .icon = .{
                .bounds = rectToC(icon.bounds),
                .kind = icon.kind,
                .color = colorToC(icon.color),
            } },
        },
        .image => |image| .{
            .kind = .image,
            .data = .{ .image = .{
                .bounds = rectToC(image.bounds),
                .resource_id = image.source.id.value,
                .revision = image.source.id.revision,
                .width = image.source.width,
                .height = image.source.height,
                .rgba = image.source.rgba.ptr,
                .rgba_len = image.source.rgba.len,
                .fit = switch (image.fit) {
                    .contain => .contain,
                    .cover => .cover,
                    .stretch => .stretch,
                },
            } },
        },
        .custom => |custom| .{
            .kind = .custom,
            .data = .{ .custom = .{
                .id_namespace = switch (custom.id.namespace) {
                    .element => .element,
                    .visual => .visual,
                },
                .value = custom.id.value,
                .bounds = rectToC(custom.bounds),
            } },
        },
    };
}

fn chromeOptions(options: CChromeOptions) chrome_module.Options {
    return .{ .scope = switch (options.kind) {
        .full => .{ .full = .{ .include_floating = options.include_floating } },
        .popup => .{ .popup = goop.ElementId.init(options.popup_element) },
    } };
}

export fn goop_chrome_create() ?*CChrome {
    const chrome = allocator.create(CChrome) catch return null;
    chrome.* = .{ .chrome = chrome_module.Chrome.init(allocator) };
    return chrome;
}

export fn goop_chrome_destroy(chrome: ?*CChrome) void {
    const instance = chrome orelse return;
    instance.operations.deinit(allocator);
    instance.chrome.deinit();
    allocator.destroy(instance);
}

export fn goop_chrome_invalidate(chrome: ?*CChrome) void {
    const instance = chrome orelse return;
    instance.operations.clearRetainingCapacity();
    instance.chrome.invalidate();
}

export fn goop_chrome_prepare(
    chrome: ?*CChrome,
    context: ?*const shared.Context,
    options: ?*const CChromeOptions,
    out_visuals: ?*CVisualList,
) CChromeResult {
    const out = out_visuals orelse return .invalid_argument;
    out.* = .{};
    const instance = chrome orelse return .invalid_argument;
    const core = context orelse return .invalid_argument;
    const requested = options orelse return .invalid_argument;

    const list = instance.chrome.prepare(core.ctx.chromeState(), chromeOptions(requested.*)) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.UnknownPopupElement => .unknown_popup_element,
        error.MissingCustomVisualId => .missing_custom_visual_id,
    };

    instance.operations.resize(allocator, list.commands.len) catch return .out_of_memory;
    for (list.commands, 0..) |operation, index| instance.operations.items[index] = operationToC(operation);
    out.* = .{
        .operations = if (instance.operations.items.len == 0) null else instance.operations.items.ptr,
        .len = instance.operations.items.len,
    };
    return .ok;
}

test "chrome C layouts match the public header" {
    const c = @cImport({
        @cInclude("goop_chrome.h");
    });
    const Pair = struct { Z: type, C: type };
    const pairs = [_]Pair{
        .{ .Z = CVisualSurface, .C = c.goop_visual_surface_t },
        .{ .Z = CVisualText, .C = c.goop_visual_text_t },
        .{ .Z = CVisualIcon, .C = c.goop_visual_icon_t },
        .{ .Z = CVisualCustom, .C = c.goop_visual_custom_t },
        .{ .Z = CVisualOperation, .C = c.goop_visual_operation_t },
        .{ .Z = CVisualList, .C = c.goop_visual_list_t },
        .{ .Z = CChromeOptions, .C = c.goop_chrome_options_t },
    };
    inline for (pairs) |pair| {
        try std.testing.expectEqual(@sizeOf(pair.Z), @sizeOf(pair.C));
        try std.testing.expectEqual(@alignOf(pair.Z), @alignOf(pair.C));
        inline for (@typeInfo(pair.Z).@"struct".fields) |field| {
            try std.testing.expectEqual(@offsetOf(pair.Z, field.name), @offsetOf(pair.C, field.name));
        }
    }
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CVisualOperationKind.surface)), c.GOOP_VISUAL_SURFACE);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CVisualOperationKind.text)), c.GOOP_VISUAL_TEXT);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CVisualOperationKind.push_clip)), c.GOOP_VISUAL_PUSH_CLIP);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CVisualOperationKind.pop_clip)), c.GOOP_VISUAL_POP_CLIP);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CVisualOperationKind.icon)), c.GOOP_VISUAL_ICON);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CVisualOperationKind.custom)), c.GOOP_VISUAL_CUSTOM);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CVisualOperationKind.image)), c.GOOP_VISUAL_IMAGE);
    try std.testing.expect(!@hasDecl(c, "goop_context_generate_paint_list"));
    try std.testing.expect(!@hasDecl(c, "goop_paint_list_t"));
}

test "caller-owned Chrome surfaces icon operations through the C visual list" {
    var context = shared.Context{
        .ctx = try goop.Context.init(std.testing.allocator, .{ .width = 320, .height = 200 }),
    };
    defer context.ctx.deinit();
    _ = try context.ctx.tree.addRootControl(.{
        .identity = .{ .element_id = .init(1) },
        .widget = .{ .icon = .{
            .kind = 0x10203040,
            .color = .{ .r = 12, .g = 34, .b = 56, .a = 78 },
        } },
    });
    context.ctx.doLayout(null);

    const chrome = goop_chrome_create() orelse return error.OutOfMemory;
    defer goop_chrome_destroy(chrome);
    const options = CChromeOptions{};
    var list: CVisualList = .{};
    try std.testing.expectEqual(CChromeResult.ok, goop_chrome_prepare(chrome, &context, &options, &list));
    try std.testing.expect(list.len > 0);
    var saw_icon = false;
    for (list.operations[0..list.len]) |operation| {
        if (operation.kind != .icon) continue;
        const icon = operation.data.icon;
        saw_icon = icon.kind == 0x10203040 and
            std.meta.eql(icon.color, CColor{ .r = 12, .g = 34, .b = 56, .a = 78 });
    }
    try std.testing.expect(saw_icon);
}
