const style = @import("style.zig");
const widget = @import("widget.zig");
const paint_types = @import("paint_types.zig");

pub const Rect = paint_types.Rect;

pub fn pointInRect(x: f32, y: f32, rect: Rect) bool {
    return x >= rect.x and x < rect.x + rect.w and
        y >= rect.y and y < rect.y + rect.h;
}

pub fn rectsIntersect(a: Rect, b: Rect) bool {
    if (a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0) return false;
    return a.x < b.x + b.w and b.x < a.x + a.w and
        a.y < b.y + b.h and b.y < a.y + a.h;
}

pub fn rectsIntersectIncludingDegenerate(a: Rect, b: Rect) bool {
    return a.x < b.x + b.w and a.x + a.w > b.x and
        a.y < b.y + b.h and a.y + a.h > b.y;
}

pub fn intersectRects(a: Rect, b: Rect) Rect {
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

pub fn unionRect(current: ?Rect, next: Rect) ?Rect {
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

pub fn normalizedRect(x0: f32, y0: f32, x1: f32, y1: f32) Rect {
    return .{
        .x = @min(x0, x1),
        .y = @min(y0, y1),
        .w = @abs(x1 - x0),
        .h = @abs(y1 - y0),
    };
}

pub fn clampRectToBounds(rect: Rect, bounds: Rect) Rect {
    const left = @min(@max(rect.x, bounds.x), bounds.x + bounds.w);
    const top = @min(@max(rect.y, bounds.y), bounds.y + bounds.h);
    const right = @min(@max(rect.x + rect.w, bounds.x), bounds.x + bounds.w);
    const bottom = @min(@max(rect.y + rect.h, bounds.y), bounds.y + bounds.h);
    return .{
        .x = left,
        .y = top,
        .w = @max(right - left, 0),
        .h = @max(bottom - top, 0),
    };
}

pub fn isFloatingKind(kind: widget.WidgetKind) bool {
    return kind == .popup or kind == .tooltip;
}

pub fn isNonFloatingKind(kind: widget.WidgetKind) bool {
    return !isFloatingKind(kind);
}

pub fn directPopupChild(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var iter = tree.children(handle);
    while (iter.next()) |child| {
        if (tree.getConst(child).kind == .popup) return child;
    }
    return null;
}

pub fn selectedTabItem(tree: *const widget.Tree, parent: widget.NodeHandle) ?widget.NodeHandle {
    var iter = tree.children(parent);
    while (iter.next()) |child| {
        const node = tree.getConst(child);
        if (node.kind == .tab_item and node.kind.tab_item.selected) return child;
    }
    return null;
}

pub fn findTreeParent(tree: *const widget.Tree, handle: widget.NodeHandle) ?widget.NodeHandle {
    var current = tree.getConst(handle).parent;
    while (current) |parent_handle| {
        const parent = tree.getConst(parent_handle);
        if (parent.kind == .tree_item) return parent_handle;
        current = parent.parent;
    }
    return null;
}

pub fn treeDepth(tree: *const widget.Tree, handle: widget.NodeHandle) u32 {
    var depth: u32 = 0;
    var current = tree.getConst(handle).parent;
    while (current) |parent_handle| {
        const parent = tree.getConst(parent_handle);
        if (parent.kind == .tree_item) depth += 1;
        current = parent.parent;
    }
    return depth;
}

pub fn treeIndent(theme: style.Theme, resolved: style.ResolvedStyle) f32 {
    return resolved.font_size + theme.spacing;
}

pub fn treeDisclosureSlotWidth(resolved: style.ResolvedStyle) f32 {
    return resolved.font_size + 4;
}

pub fn treeItemIconSlotWidth(item: widget.WidgetKind.TreeItem, theme: style.Theme, resolved: style.ResolvedStyle) f32 {
    if (item.icon == null) return 0;
    return @max(resolved.font_size, 10) + @max(theme.spacing * 0.5, 4);
}

pub fn treeDisclosureX(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) f32 {
    const node = tree.getConst(handle);
    const resolved = node.style_override.resolve(theme);
    const indent = @as(f32, @floatFromInt(treeDepth(tree, handle))) * treeIndent(theme, resolved);
    return node.layout_rect.x + resolved.padding.left + indent;
}

pub fn treeDisclosureWidth(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) f32 {
    const node = tree.getConst(handle);
    return treeDisclosureSlotWidth(node.style_override.resolve(theme));
}

pub fn treeLabelX(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) f32 {
    return treeDisclosureX(tree, handle, theme) + treeDisclosureWidth(tree, handle, theme);
}

pub fn treeTextX(tree: *const widget.Tree, handle: widget.NodeHandle, theme: style.Theme) f32 {
    const label_x = treeLabelX(tree, handle, theme);
    const node = tree.getConst(handle);
    if (node.kind != .tree_item or node.kind.tree_item.icon == null) return label_x;
    const resolved = node.style_override.resolve(theme);
    const inner_h = @max(node.layout_rect.h - resolved.padding.top - resolved.padding.bottom, 0);
    const icon_size = @min(@max(resolved.font_size, 10), inner_h);
    return label_x + icon_size + @max(theme.spacing * 0.5, 4);
}

pub fn spinBoxButtonWidth(rect: Rect) f32 {
    return @min(rect.h, 28);
}

pub fn spinBoxMiddleStart(rect: Rect) f32 {
    return rect.x + spinBoxButtonWidth(rect);
}

pub fn spinBoxMiddleEnd(rect: Rect) f32 {
    return rect.x + rect.w - spinBoxButtonWidth(rect);
}

pub fn spinBoxButtons(rect: Rect) struct { dec: Rect, inc: Rect } {
    const button_w = spinBoxButtonWidth(rect);
    return .{
        .dec = .{ .x = rect.x, .y = rect.y, .w = button_w, .h = rect.h },
        .inc = .{ .x = rect.x + rect.w - button_w, .y = rect.y, .w = button_w, .h = rect.h },
    };
}

pub fn splitterDividerRect(rect: Rect, splitter: widget.WidgetKind.Splitter, resolved: style.ResolvedStyle) Rect {
    const inner = splitterInnerRect(rect, resolved);
    const ratio = clampedSplitterRatio(splitter, rect, resolved);
    const gap = splitterGapThickness(splitter);
    return switch (splitter.direction) {
        .row => .{
            .x = inner.x + (inner.w - gap) * ratio,
            .y = inner.y,
            .w = gap,
            .h = inner.h,
        },
        .column => .{
            .x = inner.x,
            .y = inner.y + (inner.h - gap) * ratio,
            .w = inner.w,
            .h = gap,
        },
    };
}

pub fn splitterHandleRect(divider: Rect, splitter: widget.WidgetKind.Splitter) Rect {
    const handle_thickness = @max(splitter.thickness, splitterGapThickness(splitter));
    return switch (splitter.direction) {
        .row => .{
            .x = divider.x + (divider.w - handle_thickness) * 0.5,
            .y = divider.y,
            .w = handle_thickness,
            .h = divider.h,
        },
        .column => .{
            .x = divider.x,
            .y = divider.y + (divider.h - handle_thickness) * 0.5,
            .w = divider.w,
            .h = handle_thickness,
        },
    };
}

pub fn clampedSplitterRatio(splitter: widget.WidgetKind.Splitter, rect: Rect, resolved: style.ResolvedStyle) f32 {
    const raw = @min(@max(splitter.ratio, 0), 1);
    const available = splitterAvailableExtent(splitter, rect, resolved);
    if (available <= 0) return raw;

    const min_ratio = @min(@max(splitter.min_first / available, 0), 1);
    const max_ratio = @min(@max(1 - splitter.min_second / available, 0), 1);
    if (min_ratio > max_ratio) return raw;
    return @min(@max(raw, min_ratio), max_ratio);
}

pub fn splitterAvailableExtent(splitter: widget.WidgetKind.Splitter, rect: Rect, resolved: style.ResolvedStyle) f32 {
    const inner = splitterInnerRect(rect, resolved);
    return switch (splitter.direction) {
        .row => inner.w - splitterGapThickness(splitter),
        .column => inner.h - splitterGapThickness(splitter),
    };
}

pub fn splitterInnerRect(rect: Rect, resolved: style.ResolvedStyle) Rect {
    return .{
        .x = rect.x + resolved.padding.left,
        .y = rect.y + resolved.padding.top,
        .w = @max(rect.w - resolved.padding.left - resolved.padding.right, 0),
        .h = @max(rect.h - resolved.padding.top - resolved.padding.bottom, 0),
    };
}

pub fn splitterGapThickness(splitter: widget.WidgetKind.Splitter) f32 {
    return @max(@min(splitter.gap_thickness, splitter.thickness), 1);
}
