const std = @import("std");
const goop = @import("goop");
const components = @import("goop_components");
const visual = @import("goop_visual");
const style = goop.style;
const widget = goop.widget;
const layout = goop.layout;
const geometry = goop.geometry;
const scrollbar = goop.scrollbar;

pub const Rect = visual.Rect;
pub const TextAlign = visual.TextAlign;
pub const TextOverflow = visual.TextOverflow;
pub const IconId = visual.IconId;
pub const CustomId = visual.CustomId;
pub const VisualOperation = visual.Operation;
pub const VisualList = visual.List;
pub const VisualScope = union(enum) {
    full: Full,
    popup: goop.ElementId,

    pub const Full = struct {
        include_floating: bool = true,
    };
};
pub const VisualOptions = struct {
    scope: VisualScope = .{ .full = .{} },
    /// Optional caller-owned resolution of stock `custom` leaves into one
    /// canonical visual operation. Returning null preserves `.custom`.
    custom_visual: ?CustomVisualResolver = null,
};
pub const CustomVisualResolver = struct {
    context: *anyopaque,
    resolve_fn: *const fn (*anyopaque, visual.Custom) ?visual.Operation,

    pub fn resolve(self: CustomVisualResolver, value: visual.Custom) ?visual.Operation {
        return self.resolve_fn(self.context, value);
    }
};
pub const VisualError = std.mem.Allocator.Error || error{
    MissingCustomVisualId,
    UnknownPopupElement,
};

const VisualOffset = struct {
    x: f32 = 0,
    y: f32 = 0,
};

const VisualContext = struct {
    cull_rect: ?Rect = null,
    offset: VisualOffset = .{},
    custom_visual: ?CustomVisualResolver = null,

    fn visualRect(self: *const VisualContext, rect: Rect) Rect {
        return .{
            .x = rect.x + self.offset.x,
            .y = rect.y + self.offset.y,
            .w = rect.w,
            .h = rect.h,
        };
    }
};

/// Private bridge from stock Chrome's caller-owned operation storage to the
/// generic structural encoder consumed by visual components.
const ComponentEncoder = struct {
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,

    pub fn surface(self: *ComponentEncoder, value: visual.Surface) !void {
        try self.commands.append(self.allocator, .{ .surface = value });
    }

    pub fn text(self: *ComponentEncoder, value: visual.Text) !void {
        try self.commands.append(self.allocator, .{ .text = value });
    }

    pub fn icon(self: *ComponentEncoder, value: visual.Icon) !void {
        try self.commands.append(self.allocator, .{ .icon = value });
    }

    pub fn image(self: *ComponentEncoder, value: visual.Image) !void {
        try self.commands.append(self.allocator, .{ .image = value });
    }
};

/// Prepare semantic visual operations from a laid-out widget tree.
pub fn prepareVisuals(tree: *const widget.Tree, theme: style.Theme, allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, options: VisualOptions) !VisualList {
    return switch (options.scope) {
        .full => |full| prepareFullVisuals(tree, theme, allocator, text_ctx, full.include_floating, options.custom_visual),
        .popup => |element_id| preparePopupVisuals(
            tree,
            tree.findByElementId(element_id) orelse return error.UnknownPopupElement,
            theme,
            allocator,
            text_ctx,
            options.custom_visual,
        ),
    };
}

fn prepareFullVisuals(tree: *const widget.Tree, theme: style.Theme, allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, include_floating: bool, custom_visual: ?CustomVisualResolver) !VisualList {
    var commands: std.ArrayListUnmanaged(VisualOperation) = .empty;
    errdefer commands.deinit(allocator);
    var visual_ctx = VisualContext{ .custom_visual = custom_visual };

    for (tree.nodes.items, 0..) |node, i| {
        if (!node.alive) continue;
        if (node.parent == null) {
            const handle = tree.handleFromIndex(@intCast(i));
            if (node.kind != .popup and node.kind != .tooltip) {
                try emitRootNode(&visual_ctx, tree, handle, theme, &commands, allocator, text_ctx);
            }
        }
    }

    if (include_floating) {
        for (tree.nodes.items, 0..) |node, i| {
            if (!node.alive) continue;
            if (node.parent == null) {
                try emitFloatingSubtrees(&visual_ctx, tree, tree.handleFromIndex(@intCast(i)), theme, &commands, allocator, text_ctx);
            }
        }
    }

    try emitDragGhosts(&visual_ctx, tree, theme, &commands, allocator, text_ctx);

    return .{ .commands = try commands.toOwnedSlice(allocator) };
}

fn preparePopupVisuals(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme, allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, custom_visual: ?CustomVisualResolver) !VisualList {
    var commands: std.ArrayListUnmanaged(VisualOperation) = .empty;
    errdefer commands.deinit(allocator);

    const rect = tree.getConst(handle).layout_rect;
    var visual_ctx = VisualContext{
        .cull_rect = null,
        .offset = .{ .x = -rect.x, .y = -rect.y },
        .custom_visual = custom_visual,
    };

    try emitNode(&visual_ctx, tree, handle, theme, &commands, allocator, text_ctx, true);

    return .{ .commands = try commands.toOwnedSlice(allocator) };
}

fn emitRootNode(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) VisualError!void {
    const previous_cull_rect = visual_ctx.cull_rect;
    visual_ctx.cull_rect = if (previous_cull_rect) |cull_rect|
        geometry.intersectRects(cull_rect, visual_ctx.visualRect(tree.getConst(handle).layout_rect))
    else
        visual_ctx.visualRect(tree.getConst(handle).layout_rect);
    defer visual_ctx.cull_rect = previous_cull_rect;

    try emitNode(visual_ctx, tree, handle, theme, commands, allocator, text_ctx, false);
}

pub fn freeVisuals(visuals: *VisualList, allocator: std.mem.Allocator) void {
    allocator.free(visuals.commands);
    visuals.commands = &.{};
}

fn emitNode(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) VisualError!void {
    const node = tree.getConst(handle);
    const node_rect = visual_ctx.visualRect(node.layout_rect);
    if (!shouldDrawNode(tree, handle)) return;
    if (!in_floating_subtree and (node.kind == .popup or node.kind == .tooltip)) return;
    if (!in_floating_subtree) {
        if (visual_ctx.cull_rect) |cull_rect| {
            if (node_rect.w > 0 and node_rect.h > 0 and !geometry.rectsIntersect(node_rect, cull_rect) and !shouldTraverseCulledNode(tree, handle)) return;
        }
    }
    const resolved = node.style_override.resolve(theme);
    try visualEmitter(node.kind)(visual_ctx, tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);

    try emitDropTargetOverlay(visual_ctx, node, resolved, theme, commands, allocator);
}

const VisualEmitter = *const fn (
    *VisualContext,
    *const widget.Tree,
    widget.NodeHandle,
    *const widget.Node,
    style.ResolvedStyle,
    style.Theme,
    *std.ArrayListUnmanaged(VisualOperation),
    std.mem.Allocator,
    ?*const layout.TextMeasureCtx,
    bool,
) VisualError!void;

fn visualEmitter(kind: widget.WidgetKind) VisualEmitter {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return visual_emitters[@intFromEnum(tag)];
}

const visual_emitters = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var emitters: [std.meta.fields(Tag).len]VisualEmitter = undefined;
    emitters[@intFromEnum(Tag.container)] = visualContainerNode;
    emitters[@intFromEnum(Tag.text)] = visualTextNode;
    emitters[@intFromEnum(Tag.icon)] = visualIconNode;
    emitters[@intFromEnum(Tag.button)] = visualButtonNode;
    emitters[@intFromEnum(Tag.checkbox)] = visualCheckboxNode;
    emitters[@intFromEnum(Tag.radio_button)] = visualRadioButtonNode;
    emitters[@intFromEnum(Tag.tree_item)] = visualTreeItemNode;
    emitters[@intFromEnum(Tag.dropdown)] = visualDropdownNode;
    emitters[@intFromEnum(Tag.list_box)] = visualListBoxNode;
    emitters[@intFromEnum(Tag.selectable)] = visualSelectableNode;
    emitters[@intFromEnum(Tag.grid_selector)] = visualGridSelectorNode;
    emitters[@intFromEnum(Tag.grid_item)] = visualGridItemNode;
    emitters[@intFromEnum(Tag.table)] = visualTableNode;
    emitters[@intFromEnum(Tag.table_row)] = visualTableRowNode;
    emitters[@intFromEnum(Tag.table_cell)] = visualTableCellNode;
    emitters[@intFromEnum(Tag.toolbar)] = visualToolbarNode;
    emitters[@intFromEnum(Tag.status_bar)] = visualStatusBarNode;
    emitters[@intFromEnum(Tag.menu_bar)] = visualMenuBarNode;
    emitters[@intFromEnum(Tag.menu)] = visualMenuNode;
    emitters[@intFromEnum(Tag.popup)] = visualPopupNode;
    emitters[@intFromEnum(Tag.tooltip)] = visualTooltipNode;
    emitters[@intFromEnum(Tag.menu_item)] = visualMenuItemNode;
    emitters[@intFromEnum(Tag.drag_value)] = visualDragValueNode;
    emitters[@intFromEnum(Tag.spinbox)] = visualSpinBoxNode;
    emitters[@intFromEnum(Tag.tab_bar)] = visualTabBarNode;
    emitters[@intFromEnum(Tag.tab_item)] = visualTabItemNode;
    emitters[@intFromEnum(Tag.splitter)] = visualSplitterNode;
    emitters[@intFromEnum(Tag.slider)] = visualSliderNode;
    emitters[@intFromEnum(Tag.spacer)] = visualSpacerNode;
    emitters[@intFromEnum(Tag.scroll_area)] = visualScrollAreaNode;
    emitters[@intFromEnum(Tag.text_input)] = visualTextInputNode;
    emitters[@intFromEnum(Tag.custom)] = visualCustomNode;
    break :blk emitters;
};

fn visualContainerNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitContainer(visual_ctx, tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualTextNode(visual_ctx: *VisualContext, _: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, _: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, _: bool) VisualError!void {
    try emitText(visual_ctx, node, node.kind.text, resolved, commands, allocator, text_ctx);
}

fn visualIconNode(visual_ctx: *VisualContext, _: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, _: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, _: ?*const layout.TextMeasureCtx, _: bool) VisualError!void {
    try emitIcon(visual_ctx, node, node.kind.icon, resolved, commands, allocator);
}

fn visualButtonNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitButton(visual_ctx, tree, handle, node, node.kind.button, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualCheckboxNode(visual_ctx: *VisualContext, _: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, _: bool) VisualError!void {
    try emitCheckbox(visual_ctx, node, node.kind.checkbox, resolved, theme, commands, allocator, text_ctx);
}

fn visualRadioButtonNode(visual_ctx: *VisualContext, _: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, _: bool) VisualError!void {
    try emitRadioButton(visual_ctx, node, node.kind.radio_button, resolved, theme, commands, allocator, text_ctx);
}

fn visualTreeItemNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitTreeItem(visual_ctx, tree, handle, node, node.kind.tree_item, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualDropdownNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitDropdown(visual_ctx, tree, handle, node, node.kind.dropdown, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualListBoxNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitListBox(visual_ctx, tree, handle, node, node.kind.list_box, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualSelectableNode(visual_ctx: *VisualContext, _: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, _: bool) VisualError!void {
    try emitSelectable(visual_ctx, node, node.kind.selectable, resolved, theme, commands, allocator, text_ctx);
}

fn visualGridSelectorNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitGridSelector(visual_ctx, tree, handle, node, node.kind.grid_selector, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualGridItemNode(visual_ctx: *VisualContext, _: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, _: bool) VisualError!void {
    try emitGridItem(visual_ctx, node, node.kind.grid_item, resolved, theme, commands, allocator, text_ctx);
}

fn visualTableNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitTable(visual_ctx, tree, handle, node, node.kind.table, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualTableRowNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitTableRow(visual_ctx, tree, handle, node, node.kind.table_row, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualTableCellNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitTableCell(visual_ctx, tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualToolbarNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitToolbar(visual_ctx, tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualStatusBarNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitStatusBar(visual_ctx, tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualMenuBarNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitMenuBar(visual_ctx, tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualMenuNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitMenu(visual_ctx, tree, handle, node, node.kind.menu, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualPopupNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, _: bool) VisualError!void {
    try emitPopup(visual_ctx, tree, handle, node, resolved, theme, commands, allocator, text_ctx);
}

fn visualTooltipNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, _: bool) VisualError!void {
    try emitTooltip(visual_ctx, tree, handle, node, resolved, theme, commands, allocator, text_ctx);
}

fn visualMenuItemNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, _: bool) VisualError!void {
    try emitMenuItem(visual_ctx, tree, handle, node, node.kind.menu_item, resolved, theme, commands, allocator, text_ctx);
}

fn visualDragValueNode(visual_ctx: *VisualContext, _: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, _: bool) VisualError!void {
    try emitDragValue(visual_ctx, node, &node.kind.drag_value, resolved, theme, commands, allocator, text_ctx);
}

fn visualSpinBoxNode(visual_ctx: *VisualContext, _: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, _: bool) VisualError!void {
    try emitSpinBox(visual_ctx, node, &node.kind.spinbox, resolved, theme, commands, allocator, text_ctx);
}

fn visualTabBarNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitTabBar(visual_ctx, tree, handle, node, node.kind.tab_bar, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualTabItemNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitTabItem(visual_ctx, tree, handle, node, node.kind.tab_item, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualSplitterNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitSplitter(visual_ctx, tree, handle, node, node.kind.splitter, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualSliderNode(visual_ctx: *VisualContext, _: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, _: ?*const layout.TextMeasureCtx, _: bool) VisualError!void {
    try emitSlider(visual_ctx, node, node.kind.slider, resolved, theme, commands, allocator);
}

fn visualSpacerNode(_: *VisualContext, _: *const widget.Tree, _: widget.NodeHandle, _: *const widget.Node, _: style.ResolvedStyle, _: style.Theme, _: *std.ArrayListUnmanaged(VisualOperation), _: std.mem.Allocator, _: ?*const layout.TextMeasureCtx, _: bool) VisualError!void {}

fn visualScrollAreaNode(visual_ctx: *VisualContext, tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, in_floating_subtree: bool) VisualError!void {
    try emitScrollArea(visual_ctx, tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn visualTextInputNode(visual_ctx: *VisualContext, _: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node, resolved: style.ResolvedStyle, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, text_ctx: ?*const layout.TextMeasureCtx, _: bool) VisualError!void {
    try emitTextInput(visual_ctx, node, resolved, theme, commands, allocator, text_ctx);
}

fn visualCustomNode(visual_ctx: *VisualContext, _: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node, _: style.ResolvedStyle, _: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator, _: ?*const layout.TextMeasureCtx, _: bool) VisualError!void {
    try appendCustomPaint(visual_ctx, commands, allocator, node, visual_ctx.visualRect(node.layout_rect));
}

fn appendCustomPaint(
    visual_ctx: *const VisualContext,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    node: *const widget.Node,
    bounds: Rect,
) VisualError!void {
    if (bounds.w <= 0 or bounds.h <= 0) return;
    const id = if (node.element_id) |element_id|
        visual.CustomId.fromElementId(element_id.value())
    else if (node.kind == .custom and node.kind.custom.type_id != 0)
        visual.CustomId.init(node.kind.custom.type_id)
    else
        return error.MissingCustomVisualId;
    const custom = visual.Custom{
        .id = id,
        .bounds = bounds,
    };
    if (visual_ctx.custom_visual) |resolver| {
        if (resolver.resolve(custom)) |operation| {
            try commands.append(allocator, operation);
            return;
        }
    }
    try commands.append(allocator, .{ .custom = custom });
}

fn emitContainer(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    var encoder = ComponentEncoder{ .commands = commands, .allocator = allocator };
    try (components.Surface{
        .bounds = rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    }).emit(&encoder);

    try emitChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);
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
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    bounds: Rect,
    text: []const u8,
    color: style.Color,
    font_size: f32,
    text_align: TextAlign,
    overflow: TextOverflow,
) !void {
    var encoder = ComponentEncoder{ .commands = commands, .allocator = allocator };
    try (components.Text{
        .bounds = bounds,
        .content = text,
        .color = color,
        .font_size = font_size,
        .text_align = text_align,
        .overflow = overflow,
    }).emit(&encoder);
}

fn appendIconCommand(
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    bounds: Rect,
    kind: visual.IconId,
    color: style.Color,
) !void {
    var encoder = ComponentEncoder{ .commands = commands, .allocator = allocator };
    try (components.Icon{
        .bounds = bounds,
        .kind = kind,
        .color = color,
    }).emit(&encoder);
}

fn emitText(
    visual_ctx: *const VisualContext,
    node: *const widget.Node,
    txt: widget.WidgetKind.Text,
    resolved: style.ResolvedStyle,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    const bounds = visual_ctx.visualRect(node.layout_rect);
    if (txt.overflow == .wrap) {
        try appendWrappedTextCommands(visual_ctx, commands, allocator, bounds, txt.content, resolved.fg, resolved.font_size, text_ctx);
    } else {
        try appendTextCommand(commands, allocator, bounds, txt.content, resolved.fg, resolved.font_size, .start, txt.overflow);
    }
}

fn emitIcon(
    visual_ctx: *const VisualContext,
    node: *const widget.Node,
    icon: widget.WidgetKind.Icon,
    resolved: style.ResolvedStyle,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
) !void {
    try appendIconCommand(
        commands,
        allocator,
        visual_ctx.visualRect(node.layout_rect),
        icon.kind,
        icon.color orelse resolved.fg,
    );
}

fn appendWrappedTextCommands(
    visual_ctx: *const VisualContext,
    commands: *std.ArrayListUnmanaged(VisualOperation),
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
        if (wrappedTextPastCull(visual_ctx, y)) return;
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        y = try appendWrappedParagraph(visual_ctx, commands, allocator, bounds, y, line_h, text[start..end], color, font_size, text_ctx);
        if (end == text.len) break;
        if (end == start) y += line_h;
        start = end + 1;
    }
}

fn appendWrappedParagraph(
    visual_ctx: *const VisualContext,
    commands: *std.ArrayListUnmanaged(VisualOperation),
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
            try appendWrappedLineCommand(visual_ctx, commands, allocator, bounds, y, line_h, text[0..trimmed_end], color, font_size);
        }
        return y + line_h;
    }

    var view = std.unicode.Utf8View.init(text) catch {
        try appendWrappedLineCommand(visual_ctx, commands, allocator, bounds, y, line_h, text, color, font_size);
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
            try appendWrappedLineCommand(visual_ctx, commands, allocator, bounds, y, line_h, text[line_start..trimmed_end], color, font_size);
            y += line_h;
            if (wrappedTextPastCull(visual_ctx, y)) return y;
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
        try appendWrappedLineCommand(visual_ctx, commands, allocator, bounds, y, line_h, text[line_start..trimmed_end], color, font_size);
        y += line_h;
    }
    return y;
}

fn appendWrappedLineCommand(
    visual_ctx: *const VisualContext,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    bounds: Rect,
    y: f32,
    line_h: f32,
    text: []const u8,
    color: style.Color,
    font_size: f32,
) !void {
    const line_bounds = Rect{ .x = bounds.x, .y = y, .w = bounds.w, .h = line_h };
    if (visual_ctx.cull_rect) |cull_rect| {
        if (!geometry.rectsIntersect(line_bounds, cull_rect)) return;
    }
    try appendTextCommand(commands, allocator, line_bounds, text, color, font_size, .start, .clip);
}

fn wrappedTextPastCull(visual_ctx: *const VisualContext, y: f32) bool {
    const cull_rect = visual_ctx.cull_rect orelse return false;
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
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    btn: widget.WidgetKind.Button,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    const label_bounds = defaultTextBounds(rect, resolved);
    var encoder = ComponentEncoder{ .commands = commands, .allocator = allocator };
    try (components.Button{
        .background = .{
            .bounds = rect,
            .color = interactionBg(node, resolved, theme),
            .border_color = resolved.border,
            .border_width = resolved.border_width,
            .corner_radius = resolved.border_radius,
        },
        .label = .{
            .bounds = label_bounds,
            .content = btn.label,
            .color = resolved.fg,
            .font_size = resolved.font_size,
        },
        .focus = focusRing(rect, theme, resolved.border_radius, node.interaction.focused),
    }).emit(&encoder);
    try emitChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn emitCheckbox(
    visual_ctx: *const VisualContext,
    node: *const widget.Node,
    cb: widget.WidgetKind.Checkbox,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    _: ?*const layout.TextMeasureCtx,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    const box_size = resolved.font_size;
    const inset: f32 = 3;
    const indicator: ?components.Surface = if (cb.checked)
        .{
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
        }
    else
        null;

    const label_x = rect.x + resolved.padding.left + box_size + resolved.padding.left;
    const label_bounds = customTextBounds(rect, resolved, label_x, rect.x + rect.w - resolved.padding.right - label_x);
    var encoder = ComponentEncoder{ .commands = commands, .allocator = allocator };
    try (components.Checkbox{
        .box = .{
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
        },
        .indicator = indicator,
        .label = .{
            .bounds = label_bounds,
            .content = cb.label,
            .color = resolved.fg,
            .font_size = resolved.font_size,
        },
        .focus = focusRing(rect, theme, resolved.border_radius, node.interaction.focused),
    }).emit(&encoder);
}

fn emitRadioButton(
    visual_ctx: *const VisualContext,
    node: *const widget.Node,
    rb: widget.WidgetKind.RadioButton,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    _: ?*const layout.TextMeasureCtx,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    const box_size = resolved.font_size;
    const circle_radius = box_size / 2;
    const inset: f32 = 3;
    const indicator: ?components.Surface = if (rb.selected)
        .{
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
        }
    else
        null;

    const label_x = rect.x + resolved.padding.left + box_size + resolved.padding.left;
    const label_bounds = customTextBounds(rect, resolved, label_x, rect.x + rect.w - resolved.padding.right - label_x);
    var encoder = ComponentEncoder{ .commands = commands, .allocator = allocator };
    try (components.RadioButton{
        .outer = .{
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
        },
        .indicator = indicator,
        .label = .{
            .bounds = label_bounds,
            .content = rb.label,
            .color = resolved.fg,
            .font_size = resolved.font_size,
        },
        .focus = focusRing(rect, theme, circle_radius, node.interaction.focused),
    }).emit(&encoder);
}

fn emitTreeItem(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    item: widget.WidgetKind.TreeItem,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    const depth = geometry.treeDepth(tree, handle);
    const indent = @as(f32, @floatFromInt(depth)) * geometry.treeIndent(theme, resolved);
    const slot_width = geometry.treeDisclosureSlotWidth(resolved);
    const disclosure_x = rect.x + resolved.padding.left + indent;
    const label_x = disclosure_x + slot_width;
    const icon_size = treeItemIconSize(item, rect, resolved);
    const icon_gap = treeItemIconGap(item, theme);
    const text_x = label_x + icon_size + icon_gap;
    const label_bounds = customTextBounds(rect, resolved, text_x, rect.x + rect.w - resolved.padding.right - text_x);
    const label = if (item.editing) node.kind.tree_item.internal.editor.content() else item.label;
    const has_parent = geometry.findTreeParent(tree, handle) != null;
    const has_children = treeItemHasChildren(tree, handle);
    const disclosure_bounds = treeDisclosureBounds(disclosure_x, rect, resolved);

    try emitTreeGuides(
        visual_ctx,
        tree,
        handle,
        rect,
        resolved,
        theme,
        if (has_children) disclosure_bounds else null,
        commands,
        allocator,
    );

    const chrome = treeItemChrome(node, item, resolved, theme);
    if (chrome.color.a > 0 or chrome.border_width > 0) {
        try commands.append(allocator, .{ .surface = .{
            .bounds = rect,
            .color = chrome.color,
            .border_color = chrome.border_color,
            .border_width = chrome.border_width,
            .corner_radius = resolved.border_radius,
        } });
    }
    try emitTreeItemDropIndicator(rect, item, resolved, theme, commands, allocator);

    if (has_children) {
        try emitTreeDisclosure(disclosure_bounds, resolved, theme, item.expanded, commands, allocator);
    }
    if (has_parent) {
        const connector_start_x = treeParentGuideCenterX(rect, resolved, theme, depth);
        const connector_end_x = if (has_children)
            disclosure_bounds.x - 2
        else
            label_x - 3;
        if (connector_end_x > connector_start_x) {
            try commands.append(allocator, .{ .surface = .{
                .bounds = .{
                    .x = connector_start_x,
                    .y = rect.y + rect.h * 0.5,
                    .w = connector_end_x - connector_start_x,
                    .h = 1,
                },
                .color = theme.tree_guide,
                .border_color = theme.tree_guide,
                .border_width = 0,
                .corner_radius = 0,
            } });
        }
    }
    if (item.icon) |icon| {
        try appendIconCommand(
            commands,
            allocator,
            .{
                .x = label_x,
                .y = rect.y + (rect.h - icon_size) * 0.5,
                .w = icon_size,
                .h = icon_size,
            },
            icon,
            if (item.selected) theme.accent else item.icon_color orelse resolved.fg,
        );
    }

    if (item.editing) {
        const editor = &node.kind.tree_item.internal.editor;

        if (editor.hasSelection()) {
            const range = editor.selectionRange();
            const sel_start_x = text_x + layout.textWidthUpTo(label, range.start, resolved.font_size, text_ctx);
            const sel_end_x = text_x + layout.textWidthUpTo(label, range.end, resolved.font_size, text_ctx);
            try commands.append(allocator, .{ .surface = .{
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
        try commands.append(allocator, .{ .surface = .{
            .bounds = .{ .x = cursor_x, .y = label_bounds.y, .w = 1, .h = label_bounds.h },
            .color = resolved.fg,
            .border_color = resolved.fg,
            .border_width = 0,
            .corner_radius = 0,
        } });
    } else {
        try appendTextCommand(commands, allocator, label_bounds, label, resolved.fg, resolved.font_size, .start, .visible);
    }

    try emitFocusRing(visual_ctx, node, theme, resolved.border_radius, commands, allocator);
    if (item.expanded) {
        try emitChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);
    } else {
        try emitPopupChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx);
    }
}

fn emitDropdown(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    dropdown: widget.WidgetKind.Dropdown,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    _ = in_floating_subtree;
    const label = if (dropdown.selected_text.len > 0)
        dropdown.selected_text
    else
        dropdown.placeholder;
    const rect = visual_ctx.visualRect(node.layout_rect);
    const chevron = if (dropdown.open) dropdownChevronUp() else dropdownChevronDown();
    const chevron_x = rect.x + rect.w - resolved.padding.right - resolved.font_size * 0.6;
    const label_bounds = customTextBounds(rect, resolved, rect.x + resolved.padding.left, chevron_x - theme.spacing - (rect.x + resolved.padding.left));
    const chevron_bounds = customTextBounds(rect, resolved, chevron_x, rect.x + rect.w - resolved.padding.right - chevron_x);

    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = interactionBg(node, resolved, theme),
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    try appendTextCommand(commands, allocator, label_bounds, label, if (dropdown.selected_text.len > 0) resolved.fg else theme.placeholder_fg, resolved.font_size, .start, .clip);
    try appendTextCommand(commands, allocator, chevron_bounds, chevron, resolved.fg, resolved.font_size, .center, .visible);

    try emitFocusRing(visual_ctx, node, theme, resolved.border_radius, commands, allocator);
    if (dropdown.open) {
        try emitPopupChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx);
    }
}

fn emitListBox(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    list_box: widget.WidgetKind.ListBox,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = if (list_box.internal.drop_preview_background)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 48)
        else
            resolved.bg,
        .border_color = if (list_box.internal.drop_preview_background) theme.accent else resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    try emitChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);

    if (list_box.internal.marquee_active and list_box.internal.marquee_rect.w > 0 and list_box.internal.marquee_rect.h > 0) {
        const fill = style.Color.rgba(theme.selection_bg.r, theme.selection_bg.g, theme.selection_bg.b, 96);
        try commands.append(allocator, .{ .surface = .{
            .bounds = list_box.internal.marquee_rect,
            .color = fill,
            .border_color = theme.accent,
            .border_width = 1,
            .corner_radius = 0,
        } });
    }
}

fn emitSelectable(
    visual_ctx: *const VisualContext,
    node: *const widget.Node,
    selectable: widget.WidgetKind.Selectable,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    _: ?*const layout.TextMeasureCtx,
) !void {
    const fill = selectableBg(node, selectable.selected, theme);
    const rect = visual_ctx.visualRect(node.layout_rect);
    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = if (selectable.internal.drag.active)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 72)
        else
            fill,
        .border_color = if (selectable.internal.drop_preview or selectable.selected) theme.accent else resolved.border,
        .border_width = if (selectable.internal.drop_preview or selectable.selected) 1 else 0,
        .corner_radius = resolved.border_radius,
    } });
    const selectable_bounds = defaultTextBounds(rect, resolved);
    try appendTextCommand(commands, allocator, selectable_bounds, selectable.label, resolved.fg, resolved.font_size, .start, .clip);
    try emitFocusRing(visual_ctx, node, theme, resolved.border_radius, commands, allocator);
}

fn emitGridSelector(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    grid_selector: widget.WidgetKind.GridSelector,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = if (grid_selector.internal.drop_preview_background)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 48)
        else
            resolved.bg,
        .border_color = if (grid_selector.internal.drop_preview_background) theme.accent else resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    try emitChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);

    if (grid_selector.internal.marquee_active and grid_selector.internal.marquee_rect.w > 0 and grid_selector.internal.marquee_rect.h > 0) {
        const fill = style.Color.rgba(theme.selection_bg.r, theme.selection_bg.g, theme.selection_bg.b, 96);
        try commands.append(allocator, .{ .surface = .{
            .bounds = grid_selector.internal.marquee_rect,
            .color = fill,
            .border_color = theme.accent,
            .border_width = 1,
            .corner_radius = 0,
        } });
    }
}

fn emitGridItem(
    visual_ctx: *const VisualContext,
    node: *const widget.Node,
    grid_item: widget.WidgetKind.GridItem,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    _: ?*const layout.TextMeasureCtx,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    const fill = if (grid_item.internal.drag.active)
        style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 72)
    else
        selectableBg(node, grid_item.selected, theme);
    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = fill,
        .border_color = if (grid_item.internal.drop_preview or grid_item.selected) theme.accent else resolved.border,
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
        try commands.append(allocator, .{ .surface = .{
            .bounds = icon_rect,
            .color = icon_fill,
            .border_color = if (grid_item.selected) theme.accent else resolved.border,
            .border_width = 1,
            .corner_radius = @min(resolved.border_radius, 8),
        } });

        if (grid_item.icon) |icon| {
            try appendIconCommand(
                commands,
                allocator,
                icon_rect,
                icon,
                if (grid_item.selected) theme.accent else grid_item.icon_color orelse resolved.fg,
            );
        }
    }

    const label_bounds = Rect{
        .x = inner.x,
        .y = rect.y + rect.h - resolved.padding.bottom - resolved.font_size * 1.4,
        .w = inner.w,
        .h = resolved.font_size * 1.4,
    };
    try appendTextCommand(commands, allocator, label_bounds, grid_item.label, resolved.fg, resolved.font_size, .center, .ellipsis);
    try emitFocusRing(visual_ctx, node, theme, resolved.border_radius, commands, allocator);
}

fn emitTable(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    table: widget.WidgetKind.Table,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const rect = snappedRect(visual_ctx.visualRect(node.layout_rect));
    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = if (table.internal.drop_preview_background)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 48)
        else
            resolved.bg,
        .border_color = if (table.internal.drop_preview_background) theme.accent else resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    try emitChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);

    if (table.internal.marquee_active and table.internal.marquee_rect.w > 0 and table.internal.marquee_rect.h > 0) {
        const fill = style.Color.rgba(theme.selection_bg.r, theme.selection_bg.g, theme.selection_bg.b, 96);
        try commands.append(allocator, .{ .surface = .{
            .bounds = table.internal.marquee_rect,
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
            try commands.append(allocator, .{ .surface = .{
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
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    row: widget.WidgetKind.TableRow,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    const row_fill_rect = tableRowFillRect(tree, handle, rect);
    const fill = tableRowFill(tree, handle, node, row, theme);
    if (fill.a > 0 and row_fill_rect.w > 0 and row_fill_rect.h > 0) {
        try commands.append(allocator, .{ .surface = .{
            .bounds = row_fill_rect,
            .color = fill,
            .border_color = fill,
            .border_width = 0,
            .corner_radius = 0,
        } });
    }

    if (row.internal.drop_preview and row_fill_rect.w > 0 and row_fill_rect.h > 0) {
        try commands.append(allocator, .{ .surface = .{
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
            try commands.append(allocator, .{ .surface = .{
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
            try emitTableCellContents(visual_ctx, tree, child, child_node, child_resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
        } else {
            try emitNode(visual_ctx, tree, child, theme, commands, allocator, text_ctx, in_floating_subtree);
        }
    }

    var divider_iter = tree.children(handle);
    while (divider_iter.next()) |child| {
        const child_node = tree.getConst(child);
        if (child_node.kind != .table_cell) continue;
        const child_resolved = child_node.style_override.resolve(theme);
        try emitTableCellDivider(visual_ctx, tree, child, child_node, child_resolved, commands, allocator);
    }
}

fn emitTableCell(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    try emitTableCellContents(visual_ctx, tree, handle, node, resolved, theme, commands, allocator, text_ctx, in_floating_subtree);
    try emitTableCellDivider(visual_ctx, tree, handle, node, resolved, commands, allocator);
}

fn emitTableCellContents(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
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
            const child_rect = visual_ctx.visualRect(child_node.layout_rect);
            const text_x = child_rect.x;
            const child_right = rectRight(child_rect);
            const text_w = if (sort_direction != null)
                chevron_x - text_x - resolved.font_size * 0.4
            else
                child_right - text_x;
            const text_bounds = Rect{
                .x = text_x,
                .y = child_rect.y,
                .w = @max(@min(text_w, child_rect.w), 0),
                .h = child_rect.h,
            };
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

        try emitNode(visual_ctx, tree, child, theme, commands, allocator, text_ctx, in_floating_subtree);
    }

    if (sort_direction) |direction| {
        const chevron_bounds = customTextBounds(rect, resolved, chevron_x, rectRight(rect) - resolved.padding.right - chevron_x);
        try appendTextCommand(commands, allocator, chevron_bounds, tableSortChevron(direction), theme.accent, resolved.font_size, .center, .visible);
    }
}

fn emitTableCellDivider(
    visual_ctx: *const VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
) !void {
    if (tableCellIndex(tree, handle) > 0) {
        const row_handle = tree.getConst(handle).parent orelse handle;
        const row_rect = visual_ctx.visualRect(tree.getConst(row_handle).layout_rect);
        const rect = visual_ctx.visualRect(node.layout_rect);
        const divider_thickness = tableDividerThickness(resolved.border_width);
        if (divider_thickness > 0) {
            const divider = snappedRect(.{
                .x = rect.x,
                .y = row_rect.y,
                .w = divider_thickness,
                .h = row_rect.h,
            });
            try commands.append(allocator, .{ .surface = .{
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
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    try emitChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn emitToolbar(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = 0,
    } });
    try emitChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn emitStatusBar(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = 0,
    } });
    try emitChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);
}

fn emitMenu(
    visual_ctx: *const VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    menu: widget.WidgetKind.Menu,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    _: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    _ = in_floating_subtree;
    const rect = visual_ctx.visualRect(node.layout_rect);
    try commands.append(allocator, .{ .surface = .{
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
    try emitFocusRing(visual_ctx, node, theme, resolved.border_radius, commands, allocator);
}

fn emitPopup(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    try emitChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx, true);
}

fn emitTooltip(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    try emitChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx, true);
}

fn emitMenuItem(
    visual_ctx: *const VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    item: widget.WidgetKind.MenuItem,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    const has_popup = geometry.directPopupChild(tree, handle) != null;
    const text_color = if (item.disabled)
        style.Color.rgba(resolved.fg.r, resolved.fg.g, resolved.fg.b, 120)
    else
        resolved.fg;
    const reserve_width = @max(resolved.font_size, 12);
    const gap = @max(resolved.padding.left * 0.75, 6);
    const rect = visual_ctx.visualRect(node.layout_rect);
    try commands.append(allocator, .{ .surface = .{
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
        try commands.append(allocator, .{ .surface = .{
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

    try emitFocusRing(visual_ctx, node, theme, resolved.border_radius, commands, allocator);
}

fn emitDragValue(
    visual_ctx: *const VisualContext,
    node: *const widget.Node,
    drag_value: *const widget.WidgetKind.DragValue,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);

    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = interactionBg(node, resolved, theme),
        .border_color = if (node.interaction.pressed or drag_value.editing) theme.accent else resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    const value_bounds = defaultTextBounds(rect, resolved);
    if (drag_value.editing) {
        try emitInlineEditorContents(value_bounds, &drag_value.internal.editor, resolved, theme, commands, allocator, text_ctx, true);
    } else {
        try appendTextCommand(commands, allocator, value_bounds, drag_value.displayValue(), resolved.fg, resolved.font_size, .start, .clip);
    }

    try emitFocusRing(visual_ctx, node, theme, resolved.border_radius, commands, allocator);
}

fn emitSpinBox(
    visual_ctx: *const VisualContext,
    node: *const widget.Node,
    spinbox: *const widget.WidgetKind.SpinBox,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    const buttons = geometry.spinBoxButtons(rect);
    const field_rect = Rect{
        .x = buttons.dec.x + buttons.dec.w,
        .y = rect.y,
        .w = rect.w - buttons.dec.w - buttons.inc.w,
        .h = rect.h,
    };
    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = interactionBg(node, resolved, theme),
        .border_color = if (spinbox.editing) theme.accent else resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });
    try commands.append(allocator, .{ .surface = .{
        .bounds = buttons.dec,
        .color = theme.bg_hover,
        .border_color = resolved.border,
        .border_width = 0,
        .corner_radius = resolved.border_radius,
    } });
    try commands.append(allocator, .{ .surface = .{
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
        try emitInlineEditorContents(field_text_bounds, &spinbox.internal.editor, resolved, theme, commands, allocator, text_ctx, true);
    } else {
        try appendTextCommand(commands, allocator, field_text_bounds, spinbox.displayValue(), resolved.fg, resolved.font_size, .start, .clip);
    }

    try emitFocusRing(visual_ctx, node, theme, resolved.border_radius, commands, allocator);
}

fn emitTabBar(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    _: widget.WidgetKind.TabBar,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    try commands.append(allocator, .{ .surface = .{
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
        try emitTabItemHeader(visual_ctx, child_node, child_node.kind.tab_item, child_node.style_override.resolve(theme), theme, commands, allocator, text_ctx);
    }

    if (geometry.selectedTabItem(tree, handle)) |selected| {
        try emitChildren(visual_ctx, tree, selected, theme, commands, allocator, text_ctx, in_floating_subtree);
    }
}

fn emitTabItem(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    item: widget.WidgetKind.TabItem,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    try emitTabItemHeader(visual_ctx, node, item, resolved, theme, commands, allocator, text_ctx);
    if (item.selected) {
        try emitChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);
    } else {
        try emitPopupChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx);
    }
}

fn emitTabItemHeader(
    visual_ctx: *const VisualContext,
    node: *const widget.Node,
    item: widget.WidgetKind.TabItem,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    _: ?*const layout.TextMeasureCtx,
) !void {
    const chrome = tabItemChrome(node, item, resolved, theme);
    const rect = visual_ctx.visualRect(node.layout_rect);
    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = chrome.color,
        .border_color = chrome.border_color,
        .border_width = chrome.border_width,
        .corner_radius = resolved.border_radius,
    } });
    if (item.selected) {
        try commands.append(allocator, .{ .surface = .{
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

    try emitFocusRing(visual_ctx, node, theme, resolved.border_radius, commands, allocator);
}

fn emitSplitter(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    splitter: widget.WidgetKind.Splitter,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = 0,
        .corner_radius = resolved.border_radius,
    } });

    try emitChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);

    const divider = geometry.splitterDividerRect(rect, splitter, resolved);
    const handle_rect = snappedRect(geometry.splitterHandleRect(divider, splitter));
    const visible_divider = splitterVisibleRect(divider, splitter.direction);
    const grip = splitterGripRect(handle_rect, splitter.direction);
    const divider_color = if (node.interaction.pressed)
        theme.bg_active
    else if (node.interaction.hovered)
        theme.bg_hover
    else
        resolved.border;

    try commands.append(allocator, .{ .surface = .{
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
        try commands.append(allocator, .{ .surface = .{
            .bounds = handle_rect,
            .color = overlay_color,
            .border_color = style.Color.rgba(0, 0, 0, 0),
            .border_width = 0,
            .corner_radius = 2,
        } });
        try commands.append(allocator, .{ .surface = .{
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
    visual_ctx: *const VisualContext,
    node: *const widget.Node,
    sl: widget.WidgetKind.Slider,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);

    // Track
    try commands.append(allocator, .{ .surface = .{
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

    try commands.append(allocator, .{ .surface = .{
        .bounds = .{ .x = thumb_x, .y = rect.y, .w = thumb_w, .h = rect.h },
        .color = theme.accent,
        .border_color = resolved.border,
        .border_width = 0,
        .corner_radius = resolved.border_radius,
    } });

    try emitFocusRing(visual_ctx, node, theme, resolved.border_radius, commands, allocator);
}

fn emitTextInput(
    visual_ctx: *const VisualContext,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    const ti = &node.kind.text_input;
    const rect = visual_ctx.visualRect(node.layout_rect);

    // Background
    try commands.append(allocator, .{ .surface = .{
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

    try emitFocusRing(visual_ctx, node, theme, resolved.border_radius, commands, allocator);
}

fn emitInlineEditorContents(
    text_bounds: Rect,
    ti: *const widget.WidgetKind.TextInput,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    show_cursor: bool,
) !void {
    const content = ti.content();
    if (show_cursor and ti.hasSelection()) {
        const range = ti.selectionRange();
        const sel_start_x = text_bounds.x + layout.textWidthUpTo(content, range.start, resolved.font_size, text_ctx);
        const sel_end_x = text_bounds.x + layout.textWidthUpTo(content, range.end, resolved.font_size, text_ctx);
        try commands.append(allocator, .{ .surface = .{
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
        try commands.append(allocator, .{ .surface = .{
            .bounds = .{ .x = cursor_x, .y = text_bounds.y, .w = 1, .h = text_bounds.h },
            .color = resolved.fg,
            .border_color = resolved.fg,
            .border_width = 0,
            .corner_radius = 0,
        } });
    }
}

fn emitScrollArea(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    const rect = visual_ctx.visualRect(node.layout_rect);
    const previous_cull_rect = visual_ctx.cull_rect;
    visual_ctx.cull_rect = if (previous_cull_rect) |cull_rect|
        geometry.intersectRects(cull_rect, rect)
    else
        rect;
    defer visual_ctx.cull_rect = previous_cull_rect;

    // Background
    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = resolved.bg,
        .border_color = resolved.border,
        .border_width = resolved.border_width,
        .corner_radius = resolved.border_radius,
    } });

    // Push clip
    try commands.append(allocator, .{ .push_clip = visual_ctx.cull_rect orelse rect });

    try emitChildren(visual_ctx, tree, handle, theme, commands, allocator, text_ctx, in_floating_subtree);

    // Pop clip
    try commands.append(allocator, .pop_clip);

    if (scrollbar.verticalMetrics(tree, handle, theme)) |metrics| {
        try emitScrollbar(visualScrollbarMetrics(visual_ctx, metrics), theme, commands, allocator);
    }
    if (scrollbar.horizontalMetrics(tree, handle, theme)) |metrics| {
        try emitScrollbar(visualScrollbarMetrics(visual_ctx, metrics), theme, commands, allocator);
    }
}

fn visualScrollbarMetrics(visual_ctx: *const VisualContext, metrics: scrollbar.Metrics) scrollbar.Metrics {
    var painted = metrics;
    painted.track = visual_ctx.visualRect(metrics.track);
    painted.thumb = visual_ctx.visualRect(metrics.thumb);
    return painted;
}

fn emitScrollbar(
    metrics: scrollbar.Metrics,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
) !void {
    const radius = switch (metrics.axis) {
        .vertical => metrics.track.w * 0.5,
        .horizontal => metrics.track.h * 0.5,
    };
    try commands.append(allocator, .{ .surface = .{
        .bounds = metrics.track,
        .color = style.Color.rgba(theme.border.r, theme.border.g, theme.border.b, 32),
        .border_color = style.Color.rgba(0, 0, 0, 0),
        .border_width = 0,
        .corner_radius = radius,
    } });
    try commands.append(allocator, .{ .surface = .{
        .bounds = metrics.thumb,
        .color = switch (metrics.interaction) {
            .idle => style.Color.rgba(theme.border.r, theme.border.g, theme.border.b, 150),
            .hovered => style.Color.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 128),
            .active => style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 180),
        },
        .border_color = style.Color.rgba(0, 0, 0, 0),
        .border_width = 0,
        .corner_radius = radius,
    } });
}

/// Emit a focus ring around a widget's layout rect if it has focus.
fn emitFocusRing(
    visual_ctx: *const VisualContext,
    node: *const widget.Node,
    theme: style.Theme,
    corner_radius: f32,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
) !void {
    try emitFocusRingRect(visual_ctx.visualRect(node.layout_rect), theme, corner_radius, commands, allocator, node.interaction.focused);
}

fn emitFocusRingRect(
    rect: Rect,
    theme: style.Theme,
    corner_radius: f32,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    focused: bool,
) !void {
    var encoder = ComponentEncoder{ .commands = commands, .allocator = allocator };
    try focusRing(rect, theme, corner_radius, focused).emit(&encoder);
}

fn focusRing(rect: Rect, theme: style.Theme, corner_radius: f32, focused: bool) components.FocusRing {
    return .{
        .bounds = rect,
        .color = theme.focus_ring,
        .corner_radius = corner_radius,
        .visible = focused,
    };
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
    visual_ctx: *const VisualContext,
    node: *const widget.Node,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
) !void {
    if (!node.interaction.drop_hovered) return;
    const rect = visual_ctx.visualRect(node.layout_rect);
    if (rect.w <= 0 or rect.h <= 0) return;
    try commands.append(allocator, .{ .surface = .{
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
    if (row.internal.drag.active) return style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 72);
    if (row.selected) return theme.selection_bg;
    if (row.header) return theme.bg_active;
    if (widget.tableRowSelectable(tree, handle) and node.interaction.hovered) {
        return theme.bg_hover;
    }
    if (tableStriped(tree, handle) and (tableRowIndex(tree, handle) % 2 == 1)) {
        return style.Color.rgba(theme.bg_hover.r, theme.bg_hover.g, theme.bg_hover.b, 96);
    }
    return style.Color.rgba(0, 0, 0, 0);
}

test "hovered selectable table row uses the full theme hover color" {
    const allocator = std.testing.allocator;
    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const table = try tree.addRoot(.{ .table = .{
        .columns = 1,
        .selection_mode = .single,
    } });
    const row_handle = try tree.addChild(table, .{ .table_row = .{} });
    const row_node = tree.get(row_handle);
    row_node.interaction.hovered = true;

    const theme = style.Theme{
        .bg_hover = style.Color.rgb(231, 238, 248),
    };
    try std.testing.expectEqual(
        theme.bg_hover,
        tableRowFill(&tree, row_handle, row_node, row_node.kind.table_row, theme),
    );
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

fn menuPopupVisible(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const popup = geometry.directPopupChild(tree, handle) orelse return false;
    return shouldDrawNode(tree, popup);
}

fn menuHasActiveFill(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node) bool {
    if (menuPopupVisible(tree, handle)) return true;
    if (!node.interaction.hovered) return false;

    const parent_handle = node.parent orelse return false;
    const parent = tree.getConst(parent_handle);
    if (parent.kind != .menu_bar) return false;

    var iter = tree.children(parent_handle);
    while (iter.next()) |child| {
        const popup = geometry.directPopupChild(tree, child) orelse continue;
        if (shouldDrawNode(tree, popup)) return true;
    }
    return false;
}

fn emitMenuArrow(
    rect: Rect,
    resolved: style.ResolvedStyle,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    color: style.Color,
) !void {
    const mid_y = rect.y + rect.h * 0.5;
    const right = rect.x + rect.w - resolved.padding.right * 0.75;
    try commands.append(allocator, .{ .surface = .{
        .bounds = .{ .x = right - 5, .y = mid_y - 3, .w = 1, .h = 6 },
        .color = color,
        .border_color = color,
        .border_width = 0,
        .corner_radius = 0,
    } });
    try commands.append(allocator, .{ .surface = .{
        .bounds = .{ .x = right - 3, .y = mid_y - 2, .w = 1, .h = 4 },
        .color = color,
        .border_color = color,
        .border_width = 0,
        .corner_radius = 0,
    } });
    try commands.append(allocator, .{ .surface = .{
        .bounds = .{ .x = right - 1, .y = mid_y - 1, .w = 1, .h = 2 },
        .color = color,
        .border_color = color,
        .border_width = 0,
        .corner_radius = 0,
    } });
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
        .color = if (item.internal.drag.active)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 72)
        else if (node.interaction.drop_hovered)
            style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 48)
        else if (item.internal.drop_preview == .into)
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
        .border_color = if (node.interaction.drop_hovered or item.internal.drop_preview == .into)
            theme.accent
        else if (has_custom_border)
            resolved.border
        else
            .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .border_width = if (node.interaction.drop_hovered or item.internal.drop_preview == .into)
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
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
) !void {
    const preview = item.internal.drop_preview orelse return;
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
    try commands.append(allocator, .{ .surface = .{
        .bounds = indicator_bounds,
        .color = theme.accent,
        .border_color = theme.accent,
        .border_width = 0,
        .corner_radius = 0,
    } });
}

fn emitTreeGuides(
    visual_ctx: *const VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    row_rect: Rect,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    disclosure_bounds: ?Rect,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
) !void {
    var ancestor = tree.getConst(handle).parent;
    var ancestor_depth = geometry.treeDepth(tree, handle);

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

    if (geometry.findTreeParent(tree, handle)) |parent_handle| {
        const parent_rect = visual_ctx.visualRect(tree.getConst(parent_handle).layout_rect);
        const parent_bottom_y = parent_rect.y + parent_rect.h;
        const row_center_y = row_rect.y + row_rect.h * 0.5;
        const parent_guide_x = treeParentGuideCenterX(row_rect, resolved, theme, geometry.treeDepth(tree, handle));
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
            const next_rect = visual_ctx.visualRect(tree.getConst(next_handle).layout_rect);
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
    if (node.kind.tree_item.expanded) if (disclosure_bounds) |bounds| {
        try appendTreeGuideVertical(
            commands,
            allocator,
            theme,
            bounds.x + bounds.w * 0.5,
            bounds.y + bounds.h,
            row_rect.y + row_rect.h,
        );
    };
}

fn appendTreeGuideVertical(
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    theme: style.Theme,
    x: f32,
    y0: f32,
    y1: f32,
) !void {
    const top = @min(y0, y1);
    const bottom = @max(y0, y1);
    try commands.append(allocator, .{ .surface = .{
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

fn treeDisclosureBounds(
    disclosure_x: f32,
    row_rect: Rect,
    resolved: style.ResolvedStyle,
) Rect {
    const slot_width = geometry.treeDisclosureSlotWidth(resolved);
    const size = @max(resolved.font_size * 0.8, 11);
    return .{
        .x = disclosure_x + (slot_width - size) * 0.5,
        .y = row_rect.y + (row_rect.h - size) * 0.5,
        .w = size,
        .h = size,
    };
}

fn emitTreeDisclosure(
    bounds: Rect,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    expanded: bool,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
) !void {
    try appendTextCommand(
        commands,
        allocator,
        bounds,
        if (expanded) "▾" else "▸",
        if (expanded) theme.accent else resolved.fg,
        bounds.h,
        .center,
        .visible,
    );
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
    const indent = @as(f32, @floatFromInt(depth)) * geometry.treeIndent(theme, resolved);
    return row_rect.x + resolved.padding.left + indent + geometry.treeDisclosureSlotWidth(resolved) * 0.5;
}

fn treeParentGuideCenterX(
    row_rect: Rect,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    depth: u32,
) f32 {
    return treeGuideCenterX(row_rect, resolved, theme, if (depth == 0) 0 else depth - 1);
}

fn emitChildren(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    parent: widget.NodeHandle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
    in_floating_subtree: bool,
) !void {
    var iter = tree.children(parent);
    while (iter.next()) |child| {
        if (!in_floating_subtree and (tree.getConst(child).kind == .popup or tree.getConst(child).kind == .tooltip)) continue;
        try emitNode(visual_ctx, tree, child, theme, commands, allocator, text_ctx, in_floating_subtree);
    }
}

fn emitPopupChildren(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    parent: widget.NodeHandle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    var iter = tree.children(parent);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind != .popup and tree.getConst(child).kind != .tooltip) continue;
        try emitNode(visual_ctx, tree, child, theme, commands, allocator, text_ctx, true);
    }
}

fn emitFloatingSubtrees(
    visual_ctx: *VisualContext,
    tree: *const widget.Tree,
    handle: widget.NodeHandle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    text_ctx: ?*const layout.TextMeasureCtx,
) !void {
    if (!shouldDrawNode(tree, handle)) return;
    const node = tree.getConst(handle);
    if (node.kind == .popup or node.kind == .tooltip) {
        try emitNode(visual_ctx, tree, handle, theme, commands, allocator, text_ctx, true);
        return;
    }

    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (node.kind == .tree_item and !node.kind.tree_item.expanded and tree.getConst(child).kind != .popup and tree.getConst(child).kind != .tooltip) continue;
        if (node.kind == .tab_item and !node.kind.tab_item.selected) continue;
        try emitFloatingSubtrees(visual_ctx, tree, child, theme, commands, allocator, text_ctx);
    }
}

fn shouldTraverseCulledNode(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    return culledTraversePredicate(node.kind)(tree, handle, node);
}

const CulledTraversePredicate = *const fn (*const widget.Tree, widget.NodeHandle, *const widget.Node) bool;

fn culledTraversePredicate(kind: widget.WidgetKind) CulledTraversePredicate {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return culled_traverse_predicates[@intFromEnum(tag)];
}

const culled_traverse_predicates = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var predicates: [std.meta.fields(Tag).len]CulledTraversePredicate = undefined;
    for (&predicates) |*predicate| predicate.* = neverTraverseCulledNode;
    predicates[@intFromEnum(Tag.tree_item)] = traverseCulledTreeItem;
    predicates[@intFromEnum(Tag.tab_item)] = traverseCulledTabItem;
    break :blk predicates;
};

fn neverTraverseCulledNode(_: *const widget.Tree, _: widget.NodeHandle, _: *const widget.Node) bool {
    return false;
}

fn traverseCulledTreeItem(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node) bool {
    return node.kind.tree_item.expanded and hasNonFloatingChild(tree, handle);
}

fn traverseCulledTabItem(tree: *const widget.Tree, handle: widget.NodeHandle, node: *const widget.Node) bool {
    return node.kind.tab_item.selected and hasNonFloatingChild(tree, handle);
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
    visual_ctx: *const VisualContext,
    tree: *const widget.Tree,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
    _: ?*const layout.TextMeasureCtx,
) !void {
    _ = visual_ctx;
    for (tree.nodes.items) |node| {
        if (!node.alive) continue;
        try dragGhostEmitter(node.kind)(&node, theme, commands, allocator);
    }
}

const DragGhostEmitter = *const fn (*const widget.Node, style.Theme, *std.ArrayListUnmanaged(VisualOperation), std.mem.Allocator) VisualError!void;

fn dragGhostEmitter(kind: widget.WidgetKind) DragGhostEmitter {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return drag_ghost_emitters[@intFromEnum(tag)];
}

const drag_ghost_emitters = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var emitters: [std.meta.fields(Tag).len]DragGhostEmitter = undefined;
    for (&emitters) |*emitter| emitter.* = emitNoDragGhost;
    emitters[@intFromEnum(Tag.tree_item)] = emitTreeItemDragGhost;
    emitters[@intFromEnum(Tag.selectable)] = emitSelectableDragGhost;
    emitters[@intFromEnum(Tag.grid_item)] = emitGridItemDragGhost;
    emitters[@intFromEnum(Tag.table_row)] = emitTableRowDragGhost;
    break :blk emitters;
};

fn emitNoDragGhost(_: *const widget.Node, _: style.Theme, _: *std.ArrayListUnmanaged(VisualOperation), _: std.mem.Allocator) VisualError!void {}

fn emitTreeItemDragGhost(node: *const widget.Node, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator) VisualError!void {
    const item = node.kind.tree_item;
    if (!item.internal.drag.active or item.internal.drag.rect.w <= 0 or item.internal.drag.rect.h <= 0) return;
    const resolved = node.style_override.resolve(theme);
    try emitDragGhostRect(item.internal.drag.rect, resolved, theme, commands, allocator);
    const label_x = item.internal.drag.rect.x + resolved.padding.left;
    const label_bounds = customTextBounds(item.internal.drag.rect, resolved, label_x, rectRight(item.internal.drag.rect) - resolved.padding.right - label_x);
    try appendTextCommand(commands, allocator, label_bounds, item.label, dragGhostColor(resolved.fg, 210), resolved.font_size, .start, .clip);
}

fn emitSelectableDragGhost(node: *const widget.Node, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator) VisualError!void {
    const item = node.kind.selectable;
    if (!item.internal.drag.active or item.internal.drag.rect.w <= 0 or item.internal.drag.rect.h <= 0) return;
    const resolved = node.style_override.resolve(theme);
    try emitDragGhostRect(item.internal.drag.rect, resolved, theme, commands, allocator);
    const label_bounds = defaultTextBounds(item.internal.drag.rect, resolved);
    try appendTextCommand(commands, allocator, label_bounds, item.label, dragGhostColor(resolved.fg, 210), resolved.font_size, .start, .clip);
}

fn emitGridItemDragGhost(node: *const widget.Node, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator) VisualError!void {
    const item = node.kind.grid_item;
    if (!item.internal.drag.active or item.internal.drag.rect.w <= 0 or item.internal.drag.rect.h <= 0) return;
    const resolved = node.style_override.resolve(theme);
    try emitDragGhostRect(item.internal.drag.rect, resolved, theme, commands, allocator);
    const inner = defaultTextBounds(item.internal.drag.rect, resolved);
    const icon_size = @max(@min(inner.w, inner.h - resolved.font_size - theme.spacing), 0);
    if (icon_size > 8) {
        const icon_rect = Rect{
            .x = inner.x + (inner.w - icon_size) * 0.5,
            .y = inner.y,
            .w = icon_size,
            .h = @min(icon_size, inner.h - resolved.font_size - theme.spacing),
        };
        try commands.append(allocator, .{ .surface = .{
            .bounds = icon_rect,
            .color = style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 68),
            .border_color = dragGhostColor(theme.accent, 170),
            .border_width = 1,
            .corner_radius = @min(resolved.border_radius, 8),
        } });
    }
    const label_bounds = Rect{
        .x = inner.x,
        .y = item.internal.drag.rect.y + item.internal.drag.rect.h - resolved.padding.bottom - resolved.font_size * 1.4,
        .w = inner.w,
        .h = resolved.font_size * 1.4,
    };
    try appendTextCommand(commands, allocator, label_bounds, item.label, dragGhostColor(resolved.fg, 210), resolved.font_size, .center, .ellipsis);
}

fn emitTableRowDragGhost(node: *const widget.Node, theme: style.Theme, commands: *std.ArrayListUnmanaged(VisualOperation), allocator: std.mem.Allocator) VisualError!void {
    const row = node.kind.table_row;
    if (!row.internal.drag.active or row.internal.drag.rect.w <= 0 or row.internal.drag.rect.h <= 0) return;
    const resolved = node.style_override.resolve(theme);
    try emitDragGhostRect(row.internal.drag.rect, resolved, theme, commands, allocator);
}

fn dragGhostColor(color: style.Color, alpha: u8) style.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = @min(color.a, alpha) };
}

fn emitDragGhostRect(
    rect: Rect,
    resolved: style.ResolvedStyle,
    theme: style.Theme,
    commands: *std.ArrayListUnmanaged(VisualOperation),
    allocator: std.mem.Allocator,
) !void {
    try commands.append(allocator, .{ .surface = .{
        .bounds = rect,
        .color = style.Color.rgba(theme.bg_active.r, theme.bg_active.g, theme.bg_active.b, 150),
        .border_color = dragGhostColor(theme.accent, 180),
        .border_width = @max(resolved.border_width, 1),
        .corner_radius = resolved.border_radius,
    } });
}

fn shouldDrawNode(tree: *const widget.Tree, handle: widget.NodeHandle) bool {
    const node = tree.getConst(handle);
    return drawPredicate(node.kind)(tree, handle, node);
}

const DrawPredicate = *const fn (*const widget.Tree, widget.NodeHandle, *const widget.Node) bool;

fn drawPredicate(kind: widget.WidgetKind) DrawPredicate {
    const tag: std.meta.Tag(widget.WidgetKind) = kind;
    return draw_predicates[@intFromEnum(tag)];
}

const draw_predicates = blk: {
    const Tag = std.meta.Tag(widget.WidgetKind);
    var predicates: [std.meta.fields(Tag).len]DrawPredicate = undefined;
    for (&predicates) |*predicate| predicate.* = alwaysDrawNode;
    predicates[@intFromEnum(Tag.popup)] = popupShouldDraw;
    predicates[@intFromEnum(Tag.tooltip)] = tooltipShouldDraw;
    break :blk predicates;
};

fn alwaysDrawNode(_: *const widget.Tree, _: widget.NodeHandle, _: *const widget.Node) bool {
    return true;
}

fn popupShouldDraw(tree: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node) bool {
    if (!node.kind.popup.visible) return false;

    if (node.parent) |parent_handle| {
        const parent = tree.getConst(parent_handle);
        if (parent.kind == .dropdown) {
            return parent.kind.dropdown.open;
        }
    }
    return true;
}

fn tooltipShouldDraw(tree: *const widget.Tree, _: widget.NodeHandle, node: *const widget.Node) bool {
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

test "prepare visual operations from tree" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    _ = try tree.addChild(root, .{ .button = .{ .label = "OK" } });
    _ = try tree.addChild(root, .{ .text = .{ .content = "hello" } });

    // Set some layout rects so paint has something to work with
    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };

    const theme = style.Theme.default;
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    // Container bg + button bg + button text + text label = 4 commands
    try std.testing.expectEqual(@as(usize, 4), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface); // container bg
    try std.testing.expect(dl.commands[1] == .surface); // button bg
    try std.testing.expect(dl.commands[2] == .text); // button label
    try std.testing.expect(dl.commands[3] == .text); // text widget
}

test "stock chrome preserves opaque ids for passive and grid icons" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const passive_color = style.Color.rgb(11, 22, 33);
    const grid_color = style.Color.rgb(44, 55, 66);
    const passive = try tree.addRoot(.{ .icon = .{ .kind = 101, .color = passive_color } });
    const grid_item = try tree.addRoot(.{ .grid_item = .{
        .label = "Folder",
        .icon = 202,
        .icon_color = grid_color,
    } });
    tree.get(passive).layout_rect = .{ .x = 4, .y = 8, .w = 18, .h = 18 };
    tree.get(grid_item).layout_rect = .{ .x = 40, .y = 8, .w = 96, .h = 96 };

    var visuals = try prepareVisuals(&tree, style.Theme.default, allocator, null, .{});
    defer freeVisuals(&visuals, allocator);

    var found_passive = false;
    var found_grid = false;
    for (visuals.commands) |command| {
        if (command != .icon) continue;
        switch (command.icon.kind) {
            101 => {
                found_passive = true;
                try std.testing.expectEqual(passive_color, command.icon.color);
                try std.testing.expectEqual(tree.getConst(passive).layout_rect, command.icon.bounds);
            },
            202 => {
                found_grid = true;
                try std.testing.expectEqual(grid_color, command.icon.color);
                try std.testing.expect(command.icon.bounds.w > 8);
                try std.testing.expect(command.icon.bounds.h > 8);
            },
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expect(found_passive);
    try std.testing.expect(found_grid);
}

test "canonical visual text carries resolved bounds" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const button = try tree.addRoot(.{ .button = .{ .label = "OK" } });
    tree.get(button).layout_rect = .{ .x = 10, .y = 20, .w = 120, .h = 40 };

    const text_ctx = layout.TextMeasureCtx{
        .measureFn = &testMeasureText,
    };

    var visuals = try prepareVisuals(&tree, style.Theme.default, allocator, &text_ctx, .{});
    defer freeVisuals(&visuals, allocator);

    try std.testing.expectEqual(@as(usize, 2), visuals.commands.len);
    try std.testing.expect(visuals.commands[1] == .text);
    const text = visuals.commands[1].text;
    try std.testing.expectApproxEqAbs(@as(f32, 16), text.bounds.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 26), text.bounds.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 108), text.bounds.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 28), text.bounds.h, 0.01);
}

test "popup visuals can be split from main visuals" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const root = try tree.addRoot(.{ .container = .{} });
    const menu = try tree.addChild(root, .{ .menu = .{ .label = "File" } });
    const popup = try tree.addChild(menu, .{ .popup = .{
        .placement = .below_start,
        .visible = true,
    } });
    try tree.setElementId(popup, .init(501));
    const item = try tree.addChild(popup, .{ .menu_item = .{ .label = "Open" } });

    tree.get(root).layout_rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    tree.get(menu).layout_rect = .{ .x = 10, .y = 8, .w = 48, .h = 24 };
    tree.get(popup).layout_rect = .{ .x = 10, .y = 32, .w = 144, .h = 30 };
    tree.get(item).layout_rect = .{ .x = 10, .y = 32, .w = 144, .h = 30 };

    var main_visuals = try prepareVisuals(&tree, style.Theme.default, allocator, null, .{ .scope = .{ .full = .{ .include_floating = false } } });
    defer freeVisuals(&main_visuals, allocator);
    for (main_visuals.commands) |command| {
        if (command == .surface) {
            try std.testing.expect(command.surface.bounds.y < tree.getConst(popup).layout_rect.y);
        }
    }

    var popup_visuals = try prepareVisuals(&tree, style.Theme.default, allocator, null, .{ .scope = .{ .popup = .init(501) } });
    defer freeVisuals(&popup_visuals, allocator);
    try std.testing.expect(popup_visuals.commands.len >= 3);
    try std.testing.expect(popup_visuals.commands[0] == .surface);
    try std.testing.expectApproxEqAbs(@as(f32, 0), popup_visuals.commands[0].surface.bounds.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), popup_visuals.commands[0].surface.bounds.y, 0.01);
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
    var visuals = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&visuals, allocator);

    var found_indicator = false;
    for (visuals.commands) |command| {
        if (command != .surface) continue;
        const box = command.surface;
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
    var visuals = try prepareVisuals(&tree, theme, allocator, null, .{ .scope = .{ .full = .{ .include_floating = false } } });
    defer freeVisuals(&visuals, allocator);

    var found_edit_box = false;
    for (visuals.commands) |command| {
        if (command != .surface) continue;
        const box = command.surface;
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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 5), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface); // toolbar chrome
    try std.testing.expect(dl.commands[1] == .surface); // toolbar button
    try std.testing.expect(dl.commands[2] == .text); // toolbar button label
    try std.testing.expect(dl.commands[3] == .surface); // status bar chrome
    try std.testing.expect(dl.commands[4] == .text); // status text
}

test "checkbox emits box and label" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const cb = try tree.addRoot(.{ .checkbox = .{ .label = "Enable", .checked = false } });
    tree.get(cb).layout_rect = .{ .x = 10, .y = 20, .w = 200, .h = 26 };

    const theme = style.Theme.default;
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    // Unchecked: box rect + label text = 2 commands
    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface); // box
    try std.testing.expect(dl.commands[1] == .text); // label
}

test "checked checkbox emits indicator" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const cb = try tree.addRoot(.{ .checkbox = .{ .label = "Enable", .checked = true } });
    tree.get(cb).layout_rect = .{ .x = 10, .y = 20, .w = 200, .h = 26 };

    const theme = style.Theme.default;
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    // Checked: box rect + indicator rect + label text = 3 commands
    try std.testing.expectEqual(@as(usize, 3), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface); // box
    try std.testing.expect(dl.commands[1] == .surface); // check indicator
    try std.testing.expect(dl.commands[2] == .text); // label
}

test "radio button emits circle and label" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const rb = try tree.addRoot(.{ .radio_button = .{ .label = "Option A", .group = 1 } });
    tree.get(rb).layout_rect = .{ .x = 10, .y = 20, .w = 200, .h = 26 };

    const theme = style.Theme.default;
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    // Unselected: circle rect + label text = 2 commands
    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface);
    try std.testing.expect(dl.commands[1] == .text);

    // Corner radius should be half the box size (circular)
    const circle = dl.commands[0].surface;
    try std.testing.expectApproxEqAbs(circle.bounds.w / 2, circle.corner_radius, 0.01);
}

test "selected radio button emits indicator dot" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const rb = try tree.addRoot(.{ .radio_button = .{ .label = "Option A", .group = 1, .selected = true } });
    tree.get(rb).layout_rect = .{ .x = 10, .y = 20, .w = 200, .h = 26 };

    const theme = style.Theme.default;
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    // Selected: circle rect + indicator dot + label text = 3 commands
    try std.testing.expectEqual(@as(usize, 3), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface);
    try std.testing.expect(dl.commands[1] == .surface);
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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface);
    try std.testing.expect(dl.commands[1] == .text);
    try std.testing.expectEqual(theme.selection_bg, dl.commands[0].surface.color);
    try std.testing.expectEqual(@as(f32, 0), dl.commands[0].surface.border_width);
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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 11), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface); // root bg
    try std.testing.expect(dl.commands[1] == .surface); // parent downward guide
    try std.testing.expect(dl.commands[2] == .text); // disclosure chevron
    try std.testing.expectEqualStrings("▾", dl.commands[2].text.text);
    try std.testing.expect(dl.commands[3] == .text); // parent label
    try std.testing.expect(dl.commands[4] == .surface); // child vertical guide
    try std.testing.expect(dl.commands[5] == .surface); // child sibling guide
    try std.testing.expect(dl.commands[6] == .surface); // child connector
    try std.testing.expect(dl.commands[7] == .text); // child label
    try std.testing.expect(dl.commands[8] == .surface); // sibling vertical guide
    try std.testing.expect(dl.commands[9] == .surface); // sibling connector
    try std.testing.expect(dl.commands[10] == .text); // sibling label

    const disclosure = dl.commands[2].text.bounds;
    const downward_guide = dl.commands[1].surface.bounds;
    try std.testing.expect(
        downward_guide.y >= disclosure.y + disclosure.h,
    );

    const child_guide = dl.commands[4].surface.bounds;
    try std.testing.expectApproxEqAbs(@as(f32, 25), child_guide.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 36), child_guide.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 27), child_guide.h, 0.01);

    const sibling_guide = dl.commands[5].surface.bounds;
    try std.testing.expectApproxEqAbs(child_guide.x, sibling_guide.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 63), sibling_guide.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), sibling_guide.h, 0.01);

    const child_connector = dl.commands[6].surface.bounds;
    try std.testing.expectApproxEqAbs(child_guide.x, child_connector.x, 0.01);

    tree.get(parent).kind.tree_item.expanded = false;
    var collapsed = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&collapsed, allocator);
    var found_collapsed_chevron = false;
    for (collapsed.commands) |command| {
        if (command == .text and std.mem.eql(u8, command.text.text, "▸")) {
            found_collapsed_chevron = true;
            break;
        }
    }
    try std.testing.expect(found_collapsed_chevron);
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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface);
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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 6), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface);
    try std.testing.expect(dl.commands[1] == .surface);
    try std.testing.expect(dl.commands[2] == .surface);
    try std.testing.expect(dl.commands[3] == .text);
    try std.testing.expect(dl.commands[4] == .text);
    try std.testing.expect(dl.commands[5] == .text);
    try std.testing.expectEqualStrings("4", dl.commands[5].text.text);
}

test "numeric controls emit text with stable resolved bounds" {
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

    var visuals = try prepareVisuals(&tree, style.Theme.default, allocator, &text_ctx, .{});
    defer freeVisuals(&visuals, allocator);

    try std.testing.expect(visuals.commands[1] == .text);
    try std.testing.expectApproxEqAbs(@as(f32, 26), visuals.commands[1].text.bounds.y, 0.01);
    try std.testing.expect(visuals.commands[7] == .text);
    try std.testing.expectApproxEqAbs(@as(f32, 66), visuals.commands[7].text.bounds.y, 0.01);
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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 7), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface); // tab bar bg
    try std.testing.expect(dl.commands[1] == .surface); // selected tab rect
    try std.testing.expect(dl.commands[2] == .surface); // selected tab underline
    try std.testing.expect(dl.commands[3] == .text); // selected tab label
    try std.testing.expect(dl.commands[4] == .surface); // inactive tab rect
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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 10), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface); // table bg
    try std.testing.expect(dl.commands[1] == .surface); // header fill
    try std.testing.expect(dl.commands[2] == .text); // header name
    try std.testing.expect(dl.commands[3] == .text); // header type
    try std.testing.expect(dl.commands[4] == .surface); // header divider
    try std.testing.expect(dl.commands[5] == .surface); // striped row fill
    try std.testing.expect(dl.commands[6] == .surface); // row top separator
    try std.testing.expect(dl.commands[7] == .text); // row name
    try std.testing.expect(dl.commands[8] == .text); // row type
    try std.testing.expect(dl.commands[9] == .surface); // row divider
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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 14), dl.commands.len);
    try std.testing.expect(dl.commands[6] == .surface);
    try std.testing.expect(dl.commands[10] == .surface);
    try std.testing.expect(dl.commands[4] == .surface);
    try std.testing.expect(dl.commands[13] == .surface);

    try std.testing.expectApproxEqAbs(@as(f32, 29), dl.commands[6].surface.bounds.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 57), dl.commands[10].surface.bounds.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 141), dl.commands[4].surface.bounds.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 141), dl.commands[13].surface.bounds.x, 0.01);
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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 6), dl.commands.len);
    try std.testing.expect(dl.commands[5] == .surface);
    try std.testing.expectApproxEqAbs(@as(f32, 139), dl.commands[5].surface.bounds.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 8), dl.commands[5].surface.bounds.y, 0.01);
    try std.testing.expectApproxEqAbs(widget.WidgetKind.Table.resize_grip_height, dl.commands[5].surface.bounds.h, 0.01);
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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 4), dl.commands.len);
    try std.testing.expect(dl.commands[1] == .surface);
    try std.testing.expect(dl.commands[2] == .surface);
    try std.testing.expect(dl.commands[3] == .surface);
    try std.testing.expectApproxEqAbs(@as(f32, 60), dl.commands[1].surface.bounds.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1), dl.commands[1].surface.bounds.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 56), dl.commands[2].surface.bounds.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 8), dl.commands[2].surface.bounds.w, 0.01);
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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    // Track + thumb = 2 rects
    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface); // track
    try std.testing.expect(dl.commands[1] == .surface); // thumb

    // Thumb should be roughly centered for value=0.5
    const thumb = dl.commands[1].surface;
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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    // bg rect + clip push + text + clip pop = 4
    try std.testing.expectEqual(@as(usize, 4), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface); // bg
    try std.testing.expect(dl.commands[1] == .push_clip);
    try std.testing.expect(dl.commands[2] == .text); // child text
    try std.testing.expect(dl.commands[3] == .pop_clip);
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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 6), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface);
    try std.testing.expect(dl.commands[1] == .push_clip);
    try std.testing.expect(dl.commands[2] == .text);
    try std.testing.expectEqualStrings("visible", dl.commands[2].text.text);
    try std.testing.expect(dl.commands[3] == .pop_clip);
    try std.testing.expect(dl.commands[4] == .surface);
    try std.testing.expect(dl.commands[5] == .surface);
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

    var dl = try prepareVisuals(&tree, style.Theme.default, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 5), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface);
    try std.testing.expect(dl.commands[1] == .push_clip);
    try std.testing.expect(dl.commands[2] == .pop_clip);
    try std.testing.expect(dl.commands[3] == .surface);
    try std.testing.expect(dl.commands[4] == .surface);
    try std.testing.expectEqual(
        style.Color.rgba(theme.border.r, theme.border.g, theme.border.b, 150),
        dl.commands[4].surface.color,
    );

    tree.get(scroll).kind.scroll_area.internal.active_scrollbar = .vertical;
    var active = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&active, allocator);
    try std.testing.expectEqual(
        style.Color.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 180),
        active.commands[4].surface.color,
    );
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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 5), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface);
    try std.testing.expect(dl.commands[1] == .push_clip);
    try std.testing.expect(dl.commands[2] == .pop_clip);
    try std.testing.expect(dl.commands[3] == .surface);
    try std.testing.expect(dl.commands[4] == .surface);
    try std.testing.expect(dl.commands[3].surface.bounds.w > dl.commands[3].surface.bounds.h);
    try std.testing.expect(dl.commands[4].surface.bounds.w > dl.commands[4].surface.bounds.h);
}

test "scroll area omits disabled horizontal scrollbar when content overflows width" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const scroll = try tree.addRoot(.{ .scroll_area = .{ .disable_horizontal_scroll = true } });
    const child = try tree.addChild(scroll, .{ .spacer = .{ .width = 300, .height = 40 } });
    tree.get(scroll).layout_rect = .{ .x = 0, .y = 0, .w = 120, .h = 80 };
    tree.get(child).layout_rect = .{ .x = 6, .y = 6, .w = 300, .h = 40 };

    const theme = style.Theme.default;
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 3), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface);
    try std.testing.expect(dl.commands[1] == .push_clip);
    try std.testing.expect(dl.commands[2] == .pop_clip);
}

test "wrapped text visual operations wrap and preserve newlines" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const text = try tree.addRoot(.{ .text = .{ .content = "alpha beta\ngamma", .overflow = .wrap } });
    tree.get(text).layout_rect = .{ .x = 0, .y = 0, .w = 50, .h = 80 };
    tree.get(text).style_override = .{ .font_size = 16 };

    const theme = style.Theme.default;
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    try std.testing.expectEqual(@as(usize, 3), dl.commands.len);
    try std.testing.expectEqualStrings("alpha", dl.commands[0].text.text);
    try std.testing.expectEqualStrings("beta", dl.commands[1].text.text);
    try std.testing.expectEqualStrings("gamma", dl.commands[2].text.text);
}

test "wrapped text visual operations preserve leading whitespace" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const text = try tree.addRoot(.{ .text = .{ .content = "  alpha\n\tbeta", .overflow = .wrap } });
    tree.get(text).layout_rect = .{ .x = 0, .y = 0, .w = 200, .h = 80 };
    tree.get(text).style_override = .{ .font_size = 16 };

    const theme = style.Theme.default;
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    // Unfocused, empty, no placeholder: bg rect only = 1 command
    try std.testing.expectEqual(@as(usize, 1), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface); // bg
}

test "focused text input emits cursor" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const ti = try tree.addRoot(.{ .text_input = .{} });
    tree.get(ti).layout_rect = .{ .x = 10, .y = 20, .w = 300, .h = 30 };
    tree.get(ti).interaction.focused = true;

    const theme = style.Theme.default;
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    // Focused, empty, no placeholder: bg rect + cursor rect + focus ring = 3 commands
    try std.testing.expectEqual(@as(usize, 3), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface); // bg
    try std.testing.expect(dl.commands[1] == .surface); // cursor
    try std.testing.expect(dl.commands[2] == .surface); // focus ring
}

test "empty text input shows placeholder" {
    const allocator = std.testing.allocator;

    var tree = widget.Tree.init(allocator);
    defer tree.deinit();

    const ti = try tree.addRoot(.{ .text_input = .{ .placeholder = "Enter name" } });
    tree.get(ti).layout_rect = .{ .x = 10, .y = 20, .w = 300, .h = 30 };

    const theme = style.Theme.default;
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    // Empty with placeholder: bg rect + placeholder text = 2 commands
    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface); // bg
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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    // Has content: bg rect + content text = 2 commands
    try std.testing.expectEqual(@as(usize, 2), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface); // bg
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
    var dl = try prepareVisuals(&tree, theme, allocator, null, .{});
    defer freeVisuals(&dl, allocator);

    // bg rect + selection highlight + text + cursor + focus ring = 5 commands
    try std.testing.expectEqual(@as(usize, 5), dl.commands.len);
    try std.testing.expect(dl.commands[0] == .surface); // bg
    try std.testing.expect(dl.commands[1] == .surface); // selection highlight
    try std.testing.expect(dl.commands[2] == .text); // content
    try std.testing.expect(dl.commands[3] == .surface); // cursor
    try std.testing.expect(dl.commands[4] == .surface); // focus ring

    // Verify selection highlight color
    try std.testing.expectEqual(theme.selection_bg, dl.commands[1].surface.color);
}
