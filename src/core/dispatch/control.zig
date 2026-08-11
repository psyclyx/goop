const std = @import("std");
const widget = @import("../widget.zig");
const visual_types = @import("../visual_types.zig");
const style = @import("../style.zig");
const geometry = @import("../geometry.zig");
const types = @import("types.zig");

const MouseState = types.MouseState;

pub fn updateSliderValue(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, mouse_x: f32, theme: style.Theme) void {
    const node = tree.get(handle);
    const rect = node.layout_rect;
    const resolved = node.style_override.resolve(theme);
    const thumb_w = resolved.thumb_width;
    const usable = rect.w - thumb_w;
    if (usable <= 0) return;
    const t = std.math.clamp((mouse_x - rect.x - thumb_w * 0.5) / usable, 0, 1);
    const next = node.kind.slider.min + t * (node.kind.slider.max - node.kind.slider.min);
    if (next != node.kind.slider.value) {
        node.kind.slider.value = next;
        mouse.emitScalar(tree, handle, next);
    }
}

pub fn updateTableColumns(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState) bool {
    const divider_index = mouse.drag_column_index orelse return false;
    const total_width = if (mouse.drag_origin_extent > 0)
        mouse.drag_origin_extent
    else if (widget.tableReferenceRow(tree, handle)) |row|
        tree.getConst(row).layout_rect.w
    else
        return false;
    if (total_width <= 0) return false;

    const delta = mouse.x - mouse.drag_origin_x;
    const node = tree.get(handle);
    const did_resize = node.kind.table.resizeColumns(
        divider_index,
        total_width,
        mouse.drag_origin_value,
        mouse.drag_origin_secondary_value,
        delta,
    );
    if (did_resize) {
        mouse.emitColumnFraction(tree, handle, divider_index, node.kind.table.columnWeight(divider_index).?);
    }
    return did_resize;
}

pub fn updateDragValue(tree: *widget.Tree, handle: widget.NodeHandle, mouse_x: f32, mouse: *MouseState) void {
    const node = tree.get(handle);
    const drag_value = &node.kind.drag_value;
    const delta = (mouse_x - mouse.drag_origin_x) * drag_value.speed;
    const next = std.math.clamp(mouse.drag_origin_value + delta, drag_value.min, drag_value.max);
    if (next != drag_value.value) {
        drag_value.value = next;
        drag_value.syncLabel();
        mouse.emitScalar(tree, handle, next);
    }
}

pub fn stepDragValue(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, direction: i8) void {
    const node = tree.get(handle);
    const drag_value = &node.kind.drag_value;
    const delta = drag_value.speed * @as(f32, @floatFromInt(direction));
    const next = std.math.clamp(drag_value.value + delta, drag_value.min, drag_value.max);
    if (next != drag_value.value) {
        drag_value.value = next;
        drag_value.syncLabel();
        mouse.emitScalar(tree, handle, next);
    }
}

pub fn stepSpinBox(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, direction: i8, activate: bool) void {
    const node = tree.get(handle);
    const spinbox = &node.kind.spinbox;
    const delta = spinbox.step * @as(f32, @floatFromInt(direction));
    const next = std.math.clamp(spinbox.value + delta, spinbox.min, spinbox.max);
    if (next != spinbox.value) {
        spinbox.value = next;
        spinbox.syncLabel();
        mouse.emitScalar(tree, handle, next);
        if (activate) {
            mouse.emitActivation(tree, handle);
        }
    }
}

pub fn updateSplitterRatio(
    tree: *widget.Tree,
    handle: widget.NodeHandle,
    mouse_x: f32,
    mouse_y: f32,
    mouse: *MouseState,
    theme: style.Theme,
) void {
    const node = tree.get(handle);
    const splitter = &node.kind.splitter;
    const resolved = node.style_override.resolve(theme);
    const available = geometry.splitterAvailableExtent(splitter.*, node.layout_rect, resolved);
    if (available <= 0) return;

    const delta_px = switch (splitter.direction) {
        .row => mouse_x - mouse.drag_origin_x,
        .column => mouse_y - mouse.drag_origin_y,
    };
    const next = clampSplitterRatio(splitter.*, node.layout_rect, resolved, mouse.drag_origin_value + delta_px / available);
    if (next != splitter.ratio) {
        splitter.ratio = next;
        mouse.layout_changed = true;
        mouse.emitScalar(tree, handle, next);
    }
}

pub fn stepSplitter(tree: *widget.Tree, handle: widget.NodeHandle, mouse: *MouseState, direction: i8, theme: style.Theme) void {
    const node = tree.get(handle);
    const splitter = &node.kind.splitter;
    const resolved = node.style_override.resolve(theme);
    const next = clampSplitterRatio(
        splitter.*,
        node.layout_rect,
        resolved,
        splitter.ratio + splitter.keyboard_step * @as(f32, @floatFromInt(direction)),
    );
    if (next != splitter.ratio) {
        splitter.ratio = next;
        mouse.emitScalar(tree, handle, next);
    }
}

pub fn clampSplitterRatio(
    splitter: widget.WidgetKind.Splitter,
    rect: visual_types.Rect,
    resolved: style.ResolvedStyle,
    ratio: f32,
) f32 {
    const raw = std.math.clamp(ratio, 0, 1);
    const available = geometry.splitterAvailableExtent(splitter, rect, resolved);
    if (available <= 0) return raw;

    const min_ratio = std.math.clamp(splitter.min_first / available, 0, 1);
    const max_ratio = std.math.clamp(1 - splitter.min_second / available, 0, 1);
    if (min_ratio > max_ratio) return raw;
    return std.math.clamp(raw, min_ratio, max_ratio);
}
