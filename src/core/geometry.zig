const style = @import("style.zig");
const widget = @import("widget.zig");
const paint_types = @import("paint_types.zig");

pub const Rect = paint_types.Rect;

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
