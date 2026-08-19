//! Semantic output produced by core interaction processing.
//!
//! The event vocabulary contains stable application-facing identifiers, not
//! retained tree handles. Variable-size payloads are spans into a borrowed
//! `ControlEvents` batch so dispatch can record them without allocating a
//! separate object per event.

const std = @import("std");
const ui = @import("goop_ui");

pub const ElementId = ui.ElementId;
pub const ActionId = ui.ActionId;

pub const PayloadSpan = struct {
    start: u32,
    len: u32,
};

pub const Activation = struct {
    element: ElementId,
    action: ?ActionId,
};

pub const SecondaryActivation = struct {
    element: ElementId,
    action: ?ActionId,
    x: f32,
    y: f32,
};

pub const ValueChanged = struct {
    element: ElementId,
    value: Value,

    pub const Value = union(enum) {
        scalar: f32,
        index: ?u16,
        column_fraction: struct {
            column: u8,
            fraction: f32,
        },
    };
};

pub const ToggleChanged = struct {
    element: ElementId,
    value: bool,
};

pub const TextChanged = struct {
    element: ElementId,
    text: PayloadSpan,
    committed: bool = false,
};

pub const SortChanged = struct {
    element: ElementId,
    column: u8,
    direction: Direction,

    pub const Direction = enum { ascending, descending };
};

pub const SelectionChanged = struct {
    element: ElementId,
    selected: PayloadSpan,
};

pub const ScrollChanged = struct {
    element: ElementId,
    x: f32,
    y: f32,
};

pub const PopupVisibilityChanged = struct {
    element: ElementId,
    visible: bool,
};

pub const Drop = struct {
    source: ElementId,
    target: ElementId,
    position: Position,
    modifiers: Modifiers = .{},

    pub const Position = union(enum) {
        before,
        inside,
        after,
        item,
        background,
        point: struct { x: f32, y: f32 },
    };

    pub const Modifiers = packed struct {
        ctrl: bool = false,
        shift: bool = false,
    };
};

pub const ControlEvent = union(enum) {
    activated: Activation,
    secondary_activated: SecondaryActivation,
    value_changed: ValueChanged,
    toggle_changed: ToggleChanged,
    text_changed: TextChanged,
    sort_changed: SortChanged,
    selection_changed: SelectionChanged,
    scroll_changed: ScrollChanged,
    popup_visibility_changed: PopupVisibilityChanged,
    drop: Drop,
};

/// Borrowed view of one completed processing batch.
///
/// The slices and every payload resolved through `text` / `selection` remain
/// valid until the originating runtime next processes events or is
/// deinitialized. Copy data that must live
/// longer. The batch never owns memory and does not need deinitialization.
pub const ControlEvents = struct {
    items: []const ControlEvent,
    text_bytes: []const u8,
    selection_ids: []const ElementId,

    pub fn text(self: ControlEvents, changed: TextChanged) []const u8 {
        return spanSlice(u8, self.text_bytes, changed.text);
    }

    pub fn selection(self: ControlEvents, changed: SelectionChanged) []const ElementId {
        return spanSlice(ElementId, self.selection_ids, changed.selected);
    }

    fn spanSlice(comptime T: type, values: []const T, span: PayloadSpan) []const T {
        const start: usize = span.start;
        const end = start + @as(usize, span.len);
        std.debug.assert(end <= values.len);
        return values[start..end];
    }
};

/// Retained storage used by `Runtime`. Dispatch reserves the complete batch
/// before mutating UI state, then all writes are allocation-free.
pub const Journal = struct {
    events: std.ArrayListUnmanaged(ControlEvent) = .empty,
    text_bytes: std.ArrayListUnmanaged(u8) = .empty,
    selection_ids: std.ArrayListUnmanaged(ElementId) = .empty,

    pub fn deinit(self: *Journal, allocator: std.mem.Allocator) void {
        self.selection_ids.deinit(allocator);
        self.text_bytes.deinit(allocator);
        self.events.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *Journal) void {
        self.events.clearRetainingCapacity();
        self.text_bytes.clearRetainingCapacity();
        self.selection_ids.clearRetainingCapacity();
    }

    /// Reserve the worst-case storage for an entire input batch before any
    /// event mutates retained state. Selection snapshots can contain every
    /// live node; text controls use a fixed 255-byte editor today. Capacity is
    /// retained across batches.
    pub fn prepareBatch(self: *Journal, allocator: std.mem.Allocator, node_count: usize, event_count: usize) !void {
        const event_capacity = try std.math.mul(usize, 8, event_count);
        const selection_capacity = try std.math.mul(usize, node_count, event_count);
        const text_capacity = try std.math.mul(usize, 255, event_count);
        if (selection_capacity > std.math.maxInt(u32) or text_capacity > std.math.maxInt(u32)) return error.Overflow;
        try self.events.ensureUnusedCapacity(allocator, event_capacity);
        try self.selection_ids.ensureUnusedCapacity(allocator, selection_capacity);
        try self.text_bytes.ensureUnusedCapacity(allocator, text_capacity);
    }

    pub fn view(self: *const Journal) ControlEvents {
        return .{
            .items = self.events.items,
            .text_bytes = self.text_bytes.items,
            .selection_ids = self.selection_ids.items,
        };
    }

    pub fn emit(self: *Journal, control_event: ControlEvent) void {
        self.events.appendAssumeCapacity(control_event);
    }

    pub fn appendText(self: *Journal, value: []const u8) PayloadSpan {
        const start: u32 = @intCast(self.text_bytes.items.len);
        self.text_bytes.appendSliceAssumeCapacity(value);
        return .{ .start = start, .len = @intCast(value.len) };
    }

    pub fn beginSelection(self: *const Journal) u32 {
        return @intCast(self.selection_ids.items.len);
    }

    pub fn appendSelected(self: *Journal, id: ElementId) void {
        self.selection_ids.appendAssumeCapacity(id);
    }

    pub fn finishSelection(self: *const Journal, start: u32) PayloadSpan {
        return .{
            .start = start,
            .len = @intCast(self.selection_ids.items.len - @as(usize, start)),
        };
    }
};

test "variable payload spans resolve through borrowed batch" {
    var journal: Journal = .{};
    defer journal.deinit(std.testing.allocator);
    try journal.prepareBatch(std.testing.allocator, 2, 1);

    const text_span = journal.appendText("hello");
    const selected_start = journal.beginSelection();
    journal.appendSelected(.init(3));
    journal.appendSelected(.init(5));
    const selected_span = journal.finishSelection(selected_start);
    journal.emit(.{ .text_changed = .{ .element = .init(1), .text = text_span } });
    journal.emit(.{ .selection_changed = .{ .element = .init(2), .selected = selected_span } });

    const batch = journal.view();
    try std.testing.expectEqualStrings("hello", batch.text(batch.items[0].text_changed));
    try std.testing.expectEqualSlices(ElementId, &.{ .init(3), .init(5) }, batch.selection(batch.items[1].selection_changed));
}

test "batch reservation rejects overflow before journal mutation" {
    var journal: Journal = .{};
    defer journal.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.Overflow,
        journal.prepareBatch(std.testing.allocator, std.math.maxInt(usize), 2),
    );
    try std.testing.expectEqual(@as(usize, 0), journal.view().items.len);
    try std.testing.expectEqual(@as(usize, 0), journal.view().selection_ids.len);
    try std.testing.expectEqual(@as(usize, 0), journal.view().text_bytes.len);
}
