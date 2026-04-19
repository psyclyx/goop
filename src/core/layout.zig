const std = @import("std");
const c = @cImport({
    @cInclude("clay.h");
});
const widget = @import("widget.zig");
const style_mod = @import("style.zig");


/// Generic text measurement function.
/// Given a UTF-8 string and font size, return its pixel dimensions.
pub const MeasureTextFn = *const fn (text: []const u8, font_size: f32, user_data: ?*anyopaque) TextDimensions;

pub const TextDimensions = struct {
    width: f32,
    height: f32,
};

/// Text measurement context: a function pointer + opaque user data.
/// The embedder provides this to get accurate text sizing.
pub const TextMeasureCtx = struct {
    measureFn: MeasureTextFn,
    user_data: ?*anyopaque = null,
};

/// Run the layout pass: walk the widget tree, feed elements to clay,
/// compute layout, and write computed rects back to each node.
pub fn run(tree: *widget.Tree, theme: style_mod.Theme, text_ctx: ?*const TextMeasureCtx) void {
    c.Clay_SetMeasureTextFunction(&measureText, @constCast(@ptrCast(text_ctx)));
    c.Clay_BeginLayout();

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive) continue;
        if (node.parent == null) {
            emitNode(tree, tree.handleFromIndex(@intCast(i)), theme);
        }
    }

    _ = c.Clay_EndLayout();

    writeBackRects(tree);
}

fn writeBackRects(tree: *widget.Tree) void {
    for (tree.nodes.items, 0..) |*node, i| {
        if (!node.alive) continue;
        const handle = tree.handleFromIndex(@intCast(i));
        const data = c.Clay_GetElementData(nodeId(handle));
        if (data.found) {
            node.layout_rect = .{
                .x = data.boundingBox.x,
                .y = data.boundingBox.y,
                .w = data.boundingBox.width,
                .h = data.boundingBox.height,
            };
        }
    }
}

fn emitNode(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style_mod.Theme) void {
    const node = tree.getConst(handle);
    const resolved = node.style_override.resolve(theme);

    switch (node.kind) {
        .text => |txt| emitText(handle, txt, resolved),
        .button => |btn| emitButton(handle, btn, resolved),
        .checkbox => |cb| emitCheckbox(handle, cb, resolved),
        .radio_button => |rb| emitRadioButton(handle, rb, resolved),
        .container => |cont| emitContainer(tree, handle, cont, resolved, theme),
        .slider => emitSlider(handle, resolved),
        .text_input => |ti| emitTextInput(handle, ti, resolved),
        .scroll_area => emitScrollArea(tree, handle, resolved, theme),
    }
}

fn emitText(handle: widget.NodeHandle, txt: widget.WidgetKind.Text, resolved: style_mod.ResolvedStyle) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{},
        .backgroundColor = .{},
        .cornerRadius = .{},
        .aspectRatio = .{},
        .image = .{},
        .floating = .{},
        .custom = .{},
        .clip = .{},
        .border = .{},
        .userData = null,
    });
    c.Clay__OpenTextElement(
        clayString(txt.content),
        c.Clay__StoreTextElementConfig(.{
            .userData = null,
            .textColor = clayColor(resolved.fg),
            .fontId = 0,
            .fontSize = @intFromFloat(resolved.font_size),
            .letterSpacing = 0,
            .lineHeight = 0,
            .wrapMode = c.CLAY_TEXT_WRAP_WORDS,
            .textAlignment = c.CLAY_TEXT_ALIGN_LEFT,
        }),
    );
    c.Clay__CloseElement();
}

fn emitButton(handle: widget.NodeHandle, btn: widget.WidgetKind.Button, resolved: style_mod.ResolvedStyle) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{},
            .padding = clayPadding(resolved.padding),
            .childGap = 0,
            .childAlignment = .{},
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
        },
        .backgroundColor = clayColor(resolved.bg),
        .cornerRadius = cornerRadiusAll(resolved.border_radius),
        .aspectRatio = .{},
        .image = .{},
        .floating = .{},
        .custom = .{},
        .clip = .{},
        .border = .{},
        .userData = null,
    });
    c.Clay__OpenTextElement(
        clayString(btn.label),
        c.Clay__StoreTextElementConfig(.{
            .userData = null,
            .textColor = clayColor(resolved.fg),
            .fontId = 0,
            .fontSize = @intFromFloat(resolved.font_size),
            .letterSpacing = 0,
            .lineHeight = 0,
            .wrapMode = c.CLAY_TEXT_WRAP_NONE,
            .textAlignment = c.CLAY_TEXT_ALIGN_CENTER,
        }),
    );
    c.Clay__CloseElement();
}

fn emitCheckbox(handle: widget.NodeHandle, cb: widget.WidgetKind.Checkbox, resolved: style_mod.ResolvedStyle) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = .{},
            },
            .padding = clayPadding(resolved.padding),
            .childGap = @intFromFloat(resolved.padding.left),
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
        },
        .backgroundColor = .{},
        .cornerRadius = .{},
        .aspectRatio = .{},
        .image = .{},
        .floating = .{},
        .custom = .{},
        .clip = .{},
        .border = .{},
        .userData = null,
    });
    c.Clay__OpenTextElement(
        clayString(cb.label),
        c.Clay__StoreTextElementConfig(.{
            .userData = null,
            .textColor = clayColor(resolved.fg),
            .fontId = 0,
            .fontSize = @intFromFloat(resolved.font_size),
            .letterSpacing = 0,
            .lineHeight = 0,
            .wrapMode = c.CLAY_TEXT_WRAP_NONE,
            .textAlignment = c.CLAY_TEXT_ALIGN_LEFT,
        }),
    );
    c.Clay__CloseElement();
}

fn emitRadioButton(handle: widget.NodeHandle, rb: widget.WidgetKind.RadioButton, resolved: style_mod.ResolvedStyle) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = .{},
            },
            .padding = clayPadding(resolved.padding),
            .childGap = @intFromFloat(resolved.padding.left),
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
        },
        .backgroundColor = .{},
        .cornerRadius = .{},
        .aspectRatio = .{},
        .image = .{},
        .floating = .{},
        .custom = .{},
        .clip = .{},
        .border = .{},
        .userData = null,
    });
    c.Clay__OpenTextElement(
        clayString(rb.label),
        c.Clay__StoreTextElementConfig(.{
            .userData = null,
            .textColor = clayColor(resolved.fg),
            .fontId = 0,
            .fontSize = @intFromFloat(resolved.font_size),
            .letterSpacing = 0,
            .lineHeight = 0,
            .wrapMode = c.CLAY_TEXT_WRAP_NONE,
            .textAlignment = c.CLAY_TEXT_ALIGN_LEFT,
        }),
    );
    c.Clay__CloseElement();
}

fn emitContainer(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    cont: widget.WidgetKind.Container,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = growSizing(),
            },
            .padding = clayPadding(resolved.padding),
            .childGap = @intFromFloat(theme.spacing),
            .childAlignment = .{},
            .layoutDirection = switch (cont.direction) {
                .row => c.CLAY_LEFT_TO_RIGHT,
                .column => c.CLAY_TOP_TO_BOTTOM,
            },
        },
        .backgroundColor = clayColor(resolved.bg),
        .cornerRadius = .{},
        .aspectRatio = .{},
        .image = .{},
        .floating = .{},
        .custom = .{},
        .clip = .{},
        .border = .{},
        .userData = null,
    });
    emitChildren(tree, handle, theme);
    c.Clay__CloseElement();
}

fn emitSlider(handle: widget.NodeHandle, resolved: style_mod.ResolvedStyle) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = fixedSizing(24),
            },
            .padding = clayPadding(resolved.padding),
            .childGap = 0,
            .childAlignment = .{},
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
        },
        .backgroundColor = clayColor(resolved.bg),
        .cornerRadius = cornerRadiusAll(resolved.border_radius),
        .aspectRatio = .{},
        .image = .{},
        .floating = .{},
        .custom = .{},
        .clip = .{},
        .border = .{},
        .userData = null,
    });
    c.Clay__CloseElement();
}

fn emitTextInput(handle: widget.NodeHandle, ti: widget.WidgetKind.TextInput, resolved: style_mod.ResolvedStyle) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = fixedSizing(resolved.font_size + resolved.padding.top + resolved.padding.bottom),
            },
            .padding = clayPadding(resolved.padding),
            .childGap = 0,
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
        },
        .backgroundColor = clayColor(resolved.bg),
        .cornerRadius = cornerRadiusAll(resolved.border_radius),
        .aspectRatio = .{},
        .image = .{},
        .floating = .{},
        .custom = .{},
        .clip = .{},
        .border = .{},
        .userData = null,
    });
    c.Clay__OpenTextElement(
        clayString(ti.content()),
        c.Clay__StoreTextElementConfig(.{
            .userData = null,
            .textColor = clayColor(resolved.fg),
            .fontId = 0,
            .fontSize = @intFromFloat(resolved.font_size),
            .letterSpacing = 0,
            .lineHeight = 0,
            .wrapMode = c.CLAY_TEXT_WRAP_NONE,
            .textAlignment = c.CLAY_TEXT_ALIGN_LEFT,
        }),
    );
    c.Clay__CloseElement();
}

fn emitScrollArea(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    const node = tree.getConst(handle);
    const scroll = node.kind.scroll_area;
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = growSizing(),
            },
            .padding = clayPadding(resolved.padding),
            .childGap = @intFromFloat(theme.spacing),
            .childAlignment = .{},
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
        },
        .backgroundColor = clayColor(resolved.bg),
        .cornerRadius = .{},
        .aspectRatio = .{},
        .image = .{},
        .floating = .{},
        .custom = .{},
        .clip = .{
            .horizontal = true,
            .vertical = true,
            .childOffset = .{
                .x = -scroll.scroll_x,
                .y = -scroll.scroll_y,
            },
        },
        .border = .{},
        .userData = null,
    });
    emitChildren(tree, handle, theme);
    c.Clay__CloseElement();
}

fn emitChildren(tree: *const widget.Tree, parent: widget.NodeHandle, theme: style_mod.Theme) void {
    var iter = tree.children(parent);
    while (iter.next()) |child| {
        emitNode(tree, child, theme);
    }
}

// --- Clay type helpers ---

fn nodeId(handle: widget.NodeHandle) c.Clay_ElementId {
    return c.Clay__HashString(.{
        .isStaticallyAllocated = true,
        .length = 4,
        .chars = "goop",
    }, handle.index, 0);
}

fn clayColor(col: style_mod.Color) c.Clay_Color {
    return .{
        .r = @floatFromInt(col.r),
        .g = @floatFromInt(col.g),
        .b = @floatFromInt(col.b),
        .a = @floatFromInt(col.a),
    };
}

fn clayPadding(edges: style_mod.Edges) c.Clay_Padding {
    return .{
        .left = @intFromFloat(edges.left),
        .right = @intFromFloat(edges.right),
        .top = @intFromFloat(edges.top),
        .bottom = @intFromFloat(edges.bottom),
    };
}

fn clayString(content: []const u8) c.Clay_String {
    return .{
        .isStaticallyAllocated = true,
        .length = @intCast(content.len),
        .chars = content.ptr,
    };
}

fn cornerRadiusAll(r: f32) c.Clay_CornerRadius {
    return .{
        .topLeft = r,
        .topRight = r,
        .bottomLeft = r,
        .bottomRight = r,
    };
}

fn growSizing() c.Clay_SizingAxis {
    return .{
        .size = .{ .minMax = .{ .min = 0, .max = 0 } },
        .type = c.CLAY__SIZING_TYPE_GROW,
    };
}

fn fixedSizing(px: f32) c.Clay_SizingAxis {
    return .{
        .size = .{ .minMax = .{ .min = px, .max = px } },
        .type = c.CLAY__SIZING_TYPE_FIXED,
    };
}

/// Measure the pixel width of text[0..pos].
/// Uses the provided text measurement context if available, otherwise
/// falls back to the rough font_size * 0.6 approximation.
pub fn textWidthUpTo(text: []const u8, pos: usize, font_size: f32, text_ctx: ?*const TextMeasureCtx) f32 {
    const end = @min(pos, text.len);
    if (end == 0) return 0;
    if (text_ctx) |ctx| {
        return ctx.measureFn(text[0..end], font_size, ctx.user_data).width;
    }
    return @as(f32, @floatFromInt(end)) * font_size * 0.6;
}

/// Find the character index in text closest to a given pixel x offset.
/// Iterates through character positions measuring prefixes.
pub fn charIndexAtX(text: []const u8, len: u8, rel_x: f32, font_size: f32, text_ctx: ?*const TextMeasureCtx) u8 {
    if (len == 0 or rel_x <= 0) return 0;

    if (text_ctx) |ctx| {
        var prev_w: f32 = 0;
        for (0..len) |i| {
            const w = ctx.measureFn(text[0 .. i + 1], font_size, ctx.user_data).width;
            const mid = (prev_w + w) / 2;
            if (rel_x < mid) return @intCast(i);
            prev_w = w;
        }
        return len;
    }

    // Fallback: uniform character width
    const char_width = font_size * 0.6;
    const char_pos = if (char_width > 0) rel_x / char_width else 0;
    return @intFromFloat(std.math.clamp(@round(char_pos), 0, @as(f32, @floatFromInt(len))));
}

fn measureText(
    text: c.Clay_StringSlice,
    config: [*c]c.Clay_TextElementConfig,
    user_data: ?*anyopaque,
) callconv(.c) c.Clay_Dimensions {
    const font_size: f32 = @floatFromInt(config.*.fontSize);
    const str = text.chars[0..@intCast(text.length)];

    if (user_data) |ptr| {
        const ctx: *const TextMeasureCtx = @ptrCast(@alignCast(ptr));
        const dims = ctx.measureFn(str, font_size, ctx.user_data);
        return .{ .width = dims.width, .height = dims.height };
    }

    // Fallback: rough approximation when no measurement function is provided
    const char_width = font_size * 0.6;
    const len: f32 = @floatFromInt(text.length);
    return .{
        .width = len * char_width,
        .height = font_size,
    };
}
