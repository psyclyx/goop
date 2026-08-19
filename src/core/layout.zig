const std = @import("std");
const c = @cImport({
    @cInclude("clay.h");
});
const visual_types = @import("visual_types.zig");
const widget = @import("widget.zig");
const style_mod = @import("style.zig");
const geometry = @import("geometry.zig");

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

/// Run the layout pass: walk the widget tree, feed elements to clay,
/// compute layout, and write computed rects back to each node.
pub fn run(tree: *widget.Tree, theme: style_mod.Theme, text_ctx: ?*const TextMeasureCtx) void {
    syncTableState(tree);
    c.Clay_SetMeasureTextFunction(&measureText, @ptrCast(@constCast(text_ctx)));
    const had_unresolved_splitters = hasUnresolvedSplitterRects(tree);

    performLayoutPass(tree, theme);
    writeBackRects(tree);

    const splitter_relayout_needed = had_unresolved_splitters and splitterClampWouldChange(tree, theme);
    if (splitter_relayout_needed or syncGridSelectorLayout(tree, theme)) {
        performLayoutPass(tree, theme);
        writeBackRects(tree);
        _ = syncGridSelectorLayout(tree, theme);
    } else {
        _ = syncGridSelectorLayout(tree, theme);
    }
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
        const measured = normalizeTextDimensions(ctx.measureFn(text, font_size, ctx.user_data), font_size);
        const metrics = textMetrics(font_size, text_ctx);
        return .{
            .width = measured.width,
            .height = metrics.height,
            .ascent = metrics.ascent,
            .descent = metrics.descent,
        };
    }
    return normalizeTextDimensions(.{
        .width = @as(f32, @floatFromInt(text.len)) * font_size * 0.6,
        .height = font_size,
    }, font_size);
}

fn controlTextHeight(resolved: style_mod.ResolvedStyle) f32 {
    return textMetrics(resolved.font_size, currentTextMeasureCtx()).height + resolved.padding.top + resolved.padding.bottom;
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

fn currentTextMeasureCtx() ?*const TextMeasureCtx {
    const user_data = c.Clay_GetMeasureTextUserData() orelse return null;
    return @ptrCast(@alignCast(user_data));
}

fn performLayoutPass(tree: *widget.Tree, theme: style_mod.Theme) void {
    c.Clay_BeginLayout();

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive) continue;
        if (node.parent == null) {
            emitNode(tree, tree.handleFromIndex(@intCast(i)), theme);
        }
    }

    _ = c.Clay_EndLayout();
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
    layoutEmitter(node.kind)(tree, handle, node, resolved, theme);
}

const LayoutEmitter = *const fn (*const widget.Tree, widget.NodeHandle, *const widget.Node, style_mod.ResolvedStyle, style_mod.Theme) void;

fn layoutEmitter(kind: widget.WidgetKind) LayoutEmitter {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return layout_emitters[@intFromEnum(tag)];
}

const layout_emitters = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var emitters: [std.meta.fields(Tag).len]LayoutEmitter = undefined;
    emitters[@intFromEnum(Tag.container)] = emitContainerNode;
    emitters[@intFromEnum(Tag.text)] = emitTextNode;
    emitters[@intFromEnum(Tag.icon)] = emitIconNode;
    emitters[@intFromEnum(Tag.button)] = emitButtonNode;
    emitters[@intFromEnum(Tag.checkbox)] = emitCheckboxNode;
    emitters[@intFromEnum(Tag.radio_button)] = emitRadioButtonNode;
    emitters[@intFromEnum(Tag.tree_item)] = emitTreeItemNode;
    emitters[@intFromEnum(Tag.dropdown)] = emitDropdownNode;
    emitters[@intFromEnum(Tag.list_box)] = emitListBoxNode;
    emitters[@intFromEnum(Tag.selectable)] = emitSelectableNode;
    emitters[@intFromEnum(Tag.grid_selector)] = emitGridSelectorNode;
    emitters[@intFromEnum(Tag.grid_item)] = emitGridItemNode;
    emitters[@intFromEnum(Tag.table)] = emitTableNode;
    emitters[@intFromEnum(Tag.table_row)] = emitTableRowNode;
    emitters[@intFromEnum(Tag.table_cell)] = emitTableCellNode;
    emitters[@intFromEnum(Tag.toolbar)] = emitToolbarNode;
    emitters[@intFromEnum(Tag.status_bar)] = emitStatusBarNode;
    emitters[@intFromEnum(Tag.menu_bar)] = emitMenuBarNode;
    emitters[@intFromEnum(Tag.menu)] = emitMenuNode;
    emitters[@intFromEnum(Tag.popup)] = emitPopupNode;
    emitters[@intFromEnum(Tag.tooltip)] = emitTooltipNode;
    emitters[@intFromEnum(Tag.menu_item)] = emitMenuItemNode;
    emitters[@intFromEnum(Tag.drag_value)] = emitDragValueNode;
    emitters[@intFromEnum(Tag.spinbox)] = emitSpinBoxNode;
    emitters[@intFromEnum(Tag.tab_bar)] = emitTabBarNode;
    emitters[@intFromEnum(Tag.tab_item)] = emitTabItemNode;
    emitters[@intFromEnum(Tag.splitter)] = emitSplitterNode;
    emitters[@intFromEnum(Tag.slider)] = emitSliderNode;
    emitters[@intFromEnum(Tag.spacer)] = emitSpacerNode;
    emitters[@intFromEnum(Tag.scroll_area)] = emitScrollAreaNode;
    emitters[@intFromEnum(Tag.text_input)] = emitTextInputNode;
    emitters[@intFromEnum(Tag.custom)] = emitCustomNode;
    break :blk emitters;
};

fn emitContainerNode(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitContainer(tree, handle, node.kind.container, resolved, theme);
}

fn emitTextNode(_: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, _: style_mod.Theme) void {
    emitText(handle, node.kind.text, resolved);
}

fn emitIconNode(_: *const widget.Tree, handle: widget.NodeHandle, _: *const widget.Node, resolved: style_mod.ResolvedStyle, _: style_mod.Theme) void {
    emitIcon(handle, resolved);
}

fn emitButtonNode(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitButton(tree, handle, node.kind.button, resolved, theme);
}

fn emitCheckboxNode(_: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, _: style_mod.Theme) void {
    emitCheckbox(handle, node.kind.checkbox, resolved);
}

fn emitRadioButtonNode(_: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, _: style_mod.Theme) void {
    emitRadioButton(handle, node.kind.radio_button, resolved);
}

fn emitTreeItemNode(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitTreeItem(tree, handle, node.kind.tree_item, resolved, theme);
}

fn emitDropdownNode(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitDropdown(tree, handle, node.kind.dropdown, resolved, theme);
}

fn emitListBoxNode(tree: *const widget.Tree, handle: widget.NodeHandle, _: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitListBox(tree, handle, resolved, theme);
}

fn emitSelectableNode(_: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, _: style_mod.Theme) void {
    emitSelectable(handle, node.kind.selectable, resolved);
}

fn emitGridSelectorNode(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitGridSelector(tree, handle, node.kind.grid_selector, resolved, theme);
}

fn emitGridItemNode(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, _: style_mod.Theme) void {
    emitGridItem(tree, handle, node.kind.grid_item, resolved);
}

fn emitTableNode(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitTable(tree, handle, node.kind.table, resolved, theme);
}

fn emitTableRowNode(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitTableRow(tree, handle, node.kind.table_row, resolved, theme);
}

fn emitTableCellNode(tree: *const widget.Tree, handle: widget.NodeHandle, _: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitTableCell(tree, handle, resolved, theme);
}

fn emitToolbarNode(tree: *const widget.Tree, handle: widget.NodeHandle, _: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitToolbar(tree, handle, resolved, theme);
}

fn emitStatusBarNode(tree: *const widget.Tree, handle: widget.NodeHandle, _: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitStatusBar(tree, handle, resolved, theme);
}

fn emitMenuBarNode(tree: *const widget.Tree, handle: widget.NodeHandle, _: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitMenuBar(tree, handle, resolved, theme);
}

fn emitMenuNode(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitMenu(tree, handle, node.kind.menu, resolved, theme);
}

fn emitPopupNode(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitPopup(tree, handle, node.kind.popup, resolved, theme);
}

fn emitTooltipNode(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitTooltip(tree, handle, node.kind.tooltip, resolved, theme);
}

fn emitMenuItemNode(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitMenuItem(tree, handle, node.kind.menu_item, resolved, theme);
}

fn emitDragValueNode(_: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, _: style_mod.Theme) void {
    emitDragValue(handle, &node.kind.drag_value, resolved);
}

fn emitSpinBoxNode(_: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, _: style_mod.Theme) void {
    emitSpinBox(handle, &node.kind.spinbox, resolved);
}

fn emitTabBarNode(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitTabBar(tree, handle, node.kind.tab_bar, resolved, theme);
}

fn emitTabItemNode(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitTabItem(tree, handle, node.kind.tab_item, resolved, theme);
}

fn emitSplitterNode(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitSplitter(tree, handle, node.kind.splitter, resolved, theme);
}

fn emitSliderNode(_: *const widget.Tree, handle: widget.NodeHandle, _: *const widget.Node, resolved: style_mod.ResolvedStyle, _: style_mod.Theme) void {
    emitSlider(handle, resolved);
}

fn emitSpacerNode(_: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, _: style_mod.ResolvedStyle, _: style_mod.Theme) void {
    emitSpacer(handle, node.kind.spacer);
}

fn emitScrollAreaNode(tree: *const widget.Tree, handle: widget.NodeHandle, _: *const widget.Node, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    emitScrollArea(tree, handle, resolved, theme);
}

fn emitTextInputNode(_: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style_mod.ResolvedStyle, _: style_mod.Theme) void {
    emitTextInput(handle, &node.kind.text_input, resolved);
}

fn emitCustomNode(_: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, _: style_mod.ResolvedStyle, _: style_mod.Theme) void {
    emitCustom(handle, node.kind.custom);
}

fn emitText(handle: widget.NodeHandle, txt: widget.WidgetKind.Text, resolved: style_mod.ResolvedStyle) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = switch (txt.overflow) {
                    .ellipsis, .clip => growSizing(),
                    .wrap => growSizing(),
                    .visible => .{},
                },
                .height = .{},
            },
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
        clayString(txt.content),
        c.Clay__StoreTextElementConfig(.{
            .userData = null,
            .textColor = clayColor(resolved.fg),
            .fontId = 0,
            .fontSize = @intFromFloat(resolved.font_size),
            .letterSpacing = 0,
            .lineHeight = 0,
            .wrapMode = switch (txt.overflow) {
                .visible, .clip, .ellipsis => c.CLAY_TEXT_WRAP_NONE,
                .wrap => c.CLAY_TEXT_WRAP_WORDS,
            },
            .textAlignment = c.CLAY_TEXT_ALIGN_LEFT,
        }),
    );
    c.Clay__CloseElement();
}

fn emitIcon(handle: widget.NodeHandle, resolved: style_mod.ResolvedStyle) void {
    const size = @max(resolved.font_size, 0);
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = fixedSizing(size),
                .height = fixedSizing(size),
            },
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
}

fn emitButton(tree: *const widget.Tree, handle: widget.NodeHandle, btn: widget.WidgetKind.Button, resolved: style_mod.ResolvedStyle, theme: style_mod.Theme) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{},
            .padding = clayPadding(resolved.padding),
            .childGap = @intFromFloat(resolved.spacing),
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
    if (btn.icon != null) emitAnonymousFixedBox(resolved.font_size);
    if (btn.label_visible) {
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
    }
    emitChildren(tree, handle, theme);
    c.Clay__CloseElement();
}

fn emitAnonymousFixedBox(size: f32) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .layout = .{ .sizing = .{ .width = fixedSizing(size), .height = fixedSizing(size) } },
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
                .width = if (cont.fit_main and cont.direction == .row) fitSizingMin(0) else growSizing(),
                .height = if (cont.fit_main and cont.direction == .column) fitSizingMin(0) else growSizing(),
            },
            .padding = clayPadding(resolved.padding),
            .childGap = @intFromFloat(resolved.spacing),
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
    const label = if (item.editing) node.kind.tree_item.internal.editor.content() else item.label;
    const depth = geometry.treeDepth(tree, handle);
    const left_indent = @as(f32, @floatFromInt(depth)) * geometry.treeIndent(theme, resolved);
    var header_padding = resolved.padding;
    header_padding.left += left_indent + geometry.treeDisclosureSlotWidth(resolved) + geometry.treeItemIconSlotWidth(item, theme, resolved);
    const min_width = header_padding.left + header_padding.right +
        measureTextDimensions(label, resolved.font_size, currentTextMeasureCtx()).width;

    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizingMin(min_width),
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
    const min_width = resolved.padding.left + resolved.padding.right +
        measureTextDimensions(selectable.label, resolved.font_size, currentTextMeasureCtx()).width;

    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizingMin(min_width),
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

fn emitGridSelector(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    grid_selector: widget.WidgetKind.GridSelector,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = fixedSizing(grid_selector.layoutHeight(resolved.padding)),
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

fn emitGridItem(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    _: widget.WidgetKind.GridItem,
    resolved: style_mod.ResolvedStyle,
) void {
    const size = gridItemSizing(tree, handle);
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = fixedSizing(size.w),
                .height = fixedSizing(size.h),
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
            .childGap = @intFromFloat(resolved.spacing),
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
            .childGap = @intFromFloat(resolved.spacing),
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
            .childGap = @intFromFloat(resolved.spacing),
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
            .childGap = @intFromFloat(resolved.spacing * 2),
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

    emitPopupChildren(tree, handle, theme);
    c.Clay__CloseElement();
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
            .sizing = popupSizing(tree, handle, resolved, theme),
            .padding = clayPadding(resolved.padding),
            .childGap = @intFromFloat(resolved.spacing),
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
    const has_submenu = geometry.directPopupChild(tree, handle) != null;
    const text_color = if (item.disabled)
        style_mod.Color.rgba(resolved.fg.r, resolved.fg.g, resolved.fg.b, 120)
    else
        resolved.fg;
    const reserve_width = @max(resolved.font_size, 12);

    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = growSizing(),
                .height = fixedSizing(controlTextHeight(resolved)),
            },
            .padding = clayPadding(resolved.padding),
            .childGap = @intFromFloat(@max(resolved.padding.left * 0.75, 6)),
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

    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = .{},
        .layout = .{
            .sizing = .{
                .width = fixedSizing(reserve_width),
                .height = .{},
            },
            .padding = .{},
            .childGap = 0,
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
    c.Clay__CloseElement();

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
        clayString(item.label),
        c.Clay__StoreTextElementConfig(.{
            .userData = null,
            .textColor = clayColor(text_color),
            .fontId = 0,
            .fontSize = @intFromFloat(resolved.font_size),
            .letterSpacing = 0,
            .lineHeight = 0,
            .wrapMode = c.CLAY_TEXT_WRAP_NONE,
            .textAlignment = c.CLAY_TEXT_ALIGN_LEFT,
        }),
    );
    c.Clay__CloseElement();

    if (item.shortcut.len > 0) {
        c.Clay__OpenTextElement(
            clayString(item.shortcut),
            c.Clay__StoreTextElementConfig(.{
                .userData = null,
                .textColor = clayColor(text_color),
                .fontId = 0,
                .fontSize = @intFromFloat(resolved.font_size),
                .letterSpacing = 0,
                .lineHeight = 0,
                .wrapMode = c.CLAY_TEXT_WRAP_NONE,
                .textAlignment = c.CLAY_TEXT_ALIGN_RIGHT,
            }),
        );
    }

    if (has_submenu) {
        c.Clay__OpenTextElement(
            clayString("›"),
            c.Clay__StoreTextElementConfig(.{
                .userData = null,
                .textColor = clayColor(text_color),
                .fontId = 0,
                .fontSize = @intFromFloat(resolved.font_size),
                .letterSpacing = 0,
                .lineHeight = 0,
                .wrapMode = c.CLAY_TEXT_WRAP_NONE,
                .textAlignment = c.CLAY_TEXT_ALIGN_RIGHT,
            }),
        );
    }

    emitPopupChildren(tree, handle, theme);
    c.Clay__CloseElement();
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

    if (geometry.selectedTabItem(tree, handle)) |selected| {
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
    const gap_thickness = geometry.splitterGapThickness(splitter);

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
            .sizing = splitterHandleSizing(splitter.direction, gap_thickness),
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

fn emitSpacer(handle: widget.NodeHandle, spacer: widget.WidgetKind.Spacer) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = if (spacer.width > 0) fixedSizing(spacer.width) else growSizing(),
                .height = fixedSizing(@max(spacer.height, 0)),
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
    c.Clay__CloseElement();
}

fn emitCustom(handle: widget.NodeHandle, custom: widget.WidgetKind.Custom) void {
    c.Clay__OpenElement();
    c.Clay__ConfigureOpenElement(.{
        .id = nodeId(handle),
        .layout = .{
            .sizing = .{
                .width = customSizingAxis(custom.width, custom.min_width, custom.grow_width),
                .height = customSizingAxis(custom.height, custom.min_height, custom.grow_height),
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
    c.Clay__CloseElement();
}

fn emitTextInput(handle: widget.NodeHandle, ti: *const widget.WidgetKind.TextInput, resolved: style_mod.ResolvedStyle) void {
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
            .horizontal = !scroll.disable_horizontal_scroll,
            .vertical = !scroll.disable_vertical_scroll,
            .childOffset = .{
                .x = -scroll.effectiveScrollX(),
                .y = -scroll.effectiveScrollY(),
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
        // Widget text is borrowed and callers commonly reuse an allocation
        // for different contents after rebuilding a projection. Clay's
        // "static" cache hashes the pointer rather than the bytes, which made
        // measurements depend on unrelated allocation/rebuild history.
        .isStaticallyAllocated = false,
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

fn growSizingMin(min: f32) c.Clay_SizingAxis {
    return .{
        .size = .{ .minMax = .{ .min = @max(min, 0), .max = 0 } },
        .type = c.CLAY__SIZING_TYPE_GROW,
    };
}

fn fitSizingMin(min: f32) c.Clay_SizingAxis {
    return .{
        .size = .{ .minMax = .{ .min = @max(min, 0), .max = 0 } },
        .type = c.CLAY__SIZING_TYPE_FIT,
    };
}

fn fixedSizing(px: f32) c.Clay_SizingAxis {
    return .{
        .size = .{ .minMax = .{ .min = px, .max = px } },
        .type = c.CLAY__SIZING_TYPE_FIXED,
    };
}

fn customSizingAxis(size: f32, min_size: f32, grow: bool) c.Clay_SizingAxis {
    if (size > 0) return fixedSizing(size);
    return if (grow) growSizingMin(min_size) else fitSizingMin(min_size);
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

fn hasUnresolvedSplitterRects(tree: *const widget.Tree) bool {
    for (tree.nodes.items) |node| {
        if (!node.alive or node.kind != .splitter) continue;
        if (node.layout_rect.w <= 0 or node.layout_rect.h <= 0) return true;
    }
    return false;
}

fn splitterClampWouldChange(tree: *const widget.Tree, theme: style_mod.Theme) bool {
    for (tree.nodes.items) |node| {
        if (!node.alive or node.kind != .splitter) continue;
        if (node.layout_rect.w <= 0 or node.layout_rect.h <= 0) continue;

        const resolved = node.style_override.resolve(theme);
        const clamped = geometry.clampedSplitterRatio(node.kind.splitter, node.layout_rect, resolved);
        if (@abs(clamped - node.kind.splitter.ratio) > 0.0001) return true;
    }
    return false;
}

fn syncGridSelectorLayout(tree: *widget.Tree, theme: style_mod.Theme) bool {
    var changed = false;
    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive or node.kind != .grid_selector) continue;
        const handle = tree.handleFromIndex(@intCast(i));
        const selector_node = tree.get(handle);
        const rect = selector_node.layout_rect;
        if (rect.w <= 0 or rect.h <= 0) continue;

        const resolved = selector_node.style_override.resolve(theme);
        const grid_selector = &selector_node.kind.grid_selector;
        const item_width = @max(grid_selector.item_width, 1);
        const item_height = @max(grid_selector.item_height, 1);
        const column_gap = @max(grid_selector.column_gap, 0);
        const row_gap = @max(grid_selector.row_gap, 0);
        const inner_width = @max(rect.w - resolved.padding.left - resolved.padding.right, item_width);
        const columns = gridSelectorColumns(inner_width, item_width, column_gap);
        const item_count = widget.gridSelectorItemCount(tree, handle);
        const rows = @max(gridSelectorRows(item_count, columns), 1);
        const content_height = resolved.padding.top +
            resolved.padding.bottom +
            @as(f32, @floatFromInt(rows)) * item_height +
            @as(f32, @floatFromInt(rows - 1)) * row_gap;

        if (grid_selector.computed_columns != columns or @abs(grid_selector.internal.content_height - content_height) > 0.01) {
            grid_selector.computed_columns = columns;
            grid_selector.internal.content_height = content_height;
            changed = true;
        }

        layoutGridSelectorItems(tree, handle, resolved, columns, item_width, item_height, column_gap, row_gap);
    }
    return changed;
}

fn gridSelectorColumns(inner_width: f32, item_width: f32, column_gap: f32) u16 {
    if (item_width <= 0) return 1;
    const slot_width = item_width + column_gap;
    if (slot_width <= 0) return 1;
    const columns = @as(u16, @intFromFloat(@floor((inner_width + column_gap) / slot_width)));
    return @max(columns, 1);
}

fn gridSelectorRows(item_count: u16, columns: u16) u16 {
    if (item_count == 0) return 0;
    return @intCast((@as(u32, item_count) + columns - 1) / columns);
}

fn layoutGridSelectorItems(
    tree: *widget.Tree,
    selector: widget.NodeHandle,
    resolved: style_mod.ResolvedStyle,
    columns: u16,
    item_width: f32,
    item_height: f32,
    column_gap: f32,
    row_gap: f32,
) void {
    const rect = tree.getConst(selector).layout_rect;
    var index: u16 = 0;
    var iter = tree.children(selector);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .grid_item) continue;
        const column = index % columns;
        const row = index / columns;
        tree.get(child).layout_rect = .{
            .x = rect.x + resolved.padding.left + @as(f32, @floatFromInt(column)) * (item_width + column_gap),
            .y = rect.y + resolved.padding.top + @as(f32, @floatFromInt(row)) * (item_height + row_gap),
            .w = item_width,
            .h = item_height,
        };
        index += 1;
    }
}

fn gridItemSizing(tree: *const widget.Tree, handle: widget.NodeHandle) struct { w: f32, h: f32 } {
    if (widget.gridItemParentSelector(tree, handle)) |selector| {
        const grid_selector = tree.getConst(selector).kind.grid_selector;
        return .{
            .w = @max(grid_selector.item_width, 1),
            .h = @max(grid_selector.item_height, 1),
        };
    }
    return .{ .w = 96, .h = 96 };
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
    return geometry.clampedSplitterRatio(splitter, tree.getConst(handle).layout_rect, resolved);
}

fn popupSizing(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) c.Clay_Sizing {
    var min_width = popupMenuContentMinWidth(tree, handle, resolved, theme) orelse 0;
    if (tree.getConst(handle).parent) |parent_handle| {
        const parent = tree.getConst(parent_handle);
        if (parent.kind == .dropdown and parent.layout_rect.w > 0) {
            min_width = @max(min_width, parent.layout_rect.w);
        }
    }
    if (min_width > 0) {
        return .{
            .width = fitSizingMin(min_width),
            .height = .{},
        };
    }
    return .{};
}

fn popupMenuContentMinWidth(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    resolved: style_mod.ResolvedStyle,
    theme: style_mod.Theme,
) ?f32 {
    var width: f32 = 0;
    var found_menu_item = false;
    const text_ctx = currentTextMeasureCtx();

    var iter = tree.children(handle);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (child_node.kind != .menu_item) continue;
        found_menu_item = true;

        const item_resolved = child_node.style_override.resolve(theme);
        const has_submenu = geometry.directPopupChild(tree, child) != null;
        width = @max(width, menuItemContentMinWidth(child_node.kind.menu_item, item_resolved, has_submenu, text_ctx));
    }

    if (!found_menu_item) return null;
    return width + resolved.padding.left + resolved.padding.right;
}

fn menuItemContentMinWidth(
    item: widget.WidgetKind.MenuItem,
    resolved: style_mod.ResolvedStyle,
    has_submenu: bool,
    text_ctx: ?*const TextMeasureCtx,
) f32 {
    const reserve_width = @max(resolved.font_size, 12);
    const gap = @max(resolved.padding.left * 0.75, 6);
    const label_width = measureTextDimensions(item.label, resolved.font_size, text_ctx).width;

    var width = resolved.padding.left + resolved.padding.right + reserve_width + gap + label_width;
    if (item.shortcut.len > 0) {
        const shortcut_text_width = measureTextDimensions(item.shortcut, resolved.font_size, text_ctx).width;
        width += gap + @max(shortcut_text_width + gap, reserve_width);
    }
    if (has_submenu) width += gap + reserve_width;
    return width;
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
    if (!node.kind.tooltip.visible) return false;
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

        if (!parentLayoutGate(parent.kind)(parent, node)) return false;

        current = parent_handle;
    }
}

const ParentLayoutGate = *const fn (*const widget.Node, *const widget.Node) bool;

fn parentLayoutGate(kind: widget.WidgetKind) ParentLayoutGate {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return parent_layout_gates[@intFromEnum(tag)];
}

const parent_layout_gates = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var gates: [std.meta.fields(Tag).len]ParentLayoutGate = undefined;
    for (&gates) |*gate| gate.* = allowChildLayout;
    gates[@intFromEnum(Tag.tree_item)] = allowTreeItemChildLayout;
    gates[@intFromEnum(Tag.tab_item)] = allowTabItemChildLayout;
    gates[@intFromEnum(Tag.dropdown)] = allowDropdownChildLayout;
    break :blk gates;
};

fn allowChildLayout(_: *const widget.Node, _: *const widget.Node) bool {
    return true;
}

fn allowTreeItemChildLayout(parent: *const widget.Node, node: *const widget.Node) bool {
    return parent.kind.tree_item.expanded or node.kind == .popup or node.kind == .tooltip;
}

fn allowTabItemChildLayout(parent: *const widget.Node, _: *const widget.Node) bool {
    return parent.kind.tab_item.selected;
}

fn allowDropdownChildLayout(parent: *const widget.Node, node: *const widget.Node) bool {
    return node.kind != .popup or parent.kind.dropdown.open;
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

fn popupViewport(tree: *const widget.Tree) ?visual_types.Rect {
    var viewport: ?visual_types.Rect = null;

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive or node.parent != null or node.kind == .popup or node.kind == .tooltip) continue;
        const rect = tree.handleFromIndex(@intCast(i));
        viewport = geometry.unionRect(viewport, tree.getConst(rect).layout_rect);
    }

    if (viewport == null) {
        for (tree.nodes.items, 0..) |node, i| {
            if (!node.alive or node.parent != null) continue;
            const handle = tree.handleFromIndex(@intCast(i));
            viewport = geometry.unionRect(viewport, tree.getConst(handle).layout_rect);
        }
    }

    return viewport;
}

fn clampPopupSubtree(tree: *widget.Tree, handle: widget.NodeHandle, viewport: visual_types.Rect) void {
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

fn popupSubtreeBounds(tree: *const widget.Tree, handle: widget.NodeHandle) ?visual_types.Rect {
    const node = tree.getConst(handle);
    if (node.layout_rect.w <= 0 or node.layout_rect.h <= 0) return null;

    var bounds = node.layout_rect;
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (popupSubtreeBounds(tree, child)) |child_bounds| {
            bounds = geometry.unionRect(bounds, child_bounds).?;
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
        const dims = measureTextDimensions(str, font_size, ctx);
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

test "measureTextDimensions keeps width but stabilizes line metrics" {
    const helper = struct {
        fn measure(text: []const u8, font_size: f32, _: ?*anyopaque) TextDimensions {
            if (std.mem.eql(u8, text, "Mg")) {
                return .{
                    .width = font_size,
                    .height = 20,
                    .ascent = 14,
                    .descent = 6,
                };
            }
            return .{
                .width = @as(f32, @floatFromInt(text.len)) * font_size * 0.5,
                .height = 10,
                .ascent = 8,
                .descent = 2,
            };
        }
    };

    const text_ctx = TextMeasureCtx{
        .measureFn = &helper.measure,
    };
    const dims = measureTextDimensions("hello", 16, &text_ctx);

    try std.testing.expectApproxEqAbs(@as(f32, 40), dims.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 20), dims.height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 14), dims.ascent, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 6), dims.descent, 0.01);
}

test "layout text cache keys borrowed strings by contents" {
    const allocator = std.testing.allocator;
    const min_memory = c.Clay_MinMemorySize();
    const arena = try allocator.alloc(u8, min_memory);
    defer allocator.free(arena);
    _ = c.Clay_Initialize(.{ .capacity = min_memory, .memory = arena.ptr }, .{ .width = 300, .height = 100 }, .{});
    defer c.Clay_SetCurrentContext(null);

    const helper = struct {
        fn measure(text: []const u8, font_size: f32, _: ?*anyopaque) TextDimensions {
            var width: f32 = 0;
            for (text) |byte| width += if (byte == 'W') font_size else font_size * 0.25;
            return .{ .width = width, .height = font_size };
        }
    };
    const measure_ctx = TextMeasureCtx{ .measureFn = &helper.measure };
    var bytes = [_]u8{ 'i', 'i', 'i', 'i' };
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();
    const text = try tree.addRoot(.{ .text = .{ .content = bytes[0..] } });
    run(&tree, .default, &measure_ctx);
    const narrow = tree.getConst(text).layout_rect.w;
    @memset(bytes[0..], 'W');
    run(&tree, .default, &measure_ctx);
    const wide = tree.getConst(text).layout_rect.w;
    try std.testing.expect(wide > narrow * 2);
}

test "text input content is measured from the tree node, not a stack copy" {
    // Regression: emitTextInput must borrow the text_input's inline `buffer`
    // from the live tree node. Passing the widget by value copied the 256-byte
    // buffer onto emitTextInput's stack frame; clayString borrowed a slice into
    // that copy, and Clay re-read the pointer during EndLayout after the frame
    // had returned — yielding garbage bytes that crashed text shaping the
    // moment the stack happened to be clobbered (e.g. a 17-char address bar).
    const allocator = std.testing.allocator;
    const min_memory = c.Clay_MinMemorySize();
    const arena = try allocator.alloc(u8, min_memory);
    defer allocator.free(arena);
    _ = c.Clay_Initialize(.{ .capacity = min_memory, .memory = arena.ptr }, .{ .width = 300, .height = 100 }, .{});
    defer c.Clay_SetCurrentContext(null);

    const Capture = struct {
        var input_ptr: ?[*]const u8 = null;
        fn measure(text: []const u8, font_size: f32, _: ?*anyopaque) TextDimensions {
            if (text.len == 10 and text[0] == 'a') input_ptr = text.ptr;
            return .{ .width = @as(f32, @floatFromInt(text.len)) * font_size, .height = font_size };
        }
    };
    Capture.input_ptr = null;
    const measure_ctx = TextMeasureCtx{ .measureFn = &Capture.measure };

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();
    const input = try tree.addRoot(.{ .text_input = .{} });
    {
        const node = tree.get(input);
        node.kind.text_input.len = 10;
        @memcpy(node.kind.text_input.buffer[0..10], "abcdefghij");
    }

    run(&tree, .default, &measure_ctx);

    try std.testing.expect(Capture.input_ptr != null);
    try std.testing.expectEqual(
        tree.getConst(input).kind.text_input.content().ptr,
        Capture.input_ptr.?,
    );
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

test "menu popup layout reserves intrinsic item width" {
    const allocator = std.testing.allocator;
    const min_memory = c.Clay_MinMemorySize();
    const arena = try allocator.alloc(u8, min_memory);
    defer allocator.free(arena);

    const clay_arena = c.Clay_Arena{
        .capacity = min_memory,
        .memory = arena.ptr,
    };
    _ = c.Clay_Initialize(clay_arena, .{
        .width = 500,
        .height = 240,
    }, .{});
    defer c.Clay_SetCurrentContext(null);

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const bar = try tree.addChild(root, .{ .menu_bar = .{} });
    const file = try tree.addChild(bar, .{ .menu = .{ .label = "File" } });
    const popup = try tree.addChild(file, .{ .popup = .{ .placement = .below_start } });
    _ = try tree.addChild(popup, .{ .menu_item = .{
        .label = "Open Link Target",
        .shortcut = "Ctrl+Shift+O",
        .checked = true,
    } });

    const theme = style_mod.Theme.default;
    run(&tree, theme, null);

    const popup_rect = tree.getConst(popup).layout_rect;
    const popup_resolved = tree.getConst(popup).style_override.resolve(theme);
    const item_resolved = (style_mod.Style{}).resolve(theme);
    const expected_width = popup_resolved.padding.left + popup_resolved.padding.right +
        menuItemContentMinWidth(.{
            .label = "Open Link Target",
            .shortcut = "Ctrl+Shift+O",
            .checked = true,
        }, item_resolved, false, null);

    try std.testing.expect(popup_rect.w >= expected_width - 0.01);
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

test "splitter applies minimum pane sizes on initial layout" {
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
        .ratio = 0.1,
        .min_first = 120,
        .min_second = 60,
        .thickness = 8,
    } });
    const left = try tree.addChild(splitter, .{ .container = .{} });
    const right = try tree.addChild(splitter, .{ .container = .{} });
    _ = try tree.addChild(left, .{ .text = .{ .content = "Left" } });
    _ = try tree.addChild(right, .{ .text = .{ .content = "Right" } });

    run(&tree, style_mod.Theme.default, null);

    const left_rect = tree.getConst(left).layout_rect;
    const right_rect = tree.getConst(right).layout_rect;
    try std.testing.expect(left_rect.w >= 120 - 0.01);
    try std.testing.expect(right_rect.w >= 60 - 0.01);
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

test "scroll area layout offsets child rects by scroll amount" {
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
        .height = 200,
    }, .{});
    defer c.Clay_SetCurrentContext(null);

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{ .scroll_y = 100 } });
    const child = try tree.addChild(scroll, .{ .spacer = .{ .height = 500 } });

    run(&tree, style_mod.Theme.default, null);

    try std.testing.expectApproxEqAbs(@as(f32, 0), tree.getConst(scroll).layout_rect.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -94), tree.getConst(child).layout_rect.y, 0.01);
}

test "ellipsized text grows to parent width instead of content width" {
    const theme = style_mod.Theme.default;
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
        .height = 200,
    }, .{});
    defer c.Clay_SetCurrentContext(null);

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{ .direction = .column } });
    const line = try tree.addChild(root, .{ .text = .{
        .content = "/a/very/long/path/without/spaces/that/should/not/resize/the/pane",
        .overflow = .ellipsis,
    } });

    run(&tree, theme, null);

    const root_rect = tree.getConst(root).layout_rect;
    const line_rect = tree.getConst(line).layout_rect;
    const root_inner_w = root_rect.w - theme.padding.left - theme.padding.right;
    try std.testing.expectApproxEqAbs(root_inner_w, line_rect.w, 0.01);
}

test "wrapped text inside padded scroll area uses the visible content width" {
    const theme = style_mod.Theme.default;
    const allocator = std.testing.allocator;
    const min_memory = c.Clay_MinMemorySize();
    const arena = try allocator.alloc(u8, min_memory);
    defer allocator.free(arena);

    const clay_arena = c.Clay_Arena{
        .capacity = min_memory,
        .memory = arena.ptr,
    };
    _ = c.Clay_Initialize(clay_arena, .{
        .width = 287,
        .height = 320,
    }, .{});
    defer c.Clay_SetCurrentContext(null);

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{ .disable_horizontal_scroll = true } });
    tree.get(scroll).style_override = .{ .padding = style_mod.Edges.symmetric(12, 12) };
    const content = try tree.addChild(scroll, .{ .container = .{ .direction = .column } });
    tree.get(content).style_override = .{ .padding = style_mod.Edges.all(0), .spacing = 8 };
    const text = try tree.addChild(content, .{ .text = .{
        .content = "Select a file to inspect it, or use Preview to skim folders and text files inline.",
        .overflow = .wrap,
    } });

    run(&tree, theme, null);

    const scroll_rect = tree.getConst(scroll).layout_rect;
    const text_rect = tree.getConst(text).layout_rect;
    const visible_width = scroll_rect.w - 24;
    try std.testing.expect(text_rect.w <= visible_width + 0.01);
    try std.testing.expect(text_rect.h > textMetrics(theme.font_size, null).height + 0.01);
}

// ── Property-based layout invariants ──
//
// Seeded-PRNG loops asserting structural invariants across many randomized
// trees. Spacers are the fixed-size building block: `spacer.height` lays out as
// a fixed height, so we can reason about packing, spacing, and overflow exactly.

const prop_iterations = 300;

fn propClayInit(allocator: std.mem.Allocator, width: f32, height: f32) ![]u8 {
    const min_memory = c.Clay_MinMemorySize();
    const arena = try allocator.alloc(u8, min_memory);
    _ = c.Clay_Initialize(.{ .capacity = min_memory, .memory = arena.ptr }, .{ .width = width, .height = height }, .{});
    return arena;
}

test "property: a column packs fixed children top-to-bottom with uniform gaps" {
    const allocator = std.testing.allocator;
    const arena = try propClayInit(allocator, 1000, 6000);
    defer allocator.free(arena);
    defer c.Clay_SetCurrentContext(null);

    var prng = std.Random.DefaultPrng.init(0x676f_6f70_7061_636b); // "goop pack"
    const rand = prng.random();

    var trial: usize = 0;
    while (trial < prop_iterations) : (trial += 1) {
        const spacing: f32 = @floatFromInt(rand.intRangeAtMost(u32, 0, 24));
        const n = rand.intRangeAtMost(usize, 1, 8);

        var tree = widget.Tree.init(allocator);
        defer tree.deinit();
        const root = try tree.addRoot(.{ .container = .{ .direction = .column, .fit_main = true } });
        tree.get(root).style_override = .{ .padding = style_mod.Edges.all(0), .spacing = spacing, .border_width = 0 };

        var handles: [8]widget.NodeHandle = undefined;
        var heights: [8]f32 = undefined;
        var total: f32 = 0;
        for (0..n) |i| {
            const h: f32 = @floatFromInt(rand.intRangeAtMost(u32, 1, 120));
            heights[i] = h;
            handles[i] = try tree.addChild(root, .{ .spacer = .{ .width = 20, .height = h } });
            total += h;
        }

        run(&tree, .default, null);

        // Each child keeps its fixed height, follows the previous one by exactly
        // `spacing`, and never overlaps.
        var expected_y = tree.getConst(root).layout_rect.y;
        for (0..n) |i| {
            const rect = tree.getConst(handles[i]).layout_rect;
            try std.testing.expectApproxEqAbs(heights[i], rect.h, 0.01);
            try std.testing.expectApproxEqAbs(expected_y, rect.y, 0.02);
            if (i > 0) {
                const prev = tree.getConst(handles[i - 1]).layout_rect;
                try std.testing.expect(rect.y + 0.01 >= prev.y + prev.h); // no overlap
            }
            expected_y = rect.y + rect.h + spacing;
        }

        // fit_main height is exactly the packed content, never distributed to the
        // 6000px viewport.
        const gaps = if (n > 0) @as(f32, @floatFromInt(n - 1)) * spacing else 0;
        try std.testing.expectApproxEqAbs(total + gaps, tree.getConst(root).layout_rect.h, 0.05);
    }
}

test "property: grow distributes surplus evenly, fit_main packs to content" {
    const allocator = std.testing.allocator;
    // Tall viewport so a grow column's surplus dwarfs any child's min height.
    const viewport_h: f32 = 2000;
    const reserved: f32 = 200; // a fixed sibling that eats part of the frame
    const arena = try propClayInit(allocator, 800, viewport_h);
    defer allocator.free(arena);
    defer c.Clay_SetCurrentContext(null);

    var prng = std.Random.DefaultPrng.init(0x676f_6f70_6469_7374); // "goop dist"
    const rand = prng.random();

    var trial: usize = 0;
    while (trial < prop_iterations) : (trial += 1) {
        const n = rand.intRangeAtMost(usize, 2, 6);
        const fit = rand.boolean();

        var tree = widget.Tree.init(allocator);
        defer tree.deinit();
        // Root frame grows to the viewport; the fixed spacer leaves a large
        // surplus below it for the column under test.
        const frame = try tree.addRoot(.{ .container = .{ .direction = .column } });
        tree.get(frame).style_override = .{ .padding = style_mod.Edges.all(0), .spacing = 0, .border_width = 0 };
        _ = try tree.addChild(frame, .{ .spacer = .{ .width = 10, .height = reserved } });

        const col = try tree.addChild(frame, .{ .container = .{ .direction = .column, .fit_main = fit } });
        tree.get(col).style_override = .{ .padding = style_mod.Edges.all(0), .spacing = 0, .border_width = 0 };
        var kids: [6]widget.NodeHandle = undefined;
        for (0..n) |i| kids[i] = try tree.addChild(col, .{ .container = .{ .direction = .column } });

        run(&tree, .default, null);

        const col_h = tree.getConst(col).layout_rect.h;
        if (fit) {
            // Packed to content: empty children stay at their min, so the column
            // is a small fraction of the surplus rather than filling it.
            try std.testing.expect(col_h < @as(f32, @floatFromInt(n)) * 60);
        } else {
            // Grows to fill the surplus, and shares it evenly among children.
            try std.testing.expect(col_h > (viewport_h - reserved) * 0.9);
            const first = tree.getConst(kids[0]).layout_rect.h;
            for (1..n) |i| {
                try std.testing.expectApproxEqAbs(first, tree.getConst(kids[i]).layout_rect.h, 1.0);
            }
        }
    }
}

test "property: a scroll area overflows exactly when content exceeds the viewport" {
    const allocator = std.testing.allocator;
    const viewport_w: f32 = 500;
    const viewport_h: f32 = 400;
    const arena = try propClayInit(allocator, viewport_w, viewport_h);
    defer allocator.free(arena);
    defer c.Clay_SetCurrentContext(null);

    var prng = std.Random.DefaultPrng.init(0x676f_6f70_7363_726c); // "goop scrl"
    const rand = prng.random();

    var trial: usize = 0;
    while (trial < prop_iterations) : (trial += 1) {
        var tree = widget.Tree.init(allocator);
        defer tree.deinit();
        const scroll = try tree.addRoot(.{ .scroll_area = .{} });
        tree.get(scroll).style_override = .{ .padding = style_mod.Edges.all(0), .spacing = 0, .border_width = 0 };

        // A stack of fixed-height rows. The scroll area lays out its children
        // with a childGap of theme.spacing, so the content extent includes the
        // inter-row gaps.
        const gap = style_mod.Theme.default.spacing;
        const n = rand.intRangeAtMost(usize, 1, 10);
        var content_h: f32 = 0;
        var last: widget.NodeHandle = undefined;
        for (0..n) |i| {
            const h: f32 = @floatFromInt(rand.intRangeAtMost(u32, 20, 90));
            const wide: f32 = @floatFromInt(rand.intRangeAtMost(u32, 100, 900));
            last = try tree.addChild(scroll, .{ .spacer = .{ .width = wide, .height = h } });
            content_h += h;
            if (i > 0) content_h += gap;
        }

        run(&tree, .default, null);

        const scroll_rect = tree.getConst(scroll).layout_rect;
        const bottom = tree.getConst(last).layout_rect.y + tree.getConst(last).layout_rect.h;
        const v_overflow = content_h > viewport_h + 0.01;
        // The clipped scroll box itself stays clamped to the viewport...
        try std.testing.expect(scroll_rect.h <= viewport_h + 0.01);
        try std.testing.expect(scroll_rect.w <= viewport_w + 0.01);
        // ...but the laid-out content extends past it vertically exactly when it
        // overflows.
        if (v_overflow) {
            try std.testing.expect(bottom > scroll_rect.y + scroll_rect.h - 0.01);
        } else {
            try std.testing.expect(bottom <= scroll_rect.y + scroll_rect.h + 0.01);
        }

        // Horizontal: each fixed-width row extends past the right edge exactly
        // when it is wider than the viewport.
        var it = tree.children(scroll);
        while (it.next()) |child| {
            const cr = tree.getConst(child).layout_rect;
            const right = cr.x + cr.w;
            const h_overflow = cr.w > viewport_w + 0.01;
            if (h_overflow) {
                try std.testing.expect(right > scroll_rect.x + scroll_rect.w + 0.01);
            } else {
                try std.testing.expect(right <= scroll_rect.x + scroll_rect.w + 0.01);
            }
        }
    }
}
