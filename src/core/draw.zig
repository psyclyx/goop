const std = @import("std");
const style = @import("style.zig");
const widget = @import("widget.zig");
const layout = @import("layout.zig");

/// Axis-aligned rectangle.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const TextAlign = enum {
    start,
    center,
    end,
};

pub const TextOverflow = enum {
    visible,
    clip,
    ellipsis,
};

pub const IconKind = enum {
    folder,
    file,
    symlink,
    home,
    back,
    up,
    refresh,
    list,
    grid,
    info,
};

/// A semantic paint command emitted by the core.
pub const PaintCommand = union(enum) {
    box: Box,
    text: Text,
    clip: ClipRect,
    icon: Icon,
    custom: Custom,

    pub const Box = struct {
        bounds: Rect,
        color: style.Color,
        border_color: style.Color,
        border_width: f32,
        corner_radius: f32,
    };

    pub const Text = struct {
        bounds: Rect,
        text: []const u8,
        color: style.Color,
        font_size: f32,
        text_align: TextAlign = .start,
        overflow: TextOverflow = .visible,
    };

    pub const ClipRect = struct {
        bounds: ?Rect,
    };

    pub const Icon = struct {
        bounds: Rect,
        kind: IconKind,
        color: style.Color,
    };

    pub const Custom = struct {
        handle: widget.NodeHandle,
        bounds: Rect,
    };
};

/// Accumulated semantic paint output from a frame.
pub const PaintList = struct {
    commands: []const PaintCommand,
};

/// Renderer-facing primitive draw commands.
pub const DrawCommand = union(enum) {
    rect: DrawRect,
    text: DrawText,
    clip: ClipRect,
    icon: DrawIcon,
    custom: DrawCustom,

    pub const DrawRect = struct {
        bounds: Rect,
        color: style.Color,
        border_color: style.Color,
        border_width: f32,
        corner_radius: f32,
    };

    pub const DrawText = struct {
        bounds: Rect,
        baseline_y: f32,
        text: []const u8,
        color: style.Color,
        font_size: f32,
        text_align: TextAlign = .start,
        overflow: TextOverflow = .visible,
    };

    pub const ClipRect = struct {
        bounds: ?Rect,
    };

    pub const DrawIcon = struct {
        bounds: Rect,
        kind: IconKind,
        color: style.Color,
    };

    pub const DrawCustom = struct {
        handle: widget.NodeHandle,
        bounds: Rect,
    };
};

pub const DrawList = struct {
    commands: []const DrawCommand,
};

/// Generate semantic paint commands from a laid-out widget tree.
pub fn generatePaint(tree: *const widget.Tree, theme: style.Theme, allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx) !PaintList {
    var commands: std.ArrayListUnmanaged(PaintCommand) = .empty;
    errdefer commands.deinit(allocator);

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive) continue;
        if (node.parent == null) {
            const handle = tree.handleFromIndex(@intCast(i));
            if (node.kind != .popup and node.kind != .tooltip) {
                try emitNode(tree, handle, theme, &commands, allocator, text_ctx, false);
            }
        }
    }

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive) continue;
        if (node.parent == null) {
            try emitFloatingSubtrees(tree, tree.handleFromIndex(@intCast(i)), theme, &commands, allocator, text_ctx);
        }
    }

    try emitDragGhosts(tree, theme, &commands, allocator, text_ctx);

    return .{ .commands = try commands.toOwnedSlice(allocator) };
}

pub fn freePaintList(paint_list: *PaintList, allocator: std.mem.Allocator) void {
    allocator.free(paint_list.commands);
    paint_list.commands = &.{};
}

pub fn lowerPaintList(paint_list: PaintList, allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx) !DrawList {
    var commands: std.ArrayListUnmanaged(DrawCommand) = .empty;
    errdefer commands.deinit(allocator);

    for (paint_list.commands) |command| {
        switch (command) {
            .box => |box| try commands.append(allocator, .{ .rect = .{
                .bounds = box.bounds,
                .color = box.color,
                .border_color = box.border_color,
                .border_width = box.border_width,
                .corner_radius = box.corner_radius,
            } }),
            .text => |text| try commands.append(allocator, .{ .text = lowerTextCommand(text, text_ctx) }),
            .clip => |clip| try commands.append(allocator, .{ .clip = .{ .bounds = clip.bounds } }),
            .icon => |icon| try commands.append(allocator, .{ .icon = .{
                .bounds = icon.bounds,
                .kind = icon.kind,
                .color = icon.color,
            } }),
            .custom => |custom| try commands.append(allocator, .{ .custom = .{
                .handle = custom.handle,
                .bounds = custom.bounds,
            } }),
        }
    }

    return .{ .commands = try commands.toOwnedSlice(allocator) };
}

/// Generate renderer-facing draw commands from a laid-out widget tree.
pub fn generate(tree: *const widget.Tree, theme: style.Theme, allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx) !DrawList {
    var paint_list = try generatePaint(tree, theme, allocator, text_ctx);
    defer freePaintList(&paint_list, allocator);
    return lowerPaintList(paint_list, allocator, text_ctx);
}

pub fn freeDrawList(draw_list: *DrawList, allocator: std.mem.Allocator) void {
    allocator.free(draw_list.commands);
    draw_list.commands = &.{};
}

fn emitNode(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) std.mem.Allocator.Error!void {
    const node = tree.getConst(handle);
    if (!shouldDrawNode(tree, handle)) return;
    if (!in_floating_subtree and (node.kind == .popup or node.kind == .tooltip)) return;
    const resolved = node.style_override.resolve(theme);

    switch (node.kind) {
        .container => try emitContainer(tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .text => |txt| try emitText(node, txt, resolved, commands, allocator, text_ctx),
        .button => |btn| try emitButton(tree, handle, node, btn, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .checkbox => |cb| try emitCheckbox(node, cb, resolved, theme, commands, allocator, text_ctx),
        .radio_button => |rb| try emitRadioButton(node, rb, resolved, theme, commands, allocator, text_ctx),
        .tree_item => |tree_item| try emitTreeItem(tree, handle, node, tree_item, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .dropdown => |dropdown| try emitDropdown(tree, handle, node, dropdown, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .list_box => try emitListBox(tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .selectable => |selectable| try emitSelectable(node, selectable, resolved, theme, commands, allocator, text_ctx),
        .grid_selector => |grid_selector| try emitGridSelector(tree, handle, node, grid_selector, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .grid_item => |grid_item| try emitGridItem(node, grid_item, resolved, theme, commands, allocator, text_ctx),
        .table => |table| try emitTable(tree, handle, node, table, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .table_row => |row| try emitTableRow(tree, handle, node, row, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .table_cell => try emitTableCell(tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .toolbar => try emitToolbar(tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .status_bar => try emitStatusBar(tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .menu_bar => try emitMenuBar(tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .menu => |menu| try emitMenu(tree, handle, node, menu, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .popup => try emitPopup(tree, handle, node, resolved, theme, commands, allocator, text_ctx),
        .tooltip => try emitTooltip(tree, handle, node, resolved, theme, commands, allocator, text_ctx),
        .menu_item => |item| try emitMenuItem(tree, handle, node, item, resolved, theme, commands, allocator, text_ctx),
        .drag_value => try emitDragValue(node, &node.kind.drag_value, resolved, theme, commands, allocator, text_ctx),
        .spinbox => try emitSpinBox(node, &node.kind.spinbox, resolved, theme, commands, allocator, text_ctx),
        .tab_bar => |tab_bar| try emitTabBar(tree, handle, node, tab_bar, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .tab_item => |tab_item| try emitTabItem(tree, handle, node, tab_item, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .splitter => |splitter| try emitSplitter(tree, handle, node, splitter, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .slider => |sl| try emitSlider(node, sl, resolved, theme, commands, allocator),
        .text_input => try emitTextInput(node, resolved, theme, commands, allocator, text_ctx),
        .scroll_area => try emitScrollArea(tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
    }

    if (node.custom_draw and node.layout_rect.w > 0 and node.layout_rect.h > 0) {
        try commands.append(allocator, .{ .custom = .{
            .handle = handle,
            .bounds = node.layout_rect,
        } });
    }
}

fn emitContainer(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    // Background rect
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn defaultTextBounds(rect: Rect, resolved: style.ResolvedStyle) Rect {
    return .{
        .x = rect.x + resolved.padding.left,
        .y = rect.y + resolved.padding.top,
        .w = @max(rect.w - resolved.padding.left - resolved.padding.right, 0),
        .h = @max(rect.h - resolved.padding.top - resolved.padding.bottom, 0),
    };
}

fn customTextBounds(rect: Rect, resolved: style.ResolvedStyle, x: f32, w: f32) Rect {
    return .{
        .x = x,
        .y = rect.y + resolved.padding.top,
        .w = @max(w, 0),
        .h = @max(rect.h - resolved.padding.top - resolved.padding.bottom, 0),
    };
}

fn rectRight(rect: Rect) f32 {
    return rect.x + rect.w;
}

fn appendTextCommand(
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    bounds: Rect,
    text: []const u8,
    color: style.Color,
    font_size: f32,
    text_align: TextAlign,
    overflow: TextOverflow,
) !void {
    try commands.append(allocator, .{ .text = .{
        .bounds = bounds,
        .text = text,
        .color = color,
        .font_size = font_size,
        .text_align = text_align,
        .overflow = overflow,
    } });
}

fn lowerTextCommand(text: PaintCommand.Text, text_ctx: ?*const layout.TextMeasureCtx) DrawCommand.DrawText {
    return .{
        .bounds = text.bounds,
        .baseline_y = textBaselineY(text.bounds, text.text, text.font_size, text_ctx),
        .text = text.text,
        .color = text.color,
        .font_size = text.font_size,
        .text_align = text.text_align,
        .overflow = text.overflow,
    };
}

fn textBaselineY(bounds: Rect, text: []const u8, font_size: f32, text_ctx: ?*const layout.TextMeasureCtx) f32 {
    const metrics = if (text.len > 0)
        layout.measureTextDimensions(text, font_size, text_ctx)
    else
        layout.textMetrics(font_size, text_ctx);
    const extra_vertical = @max(bounds.h - metrics.height, 0);
    return bounds.y + extra_vertical * 0.5 + metrics.ascent;
}

fn emitText(
    node: *const widget.Node,
    txt: widget.WidgetKind.Text,
    resolved: style.ResolvedStyle,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    _: ?*const layout.TextMeasureCtx,
) !void {
    try appendTextCommand(commands, allocator, node.layout_rect, txt.content, resolved.fg, resolved.font_size, .start, .visible);
}

fn emitButton(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    btn: widget.WidgetKind.Button,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    // Background rect
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = interactionBg(node, resolved, theme),
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    const label_bounds = defaultTextBounds(node.layout_rect, resolved);
    try appendTextCommand(commands, allocator, label_bounds, btn.label, resolved.fg, resolved.font_size, .start, .visible);

    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn emitCheckbox(
    node: *const widget.Node,
    cb: widget.WidgetKind.Checkbox,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    _: ?*const layout.TextMeasureCtx,
) !void {
    const rect = node.layout_rect;
    const box_size = resolved.font_size;

    // Checkbox box
    try commands.append(allocator, .{ .box = .{
        .bounds = .{
            .x = rect.x + resolved.padding.left,
            .y = rect.y + resolved.padding.top,
            .w = box_size,
            .h = box_size,
        },
        .color = interactionBg(node, resolved, theme),
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    // Check indicator (filled inner rect when checked)
    if (cb.checked) {
        const inset: f32 = 3;
        try commands.append(allocator, .{ .box = .{
            .bounds = .{
                .x = rect.x + resolved.padding.left + inset,
                .y = rect.y + resolved.padding.top + inset,
                .w = box_size - inset * 2,
                .h = box_size - inset * 2,
            },
            .color = theme.accent,
            .border_color = theme.accent,
            .border_width = 0,
            .corner_radius = @max(resolved.border_radius - inset, 0),
        } });
    }

    const label_x = rect.x + resolved.padding.left + box_size + resolved.padding.left;
    const label_bounds = customTextBounds(rect, resolved, label_x, rect.x + rect.w - resolved.padding.right - label_x);
    try appendTextCommand(commands, allocator, label_bounds, cb.label, resolved.fg, resolved.font_size, .start, .visible);

    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
}

fn emitRadioButton(
    node: *const widget.Node,
    rb: widget.WidgetKind.RadioButton,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    _: ?*const layout.TextMeasureCtx,
) !void {
    const rect = node.layout_rect;
    const box_size = resolved.font_size;
    const circle_radius = box_size / 2;

    // Outer circle
    try commands.append(allocator, .{ .box = .{
        .bounds = .{
            .x = rect.x + resolved.padding.left,
            .y = rect.y + resolved.padding.top,
            .w = box_size,
            .h = box_size,
        },
        .color = interactionBg(node, resolved, theme),
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = circle_radius,
    } });

    // Inner dot when selected
    if (rb.selected) {
        const inset: f32 = 3;
        try commands.append(allocator, .{ .box = .{
            .bounds = .{
                .x = rect.x + resolved.padding.left + inset,
                .y = rect.y + resolved.padding.top + inset,
                .w = box_size - inset * 2,
                .h = box_size - inset * 2,
            },
            .color = theme.accent,
            .border_color = theme.accent,
            .border_width = 0,
            .corner_radius = circle_radius - inset,
        } });
    }

    const label_x = rect.x + resolved.padding.left + box_size + resolved.padding.left;
    const label_bounds = customTextBounds(rect, resolved, label_x, rect.x + rect.w - resolved.padding.right - label_x);
    try appendTextCommand(commands, allocator, label_bounds, rb.label, resolved.fg, resolved.font_size, .start, .visible);

    try emitFocusRing(node, theme, circle_radius, commands, allocator);
}

fn emitTreeItem(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    item: widget.WidgetKind.TreeItem,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const rect = node.layout_rect;
    const depth = treeDepth(tree, handle);
    const indent = @as(f32, @floatFromInt(depth)) * treeIndent(theme, resolved);
    const slot_width = disclosureSlotWidth(resolved);
    const disclosure_x = rect.x + resolved.padding.left + indent;
    const disclosure_center_x = disclosure_x + slot_width * 0.5;
    const label_x = disclosure_x + slot_width;
    const label_bounds = customTextBounds(rect, resolved, label_x, rect.x + rect.w - resolved.padding.right - label_x);
    const label = if (item.editing) node.kind.tree_item.editor.content() else item.label;
    const has_parent = findTreeParent(tree, handle) != null;
    const has_children = hasNonPopupChildren(tree, handle);

    try emitTreeGuides(tree, handle, rect, resolved, theme, disclosure_center_x, commands, allocator);

    const chrome = treeItemChrome(node, item, resolved, theme);
    if (chrome.color.a > 0 or chrome.border_width > 0) {
        try commands.append(allocator, .{ .box = .{
            .bounds = rect,
            .color = chrome.color,
            .border_color = chrome.border_color,
            .border_width = chrome.border_width,
            .corner_radius = resolved.border_radius,
        } });
    }
    try emitTreeItemDropIndicator(rect, item, resolved, theme, commands, allocator);

    if (has_children) {
        try emitTreeDisclosure(disclosure_x, rect, resolved, theme, item.expanded, commands, allocator);
    }
    if (has_children or has_parent) {
        try commands.append(allocator, .{ .box = .{
            .bounds = .{
                .x = disclosure_center_x,
                .y = rect.y + rect.h * 0.5,
                .w = @max(label_x - disclosure_center_x - 3, 1),
                .h = 1,
            },
            .color = theme.tree_guide,
            .border_color = theme.tree_guide,
            .border_width = 0,
            .corner_radius = 0,
        } });
    }

    if (item.editing) {
        const editor = &node.kind.tree_item.editor;

        if (editor.hasSelection()) {
            const range = editor.selectionRange();
            const sel_start_x = label_x + layout.textWidthUpTo(label, range.start, resolved.font_size, text_ctx);
            const sel_end_x = label_x + layout.textWidthUpTo(label, range.end, resolved.font_size, text_ctx);
            try commands.append(allocator, .{ .box = .{
                .bounds = .{ .x = sel_start_x, .y = label_bounds.y, .w = sel_end_x - sel_start_x, .h = label_bounds.h },
                .color = theme.selection_bg,
                .border_color = theme.selection_bg,
                .border_width = 0,
                .corner_radius = 0,
            } });
        }

        if (label.len > 0) {
            try appendTextCommand(commands, allocator, label_bounds, label, resolved.fg, resolved.font_size, .start, .visible);
        }

        const cursor_x = label_x + layout.textWidthUpTo(label, editor.cursor, resolved.font_size, text_ctx);
        try commands.append(allocator, .{ .box = .{
            .bounds = .{ .x = cursor_x, .y = label_bounds.y, .w = 1, .h = label_bounds.h },
            .color = resolved.fg,
            .border_color = resolved.fg,
            .border_width = 0,
            .corner_radius = 0,
        } });
    } else {
        try appendTextCommand(commands, allocator, label_bounds, label, resolved.fg, resolved.font_size, .start, .visible);
    }

    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
    if (item.expanded) {
        try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);
    } else {
        try emitPopupChildren(tree, handle, theme, commands, allocator, text_ctx);
    }
}

fn emitDropdown(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    dropdown: widget.WidgetKind.Dropdown,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    _ = in_floating_subtree;
    const label = if (dropdown.selected_text.len > 0)
        dropdown.selected_text
    else
        dropdown.placeholder;
    const rect = node.layout_rect;
    const chevron = if (dropdown.open) dropdownChevronUp() else dropdownChevronDown();
    const chevron_x = rect.x + rect.w - resolved.padding.right - resolved.font_size * 0.6;
    const label_bounds = customTextBounds(rect, resolved, rect.x + resolved.padding.left, chevron_x - theme.spacing - (rect.x + resolved.padding.left));
    const chevron_bounds = customTextBounds(rect, resolved, chevron_x, rect.x + rect.w - resolved.padding.right - chevron_x);

    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = interactionBg(node, resolved, theme),
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    try appendTextCommand(commands, allocator, label_bounds, label, if (dropdown.selected_text.len > 0) resolved.fg else theme.placeholder_fg, resolved.font_size, .start, .clip);
    try appendTextCommand(commands, allocator, chevron_bounds, chevron, resolved.fg, resolved.font_size, .center, .visible);

    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
    if (dropdown.open) {
        try emitPopupChildren(tree, handle, theme, commands, allocator, text_ctx);
    }
}

fn emitListBox(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn emitSelectable(
    node: *const widget.Node,
    selectable: widget.WidgetKind.Selectable,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    _: ?*const layout.TextMeasureCtx,
) !void {
    const fill = selectableBg(node, selectable.selected, theme);
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = fill,
        .border_color = if (selectable.selected) theme.accent else resolved.border,
        .border_width = if (selectable.selected) 1 else 0,
        .corner_radius = resolved.border_radius,
    } });
    const selectable_bounds = defaultTextBounds(node.layout_rect, resolved);
    try appendTextCommand(commands, allocator, selectable_bounds, selectable.label, resolved.fg, resolved.font_size, .start, .clip);
    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
}

fn emitGridSelector(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    grid_selector: widget.WidgetKind.GridSelector,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = if (grid_selector.drop_preview_background)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 48)
        else
            resolved.bg,
        .border_color = if (grid_selector.drop_preview_background) theme.accent else resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);

    if (grid_selector.marquee_active and grid_selector.marquee_rect.w > 0 and grid_selector.marquee_rect.h > 0) {
        const fill = style.Color.rgba(theme.selection_bg.r, theme.selection_bg.g, theme.selection_bg.b, 96);
        try commands.append(allocator, .{ .box = .{
            .bounds = grid_selector.marquee_rect,
            .color = fill,
            .border_color = theme.accent,
            .border_width = 1,
            .corner_radius = 0,
        } });
    }
}

fn emitGridItem(
    node: *const widget.Node,
    grid_item: widget.WidgetKind.GridItem,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    _: ?*const layout.TextMeasureCtx,
) !void {
    const rect = node.layout_rect;
    const fill = if (grid_item.dragging)
        style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 72)
    else
        selectableBg(node, grid_item.selected, theme);
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = fill,
        .border_color = if (grid_item.drop_preview or grid_item.selected) theme.accent else resolved.border,
        .border_width = if (grid_item.selected) 1 else resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    const inner = defaultTextBounds(rect, resolved);
    const icon_size = @max(@min(inner.w, inner.h - resolved.font_size - theme.spacing), 0);
    if (icon_size > 8) {
        const icon_rect = Rect{
            .x = inner.x + (inner.w - icon_size) * 0.5,
            .y = inner.y,
            .w = icon_size,
            .h = @min(icon_size, inner.h - resolved.font_size - theme.spacing),
        };
        const icon_fill = if (grid_item.selected)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 96)
        else
            style.Color.rgba(theme.border.r, theme.border.g, theme.border.b, 72);
        try commands.append(allocator, .{ .box = .{
            .bounds = icon_rect,
            .color = icon_fill,
            .border_color = if (grid_item.selected) theme.accent else resolved.border,
            .border_width = 1,
            .corner_radius = @min(resolved.border_radius, 8),
        } });

        if (grid_item.icon.len > 0) {
            const icon_font_size = @min(icon_rect.h * 0.46, icon_rect.w * 0.46);
            try appendTextCommand(commands, allocator, icon_rect, grid_item.icon, if (grid_item.selected) theme.accent else resolved.fg, icon_font_size, .center, .visible);
        }
    }

    const label_bounds = Rect{
        .x = inner.x,
        .y = rect.y + rect.h - resolved.padding.bottom - resolved.font_size * 1.4,
        .w = inner.w,
        .h = resolved.font_size * 1.4,
    };
    try appendTextCommand(commands, allocator, label_bounds, grid_item.label, resolved.fg, resolved.font_size, .center, .ellipsis);
    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
}

fn emitTable(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    table: widget.WidgetKind.Table,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);

    if (table.resizable and table.active_columns >= 2) {
        var divider_index: u8 = 0;
        while (divider_index + 1 < table.active_columns) : (divider_index += 1) {
            const handle_rect = widget.tableResizeHandleRect(tree, handle, divider_index) orelse continue;
            const grip_color = if (node.interaction.pressed or node.interaction.hovered) theme.accent else resolved.border;
            const grip_rect = Rect{
                .x = handle_rect.x + handle_rect.w * 0.5 - widget.WidgetKind.Table.resize_grip_width * 0.5,
                .y = handle_rect.y + handle_rect.h * 0.5 - widget.WidgetKind.Table.resize_grip_height * 0.5,
                .w = widget.WidgetKind.Table.resize_grip_width,
                .h = widget.WidgetKind.Table.resize_grip_height,
            };
            try commands.append(allocator, .{ .box = .{
                .bounds = grip_rect,
                .color = grip_color,
                .border_color = grip_color,
                .border_width = 0,
                .corner_radius = widget.WidgetKind.Table.resize_grip_width,
            } });
        }
    }
}

fn emitTableRow(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    row: widget.WidgetKind.TableRow,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const fill = tableRowFill(tree, handle, node, row, theme);
    if (fill.a > 0) {
        try commands.append(allocator, .{ .box = .{
            .bounds = node.layout_rect,
            .color = fill,
            .border_color = fill,
            .border_width = 0,
            .corner_radius = 0,
        } });
    }

    if (!tableRowIsLast(tree, handle)) {
        try commands.append(allocator, .{ .box = .{
            .bounds = .{
                .x = node.layout_rect.x,
                .y = node.layout_rect.y + node.layout_rect.h - 1,
                .w = node.layout_rect.w,
                .h = 1,
            },
            .color = resolved.border,
            .border_color = resolved.border,
            .border_width = 0,
            .corner_radius = 0,
        } });
    }

    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn emitTableCell(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    if (tableCellIndex(tree, handle) > 0) {
        const row_handle = tree.getConst(handle).parent orelse handle;
        const row_rect = tree.getConst(row_handle).layout_rect;
        try commands.append(allocator, .{ .box = .{
            .bounds = .{
                .x = node.layout_rect.x,
                .y = row_rect.y,
                .w = 1,
                .h = row_rect.h,
            },
            .color = resolved.border,
            .border_color = resolved.border,
            .border_width = 0,
            .corner_radius = 0,
        } });
    }

    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);

    if (tableSortIndicator(tree, handle)) |direction| {
        const chevron_x = node.layout_rect.x + node.layout_rect.w - resolved.padding.right - resolved.font_size * 0.8;
        const chevron_bounds = customTextBounds(node.layout_rect, resolved, chevron_x, rectRight(node.layout_rect) - resolved.padding.right - chevron_x);
        try appendTextCommand(commands, allocator, chevron_bounds, tableSortChevron(direction), theme.accent, resolved.font_size, .center, .visible);
    }
}

fn emitMenuBar(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn emitToolbar(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = 0,
    } });
    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn emitStatusBar(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = 0,
    } });
    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn emitMenu(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    menu: widget.WidgetKind.Menu,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    _: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    _ = in_floating_subtree;
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = if (menuPopupVisible(tree, handle))
            theme.bg_active
        else
            interactionBg(node, resolved, theme),
        .border_color = resolved.border,
        .border_width = 0,
        .corner_radius = resolved.border_radius,
    } });
    const menu_bounds = defaultTextBounds(node.layout_rect, resolved);
    try appendTextCommand(commands, allocator, menu_bounds, menu.label, resolved.fg, resolved.font_size, .start, .visible);
    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
}

fn emitPopup(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, true);
}

fn emitTooltip(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, true);
}

fn emitMenuItem(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    item: widget.WidgetKind.MenuItem,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    _: ?*const layout.TextMeasureCtx,
) !void {
    const has_popup = directPopupChild(tree, handle) != null;
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = if (menuPopupVisible(tree, handle))
            theme.bg_active
        else
            interactionBg(node, resolved, theme),
        .border_color = resolved.border,
        .border_width = 0,
        .corner_radius = resolved.border_radius,
    } });
    const item_bounds = defaultTextBounds(node.layout_rect, resolved);
    try appendTextCommand(commands, allocator, item_bounds, item.label, resolved.fg, resolved.font_size, .start, .visible);
    if (has_popup) {
        try emitMenuArrow(node.layout_rect, resolved, commands, allocator, resolved.fg);
    }
    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
}

fn emitDragValue(
    node: *const widget.Node,
    drag_value: *const widget.WidgetKind.DragValue,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    const rect = node.layout_rect;

    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = interactionBg(node, resolved, theme),
        .border_color = if (node.interaction.pressed or drag_value.editing) theme.accent else resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    const value_bounds = defaultTextBounds(rect, resolved);
    if (drag_value.editing) {
        try emitInlineEditorContents(value_bounds, &drag_value.editor, resolved, theme, commands, allocator, text_ctx, true);
    } else {
        try appendTextCommand(commands, allocator, value_bounds, drag_value.displayValue(), resolved.fg, resolved.font_size, .start, .clip);
    }

    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
}

fn emitSpinBox(
    node: *const widget.Node,
    spinbox: *const widget.WidgetKind.SpinBox,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    const rect = node.layout_rect;
    const buttons = spinBoxButtons(rect);
    const field_rect = Rect{
        .x = buttons.dec.x + buttons.dec.w,
        .y = rect.y,
        .w = rect.w - buttons.dec.w - buttons.inc.w,
        .h = rect.h,
    };
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = interactionBg(node, resolved, theme),
        .border_color = if (spinbox.editing) theme.accent else resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    try commands.append(allocator, .{ .box = .{
        .bounds = buttons.dec,
        .color = theme.bg_hover,
        .border_color = resolved.border,
        .border_width = 0,
        .corner_radius = resolved.border_radius,
    } });
    try commands.append(allocator, .{ .box = .{
        .bounds = buttons.inc,
        .color = theme.bg_hover,
        .border_color = resolved.border,
        .border_width = 0,
        .corner_radius = resolved.border_radius,
    } });
    const dec_text_bounds = customTextBounds(buttons.dec, resolved, buttons.dec.x, buttons.dec.w);
    const inc_text_bounds = customTextBounds(buttons.inc, resolved, buttons.inc.x, buttons.inc.w);
    const field_text_bounds = defaultTextBounds(field_rect, resolved);
    try appendTextCommand(commands, allocator, dec_text_bounds, "-", resolved.fg, resolved.font_size, .center, .visible);
    try appendTextCommand(commands, allocator, inc_text_bounds, "+", resolved.fg, resolved.font_size, .center, .visible);
    if (spinbox.editing) {
        try emitInlineEditorContents(field_text_bounds, &spinbox.editor, resolved, theme, commands, allocator, text_ctx, true);
    } else {
        try appendTextCommand(commands, allocator, field_text_bounds, spinbox.displayValue(), resolved.fg, resolved.font_size, .start, .clip);
    }

    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
}

fn emitTabBar(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    _: widget.WidgetKind.TabBar,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    var iter = tree.children(handle);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (child_node.kind != .tab_item) continue;
        try emitTabItemHeader(child_node, child_node.kind.tab_item, child_node.style_override.resolve(theme), theme, commands, allocator, text_ctx);
    }

    if (selectedTabItem(tree, handle)) |selected| {
        try emitChildren(tree, selected, theme, commands, allocator, text_ctx, in_floating_subtree);
    }
}

fn emitTabItem(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    item: widget.WidgetKind.TabItem,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    try emitTabItemHeader(node, item, resolved, theme, commands, allocator, text_ctx);
    if (item.selected) {
        try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);
    } else {
        try emitPopupChildren(tree, handle, theme, commands, allocator, text_ctx);
    }
}

fn emitTabItemHeader(
    node: *const widget.Node,
    item: widget.WidgetKind.TabItem,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    _: ?*const layout.TextMeasureCtx,
) !void {
    const chrome = tabItemChrome(node, item, resolved, theme);
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = chrome.color,
        .border_color = chrome.border_color,
        .border_width = chrome.border_width,
        .corner_radius = resolved.border_radius,
    } });
    if (item.selected) {
        try commands.append(allocator, .{ .box = .{
            .bounds = .{
                .x = node.layout_rect.x,
                .y = node.layout_rect.y + node.layout_rect.h - 2,
                .w = node.layout_rect.w,
                .h = 2,
            },
            .color = theme.accent,
            .border_color = theme.accent,
            .border_width = 0,
            .corner_radius = 0,
        } });
    }
    const tab_bounds = defaultTextBounds(node.layout_rect, resolved);
    try appendTextCommand(commands, allocator, tab_bounds, item.label, resolved.fg, resolved.font_size, .start, .clip);

    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
}

fn emitSplitter(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    splitter: widget.WidgetKind.Splitter,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = 0,
        .corner_radius = resolved.border_radius,
    } });

    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);

    const divider = splitterDividerRect(node.layout_rect, splitter, resolved);
    const grip = splitterGripRect(divider, splitter.direction);
    const divider_color = if (node.interaction.pressed)
        theme.bg_active
    else if (node.interaction.hovered)
        theme.bg_hover
    else
        resolved.border;

    try commands.append(allocator, .{ .box = .{
        .bounds = divider,
        .color = divider_color,
        .border_color = divider_color,
        .border_width = 0,
        .corner_radius = resolved.border_radius,
    } });
    try commands.append(allocator, .{ .box = .{
        .bounds = grip,
        .color = if (node.interaction.pressed or node.interaction.focused) theme.accent else resolved.fg,
        .border_color = if (node.interaction.pressed or node.interaction.focused) theme.accent else resolved.fg,
        .border_width = 0,
        .corner_radius = 2,
    } });

    try emitFocusRingRect(divider, theme, resolved.border_radius, commands, allocator, node.interaction.focused);
}

fn emitSlider(
    node: *const widget.Node,
    sl: widget.WidgetKind.Slider,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
) !void {
    const rect = node.layout_rect;

    // Track
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    // Thumb
    const range = sl.max - sl.min;
    const t = if (range > 0) (sl.value - sl.min) / range else 0;
    const thumb_w = resolved.thumb_width;
    const usable = rect.w - thumb_w;
    const thumb_x = rect.x + usable * t;

    try commands.append(allocator, .{ .box = .{
        .bounds = .{ .x = thumb_x, .y = rect.y, .w = thumb_w, .h = rect.h },
        .color = theme.accent,
        .border_color = resolved.border,
        .border_width = 0,
        .corner_radius = resolved.border_radius,
    } });

    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
}

fn emitTextInput(
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    const ti = &node.kind.text_input;
    const rect = node.layout_rect;

    // Background
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = interactionBg(node, resolved, theme),
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    const text_bounds = defaultTextBounds(rect, resolved);
    // Text content or placeholder
    const content = ti.content();
    if (content.len > 0 or node.interaction.focused) {
        try emitInlineEditorContents(text_bounds, ti, resolved, theme, commands, allocator, text_ctx, node.interaction.focused);
    } else if (ti.placeholder.len > 0) {
        try appendTextCommand(commands, allocator, text_bounds, ti.placeholder, theme.placeholder_fg, resolved.font_size, .start, .clip);
    }

    try emitFocusRing(node, theme, resolved.border_radius, commands, allocator);
}

fn emitInlineEditorContents(
    text_bounds: Rect,
    ti: *const widget.WidgetKind.TextInput,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    show_cursor: bool,
) !void {
    const content = ti.content();
    if (show_cursor and ti.hasSelection()) {
        const range = ti.selectionRange();
        const sel_start_x = text_bounds.x + layout.textWidthUpTo(content, range.start, resolved.font_size, text_ctx);
        const sel_end_x = text_bounds.x + layout.textWidthUpTo(content, range.end, resolved.font_size, text_ctx);
        try commands.append(allocator, .{ .box = .{
            .bounds = .{ .x = sel_start_x, .y = text_bounds.y, .w = sel_end_x - sel_start_x, .h = text_bounds.h },
            .color = theme.selection_bg,
            .border_color = theme.selection_bg,
            .border_width = 0,
            .corner_radius = 0,
        } });
    }

    if (content.len > 0) {
        try appendTextCommand(commands, allocator, text_bounds, content, resolved.fg, resolved.font_size, .start, .clip);
    }

    if (show_cursor) {
        const cursor_x = text_bounds.x + layout.textWidthUpTo(content, ti.cursor, resolved.font_size, text_ctx);
        try commands.append(allocator, .{ .box = .{
            .bounds = .{ .x = cursor_x, .y = text_bounds.y, .w = 1, .h = text_bounds.h },
            .color = resolved.fg,
            .border_color = resolved.fg,
            .border_width = 0,
            .corner_radius = 0,
        } });
    }
}

fn emitScrollArea(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    // Background
    try commands.append(allocator, .{ .box = .{
        .bounds = node.layout_rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    // Push clip
    try commands.append(allocator, .{ .clip = .{ .bounds = node.layout_rect } });

    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);

    // Pop clip
    try commands.append(allocator, .{ .clip = .{ .bounds = null } });
}

/// Emit a focus ring around a widget's layout rect if it has focus.
fn emitFocusRing(
    node: *const widget.Node,
    theme: style.Theme,
    corner_radius: f32,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
) !void {
    try emitFocusRingRect(node.layout_rect, theme, corner_radius, commands, allocator, node.interaction.focused);
}

fn emitFocusRingRect(
    rect: Rect,
    theme: style.Theme,
    corner_radius: f32,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    focused: bool,
) !void {
    if (!focused) return;
    const r = rect;
    const inset: f32 = -2;
    try commands.append(allocator, .{ .box = .{
        .bounds = .{
            .x = r.x + inset,
            .y = r.y + inset,
            .w = r.w - inset * 2,
            .h = r.h - inset * 2,
        },
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border_color = theme.focus_ring,
        .border_width = 2,
        .corner_radius = corner_radius + 2,
    } });
}

/// Resolve the background color for an interactive widget, accounting for
/// pressed/hovered state.
fn interactionBg(node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme) style.Color {
    return if (node.interaction.pressed)
        theme.bg_active
    else if (node.interaction.hovered)
        theme.bg_hover
    else
        resolved.bg;
}

fn selectableBg(node: *const widget.Node, selected: bool, theme: style.Theme) style.Color {
    return if (node.interaction.pressed)
        theme.bg_active
    else if (selected)
        theme.selection_bg
    else if (node.interaction.hovered)
        theme.bg_hover
    else
        .{ .r = 0, .g = 0, .b = 0, .a = 0 };
}

fn tableRowFill(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    row: widget.WidgetKind.TableRow,
    theme: style.Theme,
) style.Color {
    if (row.selected) return theme.selection_bg;
    if (row.header) return theme.bg_active;
    if (widget.tableRowSelectable(tree, handle) and node.interaction.hovered) {
        return style.Color.rgba(theme.bg_hover.r, theme.bg_hover.g, theme.bg_hover.b, 160);
    }
    if (tableStriped(tree, handle) and (tableRowIndex(tree, handle) % 2 == 1)) {
        return style.Color.rgba(theme.bg_hover.r, theme.bg_hover.g, theme.bg_hover.b, 96);
    }
    return style.Color.rgba(0, 0, 0, 0);
}

fn tableStriped(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const parent_handle = tree.getConst(handle).parent orelse return false;
    const parent = tree.getConst(parent_handle);
    return parent.kind == .table and parent.kind.table.striped;
}

fn tableRowIndex(tree: *const widget.Tree, handle: widget.NodeHandle) usize {
    var index: usize = 0;
    var current = tree.getConst(handle).prev_sibling;
    while (current) |candidate| {
        if (tree.getConst(candidate).kind == .table_row) index += 1;
        current = tree.getConst(candidate).prev_sibling;
    }
    return index;
}

fn tableRowIsLast(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    var current = tree.getConst(handle).next_sibling;
    while (current) |candidate| {
        if (tree.getConst(candidate).kind == .table_row) return false;
        current = tree.getConst(candidate).next_sibling;
    }
    return true;
}

fn tableCellIndex(tree: *const widget.Tree, handle: widget.NodeHandle) usize {
    var index: usize = 0;
    var current = tree.getConst(handle).prev_sibling;
    while (current) |candidate| {
        if (tree.getConst(candidate).kind == .table_cell) index += 1;
        current = tree.getConst(candidate).prev_sibling;
    }
    return index;
}

fn tableSortIndicator(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.WidgetKind.Table.SortDirection {
    const row_handle = tree.getConst(handle).parent orelse return null;
    const row = tree.getConst(row_handle);
    if (row.kind != .table_row or !row.kind.table_row.header) return null;

    const table_handle = row.parent orelse return null;
    const table = tree.getConst(table_handle);
    if (table.kind != .table or !table.kind.table.sortable) return null;

    const sorted_column = table.kind.table.sorted_column orelse return null;
    if (sorted_column != tableCellIndex(tree, handle)) return null;
    return table.kind.table.sort_direction;
}

fn tableSortChevron(direction: widget.WidgetKind.Table.SortDirection) []const u8 {
    return switch (direction) {
        .ascending => "▴",
        .descending => "▾",
    };
}

fn directPopupChild(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .popup) return child;
    }
    return null;
}

fn menuPopupVisible(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const popup = directPopupChild(tree, handle) orelse return false;
    return popupShouldDraw(tree, popup);
}

fn emitMenuArrow(
    rect: Rect,
    resolved: style.ResolvedStyle,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    color: style.Color,
) !void {
    const mid_y = rect.y + rect.h * 0.5;
    const right = rect.x + rect.w - resolved.padding.right * 0.75;
    try commands.append(allocator, .{ .box = .{
        .bounds = .{ .x = right - 5, .y = mid_y - 3, .w = 1, .h = 6 },
        .color = color,
        .border_color = color,
        .border_width = 0,
        .corner_radius = 0,
    } });
    try commands.append(allocator, .{ .box = .{
        .bounds = .{ .x = right - 3, .y = mid_y - 2, .w = 1, .h = 4 },
        .color = color,
        .border_color = color,
        .border_width = 0,
        .corner_radius = 0,
    } });
    try commands.append(allocator, .{ .box = .{
        .bounds = .{ .x = right - 1, .y = mid_y - 1, .w = 1, .h = 2 },
        .color = color,
        .border_color = color,
        .border_width = 0,
        .corner_radius = 0,
    } });
}

fn splitterDividerRect(rect: Rect, splitter: widget.WidgetKind.Splitter, resolved: style.ResolvedStyle) Rect {
    const inner = splitterInnerRect(rect, resolved);
    const ratio = clampedSplitterRatio(splitter, rect, resolved);
    return switch (splitter.direction) {
        .row => .{
            .x = inner.x + (inner.w - splitter.thickness) * ratio,
            .y = inner.y,
            .w = splitter.thickness,
            .h = inner.h,
        },
        .column => .{
            .x = inner.x,
            .y = inner.y + (inner.h - splitter.thickness) * ratio,
            .w = inner.w,
            .h = splitter.thickness,
        },
    };
}

fn splitterGripRect(divider: Rect, direction: widget.WidgetKind.Container.Direction) Rect {
    return switch (direction) {
        .row => .{
            .x = divider.x + divider.w * 0.5 - 1,
            .y = divider.y + divider.h * 0.5 - 12,
            .w = 2,
            .h = 24,
        },
        .column => .{
            .x = divider.x + divider.w * 0.5 - 12,
            .y = divider.y + divider.h * 0.5 - 1,
            .w = 24,
            .h = 2,
        },
    };
}

fn splitterInnerRect(rect: Rect, resolved: style.ResolvedStyle) Rect {
    return .{
        .x = rect.x + resolved.padding.left,
        .y = rect.y + resolved.padding.top,
        .w = @max(rect.w - resolved.padding.left - resolved.padding.right, 0),
        .h = @max(rect.h - resolved.padding.top - resolved.padding.bottom, 0),
    };
}

fn clampedSplitterRatio(
    splitter: widget.WidgetKind.Splitter,
    rect: Rect,
    resolved: style.ResolvedStyle,
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
    rect: Rect,
    resolved: style.ResolvedStyle,
) f32 {
    const inner = splitterInnerRect(rect, resolved);
    return switch (splitter.direction) {
        .row => inner.w - splitter.thickness,
        .column => inner.h - splitter.thickness,
    };
}

fn spinBoxButtons(rect: Rect) struct { dec: Rect, inc: Rect } {
    const button_w = @min(rect.h, 28);
    return .{
        .dec = .{ .x = rect.x, .y = rect.y, .w = button_w, .h = rect.h },
        .inc = .{ .x = rect.x + rect.w - button_w, .y = rect.y, .w = button_w, .h = rect.h },
    };
}

fn tabItemChrome(
    node: *const widget.Node,
    item: widget.WidgetKind.TabItem,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
) struct { color: style.Color, border_color: style.Color, border_width: f32 } {
    return .{
        .color = if (item.selected)
            resolved.bg
        else if (node.interaction.pressed)
            theme.bg_active
        else if (node.interaction.hovered)
            theme.bg_hover
        else
            theme.bg,
        .border_color = resolved.border,
        .border_width = if (item.selected) resolved.border_width else 0,
    };
}

fn treeItemChrome(
    node: *const widget.Node,
    item: widget.WidgetKind.TreeItem,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
) struct { color: style.Color, border_color: style.Color, border_width: f32 } {
    const has_custom_bg = node.style_override.bg != null;
    const has_custom_border = node.style_override.border != null or node.style_override.border_width != null;

    return .{
        .color = if (item.dragging)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 72)
        else if (item.drop_preview == .into)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 48)
        else if (has_custom_bg)
            interactionBg(node, resolved, theme)
        else if (item.selected)
            theme.selection_bg
        else if (node.interaction.pressed)
            theme.bg_active
        else if (node.interaction.hovered)
            theme.bg_hover
        else
            .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border_color = if (item.drop_preview == .into)
            theme.accent
        else if (has_custom_border)
            resolved.border
        else
            .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border_width = if (item.drop_preview == .into)
            @max(resolved.border_width, 1)
        else if (has_custom_border)
            resolved.border_width
        else
            0,
    };
}

fn emitTreeItemDropIndicator(
    rect: Rect,
    item: widget.WidgetKind.TreeItem,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
) !void {
    const preview = item.drop_preview orelse return;
    const indicator_bounds = switch (preview) {
        .before => Rect{
            .x = rect.x + resolved.padding.left,
            .y = rect.y,
            .w = @max(rect.w - resolved.padding.left - resolved.padding.right, 0),
            .h = 2,
        },
        .after => Rect{
            .x = rect.x + resolved.padding.left,
            .y = rect.y + rect.h - 2,
            .w = @max(rect.w - resolved.padding.left - resolved.padding.right, 0),
            .h = 2,
        },
        .into => return,
    };
    try commands.append(allocator, .{ .box = .{
        .bounds = indicator_bounds,
        .color = theme.accent,
        .border_color = theme.accent,
        .border_width = 0,
        .corner_radius = 0,
    } });
}

fn emitTreeGuides(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    row_rect: Rect,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    disclosure_center_x: f32,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
) !void {
    var ancestor = tree.getConst(handle).parent;
    var ancestor_depth = treeDepth(tree, handle);

    while (ancestor) |ancestor_handle| {
        const ancestor_node = tree.getConst(ancestor_handle);
        if (ancestor_node.kind == .tree_item) {
            ancestor_depth -= 1;
            if (hasNextTreeSibling(tree, ancestor_handle)) {
                try commands.append(allocator, .{ .box = .{
                    .bounds = .{
                        .x = treeGuideCenterX(row_rect, resolved, theme, ancestor_depth),
                        .y = row_rect.y,
                        .w = 1,
                        .h = row_rect.h,
                    },
                    .color = theme.tree_guide,
                    .border_color = theme.tree_guide,
                    .border_width = 0,
                    .corner_radius = 0,
                } });
            }
        }
        ancestor = ancestor_node.parent;
    }

    if (findTreeParent(tree, handle) != null) {
        try commands.append(allocator, .{ .box = .{
            .bounds = .{
                .x = disclosure_center_x,
                .y = row_rect.y,
                .w = 1,
                .h = row_rect.h * 0.5,
            },
            .color = theme.tree_guide,
            .border_color = theme.tree_guide,
            .border_width = 0,
            .corner_radius = 0,
        } });
    }

    const node = tree.getConst(handle);
    if (node.kind.tree_item.expanded and hasNonPopupChildren(tree, handle)) {
        try commands.append(allocator, .{ .box = .{
            .bounds = .{
                .x = disclosure_center_x,
                .y = row_rect.y + row_rect.h * 0.5,
                .w = 1,
                .h = row_rect.h * 0.5,
            },
            .color = theme.tree_guide,
            .border_color = theme.tree_guide,
            .border_width = 0,
            .corner_radius = 0,
        } });
    }
}

fn emitTreeDisclosure(
    disclosure_x: f32,
    row_rect: Rect,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    expanded: bool,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
) !void {
    const slot_width = disclosureSlotWidth(resolved);
    const size = @max(resolved.font_size * 0.7, 10);
    const box_rect = Rect{
        .x = disclosure_x + (slot_width - size) * 0.5,
        .y = row_rect.y + (row_rect.h - size) * 0.5,
        .w = size,
        .h = size,
    };

    try commands.append(allocator, .{ .box = .{
        .bounds = box_rect,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border_color = if (expanded) theme.accent else resolved.border,
        .border_width = 1,
        .corner_radius = 2,
    } });

    const bar_y = box_rect.y + @floor(box_rect.h * 0.5);
    try commands.append(allocator, .{ .box = .{
        .bounds = .{
            .x = box_rect.x + 2,
            .y = bar_y,
            .w = box_rect.w - 4,
            .h = 1,
        },
        .color = resolved.fg,
        .border_color = resolved.fg,
        .border_width = 0,
        .corner_radius = 0,
    } });

    if (!expanded) {
        const bar_x = box_rect.x + @floor(box_rect.w * 0.5);
        try commands.append(allocator, .{ .box = .{
            .bounds = .{
                .x = bar_x,
                .y = box_rect.y + 2,
                .w = 1,
                .h = box_rect.h - 4,
            },
            .color = resolved.fg,
            .border_color = resolved.fg,
            .border_width = 0,
            .corner_radius = 0,
        } });
    }
}

fn hasNextTreeSibling(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    var sibling = tree.getConst(handle).next_sibling;
    while (sibling) |next_handle| {
        const next_node = tree.getConst(next_handle);
        if (next_node.kind != .popup and next_node.kind != .tooltip) return true;
        sibling = next_node.next_sibling;
    }
    return false;
}

fn treeGuideCenterX(
    row_rect: Rect,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    depth: u32,
) f32 {
    const indent = @as(f32, @floatFromInt(depth)) * treeIndent(theme, resolved);
    return row_rect.x + resolved.padding.left + indent + disclosureSlotWidth(resolved) * 0.5;
}

fn findTreeParent(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var current = tree.getConst(handle).parent;
    while (current) |parent_handle| {
        if (tree.getConst(parent_handle).kind == .tree_item) return parent_handle;
        current = tree.getConst(parent_handle).parent;
    }
    return null;
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

fn emitChildren(
    tree: *const widget.Tree,
    parent: widget.NodeHandle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    var iter = tree.children(parent);
    while (iter.next()) |child| {
        if (!in_floating_subtree and (tree.getConst(child).kind == .popup or tree.getConst(child).kind == .tooltip)) continue;
        try emitNode(tree, child, theme, commands, allocator, text_ctx, in_floating_subtree);
    }
}

fn emitPopupChildren(
    tree: *const widget.Tree,
    parent: widget.NodeHandle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    var iter = tree.children(parent);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .popup and tree.getConst(child).kind != .tooltip) continue;
        try emitNode(tree, child, theme, commands, allocator, text_ctx, true);
    }
}

fn emitFloatingSubtrees(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    if (!shouldDrawNode(tree, handle)) return;
    const node = tree.getConst(handle);
    if (node.kind == .popup or node.kind == .tooltip) {
        try emitNode(tree, handle, theme, commands, allocator, text_ctx, true);
        return;
    }

    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (node.kind == .tree_item and !node.kind.tree_item.expanded and tree.getConst(child).kind != .popup and tree.getConst(child).kind != .tooltip) continue;
        if (node.kind == .tab_item and !node.kind.tab_item.selected) continue;
        try emitFloatingSubtrees(tree, child, theme, commands, allocator, text_ctx);
    }
}

fn emitDragGhosts(
    tree: *const widget.Tree,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    _: ?*const layout.TextMeasureCtx,
) !void {
    for (tree.nodes.items) |node| {
        if (!node.alive) continue;
        switch (node.kind) {
            .tree_item => |item| {
                if (!item.dragging or item.drag_rect.w <= 0 or item.drag_rect.h <= 0) continue;
                const resolved = node.style_override.resolve(theme);
                try emitDragGhostRect(item.drag_rect, resolved, theme, commands, allocator);
                const label_x = item.drag_rect.x + resolved.padding.left;
                const label_bounds = customTextBounds(item.drag_rect, resolved, label_x, rectRight(item.drag_rect) - resolved.padding.right - label_x);
                try appendTextCommand(commands, allocator, label_bounds, item.label, resolved.fg, resolved.font_size, .start, .clip);
            },
            .grid_item => |item| {
                if (!item.dragging or item.drag_rect.w <= 0 or item.drag_rect.h <= 0) continue;
                const resolved = node.style_override.resolve(theme);
                try emitDragGhostRect(item.drag_rect, resolved, theme, commands, allocator);
                const inner = defaultTextBounds(item.drag_rect, resolved);
                const icon_size = @max(@min(inner.w, inner.h - resolved.font_size - theme.spacing), 0);
                if (icon_size > 8) {
                    const icon_rect = Rect{
                        .x = inner.x + (inner.w - icon_size) * 0.5,
                        .y = inner.y,
                        .w = icon_size,
                        .h = @min(icon_size, inner.h - resolved.font_size - theme.spacing),
                    };
                    try commands.append(allocator, .{ .box = .{
                        .bounds = icon_rect,
                        .color = style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 96),
                        .border_color = theme.accent,
                        .border_width = 1,
                        .corner_radius = @min(resolved.border_radius, 8),
                    } });
                }
                const label_bounds = Rect{
                    .x = inner.x,
                    .y = item.drag_rect.y + item.drag_rect.h - resolved.padding.bottom - resolved.font_size * 1.4,
                    .w = inner.w,
                    .h = resolved.font_size * 1.4,
                };
                try appendTextCommand(commands, allocator, label_bounds, item.label, resolved.fg, resolved.font_size, .center, .ellipsis);
            },
            else => {},
        }
    }
}

fn emitDragGhostRect(
    rect: Rect,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
) !void {
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = style.Color.rgba(theme.bg_active.r, theme.bg_active.g, theme.bg_active.b, 216),
        .border_color = theme.accent,
        .border_width = @max(resolved.border_width, 1),
        .corner_radius = resolved.border_radius,
    } });
}

fn shouldDrawNode(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    return switch (node.kind) {
        .popup => popupShouldDraw(tree, handle),
        .tooltip => tooltipShouldDraw(tree, handle),
        else => true,
    };
}

fn popupShouldDraw(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    if (!node.kind.popup.visible) return false;

    if (node.parent) |parent_handle| {
        const parent = tree.getConst(parent_handle);
        if (parent.kind == .dropdown) {
            return parent.kind.dropdown.open;
        }
    }
    return true;
}

fn tooltipShouldDraw(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    const owner_handle = node.parent orelse return false;
    const owner = tree.getConst(owner_handle);
    return (owner.interaction.hovered or owner.interaction.focused) and node.layout_rect.w > 0 and node.layout_rect.h > 0;
}

fn hasNonPopupChildren(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .popup and tree.getConst(child).kind != .tooltip) return true;
    }
    return false;
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

fn treeIndent(theme: style.Theme, resolved: style.ResolvedStyle) f32 {
    return resolved.font_size + theme.spacing;
}

fn disclosureSlotWidth(resolved: style.ResolvedStyle) f32 {
    return resolved.font_size + 4;
}

fn dropdownChevronDown() []const u8 {
    return "▾";
}

fn dropdownChevronUp() []const u8 {
    return "▴";
}

fn testMeasureText(text: []const u8, font_size: f32, _: ?*anyopaque) layout.TextDimensions {
    return .{
        .width = @as(f32, @floatFromInt(text.len)) * font_size * 0.5,
        .height = 20,
        .ascent = 14,
        .descent = 6,
    };
}

fn testMeasureTextWithStringBounds(text: []const u8, font_size: f32, _: ?*anyopaque) layout.TextDimensions {
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

test "generate draw commands from tree" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    _ = try tree.addChild(root, .{ .button = .{ .label = "OK" } });
    _ = try tree.addChild(root, .{ .text = .{ .content = "hello" } });

    // Set some layout rects so draw has something to work with
    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    // Container bg + button bg + button text + text label = 4 commands
    try std.testing.expectEqual(@as(usize, 4), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // container bg
    try std.testing.expect(dl.commands[1] == .rect); // button bg
    try std.testing.expect(dl.commands[2] == .text); // button label
    try std.testing.expect(dl.commands[3] == .text); // text widget
}

test "text draw commands carry bounds and baseline" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const button = try tree.addRoot(.{ .button = .{ .label = "OK" } });
    tree.get(button).layout_rect = .{ .x = 10, .y = 20, .w = 120, .h = 40 };

    const text_ctx = layout.TextMeasureCtx{
        .measureFn = &testMeasureText,
    };

    var dl = try generate(&tree, style.Theme.default, allocator, &text_ctx);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[1] == .text);

    const text = dl.commands[1].text;
    try std.testing.expectApproxEqAbs(@as(f32, 16), text.bounds.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 26), text.bounds.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 108), text.bounds.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 28), text.bounds.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 44), text.baseline_y, 0.01);
}

test "custom draw commands are emitted before floating popups" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const button = try tree.addChild(root, .{ .button = .{ .label = "Preview" } });
    const menu = try tree.addChild(root, .{ .menu = .{ .label = "File" } });
    const popup = try tree.addChild(menu, .{ .popup = .{
        .placement = .below_start,
        .visible = true,
    } });
    _ = try tree.addChild(popup, .{ .menu_item = .{ .label = "Open" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(button).layout_rect = .{ .x = 10, .y = 10, .w = 96, .h = 32 };
    tree.get(button).custom_draw = true;
    tree.get(menu).layout_rect = .{ .x = 118, .y = 10, .w = 64, .h = 32 };
    tree.get(popup).layout_rect = .{ .x = 118, .y = 42, .w = 140, .h = 28 };
    const item = tree.getConst(popup).first_child.?;
    tree.get(item).layout_rect = .{ .x = 118, .y = 42, .w = 140, .h = 28 };

    var dl = try generate(&tree, style.Theme.default, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 9), dl.commands.len);
    try std.testing.expect(dl.commands[3] == .custom);
    try std.testing.expect(dl.commands[6] == .rect);
    try std.testing.expect(dl.commands[6].rect.bounds.x == tree.getConst(popup).layout_rect.x);
    try std.testing.expect(dl.commands[6].rect.bounds.y == tree.getConst(popup).layout_rect.y);
}

test "toolbar and status bar emit chrome and children" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const toolbar = try tree.addRoot(.{ .toolbar = .{} });
    const tool_button = try tree.addChild(toolbar, .{ .button = .{ .label = "Move" } });
    const status = try tree.addRoot(.{ .status_bar = .{} });
    const status_text = try tree.addChild(status, .{ .text = .{ .content = "Ready" } });

    tree.get(toolbar).layout_rect = .{ .x = 0, .y = 0, .w = 320, .h = 34 };
    tree.get(tool_button).layout_rect = .{ .x = 8, .y = 6, .w = 64, .h = 22 };
    tree.get(status).layout_rect = .{ .x = 0, .y = 40, .w = 320, .h = 24 };
    tree.get(status_text).layout_rect = .{ .x = 8, .y = 45, .w = 40, .h = 14 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 5), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // toolbar chrome
    try std.testing.expect(dl.commands[1] == .rect); // toolbar button
    try std.testing.expect(dl.commands[2] == .text); // toolbar button label
    try std.testing.expect(dl.commands[3] == .rect); // status bar chrome
    try std.testing.expect(dl.commands[4] == .text); // status text
}

test "checkbox emits box and label" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const cb = try tree.addRoot(.{ .checkbox = .{ .label = "Enable", .checked = false } });
    tree.get(cb).layout_rect = .{ .x = 10, .y = 20, .w = 200, .h = 26 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    // Unchecked: box rect + label text = 2 commands
    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // box
    try std.testing.expect(dl.commands[1] == .text); // label
}

test "checked checkbox emits indicator" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const cb = try tree.addRoot(.{ .checkbox = .{ .label = "Enable", .checked = true } });
    tree.get(cb).layout_rect = .{ .x = 10, .y = 20, .w = 200, .h = 26 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    // Checked: box rect + indicator rect + label text = 3 commands
    try std.testing.expectEqual(@as(usize, 3), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // box
    try std.testing.expect(dl.commands[1] == .rect); // check indicator
    try std.testing.expect(dl.commands[2] == .text); // label
}

test "radio button emits circle and label" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const rb = try tree.addRoot(.{ .radio_button = .{ .label = "Option A", .group = 1 } });
    tree.get(rb).layout_rect = .{ .x = 10, .y = 20, .w = 200, .h = 26 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    // Unselected: circle rect + label text = 2 commands
    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect);
    try std.testing.expect(dl.commands[1] == .text);

    // Corner radius should be half the box size (circular)
    const circle = dl.commands[0].rect;
    try std.testing.expectApproxEqAbs(circle.bounds.w / 2, circle.corner_radius, 0.01);
}

test "selected radio button emits indicator dot" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const rb = try tree.addRoot(.{ .radio_button = .{ .label = "Option A", .group = 1, .selected = true } });
    tree.get(rb).layout_rect = .{ .x = 10, .y = 20, .w = 200, .h = 26 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    // Selected: circle rect + indicator dot + label text = 3 commands
    try std.testing.expectEqual(@as(usize, 3), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect);
    try std.testing.expect(dl.commands[1] == .rect);
    try std.testing.expect(dl.commands[2] == .text);
}

test "selected tree item uses fill without button border" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const item = try tree.addRoot(.{ .tree_item = .{
        .label = "Scene",
        .group = 1,
        .selected = true,
    } });
    tree.get(item).layout_rect = .{ .x = 10, .y = 20, .w = 200, .h = 26 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect);
    try std.testing.expect(dl.commands[1] == .text);
    try std.testing.expectEqual(theme.selection_bg, dl.commands[0].rect.color);
    try std.testing.expectEqual(@as(f32, 0), dl.commands[0].rect.border_width);
}

test "expanded tree item emits disclosure and child guides" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const parent = try tree.addChild(root, .{ .tree_item = .{
        .label = "Scene",
        .group = 1,
        .expanded = true,
    } });
    const child = try tree.addChild(parent, .{ .tree_item = .{
        .label = "Camera",
        .group = 1,
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 240, .h = 80 };
    tree.get(parent).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };
    tree.get(child).layout_rect = .{ .x = 10, .y = 36, .w = 220, .h = 26 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 9), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // root bg
    try std.testing.expect(dl.commands[1] == .rect); // parent downward guide
    try std.testing.expect(dl.commands[2] == .rect); // disclosure box
    try std.testing.expect(dl.commands[3] == .rect); // disclosure minus
    try std.testing.expect(dl.commands[4] == .rect); // parent connector
    try std.testing.expect(dl.commands[5] == .text); // parent label
    try std.testing.expect(dl.commands[6] == .rect); // child vertical guide
    try std.testing.expect(dl.commands[7] == .rect); // child connector
    try std.testing.expect(dl.commands[8] == .text); // child label
}

test "drag value emits bg and formatted text" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const drag_value = try tree.addRoot(.{ .drag_value = .{
        .value = 12.5,
        .precision = 1,
    } });
    tree.get(drag_value).layout_rect = .{ .x = 10, .y = 20, .w = 120, .h = 28 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect);
    try std.testing.expect(dl.commands[1] == .text);
    try std.testing.expectEqualStrings("12.5", dl.commands[1].text.text);
}

test "spinbox emits buttons and value" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const spinbox = try tree.addRoot(.{ .spinbox = .{
        .value = 4,
        .precision = 0,
    } });
    tree.get(spinbox).layout_rect = .{ .x = 10, .y = 20, .w = 120, .h = 28 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 6), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect);
    try std.testing.expect(dl.commands[1] == .rect);
    try std.testing.expect(dl.commands[2] == .rect);
    try std.testing.expect(dl.commands[3] == .text);
    try std.testing.expect(dl.commands[4] == .text);
    try std.testing.expect(dl.commands[5] == .text);
    try std.testing.expectEqualStrings("4", dl.commands[5].text.text);
}

test "numeric controls baseline uses stable line metrics" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const drag_value = try tree.addRoot(.{ .drag_value = .{
        .value = 12.5,
        .precision = 1,
    } });
    const spinbox = try tree.addRoot(.{ .spinbox = .{
        .value = 64,
        .precision = 0,
    } });
    tree.get(drag_value).layout_rect = .{ .x = 10, .y = 20, .w = 120, .h = 28 };
    tree.get(spinbox).layout_rect = .{ .x = 10, .y = 60, .w = 120, .h = 28 };

    const text_ctx = layout.TextMeasureCtx{
        .measureFn = &testMeasureTextWithStringBounds,
    };

    var dl = try generate(&tree, style.Theme.default, allocator, &text_ctx);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectApproxEqAbs(@as(f32, 40), dl.commands[1].text.baseline_y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 80), dl.commands[7].text.baseline_y, 0.01);
}

test "tab bar emits selected tab header and active panel only" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const tab_bar = try tree.addRoot(.{ .tab_bar = .{} });
    const scene = try tree.addChild(tab_bar, .{ .tab_item = .{
        .label = "Scene",
        .selected = true,
    } });
    const render = try tree.addChild(tab_bar, .{ .tab_item = .{
        .label = "Render",
    } });
    const active_text = try tree.addChild(scene, .{ .text = .{ .content = "Active panel" } });
    const hidden_text = try tree.addChild(render, .{ .text = .{ .content = "Hidden panel" } });

    tree.get(tab_bar).layout_rect = .{ .x = 0, .y = 0, .w = 220, .h = 90 };
    tree.get(scene).layout_rect = .{ .x = 0, .y = 0, .w = 70, .h = 28 };
    tree.get(render).layout_rect = .{ .x = 74, .y = 0, .w = 80, .h = 28 };
    tree.get(active_text).layout_rect = .{ .x = 8, .y = 40, .w = 100, .h = 18 };
    tree.get(hidden_text).layout_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 7), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // tab bar bg
    try std.testing.expect(dl.commands[1] == .rect); // selected tab rect
    try std.testing.expect(dl.commands[2] == .rect); // selected tab underline
    try std.testing.expect(dl.commands[3] == .text); // selected tab label
    try std.testing.expect(dl.commands[4] == .rect); // inactive tab rect
    try std.testing.expect(dl.commands[5] == .text); // inactive tab label
    try std.testing.expect(dl.commands[6] == .text); // selected panel content
    try std.testing.expectEqualStrings("Active panel", dl.commands[6].text.text);
}

test "table emits header fill, stripes, and column dividers" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const table = try tree.addRoot(.{ .table = .{ .columns = 2 } });
    const header = try tree.addChild(table, .{ .table_row = .{ .header = true } });
    const header_name = try tree.addChild(header, .{ .table_cell = .{} });
    const header_type = try tree.addChild(header, .{ .table_cell = .{} });
    const row = try tree.addChild(table, .{ .table_row = .{} });
    const row_name = try tree.addChild(row, .{ .table_cell = .{} });
    const row_type = try tree.addChild(row, .{ .table_cell = .{} });
    const header_name_text = try tree.addChild(header_name, .{ .text = .{ .content = "Name" } });
    const header_type_text = try tree.addChild(header_type, .{ .text = .{ .content = "Type" } });
    const row_name_text = try tree.addChild(row_name, .{ .text = .{ .content = "Cube" } });
    const row_type_text = try tree.addChild(row_type, .{ .text = .{ .content = "Mesh" } });

    tree.get(table).layout_rect = .{ .x = 0, .y = 0, .w = 280, .h = 56 };
    tree.get(header).layout_rect = .{ .x = 0, .y = 0, .w = 280, .h = 28 };
    tree.get(header_name).layout_rect = .{ .x = 0, .y = 0, .w = 140, .h = 28 };
    tree.get(header_type).layout_rect = .{ .x = 140, .y = 0, .w = 140, .h = 28 };
    tree.get(row).layout_rect = .{ .x = 0, .y = 28, .w = 280, .h = 28 };
    tree.get(row_name).layout_rect = .{ .x = 0, .y = 28, .w = 140, .h = 28 };
    tree.get(row_type).layout_rect = .{ .x = 140, .y = 28, .w = 140, .h = 28 };
    tree.get(header_name_text).layout_rect = .{ .x = 8, .y = 6, .w = 40, .h = 14 };
    tree.get(header_type_text).layout_rect = .{ .x = 148, .y = 6, .w = 40, .h = 14 };
    tree.get(row_name_text).layout_rect = .{ .x = 8, .y = 34, .w = 40, .h = 14 };
    tree.get(row_type_text).layout_rect = .{ .x = 148, .y = 34, .w = 40, .h = 14 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 10), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // table bg
    try std.testing.expect(dl.commands[1] == .rect); // header fill
    try std.testing.expect(dl.commands[2] == .rect); // header bottom line
    try std.testing.expect(dl.commands[3] == .text); // header name
    try std.testing.expect(dl.commands[4] == .rect); // header divider
    try std.testing.expect(dl.commands[5] == .text); // header type
    try std.testing.expect(dl.commands[6] == .rect); // striped row fill
    try std.testing.expect(dl.commands[7] == .text); // row name
    try std.testing.expect(dl.commands[8] == .rect); // row divider
    try std.testing.expect(dl.commands[9] == .text); // row type
    try std.testing.expectEqualStrings("Cube", dl.commands[7].text.text);
    try std.testing.expectEqualStrings("Mesh", dl.commands[9].text.text);
}

test "resizable table emits header grips" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const table = try tree.addRoot(.{ .table = .{
        .columns = 2,
        .resizable = true,
    } });
    const header = try tree.addChild(table, .{ .table_row = .{ .header = true } });
    const header_name = try tree.addChild(header, .{ .table_cell = .{} });
    const header_type = try tree.addChild(header, .{ .table_cell = .{} });
    const header_name_text = try tree.addChild(header_name, .{ .text = .{ .content = "Name" } });
    const header_type_text = try tree.addChild(header_type, .{ .text = .{ .content = "Type" } });

    tree.get(table).layout_rect = .{ .x = 0, .y = 0, .w = 280, .h = 28 };
    tree.get(header).layout_rect = .{ .x = 0, .y = 0, .w = 280, .h = 28 };
    tree.get(header_name).layout_rect = .{ .x = 0, .y = 0, .w = 140, .h = 28 };
    tree.get(header_type).layout_rect = .{ .x = 140, .y = 0, .w = 140, .h = 28 };
    tree.get(header_name_text).layout_rect = .{ .x = 8, .y = 6, .w = 40, .h = 14 };
    tree.get(header_type_text).layout_rect = .{ .x = 148, .y = 6, .w = 40, .h = 14 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 6), dl.commands.len);
    try std.testing.expect(dl.commands[5] == .rect);
    try std.testing.expectApproxEqAbs(@as(f32, 139), dl.commands[5].rect.bounds.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 8), dl.commands[5].rect.bounds.y, 0.01);
    try std.testing.expectApproxEqAbs(widget.WidgetKind.Table.resize_grip_height, dl.commands[5].rect.bounds.h, 0.01);
}

test "sortable table emits active sort indicator" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const table = try tree.addRoot(.{ .table = .{
        .columns = 2,
        .sortable = true,
        .sorted_column = 1,
        .sort_direction = .descending,
    } });
    tree.get(table).kind.table.syncColumns(2);

    const header = try tree.addChild(table, .{ .table_row = .{ .header = true } });
    const header_name = try tree.addChild(header, .{ .table_cell = .{} });
    const header_type = try tree.addChild(header, .{ .table_cell = .{} });
    const header_name_text = try tree.addChild(header_name, .{ .text = .{ .content = "Name" } });
    const header_type_text = try tree.addChild(header_type, .{ .text = .{ .content = "Type" } });

    tree.get(table).layout_rect = .{ .x = 0, .y = 0, .w = 280, .h = 28 };
    tree.get(header).layout_rect = .{ .x = 0, .y = 0, .w = 280, .h = 28 };
    tree.get(header_name).layout_rect = .{ .x = 0, .y = 0, .w = 140, .h = 28 };
    tree.get(header_type).layout_rect = .{ .x = 140, .y = 0, .w = 140, .h = 28 };
    tree.get(header_name_text).layout_rect = .{ .x = 8, .y = 6, .w = 40, .h = 14 };
    tree.get(header_type_text).layout_rect = .{ .x = 148, .y = 6, .w = 40, .h = 14 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    var found_indicator = false;
    for (dl.commands) |command| {
        if (command != .text) continue;
        if (std.mem.eql(u8, command.text.text, "▾")) {
            found_indicator = true;
            break;
        }
    }
    try std.testing.expect(found_indicator);
}

test "slider emits track and thumb" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const sl = try tree.addRoot(.{ .slider = .{ .value = 0.5, .min = 0, .max = 1 } });
    tree.get(sl).layout_rect = .{ .x = 10, .y = 20, .w = 200, .h = 24 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    // Track + thumb = 2 rects
    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // track
    try std.testing.expect(dl.commands[1] == .rect); // thumb

    // Thumb should be roughly centered for value=0.5
    const thumb = dl.commands[1].rect;
    const expected_x = 10.0 + (200.0 - 16.0) * 0.5;
    try std.testing.expectApproxEqAbs(expected_x, thumb.bounds.x, 0.01);
}

test "scroll area emits clip commands" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    _ = try tree.addChild(scroll, .{ .text = .{ .content = "inside" } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 200 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    // bg rect + clip push + text + clip pop = 4
    try std.testing.expectEqual(@as(usize, 4), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // bg
    try std.testing.expect(dl.commands[1] == .clip); // push
    try std.testing.expect(dl.commands[1].clip.bounds != null);
    try std.testing.expect(dl.commands[2] == .text); // child text
    try std.testing.expect(dl.commands[3] == .clip); // pop
    try std.testing.expect(dl.commands[3].clip.bounds == null);
}

test "text input emits bg and text" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const ti = try tree.addRoot(.{ .text_input = .{} });
    tree.get(ti).layout_rect = .{ .x = 10, .y = 20, .w = 300, .h = 30 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    // Unfocused, empty, no placeholder: bg rect only = 1 command
    try std.testing.expectEqual(@as(usize, 1), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // bg
}

test "focused text input emits cursor" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const ti = try tree.addRoot(.{ .text_input = .{} });
    tree.get(ti).layout_rect = .{ .x = 10, .y = 20, .w = 300, .h = 30 };
    tree.get(ti).interaction.focused = true;

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    // Focused, empty, no placeholder: bg rect + cursor rect + focus ring = 3 commands
    try std.testing.expectEqual(@as(usize, 3), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // bg
    try std.testing.expect(dl.commands[1] == .rect); // cursor
    try std.testing.expect(dl.commands[2] == .rect); // focus ring
}

test "empty text input shows placeholder" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const ti = try tree.addRoot(.{ .text_input = .{ .placeholder = "Enter name" } });
    tree.get(ti).layout_rect = .{ .x = 10, .y = 20, .w = 300, .h = 30 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    // Empty with placeholder: bg rect + placeholder text = 2 commands
    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // bg
    try std.testing.expect(dl.commands[1] == .text); // placeholder
    try std.testing.expectEqualStrings("Enter name", dl.commands[1].text.text);
    try std.testing.expectEqual(theme.placeholder_fg, dl.commands[1].text.color);
}

test "text input with content shows content not placeholder" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const ti = try tree.addRoot(.{ .text_input = .{ .placeholder = "Enter name" } });
    tree.get(ti).layout_rect = .{ .x = 10, .y = 20, .w = 300, .h = 30 };
    tree.get(ti).kind.text_input.insert('H');
    tree.get(ti).kind.text_input.insert('i');

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    // Has content: bg rect + content text = 2 commands
    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // bg
    try std.testing.expect(dl.commands[1] == .text); // content, not placeholder
    try std.testing.expectEqualStrings("Hi", dl.commands[1].text.text);
    try std.testing.expectEqual(theme.fg, dl.commands[1].text.color);
}

test "focused text input with selection emits highlight rect" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const ti = try tree.addRoot(.{ .text_input = .{} });
    tree.get(ti).layout_rect = .{ .x = 10, .y = 20, .w = 300, .h = 30 };
    tree.get(ti).interaction.focused = true;

    // Insert "hello" then select positions 1..3 ("el")
    const input = &tree.get(ti).kind.text_input;
    input.insert('h');
    input.insert('e');
    input.insert('l');
    input.insert('l');
    input.insert('o');
    input.cursor = 3;
    input.selection_anchor = 1;

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    // bg rect + selection highlight + text + cursor + focus ring = 5 commands
    try std.testing.expectEqual(@as(usize, 5), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // bg
    try std.testing.expect(dl.commands[1] == .rect); // selection highlight
    try std.testing.expect(dl.commands[2] == .text); // content
    try std.testing.expect(dl.commands[3] == .rect); // cursor
    try std.testing.expect(dl.commands[4] == .rect); // focus ring

    // Verify selection highlight color
    try std.testing.expectEqual(theme.selection_bg, dl.commands[1].rect.color);
}
