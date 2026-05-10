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

var active_paint_cull_rect: ?Rect = null;
const PaintOffset = struct {
    x: f32 = 0,
    y: f32 = 0,
};
var active_paint_offset = PaintOffset{};

pub const TextAlign = enum {
    start,
    center,
    end,
};

pub const TextOverflow = enum {
    visible,
    wrap,
    clip,
    ellipsis,
};

/// Opaque icon identity. The core does not interpret this value — it is
/// passed through from widgets to the embedder, which maps it to whatever
/// asset or vector path it wants to draw. Embedders are free to define
/// their own numeric scheme.
pub const IconId = u32;

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
        kind: IconId,
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
        kind: IconId,
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
    return generatePaintWithFloating(tree, theme, allocator, text_ctx, true);
}

pub fn generatePaintWithoutFloating(tree: *const widget.Tree, theme: style.Theme, allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx) !PaintList {
    return generatePaintWithFloating(tree, theme, allocator, text_ctx, false);
}

pub fn generatePaintForPopup(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme, allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx) !PaintList {
    var commands: std.ArrayListUnmanaged(PaintCommand) = .empty;
    errdefer commands.deinit(allocator);
    const previous_cull_rect = active_paint_cull_rect;
    const previous_offset = active_paint_offset;
    defer active_paint_cull_rect = previous_cull_rect;
    defer active_paint_offset = previous_offset;

    const rect = tree.getConst(handle).layout_rect;
    active_paint_cull_rect = null;
    active_paint_offset = .{ .x = -rect.x, .y = -rect.y };

    try emitNode(tree, handle, theme, &commands, allocator, text_ctx, true);

    return .{ .commands = try commands.toOwnedSlice(allocator) };
}

fn generatePaintWithFloating(tree: *const widget.Tree, theme: style.Theme, allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, include_floating: bool) !PaintList {
    var commands: std.ArrayListUnmanaged(PaintCommand) = .empty;
    errdefer commands.deinit(allocator);
    const previous_cull_rect = active_paint_cull_rect;
    const previous_offset = active_paint_offset;
    defer active_paint_cull_rect = previous_cull_rect;
    defer active_paint_offset = previous_offset;
    active_paint_cull_rect = null;
    active_paint_offset = .{};

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive) continue;
        if (node.parent == null) {
            const handle = tree.handleFromIndex(@intCast(i));
            if (node.kind != .popup and node.kind != .tooltip) {
                try emitRootNode(tree, handle, theme, &commands, allocator, text_ctx);
            }
        }
    }

    if (include_floating) {
        for (tree.nodes.items, 0..) |node, i| {
            if (!node.alive) continue;
            if (node.parent == null) {
                try emitFloatingSubtrees(tree, tree.handleFromIndex(@intCast(i)), theme, &commands, allocator, text_ctx);
            }
        }
    }

    try emitDragGhosts(tree, theme, &commands, allocator, text_ctx);

    return .{ .commands = try commands.toOwnedSlice(allocator) };
}

fn emitRootNode(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) std.mem.Allocator.Error!void {
    const previous_cull_rect = active_paint_cull_rect;
    active_paint_cull_rect = if (previous_cull_rect) |cull_rect|
        intersectRects(cull_rect, paintRect(tree.getConst(handle).layout_rect))
    else
        paintRect(tree.getConst(handle).layout_rect);
    defer active_paint_cull_rect = previous_cull_rect;

    try emitNode(tree, handle, theme, commands, allocator, text_ctx, false);
}

pub fn freePaintList(paint_list: *PaintList, allocator: std.mem.Allocator) void {
    allocator.free(paint_list.commands);
    paint_list.commands = &.{};
}

pub fn lowerPaintList(paint_list: PaintList, allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx) !DrawList {
    var commands: std.ArrayListUnmanaged(DrawCommand) = .empty;
    errdefer commands.deinit(allocator);
    var metrics_cache = TextMetricsCache{};

    for (paint_list.commands) |command| {
        switch (command) {
            .box => |box| try commands.append(allocator, .{ .rect = .{
                .bounds = box.bounds,
                .color = box.color,
                .border_color = box.border_color,
                .border_width = box.border_width,
                .corner_radius = box.corner_radius,
            } }),
            .text => |text| {
                const metrics = metrics_cache.metricsFor(text.font_size, text_ctx);
                try commands.append(allocator, .{ .text = lowerTextCommand(text, metrics) });
            },
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
    const node_rect = paintRect(node.layout_rect);
    if (!shouldDrawNode(tree, handle)) return;
    if (!in_floating_subtree and (node.kind == .popup or node.kind == .tooltip)) return;
    if (!in_floating_subtree) {
        if (active_paint_cull_rect) |cull_rect| {
            if (node_rect.w > 0 and node_rect.h > 0 and !rectsIntersect(node_rect, cull_rect) and !shouldTraverseCulledNode(tree, handle)) return;
        }
    }
    const resolved = node.style_override.resolve(theme);

    switch (node.kind) {
        .container => try emitContainer(tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .text => |txt| try emitText(node, txt, resolved, commands, allocator, text_ctx),
        .button => |btn| try emitButton(tree, handle, node, btn, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .checkbox => |cb| try emitCheckbox(node, cb, resolved, theme, commands, allocator, text_ctx),
        .radio_button => |rb| try emitRadioButton(node, rb, resolved, theme, commands, allocator, text_ctx),
        .tree_item => |tree_item| try emitTreeItem(tree, handle, node, tree_item, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .dropdown => |dropdown| try emitDropdown(tree, handle, node, dropdown, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
        .list_box => |list_box| try emitListBox(tree, handle, node, list_box, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
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
        .spacer => {},
        .text_input => try emitTextInput(node, resolved, theme, commands, allocator, text_ctx),
        .scroll_area => try emitScrollArea(tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree),
    }

    try emitDropTargetOverlay(node, resolved, theme, commands, allocator);

    if (node.custom_draw and node.kind != .table_cell and node_rect.w > 0 and node_rect.h > 0) {
        try commands.append(allocator, .{ .custom = .{
            .handle = handle,
            .bounds = node_rect,
        } });
    }
}

fn paintRect(rect: Rect) Rect {
    return .{
        .x = rect.x + active_paint_offset.x,
        .y = rect.y + active_paint_offset.y,
        .w = rect.w,
        .h = rect.h,
    };
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
    const rect = paintRect(node.layout_rect);
    // Background rect
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
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

const TextMetricsCache = struct {
    const Entry = struct {
        font_size: f32,
        metrics: layout.TextDimensions,
    };

    entries: [8]?Entry = [_]?Entry{null} ** 8,
    len: usize = 0,
    next_slot: usize = 0,

    fn metricsFor(self: *TextMetricsCache, font_size: f32, text_ctx: ?*const layout.TextMeasureCtx) layout.TextDimensions {
        for (self.entries[0..self.len]) |entry_opt| {
            const entry = entry_opt orelse continue;
            if (entry.font_size == font_size) return entry.metrics;
        }

        const metrics = layout.textMetrics(font_size, text_ctx);
        if (self.len < self.entries.len) {
            self.entries[self.len] = .{
                .font_size = font_size,
                .metrics = metrics,
            };
            self.len += 1;
        } else {
            self.entries[self.next_slot] = .{
                .font_size = font_size,
                .metrics = metrics,
            };
            self.next_slot = (self.next_slot + 1) % self.entries.len;
        }
        return metrics;
    }
};

fn lowerTextCommand(text: PaintCommand.Text, metrics: layout.TextDimensions) DrawCommand.DrawText {
    return .{
        .bounds = text.bounds,
        .baseline_y = textBaselineY(text.bounds, metrics),
        .text = text.text,
        .color = text.color,
        .font_size = text.font_size,
        .text_align = text.text_align,
        .overflow = text.overflow,
    };
}

fn textBaselineY(bounds: Rect, metrics: layout.TextDimensions) f32 {
    const extra_vertical = @max(bounds.h - metrics.height, 0);
    return bounds.y + extra_vertical * 0.5 + metrics.ascent;
}

fn emitText(
    node: *const widget.Node,
    txt: widget.WidgetKind.Text,
    resolved: style.ResolvedStyle,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    const bounds = paintRect(node.layout_rect);
    if (txt.overflow == .wrap) {
        try appendWrappedTextCommands(commands, allocator, bounds, txt.content, resolved.fg, resolved.font_size, text_ctx);
    } else {
        try appendTextCommand(commands, allocator, bounds, txt.content, resolved.fg, resolved.font_size, .start, txt.overflow);
    }
}

fn appendWrappedTextCommands(
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    bounds: Rect,
    text: []const u8,
    color: style.Color,
    font_size: f32,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    if (text.len == 0) return;
    if (bounds.w <= 0.01) {
        try appendTextCommand(commands, allocator, bounds, text, color, font_size, .start, .visible);
        return;
    }

    const metrics = layout.textMetrics(font_size, text_ctx);
    const line_h = @max(metrics.height, font_size);
    var y = bounds.y;
    var start: usize = 0;
    while (start <= text.len) {
        if (wrappedTextPastCull(y)) return;
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        y = try appendWrappedParagraph(commands, allocator, bounds, y, line_h, text[start..end], color, font_size, text_ctx);
        if (end == text.len) break;
        if (end == start) y += line_h;
        start = end + 1;
    }
}

fn appendWrappedParagraph(
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    bounds: Rect,
    start_y: f32,
    line_h: f32,
    text: []const u8,
    color: style.Color,
    font_size: f32,
    text_ctx: ?*const layout.TextMeasureCtx,
) !f32 {
    if (text.len == 0) return start_y;
    var y = start_y;
    var line_start: usize = 0;
    var line_end: usize = 0;
    var wrap_end: ?usize = null;
    const wrap_width = bounds.w + @max(font_size * 0.25, 1);
    const full_width = layout.measureTextDimensions(text, font_size, text_ctx).width;
    if (full_width <= wrap_width) {
        const trimmed_end = trimTrailingWhitespace(text);
        if (trimmed_end > 0) {
            try appendWrappedLineCommand(commands, allocator, bounds, y, line_h, text[0..trimmed_end], color, font_size);
        }
        return y + line_h;
    }

    var view = std.unicode.Utf8View.init(text) catch {
        try appendWrappedLineCommand(commands, allocator, bounds, y, line_h, text, color, font_size);
        return y + line_h;
    };
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const offset = @intFromPtr(slice.ptr) - @intFromPtr(text.ptr);
        const end = offset + slice.len;
        const codepoint = std.unicode.utf8Decode(slice) catch 0;
        const candidate = text[line_start..end];
        const candidate_width = layout.measureTextDimensions(candidate, font_size, text_ctx).width;
        if (candidate_width <= wrap_width or line_start == offset) {
            line_end = end;
            if (isTextWrapBoundary(codepoint)) wrap_end = end;
            continue;
        }

        const chosen_end = wrap_end orelse if (isTextWrapBoundary(codepoint)) offset else {
            line_end = end;
            continue;
        };
        const trimmed_end = trimTrailingWhitespace(text[line_start..chosen_end]) + line_start;
        const emitted_visible_line = trimmed_end > line_start;
        if (trimmed_end > line_start) {
            try appendWrappedLineCommand(commands, allocator, bounds, y, line_h, text[line_start..trimmed_end], color, font_size);
            y += line_h;
            if (wrappedTextPastCull(y)) return y;
        }

        line_start = if (emitted_visible_line) skipSoftWrapWhitespace(text, chosen_end) else chosen_end;
        if (line_start >= end) {
            line_end = line_start;
            wrap_end = null;
            continue;
        }

        line_end = end;
        wrap_end = if (isTextWrapBoundary(codepoint)) end else null;
    }

    const trimmed_end = trimTrailingWhitespace(text[line_start..line_end]) + line_start;
    if (trimmed_end > line_start) {
        try appendWrappedLineCommand(commands, allocator, bounds, y, line_h, text[line_start..trimmed_end], color, font_size);
        y += line_h;
    }
    return y;
}

fn appendWrappedLineCommand(
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    bounds: Rect,
    y: f32,
    line_h: f32,
    text: []const u8,
    color: style.Color,
    font_size: f32,
) !void {
    const line_bounds = Rect{ .x = bounds.x, .y = y, .w = bounds.w, .h = line_h };
    if (active_paint_cull_rect) |cull_rect| {
        if (!rectsIntersect(line_bounds, cull_rect)) return;
    }
    try appendTextCommand(commands, allocator, line_bounds, text, color, font_size, .start, .clip);
}

fn wrappedTextPastCull(y: f32) bool {
    const cull_rect = active_paint_cull_rect orelse return false;
    return y >= cull_rect.y + cull_rect.h;
}

fn isTextWrapBoundary(codepoint: u21) bool {
    return switch (codepoint) {
        ' ', '\t', '/', '\\', '-', '_', '.', ',' => true,
        else => false,
    };
}

fn trimTrailingWhitespace(text: []const u8) usize {
    var end = text.len;
    while (end > 0 and std.ascii.isWhitespace(text[end - 1])) end -= 1;
    return end;
}

fn skipSoftWrapWhitespace(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len and std.ascii.isWhitespace(text[index])) index += 1;
    return index;
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
    const rect = paintRect(node.layout_rect);
    // Background rect
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = interactionBg(node, resolved, theme),
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    const label_bounds = defaultTextBounds(rect, resolved);
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
    const rect = paintRect(node.layout_rect);
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
    const rect = paintRect(node.layout_rect);
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
    const rect = paintRect(node.layout_rect);
    const depth = treeDepth(tree, handle);
    const indent = @as(f32, @floatFromInt(depth)) * treeIndent(theme, resolved);
    const slot_width = disclosureSlotWidth(resolved);
    const disclosure_x = rect.x + resolved.padding.left + indent;
    const disclosure_center_x = disclosure_x + slot_width * 0.5;
    const label_x = disclosure_x + slot_width;
    const icon_size = treeItemIconSize(item, rect, resolved);
    const icon_gap = treeItemIconGap(item, theme);
    const text_x = label_x + icon_size + icon_gap;
    const label_bounds = customTextBounds(rect, resolved, text_x, rect.x + rect.w - resolved.padding.right - text_x);
    const label = if (item.editing) node.kind.tree_item.editor.content() else item.label;
    const has_parent = findTreeParent(tree, handle) != null;
    const has_children = treeItemHasChildren(tree, handle);

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
        const connector_start_x = if (has_parent)
            treeParentGuideCenterX(rect, resolved, theme, depth)
        else
            disclosure_center_x;
        try commands.append(allocator, .{ .box = .{
            .bounds = .{
                .x = connector_start_x,
                .y = rect.y + rect.h * 0.5,
                .w = @max(label_x - connector_start_x - 3, 1),
                .h = 1,
            },
            .color = theme.tree_guide,
            .border_color = theme.tree_guide,
            .border_width = 0,
            .corner_radius = 0,
        } });
    }
    if (item.icon) |icon| {
        try commands.append(allocator, .{ .icon = .{
            .bounds = .{
                .x = label_x,
                .y = rect.y + (rect.h - icon_size) * 0.5,
                .w = icon_size,
                .h = icon_size,
            },
            .kind = icon,
            .color = if (item.selected) theme.accent else item.icon_color orelse resolved.fg,
        } });
    }

    if (item.editing) {
        const editor = &node.kind.tree_item.editor;

        if (editor.hasSelection()) {
            const range = editor.selectionRange();
            const sel_start_x = text_x + layout.textWidthUpTo(label, range.start, resolved.font_size, text_ctx);
            const sel_end_x = text_x + layout.textWidthUpTo(label, range.end, resolved.font_size, text_ctx);
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

        const cursor_x = text_x + layout.textWidthUpTo(label, editor.cursor, resolved.font_size, text_ctx);
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
    const rect = paintRect(node.layout_rect);
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
    list_box: widget.WidgetKind.ListBox,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const rect = paintRect(node.layout_rect);
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = if (list_box.drop_preview_background)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 48)
        else
            resolved.bg,
        .border_color = if (list_box.drop_preview_background) theme.accent else resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);

    if (list_box.marquee_active and list_box.marquee_rect.w > 0 and list_box.marquee_rect.h > 0) {
        const fill = style.Color.rgba(theme.selection_bg.r, theme.selection_bg.g, theme.selection_bg.b, 96);
        try commands.append(allocator, .{ .box = .{
            .bounds = list_box.marquee_rect,
            .color = fill,
            .border_color = theme.accent,
            .border_width = 1,
            .corner_radius = 0,
        } });
    }
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
    const rect = paintRect(node.layout_rect);
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = if (selectable.dragging)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 72)
        else
            fill,
        .border_color = if (selectable.drop_preview or selectable.selected) theme.accent else resolved.border,
        .border_width = if (selectable.drop_preview or selectable.selected) 1 else 0,
        .corner_radius = resolved.border_radius,
    } });
    const selectable_bounds = defaultTextBounds(rect, resolved);
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
    const rect = paintRect(node.layout_rect);
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
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
    const rect = paintRect(node.layout_rect);
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
    const rect = snappedRect(paintRect(node.layout_rect));
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = if (table.drop_preview_background)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 48)
        else
            resolved.bg,
        .border_color = if (table.drop_preview_background) theme.accent else resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);

    if (table.marquee_active and table.marquee_rect.w > 0 and table.marquee_rect.h > 0) {
        const fill = style.Color.rgba(theme.selection_bg.r, theme.selection_bg.g, theme.selection_bg.b, 96);
        try commands.append(allocator, .{ .box = .{
            .bounds = table.marquee_rect,
            .color = fill,
            .border_color = theme.accent,
            .border_width = 1,
            .corner_radius = 0,
        } });
    }

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
    const rect = paintRect(node.layout_rect);
    const row_fill_rect = tableRowFillRect(tree, handle, rect);
    const fill = tableRowFill(tree, handle, node, row, theme);
    if (fill.a > 0 and row_fill_rect.w > 0 and row_fill_rect.h > 0) {
        try commands.append(allocator, .{ .box = .{
            .bounds = row_fill_rect,
            .color = fill,
            .border_color = fill,
            .border_width = 0,
            .corner_radius = 0,
        } });
    }

    if (row.drop_preview and row_fill_rect.w > 0 and row_fill_rect.h > 0) {
        try commands.append(allocator, .{ .box = .{
            .bounds = row_fill_rect,
            .color = style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 36),
            .border_color = theme.accent,
            .border_width = 1,
            .corner_radius = 0,
        } });
    }

    if (tableRowHasTopDivider(tree, handle)) {
        const divider_thickness = tableDividerThickness(resolved.border_width);
        if (divider_thickness > 0) {
            const divider = snappedRect(.{
                .x = rect.x,
                .y = rect.y,
                .w = rect.w,
                .h = divider_thickness,
            });
            try commands.append(allocator, .{ .box = .{
                .bounds = divider,
                .color = resolved.border,
                .border_color = resolved.border,
                .border_width = 0,
                .corner_radius = 0,
            } });
        }
    }

    var iter = tree.children(handle);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (child_node.kind == .table_cell) {
            const child_resolved = child_node.style_override.resolve(theme);
            try emitTableCellContents(tree, child, child_node, child_resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
        } else {
            try emitNode(tree, child, theme, commands, allocator, text_ctx, in_floating_subtree);
        }
    }

    var divider_iter = tree.children(handle);
    while (divider_iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (child_node.kind != .table_cell) continue;
        const child_resolved = child_node.style_override.resolve(theme);
        try emitTableCellDivider(tree, child, child_node, child_resolved, commands, allocator);
    }
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
    try emitTableCellContents(tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
    try emitTableCellDivider(tree, handle, node, resolved, commands, allocator);
}

fn emitTableCellContents(
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
    const rect = paintRect(node.layout_rect);
    const sort_direction = tableSortIndicator(tree, handle);
    const chevron_x = if (sort_direction != null)
        rect.x + rect.w - resolved.padding.right - resolved.font_size * 0.8
    else
        0;

    var iter = tree.children(handle);
    while (iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (child_node.kind == .text) {
            const child_resolved = child_node.style_override.resolve(theme);
            const text_x = rect.x + resolved.padding.left;
            const text_w = if (sort_direction != null)
                chevron_x - text_x - resolved.font_size * 0.4
            else
                rectRight(rect) - resolved.padding.right - text_x;
            const text_bounds = customTextBounds(rect, resolved, text_x, text_w);
            try appendTextCommand(
                commands,
                allocator,
                text_bounds,
                child_node.kind.text.content,
                child_resolved.fg,
                child_resolved.font_size,
                .start,
                child_node.kind.text.overflow,
            );
            continue;
        }

        try emitNode(tree, child, theme, commands, allocator, text_ctx, in_floating_subtree);
    }

    if (sort_direction) |direction| {
        const chevron_bounds = customTextBounds(rect, resolved, chevron_x, rectRight(rect) - resolved.padding.right - chevron_x);
        try appendTextCommand(commands, allocator, chevron_bounds, tableSortChevron(direction), theme.accent, resolved.font_size, .center, .visible);
    }

    if (node.custom_draw and rect.w > 0 and rect.h > 0) {
        try commands.append(allocator, .{ .custom = .{
            .handle = handle,
            .bounds = rect,
        } });
    }
}

fn emitTableCellDivider(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
) !void {
    if (tableCellIndex(tree, handle) > 0) {
        const row_handle = tree.getConst(handle).parent orelse handle;
        const row_rect = paintRect(tree.getConst(row_handle).layout_rect);
        const rect = paintRect(node.layout_rect);
        const divider_thickness = tableDividerThickness(resolved.border_width);
        if (divider_thickness > 0) {
            const divider = snappedRect(.{
                .x = rect.x,
                .y = row_rect.y,
                .w = divider_thickness,
                .h = row_rect.h,
            });
            try commands.append(allocator, .{ .box = .{
                .bounds = divider,
                .color = resolved.border,
                .border_color = resolved.border,
                .border_width = 0,
                .corner_radius = 0,
            } });
        }
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
    const rect = paintRect(node.layout_rect);
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
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
    const rect = paintRect(node.layout_rect);
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
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
    const rect = paintRect(node.layout_rect);
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
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
    const rect = paintRect(node.layout_rect);
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = if (menuHasActiveFill(tree, handle, node))
            theme.bg_active
        else
            interactionBg(node, resolved, theme),
        .border_color = resolved.border,
        .border_width = 0,
        .corner_radius = resolved.border_radius,
    } });
    const menu_bounds = defaultTextBounds(rect, resolved);
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
    const rect = paintRect(node.layout_rect);
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
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
    const rect = paintRect(node.layout_rect);
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
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
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    const has_popup = directPopupChild(tree, handle) != null;
    const text_color = if (item.enabled)
        resolved.fg
    else
        style.Color.rgba(resolved.fg.r, resolved.fg.g, resolved.fg.b, 120);
    const reserve_width = @max(resolved.font_size, 12);
    const gap = @max(resolved.padding.left * 0.75, 6);
    const rect = paintRect(node.layout_rect);
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = if (menuPopupVisible(tree, handle))
            theme.bg_active
        else
            interactionBg(node, resolved, theme),
        .border_color = resolved.border,
        .border_width = 0,
        .corner_radius = resolved.border_radius,
    } });

    const check_bounds = customTextBounds(rect, resolved, rect.x + resolved.padding.left, reserve_width);
    if (item.checked) {
        const indicator_size = @max(@min(@min(check_bounds.w, check_bounds.h) * 0.45, resolved.font_size * 0.5), 4);
        const indicator_bounds = Rect{
            .x = check_bounds.x + (check_bounds.w - indicator_size) * 0.5,
            .y = check_bounds.y + (check_bounds.h - indicator_size) * 0.5,
            .w = indicator_size,
            .h = indicator_size,
        };
        try commands.append(allocator, .{ .box = .{
            .bounds = indicator_bounds,
            .color = text_color,
            .border_color = text_color,
            .border_width = 0,
            .corner_radius = indicator_size * 0.5,
        } });
    }

    var label_right = rectRight(rect) - resolved.padding.right;
    if (has_popup) label_right -= reserve_width;

    const shortcut_width = if (item.shortcut.len > 0)
        @max(layout.measureTextDimensions(item.shortcut, resolved.font_size, text_ctx).width + gap, reserve_width)
    else
        0;
    if (shortcut_width > 0) label_right -= shortcut_width + gap;

    const label_left = check_bounds.x + reserve_width + gap;
    const label_bounds = customTextBounds(rect, resolved, label_left, @max(label_right - label_left, 0));
    try appendTextCommand(commands, allocator, label_bounds, item.label, text_color, resolved.font_size, .start, .ellipsis);

    if (item.shortcut.len > 0) {
        const shortcut_bounds = customTextBounds(
            rect,
            resolved,
            label_right + gap,
            shortcut_width - gap,
        );
        try appendTextCommand(commands, allocator, shortcut_bounds, item.shortcut, text_color, resolved.font_size, .end, .visible);
    }

    if (has_popup) {
        const arrow_bounds = customTextBounds(
            rect,
            resolved,
            rectRight(rect) - resolved.padding.right - reserve_width,
            reserve_width,
        );
        try appendTextCommand(commands, allocator, arrow_bounds, "›", text_color, resolved.font_size, .end, .visible);
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
    const rect = paintRect(node.layout_rect);

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
    const rect = paintRect(node.layout_rect);
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
    const rect = paintRect(node.layout_rect);
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
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
    const rect = paintRect(node.layout_rect);
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = chrome.color,
        .border_color = chrome.border_color,
        .border_width = chrome.border_width,
        .corner_radius = resolved.border_radius,
    } });
    if (item.selected) {
        try commands.append(allocator, .{ .box = .{
            .bounds = .{
                .x = rect.x,
                .y = rect.y + rect.h - 2,
                .w = rect.w,
                .h = 2,
            },
            .color = theme.accent,
            .border_color = theme.accent,
            .border_width = 0,
            .corner_radius = 0,
        } });
    }
    const tab_bounds = defaultTextBounds(rect, resolved);
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
    const rect = paintRect(node.layout_rect);
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = 0,
        .corner_radius = resolved.border_radius,
    } });

    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);

    const divider = splitterDividerRect(rect, splitter, resolved);
    const handle_rect = splitterHandleRect(divider, splitter);
    const visible_divider = splitterVisibleRect(divider, splitter.direction);
    const grip = splitterGripRect(handle_rect, splitter.direction);
    const divider_color = if (node.interaction.pressed)
        theme.bg_active
    else if (node.interaction.hovered)
        theme.bg_hover
    else
        resolved.border;

    try commands.append(allocator, .{ .box = .{
        .bounds = visible_divider,
        .color = divider_color,
        .border_color = divider_color,
        .border_width = 0,
        .corner_radius = resolved.border_radius,
    } });
    if (node.interaction.pressed or node.interaction.hovered or node.interaction.focused) {
        const overlay_color = if (node.interaction.pressed)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 72)
        else if (node.interaction.focused)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 48)
        else
            style.Color.rgba(theme.border.r, theme.border.g, theme.border.b, 40);
        try commands.append(allocator, .{ .box = .{
            .bounds = handle_rect,
            .color = overlay_color,
            .border_color = style.Color.rgba(0, 0, 0, 0),
            .border_width = 0,
            .corner_radius = 2,
        } });
        try commands.append(allocator, .{ .box = .{
            .bounds = grip,
            .color = if (node.interaction.pressed or node.interaction.focused) theme.accent else resolved.fg,
            .border_color = if (node.interaction.pressed or node.interaction.focused) theme.accent else resolved.fg,
            .border_width = 0,
            .corner_radius = 2,
        } });
    }

    try emitFocusRingRect(handle_rect, theme, resolved.border_radius, commands, allocator, node.interaction.focused);
}

fn emitSlider(
    node: *const widget.Node,
    sl: widget.WidgetKind.Slider,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
) !void {
    const rect = paintRect(node.layout_rect);

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
    const rect = paintRect(node.layout_rect);

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
    const rect = paintRect(node.layout_rect);
    const previous_cull_rect = active_paint_cull_rect;
    active_paint_cull_rect = if (previous_cull_rect) |cull_rect|
        intersectRects(cull_rect, rect)
    else
        rect;
    defer active_paint_cull_rect = previous_cull_rect;

    // Background
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    // Push clip
    try commands.append(allocator, .{ .clip = .{ .bounds = active_paint_cull_rect orelse rect } });

    try emitChildren(tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);

    // Pop clip
    try commands.append(allocator, .{ .clip = .{ .bounds = null } });

    const extent = scrollContentExtent(tree, handle);
    const scroll = node.kind.scroll_area;
    const has_vertical_scrollbar = scroll.allow_vertical_scroll and extent.h > rect.h + 0.01;
    const has_horizontal_scrollbar = scroll.allow_horizontal_scroll and extent.w > rect.w + 0.01;

    if (has_vertical_scrollbar) {
        const scrollbar_inset: f32 = 2;
        const track_w = @max(resolved.thumb_width * 0.5, 6);
        const horizontal_reserve = if (has_horizontal_scrollbar) track_w + scrollbar_inset else 0;
        const track = Rect{
            .x = rect.x + rect.w - track_w - scrollbar_inset,
            .y = rect.y + scrollbar_inset,
            .w = track_w,
            .h = @max(rect.h - scrollbar_inset * 2 - horizontal_reserve, 0),
        };
        const thumb_h = @max(track.h * (rect.h / extent.h), @min(resolved.thumb_width * 1.5, track.h));
        const max_scroll = @max(extent.h - rect.h, 0);
        const thumb_t = if (max_scroll > 0) std.math.clamp(node.kind.scroll_area.scroll_y / max_scroll, 0, 1) else 0;
        const thumb_y = track.y + (track.h - thumb_h) * thumb_t;

        try commands.append(allocator, .{ .box = .{
            .bounds = track,
            .color = style.Color.rgba(theme.border.r, theme.border.g, theme.border.b, 64),
            .border_color = style.Color.rgba(0, 0, 0, 0),
            .border_width = 0,
            .corner_radius = track.w * 0.5,
        } });
        try commands.append(allocator, .{ .box = .{
            .bounds = .{ .x = track.x, .y = thumb_y, .w = track.w, .h = thumb_h },
            .color = style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 180),
            .border_color = style.Color.rgba(0, 0, 0, 0),
            .border_width = 0,
            .corner_radius = track.w * 0.5,
        } });
    }

    if (has_horizontal_scrollbar) {
        const scrollbar_inset: f32 = 2;
        const track_h = @max(resolved.thumb_width * 0.5, 6);
        const vertical_reserve = if (has_vertical_scrollbar) track_h + scrollbar_inset else 0;
        const track = Rect{
            .x = rect.x + scrollbar_inset,
            .y = rect.y + rect.h - track_h - scrollbar_inset,
            .w = @max(rect.w - scrollbar_inset * 2 - vertical_reserve, 0),
            .h = track_h,
        };
        const thumb_w = @max(track.w * (rect.w / extent.w), @min(resolved.thumb_width * 1.5, track.w));
        const max_scroll = @max(extent.w - rect.w, 0);
        const thumb_t = if (max_scroll > 0) std.math.clamp(node.kind.scroll_area.scroll_x / max_scroll, 0, 1) else 0;
        const thumb_x = track.x + (track.w - thumb_w) * thumb_t;

        try commands.append(allocator, .{ .box = .{
            .bounds = track,
            .color = style.Color.rgba(theme.border.r, theme.border.g, theme.border.b, 64),
            .border_color = style.Color.rgba(0, 0, 0, 0),
            .border_width = 0,
            .corner_radius = track.h * 0.5,
        } });
        try commands.append(allocator, .{ .box = .{
            .bounds = .{ .x = thumb_x, .y = track.y, .w = thumb_w, .h = track.h },
            .color = style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 180),
            .border_color = style.Color.rgba(0, 0, 0, 0),
            .border_width = 0,
            .corner_radius = track.h * 0.5,
        } });
    }
}

fn scrollContentExtent(tree: *const widget.Tree, handle: widget.NodeHandle) struct { w: f32, h: f32 } {
    const node = tree.getConst(handle);
    const parent_rect = node.layout_rect;
    const scroll = node.kind.scroll_area;
    var max_x: f32 = parent_rect.x;
    var max_y: f32 = parent_rect.y;

    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .popup or tree.getConst(child).kind == .tooltip) continue;
        const r = tree.getConst(child).layout_rect;
        max_x = @max(max_x, r.x + scroll.effectiveScrollX() + r.w);
        max_y = @max(max_y, r.y + scroll.effectiveScrollY() + r.h);
    }

    return .{
        .w = max_x - parent_rect.x,
        .h = max_y - parent_rect.y,
    };
}

/// Emit a focus ring around a widget's layout rect if it has focus.
fn emitFocusRing(
    node: *const widget.Node,
    theme: style.Theme,
    corner_radius: f32,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
) !void {
    try emitFocusRingRect(paintRect(node.layout_rect), theme, corner_radius, commands, allocator, node.interaction.focused);
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
    return if (node.interaction.drop_hovered)
        style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 48)
    else if (node.interaction.pressed)
        theme.bg_active
    else if (node.interaction.hovered)
        theme.bg_hover
    else
        resolved.bg;
}

fn selectableBg(node: *const widget.Node, selected: bool, theme: style.Theme) style.Color {
    return if (node.interaction.drop_hovered)
        style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 48)
    else if (node.interaction.pressed)
        theme.bg_active
    else if (selected)
        theme.selection_bg
    else if (node.interaction.hovered)
        theme.bg_hover
    else
        .{ .r = 0, .g = 0, .b = 0, .a = 0 };
}

fn emitDropTargetOverlay(
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
) !void {
    if (!node.interaction.drop_hovered) return;
    const rect = paintRect(node.layout_rect);
    if (rect.w <= 0 or rect.h <= 0) return;
    try commands.append(allocator, .{ .box = .{
        .bounds = rect,
        .color = style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 32),
        .border_color = theme.accent,
        .border_width = @max(resolved.border_width, 1),
        .corner_radius = resolved.border_radius,
    } });
}

fn tableRowFill(
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    row: widget.WidgetKind.TableRow,
    theme: style.Theme,
) style.Color {
    if (row.dragging) return style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 72);
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

fn tableRowHasTopDivider(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    return tableRowIndex(tree, handle) > 0;
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

fn menuHasActiveFill(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node) bool {
    if (menuPopupVisible(tree, handle)) return true;
    if (!node.interaction.hovered) return false;

    const parent_handle = node.parent orelse return false;
    const parent = tree.getConst(parent_handle);
    if (parent.kind != .menu_bar) return false;

    var iter = tree.children(parent_handle);
    while (iter.next()) |child| {
        const popup = directPopupChild(tree, child) orelse continue;
        if (popupShouldDraw(tree, popup)) return true;
    }
    return false;
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
    const gap_thickness = splitterGapThickness(splitter);
    return switch (splitter.direction) {
        .row => .{
            .x = inner.x + (inner.w - gap_thickness) * ratio,
            .y = inner.y,
            .w = gap_thickness,
            .h = inner.h,
        },
        .column => .{
            .x = inner.x,
            .y = inner.y + (inner.h - gap_thickness) * ratio,
            .w = inner.w,
            .h = gap_thickness,
        },
    };
}

fn splitterHandleRect(divider: Rect, splitter: widget.WidgetKind.Splitter) Rect {
    const handle_thickness = @max(splitter.thickness, splitterGapThickness(splitter));
    return switch (splitter.direction) {
        .row => snappedRect(.{
            .x = divider.x + (divider.w - handle_thickness) * 0.5,
            .y = divider.y,
            .w = handle_thickness,
            .h = divider.h,
        }),
        .column => snappedRect(.{
            .x = divider.x,
            .y = divider.y + (divider.h - handle_thickness) * 0.5,
            .w = divider.w,
            .h = handle_thickness,
        }),
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

fn snappedRect(bounds: Rect) Rect {
    const x0 = @round(bounds.x);
    const y0 = @round(bounds.y);
    const x1 = @round(bounds.x + bounds.w);
    const y1 = @round(bounds.y + bounds.h);
    return .{
        .x = x0,
        .y = y0,
        .w = @max(x1 - x0, 0),
        .h = @max(y1 - y0, 0),
    };
}

fn snappedHairlineRect(bounds: Rect, axis: widget.WidgetKind.Container.Direction) Rect {
    return switch (axis) {
        .row => .{
            .x = @round(bounds.x),
            .y = @round(bounds.y),
            .w = 1,
            .h = @max(@round(bounds.h), 0),
        },
        .column => .{
            .x = @round(bounds.x),
            .y = @round(bounds.y),
            .w = @max(@round(bounds.w), 0),
            .h = 1,
        },
    };
}

fn tableRowFillRect(tree: *const widget.Tree, handle: widget.NodeHandle, rect: Rect) Rect {
    _ = tree;
    _ = handle;
    return snappedRect(rect);
}

fn tableDividerThickness(border_width: f32) f32 {
    return @max(@round(border_width), 0);
}

fn splitterVisibleRect(divider: Rect, direction: widget.WidgetKind.Container.Direction) Rect {
    _ = direction;
    return snappedRect(divider);
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
        .row => inner.w - splitterGapThickness(splitter),
        .column => inner.h - splitterGapThickness(splitter),
    };
}

fn splitterGapThickness(splitter: widget.WidgetKind.Splitter) f32 {
    return @max(@min(splitter.gap_thickness, splitter.thickness), 1);
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
        else if (node.interaction.drop_hovered)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 48)
        else if (item.drop_preview == .into)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 48)
        else if (item.selected)
            theme.selection_bg
        else if (has_custom_bg)
            interactionBg(node, resolved, theme)
        else if (node.interaction.pressed)
            theme.bg_active
        else if (node.interaction.hovered)
            theme.bg_hover
        else
            .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border_color = if (node.interaction.drop_hovered or item.drop_preview == .into)
            theme.accent
        else if (has_custom_border)
            resolved.border
        else
            .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border_width = if (node.interaction.drop_hovered or item.drop_preview == .into)
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
                try appendTreeGuideVertical(
                    commands,
                    allocator,
                    theme,
                    treeGuideCenterX(row_rect, resolved, theme, ancestor_depth),
                    row_rect.y,
                    row_rect.y + row_rect.h,
                );
            }
        }
        ancestor = ancestor_node.parent;
    }

    if (findTreeParent(tree, handle)) |parent_handle| {
        const parent_rect = paintRect(tree.getConst(parent_handle).layout_rect);
        const parent_bottom_y = parent_rect.y + parent_rect.h;
        const row_center_y = row_rect.y + row_rect.h * 0.5;
        const parent_guide_x = treeParentGuideCenterX(row_rect, resolved, theme, treeDepth(tree, handle));
        const start_y = if (previousTreeSibling(tree, handle) != null)
            row_rect.y
        else
            @min(parent_bottom_y, row_rect.y);
        try appendTreeGuideVertical(
            commands,
            allocator,
            theme,
            parent_guide_x,
            start_y,
            row_center_y,
        );

        if (nextTreeSibling(tree, handle)) |next_handle| {
            const next_rect = paintRect(tree.getConst(next_handle).layout_rect);
            try appendTreeGuideVertical(
                commands,
                allocator,
                theme,
                parent_guide_x,
                row_center_y,
                next_rect.y + next_rect.h * 0.5,
            );
        }
    }

    const node = tree.getConst(handle);
    if (node.kind.tree_item.expanded and treeItemHasChildren(tree, handle)) {
        try appendTreeGuideVertical(
            commands,
            allocator,
            theme,
            disclosure_center_x,
            row_rect.y + row_rect.h * 0.5,
            row_rect.y + row_rect.h,
        );
    }
}

fn appendTreeGuideVertical(
    commands: *std.ArrayListUnmanaged(PaintCommand),
    allocator: std.mem.Allocator,
    theme: style.Theme,
    x: f32,
    y0: f32,
    y1: f32,
) !void {
    const top = @min(y0, y1);
    const bottom = @max(y0, y1);
    try commands.append(allocator, .{ .box = .{
        .bounds = .{
            .x = x,
            .y = top,
            .w = 1,
            .h = @max(bottom - top, 1),
        },
        .color = theme.tree_guide,
        .border_color = theme.tree_guide,
        .border_width = 0,
        .corner_radius = 0,
    } });
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
    return nextTreeSibling(tree, handle) != null;
}

fn nextTreeSibling(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var sibling = tree.getConst(handle).next_sibling;
    while (sibling) |next_handle| {
        const next_node = tree.getConst(next_handle);
        if (next_node.kind != .popup and next_node.kind != .tooltip) return next_handle;
        sibling = next_node.next_sibling;
    }
    return null;
}

fn previousTreeSibling(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var sibling = tree.getConst(handle).prev_sibling;
    while (sibling) |previous_handle| {
        const previous_node = tree.getConst(previous_handle);
        if (previous_node.kind != .popup and previous_node.kind != .tooltip) return previous_handle;
        sibling = previous_node.prev_sibling;
    }
    return null;
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

fn treeParentGuideCenterX(
    row_rect: Rect,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    depth: u32,
) f32 {
    return treeGuideCenterX(row_rect, resolved, theme, if (depth == 0) 0 else depth - 1);
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

fn shouldTraverseCulledNode(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    switch (node.kind) {
        .tree_item => |item| return item.expanded and hasNonFloatingChild(tree, handle),
        .tab_item => |item| return item.selected and hasNonFloatingChild(tree, handle),
        else => return false,
    }
}

fn hasNonFloatingChild(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        const child_kind = tree.getConst(child).kind;
        if (child_kind != .popup and child_kind != .tooltip) return true;
    }
    return false;
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
                try appendTextCommand(commands, allocator, label_bounds, item.label, dragGhostColor(resolved.fg, 210), resolved.font_size, .start, .clip);
            },
            .selectable => |item| {
                if (!item.dragging or item.drag_rect.w <= 0 or item.drag_rect.h <= 0) continue;
                const resolved = node.style_override.resolve(theme);
                try emitDragGhostRect(item.drag_rect, resolved, theme, commands, allocator);
                const label_bounds = defaultTextBounds(item.drag_rect, resolved);
                try appendTextCommand(commands, allocator, label_bounds, item.label, dragGhostColor(resolved.fg, 210), resolved.font_size, .start, .clip);
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
                        .color = style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 68),
                        .border_color = dragGhostColor(theme.accent, 170),
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
                try appendTextCommand(commands, allocator, label_bounds, item.label, dragGhostColor(resolved.fg, 210), resolved.font_size, .center, .ellipsis);
            },
            .table_row => |row| {
                if (!row.dragging or row.drag_rect.w <= 0 or row.drag_rect.h <= 0) continue;
                const resolved = node.style_override.resolve(theme);
                try emitDragGhostRect(row.drag_rect, resolved, theme, commands, allocator);
            },
            else => {},
        }
    }
}

fn dragGhostColor(color: style.Color, alpha: u8) style.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = @min(color.a, alpha) };
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
        .color = style.Color.rgba(theme.bg_active.r, theme.bg_active.g, theme.bg_active.b, 150),
        .border_color = dragGhostColor(theme.accent, 180),
        .border_width = @max(resolved.border_width, 1),
        .corner_radius = resolved.border_radius,
    } });
}

fn rectsIntersect(a: Rect, b: Rect) bool {
    if (a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0) return false;
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

fn intersectRects(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{
        .x = x0,
        .y = y0,
        .w = @max(x1 - x0, 0),
        .h = @max(y1 - y0, 0),
    };
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

fn treeItemHasChildren(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    if (node.kind == .tree_item and node.kind.tree_item.has_children) return true;
    return hasNonPopupChildren(tree, handle);
}

fn treeItemIconSize(item: widget.WidgetKind.TreeItem, row_rect: Rect, resolved: style.ResolvedStyle) f32 {
    if (item.icon == null) return 0;
    const inner_h = @max(row_rect.h - resolved.padding.top - resolved.padding.bottom, 0);
    return @min(@max(resolved.font_size, 10), inner_h);
}

fn treeItemIconGap(item: widget.WidgetKind.TreeItem, theme: style.Theme) f32 {
    if (item.icon == null) return 0;
    return @max(theme.spacing * 0.5, 4);
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

test "popup paint can be split from main paint" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const menu = try tree.addChild(root, .{ .menu = .{ .label = "File" } });
    const popup = try tree.addChild(menu, .{ .popup = .{
        .placement = .below_start,
        .visible = true,
    } });
    const item = try tree.addChild(popup, .{ .menu_item = .{ .label = "Open" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(menu).layout_rect = .{ .x = 10, .y = 8, .w = 48, .h = 24 };
    tree.get(popup).layout_rect = .{ .x = 10, .y = 32, .w = 144, .h = 30 };
    tree.get(item).layout_rect = .{ .x = 10, .y = 32, .w = 144, .h = 30 };

    var main_paint = try generatePaintWithoutFloating(&tree, style.Theme.default, allocator, null);
    defer freePaintList(&main_paint, allocator);
    for (main_paint.commands) |command| {
        if (command == .box) {
            try std.testing.expect(command.box.bounds.y < tree.getConst(popup).layout_rect.y);
        }
    }

    var popup_paint = try generatePaintForPopup(&tree, popup, style.Theme.default, allocator, null);
    defer freePaintList(&popup_paint, allocator);
    try std.testing.expect(popup_paint.commands.len >= 3);
    try std.testing.expect(popup_paint.commands[0] == .box);
    try std.testing.expectApproxEqAbs(@as(f32, 0), popup_paint.commands[0].box.bounds.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), popup_paint.commands[0].box.bounds.y, 0.01);
}

test "checked menu item emits checked indicator" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const item = try tree.addChild(root, .{ .menu_item = .{
        .label = "Sidebar",
        .checked = true,
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 140, .h = 36 };
    tree.get(item).layout_rect = .{ .x = 0, .y = 0, .w = 140, .h = 28 };

    const theme = style.Theme.default;
    var paint = try generatePaint(&tree, theme, allocator, null);
    defer freePaintList(&paint, allocator);

    var found_indicator = false;
    for (paint.commands) |command| {
        if (command != .box) continue;
        const box = command.box;
        if (box.bounds.w > 0 and box.bounds.w < 10 and box.bounds.h > 0 and box.bounds.h < 10) {
            found_indicator = true;
            try std.testing.expectEqual(theme.fg, box.color);
        }
    }
    try std.testing.expect(found_indicator);
}

test "hovered top-level menu uses active fill while menu bar is open" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const bar = try tree.addChild(root, .{ .menu_bar = .{} });
    const file = try tree.addChild(bar, .{ .menu = .{ .label = "File" } });
    const file_popup = try tree.addChild(file, .{ .popup = .{
        .placement = .below_start,
        .visible = true,
    } });
    const edit = try tree.addChild(bar, .{ .menu = .{ .label = "Edit" } });
    _ = try tree.addChild(edit, .{ .popup = .{
        .placement = .below_start,
        .visible = false,
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 320, .h = 160 };
    tree.get(bar).layout_rect = .{ .x = 0, .y = 0, .w = 320, .h = 24 };
    tree.get(file).layout_rect = .{ .x = 4, .y = 2, .w = 42, .h = 20 };
    tree.get(file_popup).layout_rect = .{ .x = 4, .y = 24, .w = 120, .h = 28 };
    tree.get(file).interaction.focused = true;
    tree.get(edit).layout_rect = .{ .x = 46, .y = 2, .w = 42, .h = 20 };
    tree.get(edit).interaction.hovered = true;

    const theme = style.Theme.default;
    var paint = try generatePaintWithoutFloating(&tree, theme, allocator, null);
    defer freePaintList(&paint, allocator);

    var found_edit_box = false;
    for (paint.commands) |command| {
        if (command != .box) continue;
        const box = command.box;
        if (box.bounds.x == tree.getConst(edit).layout_rect.x and
            box.bounds.y == tree.getConst(edit).layout_rect.y and
            box.bounds.w == tree.getConst(edit).layout_rect.w and
            box.bounds.h == tree.getConst(edit).layout_rect.h)
        {
            found_edit_box = true;
            try std.testing.expectEqual(theme.bg_active, box.color);
        }
    }
    try std.testing.expect(found_edit_box);
}

test "table cells emit custom draw commands after text contents" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const cell = try tree.addRoot(.{ .table_cell = .{} });
    _ = try tree.addChild(cell, .{ .text = .{ .content = "Name", .overflow = .ellipsis } });
    tree.get(cell).layout_rect = .{ .x = 10, .y = 20, .w = 160, .h = 28 };
    tree.get(cell).custom_draw = true;

    var dl = try generate(&tree, style.Theme.default, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .text);
    try std.testing.expect(dl.commands[1] == .custom);
    try std.testing.expect(dl.commands[1].custom.handle.eql(cell));
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
    const sibling = try tree.addChild(parent, .{ .tree_item = .{
        .label = "Light",
        .group = 1,
    } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 240, .h = 130 };
    tree.get(parent).layout_rect = .{ .x = 10, .y = 10, .w = 220, .h = 26 };
    tree.get(child).layout_rect = .{ .x = 10, .y = 50, .w = 220, .h = 26 };
    tree.get(sibling).layout_rect = .{ .x = 10, .y = 90, .w = 220, .h = 26 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 13), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect); // root bg
    try std.testing.expect(dl.commands[1] == .rect); // parent downward guide
    try std.testing.expect(dl.commands[2] == .rect); // disclosure box
    try std.testing.expect(dl.commands[3] == .rect); // disclosure minus
    try std.testing.expect(dl.commands[4] == .rect); // parent connector
    try std.testing.expect(dl.commands[5] == .text); // parent label
    try std.testing.expect(dl.commands[6] == .rect); // child vertical guide
    try std.testing.expect(dl.commands[7] == .rect); // child sibling guide
    try std.testing.expect(dl.commands[8] == .rect); // child connector
    try std.testing.expect(dl.commands[9] == .text); // child label
    try std.testing.expect(dl.commands[10] == .rect); // sibling vertical guide
    try std.testing.expect(dl.commands[11] == .rect); // sibling connector
    try std.testing.expect(dl.commands[12] == .text); // sibling label

    const child_guide = dl.commands[6].rect.bounds;
    try std.testing.expectApproxEqAbs(@as(f32, 25), child_guide.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 36), child_guide.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 27), child_guide.h, 0.01);

    const sibling_guide = dl.commands[7].rect.bounds;
    try std.testing.expectApproxEqAbs(child_guide.x, sibling_guide.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 63), sibling_guide.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), sibling_guide.h, 0.01);

    const child_connector = dl.commands[8].rect.bounds;
    try std.testing.expectApproxEqAbs(child_guide.x, child_connector.x, 0.01);
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

test "table emits header fill, row separators, and column dividers" {
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
    try std.testing.expect(dl.commands[2] == .text); // header name
    try std.testing.expect(dl.commands[3] == .text); // header type
    try std.testing.expect(dl.commands[4] == .rect); // header divider
    try std.testing.expect(dl.commands[5] == .rect); // striped row fill
    try std.testing.expect(dl.commands[6] == .rect); // row top separator
    try std.testing.expect(dl.commands[7] == .text); // row name
    try std.testing.expect(dl.commands[8] == .text); // row type
    try std.testing.expect(dl.commands[9] == .rect); // row divider
    try std.testing.expectEqualStrings("Cube", dl.commands[7].text.text);
    try std.testing.expectEqualStrings("Mesh", dl.commands[8].text.text);
}

test "table separators snap to whole pixels for fractional row positions" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const table = try tree.addRoot(.{ .table = .{ .columns = 2 } });
    const header = try tree.addChild(table, .{ .table_row = .{ .header = true } });
    const header_name = try tree.addChild(header, .{ .table_cell = .{} });
    const header_type = try tree.addChild(header, .{ .table_cell = .{} });
    const row_a = try tree.addChild(table, .{ .table_row = .{} });
    const row_a_name = try tree.addChild(row_a, .{ .table_cell = .{} });
    const row_a_type = try tree.addChild(row_a, .{ .table_cell = .{} });
    const row_b = try tree.addChild(table, .{ .table_row = .{} });
    const row_b_name = try tree.addChild(row_b, .{ .table_cell = .{} });
    const row_b_type = try tree.addChild(row_b, .{ .table_cell = .{} });
    _ = try tree.addChild(header_name, .{ .text = .{ .content = "Name" } });
    _ = try tree.addChild(header_type, .{ .text = .{ .content = "Type" } });
    _ = try tree.addChild(row_a_name, .{ .text = .{ .content = "Alpha" } });
    _ = try tree.addChild(row_a_type, .{ .text = .{ .content = "File" } });
    _ = try tree.addChild(row_b_name, .{ .text = .{ .content = "Beta" } });
    _ = try tree.addChild(row_b_type, .{ .text = .{ .content = "File" } });

    tree.get(table).layout_rect = .{ .x = 0.5, .y = 0.5, .w = 280.25, .h = 84.75 };
    tree.get(header).layout_rect = .{ .x = 0.5, .y = 0.5, .w = 280.25, .h = 28.25 };
    tree.get(header_name).layout_rect = .{ .x = 0.5, .y = 0.5, .w = 140.125, .h = 28.25 };
    tree.get(header_type).layout_rect = .{ .x = 140.625, .y = 0.5, .w = 140.125, .h = 28.25 };
    tree.get(row_a).layout_rect = .{ .x = 0.5, .y = 28.75, .w = 280.25, .h = 28.25 };
    tree.get(row_a_name).layout_rect = .{ .x = 0.5, .y = 28.75, .w = 140.125, .h = 28.25 };
    tree.get(row_a_type).layout_rect = .{ .x = 140.625, .y = 28.75, .w = 140.125, .h = 28.25 };
    tree.get(row_b).layout_rect = .{ .x = 0.5, .y = 57.0, .w = 280.25, .h = 28.25 };
    tree.get(row_b_name).layout_rect = .{ .x = 0.5, .y = 57.0, .w = 140.125, .h = 28.25 };
    tree.get(row_b_type).layout_rect = .{ .x = 140.625, .y = 57.0, .w = 140.125, .h = 28.25 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 14), dl.commands.len);
    try std.testing.expect(dl.commands[6] == .rect);
    try std.testing.expect(dl.commands[10] == .rect);
    try std.testing.expect(dl.commands[4] == .rect);
    try std.testing.expect(dl.commands[13] == .rect);

    try std.testing.expectApproxEqAbs(@as(f32, 29), dl.commands[6].rect.bounds.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 57), dl.commands[10].rect.bounds.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 141), dl.commands[4].rect.bounds.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 141), dl.commands[13].rect.bounds.x, 0.01);
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

test "splitter paints thin divider and hover overlay" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const splitter = try tree.addRoot(.{ .splitter = .{
        .direction = .row,
        .ratio = 0.5,
        .min_first = 0,
        .min_second = 0,
        .thickness = 8,
    } });
    tree.get(splitter).layout_rect = .{ .x = 10, .y = 20, .w = 100, .h = 40 };
    tree.get(splitter).interaction.hovered = true;

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 4), dl.commands.len);
    try std.testing.expect(dl.commands[1] == .rect);
    try std.testing.expect(dl.commands[2] == .rect);
    try std.testing.expect(dl.commands[3] == .rect);
    try std.testing.expectApproxEqAbs(@as(f32, 60), dl.commands[1].rect.bounds.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1), dl.commands[1].rect.bounds.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 56), dl.commands[2].rect.bounds.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 8), dl.commands[2].rect.bounds.w, 0.01);
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
    const child = try tree.addChild(scroll, .{ .text = .{ .content = "inside" } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 200 };
    tree.get(child).layout_rect = .{ .x = 8, .y = 6, .w = 40, .h = 14 };

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

test "scroll area paints child rects at their laid out scroll position" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{ .scroll_y = 20 } });
    const child = try tree.addChild(scroll, .{ .text = .{ .content = "inside" } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 300, .h = 80 };
    tree.get(child).layout_rect = .{ .x = 8, .y = 10, .w = 40, .h = 14 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 4), dl.commands.len);
    try std.testing.expect(dl.commands[2] == .text);
    try std.testing.expectEqualStrings("inside", dl.commands[2].text.text);
    try std.testing.expectApproxEqAbs(@as(f32, 10), dl.commands[2].text.bounds.y, 0.01);
}

test "scroll area omits fully offscreen children" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    const visible = try tree.addChild(scroll, .{ .text = .{ .content = "visible" } });
    const hidden = try tree.addChild(scroll, .{ .text = .{ .content = "hidden" } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 120, .h = 40 };
    tree.get(visible).layout_rect = .{ .x = 8, .y = 10, .w = 44, .h = 14 };
    tree.get(hidden).layout_rect = .{ .x = 8, .y = 64, .w = 40, .h = 14 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 6), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect);
    try std.testing.expect(dl.commands[1] == .clip);
    try std.testing.expect(dl.commands[2] == .text);
    try std.testing.expectEqualStrings("visible", dl.commands[2].text.text);
    try std.testing.expect(dl.commands[3] == .clip);
    try std.testing.expect(dl.commands[4] == .rect);
    try std.testing.expect(dl.commands[5] == .rect);
}

test "root paint culls fully offscreen children" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const visible = try tree.addChild(root, .{ .text = .{ .content = "visible" } });
    const hidden = try tree.addChild(root, .{ .text = .{ .content = "hidden" } });
    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 120, .h = 40 };
    tree.get(visible).layout_rect = .{ .x = 8, .y = 10, .w = 44, .h = 14 };
    tree.get(hidden).layout_rect = .{ .x = 8, .y = 64, .w = 40, .h = 14 };

    var dl = try generate(&tree, style.Theme.default, allocator, null);
    defer freeDrawList(&dl, allocator);

    var found_visible = false;
    var found_hidden = false;
    for (dl.commands) |command| {
        if (command != .text) continue;
        found_visible = found_visible or std.mem.eql(u8, command.text.text, "visible");
        found_hidden = found_hidden or std.mem.eql(u8, command.text.text, "hidden");
    }
    try std.testing.expect(found_visible);
    try std.testing.expect(!found_hidden);
}

test "scroll area still paints visible tree children when expanded parent row is offscreen" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    const parent = try tree.addChild(scroll, .{ .tree_item = .{ .label = "Root", .expanded = true } });
    const child = try tree.addChild(parent, .{ .tree_item = .{ .label = "Child" } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 160, .h = 40 };
    tree.get(parent).layout_rect = .{ .x = 0, .y = -30, .w = 150, .h = 20 };
    tree.get(child).layout_rect = .{ .x = 0, .y = 4, .w = 150, .h = 20 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    var found_child_label = false;
    for (dl.commands) |command| {
        if (command == .text and std.mem.eql(u8, command.text.text, "Child")) {
            found_child_label = true;
            break;
        }
    }

    try std.testing.expect(found_child_label);
}

test "scroll area emits scrollbar thumb when content overflows" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{ .scroll_y = 40 } });
    const child = try tree.addChild(scroll, .{ .spacer = .{ .height = 300 } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 120, .h = 80 };
    tree.get(child).layout_rect = .{ .x = 6, .y = -34, .w = 108, .h = 300 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 5), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect);
    try std.testing.expect(dl.commands[1] == .clip);
    try std.testing.expect(dl.commands[2] == .clip);
    try std.testing.expect(dl.commands[3] == .rect);
    try std.testing.expect(dl.commands[4] == .rect);
}

test "scroll area emits horizontal scrollbar thumb when content overflows width" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{ .scroll_x = 40 } });
    const child = try tree.addChild(scroll, .{ .spacer = .{ .width = 300, .height = 40 } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 120, .h = 80 };
    tree.get(child).layout_rect = .{ .x = -34, .y = 6, .w = 300, .h = 40 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 5), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect);
    try std.testing.expect(dl.commands[1] == .clip);
    try std.testing.expect(dl.commands[2] == .clip);
    try std.testing.expect(dl.commands[3] == .rect);
    try std.testing.expect(dl.commands[4] == .rect);
    try std.testing.expect(dl.commands[3].rect.bounds.w > dl.commands[3].rect.bounds.h);
    try std.testing.expect(dl.commands[4].rect.bounds.w > dl.commands[4].rect.bounds.h);
}

test "scroll area omits disabled horizontal scrollbar when content overflows width" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{ .allow_horizontal_scroll = false } });
    const child = try tree.addChild(scroll, .{ .spacer = .{ .width = 300, .height = 40 } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 120, .h = 80 };
    tree.get(child).layout_rect = .{ .x = 6, .y = 6, .w = 300, .h = 40 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 3), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .rect);
    try std.testing.expect(dl.commands[1] == .clip);
    try std.testing.expect(dl.commands[2] == .clip);
}

test "wrapped text paint commands wrap and preserve newlines" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const text = try tree.addRoot(.{ .text = .{ .content = "alpha beta\ngamma", .overflow = .wrap } });
    tree.get(text).layout_rect = .{ .x = 0, .y = 0, .w = 50, .h = 80 };
    tree.get(text).style_override = .{ .font_size = 16 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 3), dl.commands.len);
    try std.testing.expectEqualStrings("alpha", dl.commands[0].text.text);
    try std.testing.expectEqualStrings("beta", dl.commands[1].text.text);
    try std.testing.expectEqualStrings("gamma", dl.commands[2].text.text);
}

test "wrapped text paint commands preserve leading whitespace" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const text = try tree.addRoot(.{ .text = .{ .content = "  alpha\n\tbeta", .overflow = .wrap } });
    tree.get(text).layout_rect = .{ .x = 0, .y = 0, .w = 200, .h = 80 };
    tree.get(text).style_override = .{ .font_size = 16 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expectEqualStrings("  alpha", dl.commands[0].text.text);
    try std.testing.expectEqualStrings("\tbeta", dl.commands[1].text.text);
}

test "wrapped text culls lines outside scroll viewport" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{} });
    const text = try tree.addChild(scroll, .{ .text = .{ .content = "before\nvisible-a\nvisible-b\nafter", .overflow = .wrap } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 180, .h = 20 };
    tree.get(text).layout_rect = .{ .x = 4, .y = -10, .w = 140, .h = 40 };
    tree.get(text).style_override = .{ .font_size = 10 };

    const theme = style.Theme.default;
    var dl = try generate(&tree, theme, allocator, null);
    defer freeDrawList(&dl, allocator);

    var found_before = false;
    var found_visible_a = false;
    var found_visible_b = false;
    var found_after = false;
    for (dl.commands) |command| {
        if (command != .text) continue;
        if (std.mem.eql(u8, command.text.text, "before")) found_before = true;
        if (std.mem.eql(u8, command.text.text, "visible-a")) found_visible_a = true;
        if (std.mem.eql(u8, command.text.text, "visible-b")) found_visible_b = true;
        if (std.mem.eql(u8, command.text.text, "after")) found_after = true;
    }

    try std.testing.expect(!found_before);
    try std.testing.expect(found_visible_a);
    try std.testing.expect(found_visible_b);
    try std.testing.expect(!found_after);
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
