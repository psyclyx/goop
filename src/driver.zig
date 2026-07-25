//! Retained UI driver.
//!
//! The driver owns interaction/reconciliation state. Declarative components
//! remain plain values, while renderers consume only `goop_display` deltas.

const std = @import("std");
const display = @import("goop_display");
const runtime = @import("core/runtime.zig");

pub const Runtime = runtime.Runtime;
pub const Context = runtime.Context;
pub const Event = runtime.Event;
pub const FrameSnapshot = runtime.FrameSnapshot;
pub const Clipboard = runtime.Clipboard;
pub const TextMeasureCtx = runtime.TextMeasureCtx;
pub const TextDimensions = runtime.TextDimensions;
pub const MeasureTextFn = runtime.MeasureTextFn;

pub const InputEvent = union(enum) {
    pointer_motion: Point,
    pointer_leave,
    pointer_button: PointerButton,
    key: Key,

    pub const PointerButton = struct {
        button: enum { primary, secondary, other },
        state: enum { pressed, released },
        position: Point,
    };

    pub const Key = struct {
        scancode: u32,
        state: enum { pressed, released },
        modifiers: Modifiers = .{},
    };
};

pub const Point = struct {
    x: f32,
    y: f32,
};

pub const Modifiers = packed struct {
    control: bool = false,
    shift: bool = false,
    alt: bool = false,
    logo: bool = false,
};

pub const SceneError = error{
    DuplicateCommandId,
};

const RetainedCommand = struct {
    fingerprint: u64,
    order: u32,
    bounds: ?display.Rect,
    generation: u64,
};

/// Retained semantic display state.
///
/// Paint command payloads are intentionally not retained: text and other
/// slices may be frame-arena values. Only stable identity, fingerprint, and
/// old bounds survive reconciliation.
pub const Scene = struct {
    allocator: std.mem.Allocator,
    retained: std.AutoHashMapUnmanaged(display.CommandId, RetainedCommand) = .empty,
    operations: std.ArrayListUnmanaged(display.Operation) = .empty,
    removals: std.ArrayListUnmanaged(display.CommandId) = .empty,
    damage: display.DamageSet = .{},
    generation: u64 = 0,
    initialized: bool = false,
    force_full: bool = false,

    pub fn init(allocator: std.mem.Allocator) Scene {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scene) void {
        self.retained.deinit(self.allocator);
        self.operations.deinit(self.allocator);
        self.removals.deinit(self.allocator);
        self.damage.deinit(self.allocator);
        self.* = undefined;
    }

    /// Reconcile one complete ordered display snapshot. The returned slices
    /// remain valid until the next call to `reconcile`.
    pub fn reconcile(
        self: *Scene,
        commands: []const display.Command,
    ) (std.mem.Allocator.Error || SceneError)!display.DisplayDelta {
        self.operations.clearRetainingCapacity();
        self.removals.clearRetainingCapacity();
        self.damage.clear();
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;

        for (commands) |paint_command| {
            const entry = try self.retained.getOrPut(self.allocator, paint_command.id);
            if (entry.found_existing and entry.value_ptr.generation == self.generation) {
                return error.DuplicateCommandId;
            }

            const new_bounds = paint_command.bounds();
            if (!entry.found_existing) {
                entry.value_ptr.* = .{
                    .fingerprint = paint_command.fingerprint,
                    .order = paint_command.order,
                    .bounds = new_bounds,
                    .generation = self.generation,
                };
                try self.operations.append(self.allocator, .{ .put = paint_command });
                try self.damage.addOldAndNew(self.allocator, null, new_bounds);
                continue;
            }

            const previous = entry.value_ptr.*;
            if (self.force_full or
                previous.fingerprint != paint_command.fingerprint or
                previous.order != paint_command.order or
                !optionalRectEqual(previous.bounds, new_bounds))
            {
                try self.operations.append(self.allocator, .{ .put = paint_command });
                try self.damage.addOldAndNew(self.allocator, previous.bounds, new_bounds);
            }
            entry.value_ptr.* = .{
                .fingerprint = paint_command.fingerprint,
                .order = paint_command.order,
                .bounds = new_bounds,
                .generation = self.generation,
            };
        }

        var iterator = self.retained.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.generation != self.generation) {
                try self.removals.append(self.allocator, entry.key_ptr.*);
            }
        }
        for (self.removals.items) |id| {
            const removed = self.retained.fetchRemove(id).?.value;
            try self.operations.append(self.allocator, .{ .remove = .{
                .id = id,
                .old_bounds = removed.bounds,
            } });
            try self.damage.addOldAndNew(self.allocator, removed.bounds, null);
        }

        if (!self.initialized or self.force_full) {
            self.initialized = true;
            self.force_full = false;
            self.damage.markFull();
        }
        return .{
            .operations = self.operations.items,
            .damage = if (self.damage.full)
                .full
            else if (self.damage.regions.items.len == 0)
                .none
            else
                .{ .regions = self.damage.regions.items },
        };
    }

    pub fn commandCount(self: *const Scene) usize {
        return self.retained.count();
    }

    pub fn invalidateAll(self: *Scene) void {
        self.force_full = true;
    }
};

pub fn command(id: display.CommandId, paint: display.PaintCommand) display.Command {
    return .{
        .id = id,
        .fingerprint = display.fingerprint(paint),
        .paint = paint,
    };
}

pub const Frame = struct {
    delta: display.DisplayDelta,
    actions: []const @import("goop_ui").ActionId,
};

const HitTarget = struct {
    id: @import("goop_ui").ElementId,
    action: @import("goop_ui").ActionId,
    bounds: display.Rect,
};

/// Small declarative layout and interaction driver.
///
/// It deliberately supports a compact opinionated layout vocabulary. More
/// sophisticated widgets can be added without changing component or renderer
/// APIs because retained state and display reconciliation stay here.
pub const DeclarativeDriver = struct {
    const ui = @import("goop_ui");

    allocator: std.mem.Allocator,
    scene: Scene,
    commands: std.ArrayListUnmanaged(display.Command) = .empty,
    hits: std.ArrayListUnmanaged(HitTarget) = .empty,
    actions: std.ArrayListUnmanaged(ui.ActionId) = .empty,
    hovered: ?ui.ElementId = null,
    pressed: ?ui.ElementId = null,
    pointer: Point = .{ .x = 0, .y = 0 },
    dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator) DeclarativeDriver {
        return .{
            .allocator = allocator,
            .scene = Scene.init(allocator),
        };
    }

    pub fn deinit(self: *DeclarativeDriver) void {
        self.scene.deinit();
        self.commands.deinit(self.allocator);
        self.hits.deinit(self.allocator);
        self.actions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn pushEvent(self: *DeclarativeDriver, event: InputEvent) std.mem.Allocator.Error!void {
        switch (event) {
            .pointer_motion => |point| {
                self.pointer = point;
                const next_hovered = if (self.hitAt(point)) |hit| hit.id else null;
                if (!optionalElementEqual(self.hovered, next_hovered)) {
                    self.hovered = next_hovered;
                    self.dirty = true;
                }
            },
            .pointer_leave => {
                if (self.hovered != null) self.dirty = true;
                self.hovered = null;
            },
            .pointer_button => |button| {
                self.pointer = button.position;
                if (button.button != .primary) return;
                const hit = self.hitAt(button.position);
                switch (button.state) {
                    .pressed => {
                        self.pressed = if (hit) |target| target.id else null;
                        self.dirty = true;
                    },
                    .released => {
                        if (hit) |target| {
                            if (optionalElementEqual(self.pressed, target.id)) {
                                try self.actions.append(self.allocator, target.action);
                            }
                        }
                        if (self.pressed != null) self.dirty = true;
                        self.pressed = null;
                    },
                }
            },
            .key => {},
        }
    }

    pub fn needsFrame(self: *const DeclarativeDriver) bool {
        return self.dirty or self.actions.items.len > 0;
    }

    pub fn pendingActions(self: *const DeclarativeDriver) []const ui.ActionId {
        return self.actions.items;
    }

    pub fn invalidate(self: *DeclarativeDriver) void {
        self.dirty = true;
    }

    pub fn invalidateAll(self: *DeclarativeDriver) void {
        self.scene.invalidateAll();
        self.dirty = true;
    }

    /// Layout and paint one declarative tree. Returned data remains borrowed
    /// until the next `frame` call.
    pub fn frame(
        self: *DeclarativeDriver,
        root: ui.Element,
        viewport: display.Rect,
        theme: ui.Theme,
    ) (std.mem.Allocator.Error || SceneError)!Frame {
        self.commands.clearRetainingCapacity();
        self.hits.clearRetainingCapacity();
        try self.layoutElement(root, viewport, theme);
        for (self.commands.items, 0..) |*paint_command, index| {
            paint_command.order = @intCast(index);
            var order_hash = std.hash.Wyhash.init(paint_command.fingerprint);
            order_hash.update(std.mem.asBytes(&paint_command.order));
            paint_command.fingerprint = order_hash.final();
        }
        const delta = try self.scene.reconcile(self.commands.items);
        self.dirty = false;
        return .{
            .delta = delta,
            .actions = self.actions.items,
        };
    }

    pub fn consumeActions(self: *DeclarativeDriver) void {
        self.actions.clearRetainingCapacity();
    }

    fn layoutElement(
        self: *DeclarativeDriver,
        element: ui.Element,
        bounds: display.Rect,
        theme: ui.Theme,
    ) std.mem.Allocator.Error!void {
        try self.paintElement(element, bounds, theme);
        if (element.action) |action| {
            try self.hits.append(self.allocator, .{
                .id = element.id,
                .action = action,
                .bounds = bounds,
            });
        }
        if (element.children.len == 0) return;

        const padding = element.style.padding orelse theme.padding;
        const content = inset(bounds, padding);
        const direction = switch (element.widget) {
            .container => |container| container.direction,
            else => ui.WidgetKind.Container.Direction.column,
        };
        const gap = element.style.gap orelse theme.spacing;
        const available_main = if (direction == .row) content.w else content.h;
        const gaps = gap * @as(f32, @floatFromInt(element.children.len - 1));

        var fixed: f32 = 0;
        var grow: f32 = 0;
        for (element.children) |child| {
            if (mainSize(child.style, direction)) |size| {
                fixed += size;
            } else if (child.style.flex_grow > 0) {
                grow += child.style.flex_grow;
            } else {
                fixed += intrinsicMainSize(child, direction, theme);
            }
        }
        const flexible = @max(0, available_main - fixed - gaps);

        var cursor: f32 = if (direction == .row) content.x else content.y;
        for (element.children) |child| {
            const main = if (mainSize(child.style, direction)) |size|
                size
            else if (child.style.flex_grow > 0 and grow > 0)
                flexible * child.style.flex_grow / grow
            else
                intrinsicMainSize(child, direction, theme);
            const child_bounds = if (direction == .row)
                display.Rect{
                    .x = cursor,
                    .y = content.y,
                    .w = @max(child.style.min_width, child.style.width orelse main),
                    .h = @max(child.style.min_height, child.style.height orelse content.h),
                }
            else
                display.Rect{
                    .x = content.x,
                    .y = cursor,
                    .w = @max(child.style.min_width, child.style.width orelse content.w),
                    .h = @max(child.style.min_height, child.style.height orelse main),
                };
            try self.layoutElement(child, child_bounds, theme);
            cursor += main + gap;
        }
    }

    fn paintElement(
        self: *DeclarativeDriver,
        element: ui.Element,
        bounds: display.Rect,
        theme: ui.Theme,
    ) std.mem.Allocator.Error!void {
        const is_hovered = optionalElementEqual(self.hovered, element.id);
        const is_pressed = optionalElementEqual(self.pressed, element.id);
        const default_bg: ?display.Color = switch (element.widget) {
            .button => if (is_pressed)
                element.style.bg_active orelse theme.bg_active
            else if (is_hovered)
                element.style.bg_hover orelse theme.bg_hover
            else
                element.style.bg orelse theme.bg,
            else => element.style.bg,
        };
        if (default_bg) |color| {
            const surface = display.PaintCommand{ .surface = .{
                .bounds = bounds,
                .role = if (element.widget == .button) .control else .container,
                .state = .{ .hovered = is_hovered, .pressed = is_pressed },
                .color = color,
                .border_color = element.style.border orelse theme.border,
                .border_width = element.style.border_width orelse theme.border_width,
                .corner_radius = element.style.border_radius orelse theme.border_radius,
            } };
            try self.commands.append(
                self.allocator,
                command(.fromElement(element.id.value(), 0), surface),
            );
        }

        const foreground = element.style.fg orelse theme.fg;
        switch (element.widget) {
            .text => |text| try self.appendText(element, bounds, text.content, text.overflow, foreground, theme),
            .button => |button| try self.appendText(element, bounds, button.label, .clip, foreground, theme),
            .icon => |icon| {
                const icon_paint = display.PaintCommand{ .icon = .{
                    .bounds = bounds,
                    .kind = icon.kind,
                    .color = foreground,
                } };
                try self.commands.append(
                    self.allocator,
                    command(.fromElement(element.id.value(), 1), icon_paint),
                );
            },
            .container, .spacer => {},
        }
    }

    fn appendText(
        self: *DeclarativeDriver,
        element: ui.Element,
        bounds: display.Rect,
        text: []const u8,
        overflow: display.TextOverflow,
        color: display.Color,
        theme: ui.Theme,
    ) std.mem.Allocator.Error!void {
        const padding = element.style.padding orelse theme.padding;
        const paint = display.PaintCommand{ .text = .{
            .bounds = inset(bounds, padding),
            .text = text,
            .color = color,
            .font_size = element.style.font_size orelse theme.font_size,
            .text_align = element.style.text_align,
            .overflow = overflow,
        } };
        try self.commands.append(
            self.allocator,
            command(.fromElement(element.id.value(), 1), paint),
        );
    }

    fn hitAt(self: *const DeclarativeDriver, point: Point) ?HitTarget {
        var index = self.hits.items.len;
        while (index > 0) {
            index -= 1;
            const target = self.hits.items[index];
            if (contains(target.bounds, point)) return target;
        }
        return null;
    }
};

fn mainSize(style: @import("goop_ui").Style, direction: @import("goop_ui").WidgetKind.Container.Direction) ?f32 {
    return if (direction == .row) style.width else style.height;
}

fn intrinsicMainSize(
    element: @import("goop_ui").Element,
    direction: @import("goop_ui").WidgetKind.Container.Direction,
    theme: @import("goop_ui").Theme,
) f32 {
    if (direction == .row) return @max(element.style.min_width, element.style.width orelse 80);
    const padding = element.style.padding orelse theme.padding;
    const text_height = (element.style.font_size orelse theme.font_size) * 1.35;
    return @max(element.style.min_height, text_height + padding.top + padding.bottom);
}

fn inset(rect: display.Rect, edges: @import("goop_ui").Edges) display.Rect {
    return .{
        .x = rect.x + edges.left,
        .y = rect.y + edges.top,
        .w = @max(0, rect.w - edges.left - edges.right),
        .h = @max(0, rect.h - edges.top - edges.bottom),
    };
}

fn contains(rect: display.Rect, point: Point) bool {
    return point.x >= rect.x and point.y >= rect.y and
        point.x < rect.x + rect.w and point.y < rect.y + rect.h;
}

fn optionalElementEqual(
    a: ?@import("goop_ui").ElementId,
    b: ?@import("goop_ui").ElementId,
) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

fn optionalRectEqual(a: ?display.Rect, b: ?display.Rect) bool {
    if (a == null or b == null) return a == null and b == null;
    const lhs = a.?;
    const rhs = b.?;
    return lhs.x == rhs.x and lhs.y == rhs.y and lhs.w == rhs.w and lhs.h == rhs.h;
}

test "unchanged semantic display produces no work" {
    const allocator = std.testing.allocator;
    var scene = Scene.init(allocator);
    defer scene.deinit();

    const paint = display.PaintCommand{ .surface = .{
        .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 40 },
        .color = .rgb(10, 20, 30),
        .border_color = .rgb(0, 0, 0),
        .border_width = 0,
        .corner_radius = 0,
    } };
    const commands = [_]display.Command{command(.init(1), paint)};
    const first = try scene.reconcile(&commands);
    try std.testing.expect(first.damage == .full);
    try std.testing.expectEqual(@as(usize, 1), first.operations.len);

    const second = try scene.reconcile(&commands);
    try std.testing.expect(second.damage == .none);
    try std.testing.expectEqual(@as(usize, 0), second.operations.len);
}

test "full invalidation replays retained commands for a rebuilt renderer" {
    const allocator = std.testing.allocator;
    var scene = Scene.init(allocator);
    defer scene.deinit();

    const paint = display.PaintCommand{ .surface = .{
        .bounds = .{ .x = 0, .y = 0, .w = 100, .h = 40 },
        .color = .rgb(10, 20, 30),
        .border_color = .rgb(0, 0, 0),
        .border_width = 0,
        .corner_radius = 0,
    } };
    const commands = [_]display.Command{command(.init(1), paint)};
    _ = try scene.reconcile(&commands);
    _ = try scene.reconcile(&commands);

    scene.invalidateAll();
    const replay = try scene.reconcile(&commands);
    try std.testing.expect(replay.damage == .full);
    try std.testing.expectEqual(@as(usize, 1), replay.operations.len);
    try std.testing.expect(replay.operations[0] == .put);
}

test "moving and removing commands damage old and new bounds" {
    const allocator = std.testing.allocator;
    var scene = Scene.init(allocator);
    defer scene.deinit();

    const old_paint = display.PaintCommand{ .icon = .{
        .bounds = .{ .x = 2, .y = 3, .w = 10, .h = 10 },
        .kind = 4,
        .color = .rgb(255, 255, 255),
    } };
    const old = [_]display.Command{command(.init(9), old_paint)};
    _ = try scene.reconcile(&old);

    const new_paint = display.PaintCommand{ .icon = .{
        .bounds = .{ .x = 40, .y = 3, .w = 10, .h = 10 },
        .kind = 4,
        .color = .rgb(255, 255, 255),
    } };
    const moved = [_]display.Command{command(.init(9), new_paint)};
    const update = try scene.reconcile(&moved);
    try std.testing.expect(update.damage == .regions);
    try std.testing.expectEqual(@as(usize, 2), update.damage.regions.len);
    try std.testing.expectEqual(@as(usize, 1), update.operations.len);

    const removal = try scene.reconcile(&.{});
    try std.testing.expect(removal.damage == .regions);
    try std.testing.expectEqual(@as(usize, 1), removal.operations.len);
    try std.testing.expect(removal.operations[0] == .remove);
    try std.testing.expectEqual(@as(usize, 0), scene.commandCount());
}

test "duplicate stable IDs are rejected" {
    const allocator = std.testing.allocator;
    var scene = Scene.init(allocator);
    defer scene.deinit();

    const paint = display.PaintCommand{ .clip = .{ .bounds = null } };
    const duplicate = [_]display.Command{
        command(.init(1), paint),
        command(.init(1), paint),
    };
    try std.testing.expectError(error.DuplicateCommandId, scene.reconcile(&duplicate));
}

test "declarative interaction emits semantic actions" {
    const allocator = std.testing.allocator;
    var retained_driver = DeclarativeDriver.init(allocator);
    defer retained_driver.deinit();

    const root = @import("goop_ui").Element{
        .id = .init(20),
        .widget = .{ .button = .{ .label = "Open" } },
        .action = .init(99),
        .style = .{ .padding = .all(0) },
    };
    _ = try retained_driver.frame(
        root,
        .{ .x = 0, .y = 0, .w = 100, .h = 30 },
        .default,
    );
    try retained_driver.pushEvent(.{ .pointer_button = .{
        .button = .primary,
        .state = .pressed,
        .position = .{ .x = 10, .y = 10 },
    } });
    try retained_driver.pushEvent(.{ .pointer_button = .{
        .button = .primary,
        .state = .released,
        .position = .{ .x = 10, .y = 10 },
    } });
    try std.testing.expectEqual(@as(usize, 1), retained_driver.pendingActions().len);
    try std.testing.expectEqual(@as(u64, 99), retained_driver.pendingActions()[0].value());
}
