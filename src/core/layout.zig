const std = @import("std");
const c = @cImport({
    @cInclude("clay.h");
});
const draw = @import("draw.zig");
const widget = @import("widget.zig");
const style_mod = @import("style.zig");

/// Generic text measurement function.
/// Given a UTF-8 string and font size, return its pixel dimensions.
pub const MeasureTextFn = *const fn (text: []const u8, font_size: f32, user_data: ?*anyopaque) TextDimensions;

pub const TextDimensions = struct {
    width: f32,
    height: f32,
    ascent: f32 = 0,
    descent: f32 = 0,
};

/// Text measurement context: a function pointer + opaque user data.
/// The embedder provides this to get accurate text sizing.
pub const TextMeasureCtx = struct {
    measureFn: MeasureTextFn,
    user_data: ?*anyopaque = null,
};

var active_text_ctx: ?*const TextMeasureCtx = null;

/// Run the layout pass: walk the widget tree, feed elements to clay,
/// compute layout, and write computed rects back to each node.
pub fn run(tree: *widget.Tree, theme: style_mod.Theme, text_ctx: ?*const TextMeasureCtx) void {
    active_text_ctx = text_ctx;
    defer active_text_ctx = null;
    syncTableState(tree);
    c.Clay_SetMeasureTextFunction(&measureText, @ptrCast(@constCast(text_ctx)));
    c.Clay_BeginLayout();

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive) continue;
        if (node.parent == null) {
            emitNode(tree, tree.handleFromIndex(@intCast(i)), theme);
        }
    }

    _ = c.Clay_EndLayout();

    writeBackRects(tree);
    clampPopupRects(tree);
}

pub fn textMetrics(font_size: f32, text_ctx: ?*const TextMeasureCtx) TextDimensions {
    if (text_ctx) |ctx| {
        return normalizeTextDimensions(ctx.measureFn("Mg", font_size, ctx.user_data), font_size);
    }
    return normalizeTextDimensions(.{ .width = 0, .height = font_size }, font_size);
}

pub fn measureTextDimensions(text: []const u8, font_size: f32, text_ctx: ?*const TextMeasureCtx) TextDimensions {
    if (text_ctx) |ctx| {
        return normalizeTextDimensions(ctx.measureFn(text, font_size, ctx.user_data), font_size);
    }
    return normalizeTextDimensions(.{
        .width = @as(f32, @floatFromInt(text.len)) * font_size * 0.6,
        .height = font_size,
    }, font_size);
}

fn controlTextHeight(resolved: style_mod.ResolvedStyle) f32 {
    return textMetrics(resolved.font_size, active_text_ctx).height + resolved.padding.top + resolved.padding.bottom;
}

fn normalizeTextDimensions(raw: TextDimensions, font_size: f32) TextDimensions {
    const fallback_ascent = font_size * 0.8;
    const fallback_descent = font_size * 0.2;

    var dims = raw;
    if (dims.ascent <= 0 and dims.descent <= 0) {
        if (dims.height > 0) {
            dims.ascent = dims.height * 0.8;
            dims.descent = dims.height - dims.ascent;
        } else {
            dims.ascent = fallback_ascent;
            dims.descent = fallback_descent;
            dims.height = font_size;
        }
    } else {
        if (dims.ascent <= 0) dims.ascent = @max(dims.height - dims.descent, fallback_ascent);
        if (dims.descent < 0) dims.descent = 0;
        if (dims.height <= 0) dims.height = dims.ascent + dims.descent;
    }

    if (dims.height <= 0) dims.height = dims.ascent + dims.descent;
    if (dims.height <= 0) dims.height = font_size;
    return dims;
}

fn writeBackRects(tree: *widget.Tree) void {
    for (tree.nodes.items, 0..) |*node, i| {
        if (!node.alive) continue;
        const handle = tree.handleFromIndex(@intCast(i));
        if (!nodeParticipatesInLayout(tree, handle)) {
            node.layout_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
            continue;
        }
        const data = c.Clay_GetElementData(nodeId(handle));
        if (data.found) {
            node.layout_rect = .{
                .x = data.boundingBox.x,
                .y = data.boundingBox.y,
                .w = data.boundingBox.width,
                .h = data.boundingBox.height,
            };
        } else {
            node.layout_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
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
        .tree_item => |tree_item| emitTreeItem(tree, handle, tree_item, resolved, theme),
        .dropdown => |dropdown| emitDropdown(tree, handle, dropdown, resolved, theme),
        .list_box => emitListBox(tree, handle, resolved, theme),
        .selectable => |selectable| emitSelectable(handle, selectable, resolved),
        .table => |table| emitTable(tree, handle, table, resolved, theme),
        .table_row => |row| emitTableRow(tree, handle, row, resolved, theme),
        .table_cell => emitTableCell(tree, handle, resolved, theme),
        .toolbar => emitToolbar(tree, handle, resolved, theme),
        .status_bar => emitStatusBar(tree, handle, resolved, theme),
        .menu_bar => emitMenuBar(tree, handle, resolved, theme),
        .menu => |menu| emitMenu(tree, handle, menu, resolved, theme),
        .popup => |popup| emitPopup(tree, handle, popup, resolved, theme),
        .tooltip => |tooltip| emitTooltip(tree, handle, tooltip, resolved, theme),
        .menu_item => |menu_item| emitMenuItem(tree, handle, menu_item, resolved, theme),
        .drag_value => emitDragValue(handle, &node.kind.drag_value, resolved),
        .spinbox => emitSpinBox(handle, &node.kind.spinbox, resolved),
        .tab_bar => |tab_bar| emitTabBar(tree, handle, tab_bar, resolved, theme),
        .tab_item => |tab_item| emitTabItem(tree, handle, tab_item, resolved, theme),
        .splitter => |splitter| emitSplitter(tree, handle, splitter, resolved, theme),
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
            .childAlignment = switch (cont.direction) {
                .row => .{ .y = c.CLAY_ALIGN_Y_CENTER },
                .column => .{},
            },
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

fn emitTreeItem(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    item: widget.WidgetKind.TreeItem,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    const node = tree.getConst(handle);
    const label = if (item.editing) node.kind.tree_item.editor.content() else item.label;
    const depth = treeDepth(tree, handle);
    const left_indent = @as(f32, @floatFromInt(depth)) * treeIndent(theme, resolved);
    var header_padding = resolved.padding;
    header_padding.left += left_indent + disclosureSlotWidth(resolved);

    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = fixedSizing(controlTextHeight(resolved)),
            },
            .padding = clayPadding(header_padding),
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
        clayString(label),
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

    if (item.expanded) emitChildrenSkippingPopups(tree, handle, theme);
    emitPopupChildren(tree, handle, theme);
}

fn emitDropdown(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    dropdown: widget.WidgetKind.Dropdown,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    const label = if (dropdown.selected_text.len > 0)
        dropdown.selected_text
    else
        dropdown.placeholder;

    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = .{},
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = .{},
            },
            .padding = .{},
            .childGap = 0,
            .childAlignment = .{},
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
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

    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = fixedSizing(controlTextHeight(resolved)),
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
        clayString(label),
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

    if (dropdown.open) emitPopupChildren(tree, handle, theme);
    c.Clay__CloseElement();
}

fn emitListBox(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = .{},
            },
            .padding = clayPadding(resolved.padding),
            .childGap = 0,
            .childAlignment = .{},
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
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
    emitChildren(tree, handle, theme);
    c.Clay__CloseElement();
}

fn emitSelectable(
    handle: widget.NodeHandle,
    selectable: widget.WidgetKind.Selectable,
    resolved: style_mod.ResolvedStyle,
) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = fixedSizing(controlTextHeight(resolved)),
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
        clayString(selectable.label),
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

fn emitTable(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    table: widget.WidgetKind.Table,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    _ = table;
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = .{},
            },
            .padding = clayPadding(resolved.padding),
            .childGap = 0,
            .childAlignment = .{},
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
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
    emitChildrenSkippingPopups(tree, handle, theme);
    c.Clay__CloseElement();
}

fn emitTableRow(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    row: widget.WidgetKind.TableRow,
    _: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    _ = row;
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = .{},
            },
            .padding = .{},
            .childGap = 0,
            .childAlignment = .{},
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
    emitTableRowCells(tree, handle, theme);
    c.Clay__CloseElement();
}

fn emitTableCell(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = .{},
            },
            .padding = clayPadding(resolved.padding),
            .childGap = @intFromFloat(theme.spacing),
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
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
    emitChildrenSkippingPopups(tree, handle, theme);
    c.Clay__CloseElement();
}

fn emitMenuBar(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = .{},
            },
            .padding = clayPadding(resolved.padding),
            .childGap = @intFromFloat(theme.spacing),
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
    emitChildrenSkippingPopups(tree, handle, theme);
    emitPopupChildren(tree, handle, theme);
    c.Clay__CloseElement();
}

fn emitToolbar(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = .{},
            },
            .padding = clayPadding(resolved.padding),
            .childGap = @intFromFloat(theme.spacing),
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
        },
        .backgroundColor = clayColor(resolved.bg),
        .cornerRadius = cornerRadiusAll(0),
        .aspectRatio = .{},
        .image = .{},
        .floating = .{},
        .custom = .{},
        .clip = .{},
        .border = .{},
        .userData = null,
    });
    emitChildrenSkippingPopups(tree, handle, theme);
    c.Clay__CloseElement();
}

fn emitStatusBar(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = .{},
            },
            .padding = clayPadding(resolved.padding),
            .childGap = @intFromFloat(theme.spacing * 2),
            .childAlignment = .{ .y = c.CLAY_ALIGN_Y_CENTER },
            .layoutDirection = c.CLAY_LEFT_TO_RIGHT,
        },
        .backgroundColor = clayColor(resolved.bg),
        .cornerRadius = cornerRadiusAll(0),
        .aspectRatio = .{},
        .image = .{},
        .floating = .{},
        .custom = .{},
        .clip = .{},
        .border = .{},
        .userData = null,
    });
    emitChildrenSkippingPopups(tree, handle, theme);
    c.Clay__CloseElement();
}

fn emitMenu(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    menu: widget.WidgetKind.Menu,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = .{},
                .height = fixedSizing(controlTextHeight(resolved)),
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
        clayString(menu.label),
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

    emitPopupChildren(tree, handle, theme);
}

fn emitPopup(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    popup: widget.WidgetKind.Popup,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    if (!popupShouldRender(tree, handle)) return;

    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = popupSizing(tree, handle),
            .padding = clayPadding(resolved.padding),
            .childGap = @intFromFloat(theme.spacing),
            .childAlignment = .{},
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
        },
        .backgroundColor = clayColor(resolved.bg),
        .cornerRadius = cornerRadiusAll(resolved.border_radius),
        .aspectRatio = .{},
        .image = .{},
        .floating = popupFloatingConfig(tree, handle, popup),
        .custom = .{},
        .clip = .{},
        .border = .{},
        .userData = null,
    });
    emitChildren(tree, handle, theme);
    c.Clay__CloseElement();
}

fn emitTooltip(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    tooltip: widget.WidgetKind.Tooltip,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    if (!tooltipShouldRender(tree, handle)) return;

    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{},
            .padding = clayPadding(resolved.padding),
            .childGap = @intFromFloat(theme.spacing),
            .childAlignment = .{},
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
        },
        .backgroundColor = clayColor(resolved.bg),
        .cornerRadius = cornerRadiusAll(resolved.border_radius),
        .aspectRatio = .{},
        .image = .{},
        .floating = tooltipFloatingConfig(tree, handle, tooltip),
        .custom = .{},
        .clip = .{},
        .border = .{},
        .userData = null,
    });
    emitChildren(tree, handle, theme);
    c.Clay__CloseElement();
}

fn emitMenuItem(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    item: widget.WidgetKind.MenuItem,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    var padding = resolved.padding;
    if (directPopupChild(tree, handle) != null) {
        padding.right += resolved.font_size;
    }
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = fixedSizing(controlTextHeight(resolved)),
            },
            .padding = clayPadding(padding),
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
        clayString(item.label),
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

    emitPopupChildren(tree, handle, theme);
}

fn emitDragValue(handle: widget.NodeHandle, drag_value: *const widget.WidgetKind.DragValue, resolved: style_mod.ResolvedStyle) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = fixedSizing(controlTextHeight(resolved)),
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
        clayString(drag_value.displayValue()),
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

fn emitSpinBox(handle: widget.NodeHandle, spinbox: *const widget.WidgetKind.SpinBox, resolved: style_mod.ResolvedStyle) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = fixedSizing(controlTextHeight(resolved)),
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
        clayString(spinbox.displayValue()),
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

fn emitTabBar(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    _: widget.WidgetKind.TabBar,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = .{},
            },
            .padding = .{},
            .childGap = 0,
            .childAlignment = .{},
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
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

    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = .{},
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = .{},
            },
            .padding = .{},
            .childGap = @intFromFloat(theme.spacing),
            .childAlignment = .{},
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

    var iter = tree.children(handle);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (child_node.kind != .tab_item) continue;
        emitTabItemHeader(child, child_node.kind.tab_item, child_node.style_override.resolve(theme));
    }
    c.Clay__CloseElement();

    if (selectedTabItem(tree, handle)) |selected| {
        c.Clay__OpenElement();
        c.Clay__ConfigureOpenElement(.{
            .id = .{},
            .layout = .{
                .sizing = .{
                    .width = growSizing(),
                    .height = .{},
                },
                .padding = clayPadding(resolved.padding),
                .childGap = @intFromFloat(theme.spacing),
                .childAlignment = .{},
                .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
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
        emitChildren(tree, selected, theme);
        c.Clay__CloseElement();
    }

    c.Clay__CloseElement();
}

fn emitTabItem(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    item: widget.WidgetKind.TabItem,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    emitTabItemHeader(handle, item, resolved);
    if (item.selected) emitChildren(tree, handle, theme);
}

fn emitTabItemHeader(handle: widget.NodeHandle, item: widget.WidgetKind.TabItem, resolved: style_mod.ResolvedStyle) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{},
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
        clayString(item.label),
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

fn emitSplitter(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    splitter: widget.WidgetKind.Splitter,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    const panes = splitterPaneChildren(tree, handle);
    const ratio = splitterLayoutRatio(tree, handle, splitter, resolved);

    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = growSizing(),
            },
            .padding = clayPadding(resolved.padding),
            .childGap = 0,
            .childAlignment = .{},
            .layoutDirection = switch (splitter.direction) {
                .row => c.CLAY_LEFT_TO_RIGHT,
                .column => c.CLAY_TOP_TO_BOTTOM,
            },
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

    emitSplitterPaneOpen(splitter.direction, ratio);
    if (panes.first) |child| emitNode(tree, child, theme);
    c.Clay__CloseElement();

    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = .{},
        .layout = .{
            .sizing = splitterHandleSizing(splitter.direction, splitter.thickness),
            .padding = .{},
            .childGap = 0,
            .childAlignment = .{},
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
    c.Clay__CloseElement();

    emitSplitterPaneOpen(splitter.direction, std.math.clamp(1 - ratio, 0, 1));
    if (panes.second) |child| emitNode(tree, child, theme);
    c.Clay__CloseElement();

    c.Clay__CloseElement();
    emitPopupChildren(tree, handle, theme);
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
                .height = fixedSizing(controlTextHeight(resolved)),
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

fn emitChildrenSkippingPopups(tree: *const widget.Tree, parent: widget.NodeHandle, theme: style_mod.Theme) void {
    var iter = tree.children(parent);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .popup) continue;
        emitNode(tree, child, theme);
    }
}

fn emitPopupChildren(tree: *const widget.Tree, parent: widget.NodeHandle, theme: style_mod.Theme) void {
    var iter = tree.children(parent);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .popup and tree.getConst(child).kind != .tooltip) continue;
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

fn percentSizing(percent: f32) c.Clay_SizingAxis {
    return .{
        .size = .{ .percent = std.math.clamp(percent, 0, 1) },
        .type = c.CLAY__SIZING_TYPE_PERCENT,
    };
}

fn emitTableRowCells(tree: *const widget.Tree, row: widget.NodeHandle, theme: style_mod.Theme) void {
    const table_handle = tree.getConst(row).parent orelse return;
    const table = tree.getConst(table_handle).kind.table;
    const columns = @max(table.active_columns, @as(u8, 1));

    var cell_index: u8 = 0;
    var iter = tree.children(row);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .popup or tree.getConst(child).kind == .tooltip) continue;

        const slot_percent = table.columnWeight(cell_index) orelse (1.0 / @as(f32, @floatFromInt(columns)));
        cell_index += 1;

        c.Clay__OpenElement();
        c.Clay__ConfigureOpenElement(.{
            .id = .{},
            .layout = .{
                .sizing = .{
                    .width = percentSizing(slot_percent),
                    .height = .{},
                },
                .padding = .{},
                .childGap = 0,
                .childAlignment = .{},
                .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
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
        emitNode(tree, child, theme);
        c.Clay__CloseElement();
    }
}

fn countNonPopupChildren(tree: *const widget.Tree, parent: widget.NodeHandle) u16 {
    var count: u16 = 0;
    var iter = tree.children(parent);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .popup or tree.getConst(child).kind == .tooltip) continue;
        count += 1;
    }
    return count;
}

fn syncTableState(tree: *widget.Tree) void {
    for (tree.nodes.items, 0..) |*node, i| {
        if (!node.alive or node.kind != .table) continue;
        const handle = tree.handleFromIndex(@intCast(i));
        node.kind.table.syncColumns(@intCast(widget.tableEffectiveColumnCount(tree, handle)));
    }
}

fn directPopupChild(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .popup) return child;
    }
    return null;
}

fn emitSplitterPaneOpen(direction: widget.WidgetKind.Container.Direction, ratio: f32) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = .{},
        .layout = .{
            .sizing = switch (direction) {
                .row => .{
                    .width = percentSizing(ratio),
                    .height = growSizing(),
                },
                .column => .{
                    .width = growSizing(),
                    .height = percentSizing(ratio),
                },
            },
            .padding = .{},
            .childGap = 0,
            .childAlignment = .{},
            .layoutDirection = c.CLAY_TOP_TO_BOTTOM,
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
}

fn splitterHandleSizing(direction: widget.WidgetKind.Container.Direction, thickness: f32) c.Clay_Sizing {
    return switch (direction) {
        .row => .{
            .width = fixedSizing(thickness),
            .height = growSizing(),
        },
        .column => .{
            .width = growSizing(),
            .height = fixedSizing(thickness),
        },
    };
}

fn splitterPaneChildren(tree: *const widget.Tree, handle: widget.NodeHandle) struct {
    first: ?widget.NodeHandle,
    second: ?widget.NodeHandle,
} {
    var first: ?widget.NodeHandle = null;
    var second: ?widget.NodeHandle = null;

    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .popup or tree.getConst(child).kind == .tooltip) continue;
        if (first == null) {
            first = child;
        } else if (second == null) {
            second = child;
            break;
        }
    }
    return .{ .first = first, .second = second };
}

fn splitterLayoutRatio(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    splitter: widget.WidgetKind.Splitter,
    resolved: style_mod.ResolvedStyle,
) f32 {
    return clampedSplitterRatio(splitter, tree.getConst(handle).layout_rect, resolved);
}

fn clampedSplitterRatio(
    splitter: widget.WidgetKind.Splitter,
    rect: draw.Rect,
    resolved: style_mod.ResolvedStyle,
) f32 {
    const raw = std.math.clamp(splitter.ratio, 0, 1);
    const available = splitterAvailableExtent(splitter, rect, resolved);
    if (available <= 0) return raw;

    const min_ratio = std.math.clamp(splitter.min_first / available, 0, 1);
    const max_ratio = std.math.clamp(1 - splitter.min_second / available, 0, 1);
    if (min_ratio > max_ratio) return raw;
    return std.math.clamp(raw, min_ratio, max_ratio);
}

fn splitterAvailableExtent(
    splitter: widget.WidgetKind.Splitter,
    rect: draw.Rect,
    resolved: style_mod.ResolvedStyle,
) f32 {
    return switch (splitter.direction) {
        .row => rect.w - resolved.padding.left - resolved.padding.right - splitter.thickness,
        .column => rect.h - resolved.padding.top - resolved.padding.bottom - splitter.thickness,
    };
}

fn popupSizing(tree: *const widget.Tree, handle: widget.NodeHandle) c.Clay_Sizing {
    if (tree.getConst(handle).parent) |parent_handle| {
        const parent = tree.getConst(parent_handle);
        if (parent.kind == .dropdown and parent.layout_rect.w > 0) {
            return .{
                .width = fixedSizing(parent.layout_rect.w),
                .height = .{},
            };
        }
    }
    return .{};
}

fn treeDepth(tree: *const widget.Tree, handle: widget.NodeHandle) u32 {
    var depth: u32 = 0;
    var current = tree.getConst(handle).parent;
    while (current) |parent_handle| {
        const parent = tree.getConst(parent_handle);
        if (parent.kind == .tree_item) depth += 1;
        current = parent.parent;
    }
    return depth;
}

fn treeIndent(theme: style_mod.Theme, resolved: style_mod.ResolvedStyle) f32 {
    return resolved.font_size + theme.spacing;
}

fn disclosureSlotWidth(resolved: style_mod.ResolvedStyle) f32 {
    return resolved.font_size + 4;
}

fn selectedTabItem(tree: *const widget.Tree, parent: widget.NodeHandle) ?widget.NodeHandle {
    var iter = tree.children(parent);
    while (iter.next()) |child| {
        const node = tree.getConst(child);
        if (node.kind == .tab_item and node.kind.tab_item.selected) return child;
    }
    return null;
}

fn formatScalar(buf: *[64]u8, value: f32, precision: u8) []const u8 {
    return switch (@min(precision, 4)) {
        0 => std.fmt.bufPrint(buf, "{d:.0}", .{value}) catch "0",
        1 => std.fmt.bufPrint(buf, "{d:.1}", .{value}) catch "0.0",
        2 => std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch "0.00",
        3 => std.fmt.bufPrint(buf, "{d:.3}", .{value}) catch "0.000",
        else => std.fmt.bufPrint(buf, "{d:.4}", .{value}) catch "0.0000",
    };
}

fn popupShouldRender(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    const popup = node.kind.popup;
    if (!popup.visible) return false;

    if (node.parent) |parent_handle| {
        const parent = tree.getConst(parent_handle);
        if (parent.kind == .dropdown) {
            return parent.kind.dropdown.open;
        }
    }
    return true;
}

fn tooltipShouldRender(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    const owner_handle = node.parent orelse return false;
    const owner = tree.getConst(owner_handle);
    return owner.interaction.hovered or owner.interaction.focused;
}

fn nodeParticipatesInLayout(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    var current = handle;
    while (true) {
        const node = tree.getConst(current);
        if (node.kind == .popup and !popupShouldRender(tree, current)) return false;
        if (node.kind == .tooltip and !tooltipShouldRender(tree, current)) return false;

        const parent_handle = node.parent orelse return true;
        const parent = tree.getConst(parent_handle);

        switch (parent.kind) {
            .tree_item => {
                if (!parent.kind.tree_item.expanded and node.kind != .popup and node.kind != .tooltip) return false;
            },
            .tab_item => {
                if (!parent.kind.tab_item.selected) return false;
            },
            .dropdown => {
                if (node.kind == .popup and !parent.kind.dropdown.open) return false;
            },
            else => {},
        }

        current = parent_handle;
    }
}

fn popupFloatingConfig(tree: *const widget.Tree, handle: widget.NodeHandle, popup: widget.WidgetKind.Popup) c.Clay_FloatingElementConfig {
    return floatingConfigForPlacement(
        tree.getConst(handle).parent != null and popup.placement != .absolute,
        popup.placement,
        popup.x,
        popup.y,
        popup.z_index,
        popup.pointer_passthrough,
    );
}

fn tooltipFloatingConfig(tree: *const widget.Tree, handle: widget.NodeHandle, tooltip: widget.WidgetKind.Tooltip) c.Clay_FloatingElementConfig {
    return floatingConfigForPlacement(
        tree.getConst(handle).parent != null and tooltip.placement != .absolute,
        tooltip.placement,
        tooltip.x,
        tooltip.y,
        tooltip.z_index,
        true,
    );
}

fn floatingConfigForPlacement(
    attach_to_parent: bool,
    placement: widget.WidgetKind.Popup.Placement,
    x: f32,
    y: f32,
    z_index: i16,
    pointer_passthrough: bool,
) c.Clay_FloatingElementConfig {
    var attach_points = c.Clay_FloatingAttachPoints{
        .element = c.CLAY_ATTACH_POINT_LEFT_TOP,
        .parent = c.CLAY_ATTACH_POINT_LEFT_TOP,
    };
    switch (placement) {
        .absolute => {},
        .below_start => {
            attach_points.parent = c.CLAY_ATTACH_POINT_LEFT_BOTTOM;
        },
        .below_end => {
            attach_points.element = c.CLAY_ATTACH_POINT_RIGHT_TOP;
            attach_points.parent = c.CLAY_ATTACH_POINT_RIGHT_BOTTOM;
        },
        .right_start => {
            attach_points.parent = c.CLAY_ATTACH_POINT_RIGHT_TOP;
        },
    }

    return .{
        .offset = .{ .x = x, .y = y },
        .expand = .{},
        .parentId = 0,
        .zIndex = z_index,
        .attachPoints = attach_points,
        .pointerCaptureMode = if (pointer_passthrough)
            c.CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH
        else
            c.CLAY_POINTER_CAPTURE_MODE_CAPTURE,
        .attachTo = if (attach_to_parent)
            c.CLAY_ATTACH_TO_PARENT
        else
            c.CLAY_ATTACH_TO_ROOT,
        .clipTo = c.CLAY_CLIP_TO_NONE,
    };
}

fn clampPopupRects(tree: *widget.Tree) void {
    const viewport = popupViewport(tree) orelse return;

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive or (node.kind != .popup and node.kind != .tooltip)) continue;
        const handle = tree.handleFromIndex(@intCast(i));
        if (node.kind == .popup and !popupShouldRender(tree, handle)) continue;
        if (node.kind == .tooltip and !tooltipShouldRender(tree, handle)) continue;
        clampPopupSubtree(tree, handle, viewport);
    }
}

fn popupViewport(tree: *const widget.Tree) ?draw.Rect {
    var viewport: ?draw.Rect = null;

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive or node.parent != null or node.kind == .popup or node.kind == .tooltip) continue;
        const rect = tree.handleFromIndex(@intCast(i));
        viewport = unionRect(viewport, tree.getConst(rect).layout_rect);
    }

    if (viewport == null) {
        for (tree.nodes.items, 0..) |node, i| {
            if (!node.alive or node.parent != null) continue;
            const handle = tree.handleFromIndex(@intCast(i));
            viewport = unionRect(viewport, tree.getConst(handle).layout_rect);
        }
    }

    return viewport;
}

fn clampPopupSubtree(tree: *widget.Tree, handle: widget.NodeHandle, viewport: draw.Rect) void {
    const bounds = popupSubtreeBounds(tree, handle) orelse return;

    var dx: f32 = 0;
    if (bounds.w > viewport.w) {
        dx = viewport.x - bounds.x;
    } else if (bounds.x < viewport.x) {
        dx = viewport.x - bounds.x;
    } else if (bounds.x + bounds.w > viewport.x + viewport.w) {
        dx = viewport.x + viewport.w - (bounds.x + bounds.w);
    }

    var dy: f32 = 0;
    if (bounds.h > viewport.h) {
        dy = viewport.y - bounds.y;
    } else if (bounds.y < viewport.y) {
        dy = viewport.y - bounds.y;
    } else if (bounds.y + bounds.h > viewport.y + viewport.h) {
        dy = viewport.y + viewport.h - (bounds.y + bounds.h);
    }

    if (dx != 0 or dy != 0) shiftSubtree(tree, handle, dx, dy);
}

fn popupSubtreeBounds(tree: *const widget.Tree, handle: widget.NodeHandle) ?draw.Rect {
    const node = tree.getConst(handle);
    if (node.layout_rect.w <= 0 or node.layout_rect.h <= 0) return null;

    var bounds = node.layout_rect;
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (popupSubtreeBounds(tree, child)) |child_bounds| {
            bounds = unionRect(bounds, child_bounds).?;
        }
    }
    return bounds;
}

fn shiftSubtree(tree: *widget.Tree, handle: widget.NodeHandle, dx: f32, dy: f32) void {
    const node = tree.get(handle);
    node.layout_rect.x += dx;
    node.layout_rect.y += dy;

    var iter = tree.children(handle);
    while (iter.next()) |child| {
        shiftSubtree(tree, child, dx, dy);
    }
}

fn unionRect(current: ?draw.Rect, next: draw.Rect) ?draw.Rect {
    if (next.w <= 0 or next.h <= 0) return current;
    if (current == null) return next;

    const c_rect = current.?;
    const left = @min(c_rect.x, next.x);
    const top = @min(c_rect.y, next.y);
    const right = @max(c_rect.x + c_rect.w, next.x + next.w);
    const bottom = @max(c_rect.y + c_rect.h, next.y + next.h);
    return .{
        .x = left,
        .y = top,
        .w = right - left,
        .h = bottom - top,
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
    const text_len: usize = @min(@as(usize, len), text.len);
    if (text_len == 0 or rel_x <= 0) return 0;

    const safe_text = text[0..text_len];
    const view = std.unicode.Utf8View.init(safe_text) catch {
        if (text_ctx) |ctx| {
            var prev_w: f32 = 0;
            for (0..text_len) |i| {
                const w = ctx.measureFn(safe_text[0 .. i + 1], font_size, ctx.user_data).width;
                const mid = (prev_w + w) / 2;
                if (rel_x < mid) return @intCast(i);
                prev_w = w;
            }
            return @intCast(text_len);
        }

        const char_width = font_size * 0.6;
        const char_pos = if (char_width > 0) rel_x / char_width else 0;
        return @intFromFloat(std.math.clamp(@round(char_pos), 0, @as(f32, @floatFromInt(text_len))));
    };

    var iter = view.iterator();
    var prev_w: f32 = 0;
    var byte_index: usize = 0;
    while (iter.nextCodepointSlice()) |slice| {
        const next_index = byte_index + slice.len;
        const w = if (text_ctx) |ctx|
            ctx.measureFn(safe_text[0..next_index], font_size, ctx.user_data).width
        else
            prev_w + font_size * 0.6;
        const mid = (prev_w + w) / 2;
        if (rel_x < mid) return @intCast(byte_index);
        prev_w = w;
        byte_index = next_index;
    }
    return @intCast(text_len);
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
        const normalized = normalizeTextDimensions(dims, font_size);
        return .{ .width = normalized.width, .height = normalized.height };
    }

    // Fallback: rough approximation when no measurement function is provided
    const char_width = font_size * 0.6;
    const len: f32 = @floatFromInt(text.length);
    return .{
        .width = len * char_width,
        .height = font_size,
    };
}

test "popup layout is clamped into the viewport" {
    const allocator = std.testing.allocator;
    const min_memory = c.Clay_MinMemorySize();
    const arena = try allocator.alloc(u8, min_memory);
    defer allocator.free(arena);

    const clay_arena = c.Clay_Arena{
        .capacity = min_memory,
        .memory = arena.ptr,
    };
    _ = c.Clay_Initialize(clay_arena, .{
        .width = 200,
        .height = 120,
    }, .{});
    defer c.Clay_SetCurrentContext(null);

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const popup = try tree.addRoot(.{ .popup = .{ .placement = .absolute, .x = 190, .y = 110 } });
    _ = try tree.addChild(root, .{ .text = .{ .content = "root" } });
    _ = try tree.addChild(popup, .{ .menu_item = .{ .label = "Item" } });

    run(&tree, style_mod.Theme.default, null);

    const root_rect = tree.getConst(root).layout_rect;
    const popup_rect = tree.getConst(popup).layout_rect;
    try std.testing.expect(popup_rect.x + popup_rect.w <= root_rect.x + root_rect.w + 0.01);
    try std.testing.expect(popup_rect.y + popup_rect.h <= root_rect.y + root_rect.h + 0.01);
}

test "splitter layout assigns both panes" {
    const allocator = std.testing.allocator;
    const min_memory = c.Clay_MinMemorySize();
    const arena = try allocator.alloc(u8, min_memory);
    defer allocator.free(arena);

    const clay_arena = c.Clay_Arena{
        .capacity = min_memory,
        .memory = arena.ptr,
    };
    _ = c.Clay_Initialize(clay_arena, .{
        .width = 320,
        .height = 180,
    }, .{});
    defer c.Clay_SetCurrentContext(null);

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const splitter = try tree.addChild(root, .{ .splitter = .{
        .direction = .row,
        .ratio = 0.4,
        .min_first = 60,
        .min_second = 60,
        .thickness = 8,
    } });
    const left = try tree.addChild(splitter, .{ .container = .{} });
    const right = try tree.addChild(splitter, .{ .container = .{} });
    _ = try tree.addChild(left, .{ .text = .{ .content = "Left" } });
    _ = try tree.addChild(right, .{ .text = .{ .content = "Right" } });

    run(&tree, style_mod.Theme.default, null);

    const splitter_rect = tree.getConst(splitter).layout_rect;
    const left_rect = tree.getConst(left).layout_rect;
    const right_rect = tree.getConst(right).layout_rect;
    try std.testing.expect(splitter_rect.w > 0 and splitter_rect.h > 0);
    try std.testing.expect(left_rect.w > 0 and left_rect.h > 0);
    try std.testing.expect(right_rect.w > 0 and right_rect.h > 0);
    try std.testing.expect(left_rect.x < right_rect.x);
}

test "row containers center children vertically" {
    const allocator = std.testing.allocator;
    const min_memory = c.Clay_MinMemorySize();
    const arena = try allocator.alloc(u8, min_memory);
    defer allocator.free(arena);

    const clay_arena = c.Clay_Arena{
        .capacity = min_memory,
        .memory = arena.ptr,
    };
    _ = c.Clay_Initialize(clay_arena, .{
        .width = 320,
        .height = 120,
    }, .{});
    defer c.Clay_SetCurrentContext(null);

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const row = try tree.addChild(root, .{ .container = .{ .direction = .row } });
    const label = try tree.addChild(row, .{ .text = .{ .content = "Exposure" } });
    const value = try tree.addChild(row, .{ .drag_value = .{
        .value = 1.25,
        .precision = 2,
    } });

    run(&tree, style_mod.Theme.default, null);

    const label_rect = tree.getConst(label).layout_rect;
    const value_rect = tree.getConst(value).layout_rect;
    const label_center_y = label_rect.y + label_rect.h * 0.5;
    const value_center_y = value_rect.y + value_rect.h * 0.5;

    try std.testing.expect(value_rect.h > label_rect.h);
    try std.testing.expectApproxEqAbs(value_center_y, label_center_y, 0.01);
}
