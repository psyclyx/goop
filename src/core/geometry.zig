const std = @import("std");
const style = @import("style.zig");
const widget = @import("widget.zig");
const visual_types = @import("visual_types.zig");

pub const Rect = visual_types.Rect;

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

/// The authoritative pointer/focus region for a splitter divider. Unlike the
/// visible divider, this is deliberately wide enough to grab and is contained
/// by the splitter's styled inner bounds.
pub fn splitterInteractionRect(rect: Rect, splitter: widget.WidgetKind.Splitter, resolved: style.ResolvedStyle) Rect {
    return clampRectToBounds(
        splitterHandleRect(splitterDividerRect(rect, splitter, resolved), splitter),
        splitterInnerRect(rect, resolved),
    );
}

/// Center a table-column interaction strip on a laid-out divider. Keeping this
/// primitive independent of Tree structure lets table hit testing and chrome
/// share the same resolved rectangle.
pub fn tableColumnInteractionRect(row_rect: Rect, divider_x: f32, width: f32) Rect {
    return clampRectToBounds(.{
        .x = divider_x - @max(width, 0) * 0.5,
        .y = row_rect.y,
        .w = @max(width, 0),
        .h = @max(row_rect.h, 0),
    }, row_rect);
}

/// Bounds actually occupied by one rendered text run inside its command
/// bounds. This mirrors renderer alignment and vertical centering, while
/// clamping oversized runs to the command's clip rectangle.
pub fn renderedTextRect(bounds: Rect, measured_width: f32, measured_height: f32, text_align: visual_types.TextAlign) Rect {
    const width = @min(@max(measured_width, 0), @max(bounds.w, 0));
    const height = @min(@max(measured_height, 0), @max(bounds.h, 0));
    const x = switch (text_align) {
        .start => bounds.x,
        .center => bounds.x + (@max(bounds.w, 0) - width) * 0.5,
        .end => bounds.x + @max(bounds.w, 0) - width,
    };
    return .{
        .x = x,
        .y = bounds.y + (@max(bounds.h, 0) - height) * 0.5,
        .w = width,
        .h = height,
    };
}

pub fn gridItemLabelRect(rect: Rect, resolved: style.ResolvedStyle) Rect {
    return .{
        .x = rect.x + resolved.padding.left,
        .y = rect.y + rect.h - resolved.padding.bottom - resolved.font_size * 1.4,
        .w = @max(rect.w - resolved.padding.left - resolved.padding.right, 0),
        .h = resolved.font_size * 1.4,
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

test "splitter interaction rectangle is stable, contained, and no thinner than its visible divider" {
    var prng = std.Random.DefaultPrng.init(0x676f_6f70_7370_6c74);
    const random = prng.random();
    for (0..512) |_| {
        const direction: widget.WidgetKind.Container.Direction = if (random.boolean()) .row else .column;
        const rect = Rect{
            .x = random.float(f32) * 50,
            .y = random.float(f32) * 50,
            .w = 24 + random.float(f32) * 600,
            .h = 24 + random.float(f32) * 400,
        };
        const splitter = widget.WidgetKind.Splitter{
            .direction = direction,
            .ratio = random.float(f32),
            .min_first = 0,
            .min_second = 0,
            .thickness = 1 + random.float(f32) * 23,
            .gap_thickness = 1 + random.float(f32) * 5,
        };
        const resolved = (style.Style{ .padding = .{
            .left = random.float(f32) * 8,
            .right = random.float(f32) * 8,
            .top = random.float(f32) * 8,
            .bottom = random.float(f32) * 8,
        } }).resolve(style.Theme.default);
        const inner = splitterInnerRect(rect, resolved);
        const divider = splitterDividerRect(rect, splitter, resolved);
        const interaction = splitterInteractionRect(rect, splitter, resolved);

        try std.testing.expect(interaction.x >= inner.x - 0.001);
        try std.testing.expect(interaction.y >= inner.y - 0.001);
        try std.testing.expect(interaction.x + interaction.w <= inner.x + inner.w + 0.001);
        try std.testing.expect(interaction.y + interaction.h <= inner.y + inner.h + 0.001);
        try std.testing.expect(interaction.w + 0.001 >= divider.w);
        try std.testing.expect(interaction.h + 0.001 >= divider.h);
        const raw_handle = splitterHandleRect(divider, splitter);
        const raw_is_contained = raw_handle.x >= inner.x and raw_handle.y >= inner.y and
            raw_handle.x + raw_handle.w <= inner.x + inner.w and
            raw_handle.y + raw_handle.h <= inner.y + inner.h;
        if (direction == .row and raw_is_contained) {
            try std.testing.expectApproxEqAbs(splitter.thickness, interaction.w, 0.001);
        }
        if (direction == .column and raw_is_contained) {
            try std.testing.expectApproxEqAbs(splitter.thickness, interaction.h, 0.001);
        }
    }
}

test "table column interaction rectangle contains its divider across generated rows" {
    var prng = std.Random.DefaultPrng.init(0x676f_6f70_7462_6c65);
    const random = prng.random();
    for (0..512) |_| {
        const row = Rect{
            .x = random.float(f32) * 30,
            .y = random.float(f32) * 30,
            .w = 12 + random.float(f32) * 600,
            .h = 12 + random.float(f32) * 60,
        };
        const divider_x = row.x + random.float(f32) * row.w;
        const requested_width = 1 + random.float(f32) * 23;
        const interaction = tableColumnInteractionRect(row, divider_x, requested_width);
        try std.testing.expect(interaction.x >= row.x - 0.001);
        try std.testing.expect(interaction.x + interaction.w <= row.x + row.w + 0.001);
        try std.testing.expectApproxEqAbs(row.y, interaction.y, 0.001);
        try std.testing.expectApproxEqAbs(row.h, interaction.h, 0.001);
        try std.testing.expect(divider_x >= interaction.x - 0.001);
        try std.testing.expect(divider_x <= interaction.x + interaction.w + 0.001);
    }
}

test "table tree resize handles use the shared interaction rectangle" {
    var prng = std.Random.DefaultPrng.init(0x676f_6f70_7472_6565);
    const random = prng.random();
    for (0..256) |_| {
        var tree = widget.Tree.init(std.testing.allocator);
        defer tree.deinit();
        const table = try tree.addRoot(.{ .table = .{ .columns = 2, .resizable = true } });
        tree.get(table).kind.table.syncColumns(2);
        const header = try tree.addChild(table, .{ .table_row = .{ .header = true } });
        const left = try tree.addChild(header, .{ .table_cell = .{} });
        _ = try tree.addChild(header, .{ .table_cell = .{} });

        const row = Rect{
            .x = random.float(f32) * 30,
            .y = random.float(f32) * 30,
            .w = 80 + random.float(f32) * 600,
            .h = 16 + random.float(f32) * 50,
        };
        const left_width = 12 + random.float(f32) * (row.w - 24);
        tree.get(table).layout_rect = row;
        tree.get(header).layout_rect = row;
        tree.get(left).layout_rect = .{ .x = row.x, .y = row.y, .w = left_width, .h = row.h };

        const actual = widget.tableResizeHandleRect(&tree, table, 0).?;
        const expected = tableColumnInteractionRect(row, row.x + left_width, widget.WidgetKind.Table.resize_handle_width);
        try std.testing.expectApproxEqAbs(expected.x, actual.x, 0.001);
        try std.testing.expectApproxEqAbs(expected.y, actual.y, 0.001);
        try std.testing.expectApproxEqAbs(expected.w, actual.w, 0.001);
        try std.testing.expectApproxEqAbs(expected.h, actual.h, 0.001);
        for (0..7) |sample| {
            const x = actual.x + actual.w * (@as(f32, @floatFromInt(sample)) + 0.5) / 7;
            const y = actual.y + actual.h * 0.5;
            try std.testing.expectEqual(@as(?u8, 0), widget.tableResizeHandleIndexAtPoint(&tree, table, x, y));
            try std.testing.expect(widget.tableHeaderCellIndexAtPoint(&tree, table, x, y) == null);
        }
    }
}

test "rendered text rectangle is contained and follows alignment" {
    const bounds = Rect{ .x = 10, .y = 20, .w = 100, .h = 30 };
    const start = renderedTextRect(bounds, 40, 14, .start);
    const center = renderedTextRect(bounds, 40, 14, .center);
    const end = renderedTextRect(bounds, 40, 14, .end);
    try std.testing.expectEqual(@as(f32, 10), start.x);
    try std.testing.expectEqual(@as(f32, 40), center.x);
    try std.testing.expectEqual(@as(f32, 70), end.x);
    try std.testing.expectEqual(@as(f32, 28), center.y);
    try std.testing.expectEqual(@as(f32, 40), center.w);
    try std.testing.expectEqual(@as(f32, 14), center.h);

    const clipped = renderedTextRect(bounds, 140, 50, .center);
    try std.testing.expectEqual(bounds, clipped);

    var prng = std.Random.DefaultPrng.init(0x676f_6f70_7465_7874);
    const random = prng.random();
    for (0..512) |_| {
        const generated_bounds = Rect{
            .x = random.float(f32) * 500,
            .y = random.float(f32) * 500,
            .w = random.float(f32) * 400,
            .h = random.float(f32) * 100,
        };
        const measured_width = random.float(f32) * 600;
        const measured_height = random.float(f32) * 160;
        const text_align: visual_types.TextAlign = switch (random.uintLessThan(u8, 3)) {
            0 => .start,
            1 => .center,
            else => .end,
        };
        const actual = renderedTextRect(generated_bounds, measured_width, measured_height, text_align);
        try std.testing.expect(actual.x >= generated_bounds.x - 0.001);
        try std.testing.expect(actual.y >= generated_bounds.y - 0.001);
        try std.testing.expect(actual.x + actual.w <= generated_bounds.x + generated_bounds.w + 0.001);
        try std.testing.expect(actual.y + actual.h <= generated_bounds.y + generated_bounds.h + 0.001);
        try std.testing.expectApproxEqAbs(@min(measured_width, generated_bounds.w), actual.w, 0.001);
        try std.testing.expectApproxEqAbs(@min(measured_height, generated_bounds.h), actual.h, 0.001);

        // Moving this element in a larger layout can translate its glyph
        // bounds, but cannot change their measured extent.
        const dx = random.float(f32) * 80 - 40;
        const dy = random.float(f32) * 80 - 40;
        const translated = renderedTextRect(.{
            .x = generated_bounds.x + dx,
            .y = generated_bounds.y + dy,
            .w = generated_bounds.w,
            .h = generated_bounds.h,
        }, measured_width, measured_height, text_align);
        try std.testing.expectApproxEqAbs(actual.x + dx, translated.x, 0.001);
        try std.testing.expectApproxEqAbs(actual.y + dy, translated.y, 0.001);
        try std.testing.expectApproxEqAbs(actual.w, translated.w, 0.001);
        try std.testing.expectApproxEqAbs(actual.h, translated.h, 0.001);
    }
}
