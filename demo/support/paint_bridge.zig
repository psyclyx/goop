//! Adapter from the established goop widget paint list to the renderer-neutral
//! retained display protocol.
//!
//! The widget library and application logic know nothing about Vulkan. This
//! module is the sole compatibility boundary while the public widget API is
//! retained.

const std = @import("std");
const goop = @import("goop");
const display = @import("goop_display");
const driver = @import("goop_driver");

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    scene: driver.Scene,
    commands: std.ArrayListUnmanaged(display.Command) = .empty,
    previous: std.ArrayListUnmanaged(PreviousCommand) = .empty,
    matches: std.ArrayListUnmanaged(?u32) = .empty,
    match_next: std.ArrayListUnmanaged(usize) = .empty,
    match_buckets: std.AutoHashMapUnmanaged(u64, MatchBucket) = .empty,
    next_id: u64 = 1,
    scale: f32 = 1,

    pub fn init(allocator: std.mem.Allocator) Bridge {
        return .{
            .allocator = allocator,
            .scene = driver.Scene.init(allocator),
        };
    }

    pub fn deinit(self: *Bridge) void {
        self.commands.deinit(self.allocator);
        self.previous.deinit(self.allocator);
        self.matches.deinit(self.allocator);
        self.match_next.deinit(self.allocator);
        self.match_buckets.deinit(self.allocator);
        self.scene.deinit();
        self.* = undefined;
    }

    pub fn invalidateAll(self: *Bridge) void {
        self.scene.invalidateAll();
    }

    /// Convert and reconcile one complete paint snapshot. Returned slices live
    /// until the next call.
    pub fn frame(
        self: *Bridge,
        paint_list: goop.PaintList,
        scale: f32,
    ) !display.DisplayDelta {
        if (self.scale != scale) {
            self.scale = scale;
            self.scene.invalidateAll();
        }
        try self.prepareMatches();
        self.commands.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        try self.commands.ensureTotalCapacity(self.allocator, paint_list.commands.len);
        try self.matches.ensureTotalCapacity(self.allocator, paint_list.commands.len);
        for (paint_list.commands) |paint_command| {
            const converted = convertPaint(paint_command, scale);
            const fingerprint = display.fingerprint(converted);
            const matched = self.takeMatch(fingerprint);
            self.commands.appendAssumeCapacity(.{
                .id = if (matched) |previous_index|
                    self.previous.items[previous_index].id
                else
                    self.allocateId(),
                .fingerprint = fingerprint,
                .order = 0,
                .paint = converted,
            });
            self.matches.appendAssumeCapacity(if (matched) |previous_index|
                self.previous.items[previous_index].order
            else
                null);
        }
        self.assignStableOrders();

        const delta = try self.scene.reconcile(self.commands.items);
        try self.rememberCurrent();
        return delta;
    }

    fn prepareMatches(self: *Bridge) !void {
        const none = std.math.maxInt(usize);
        self.match_buckets.clearRetainingCapacity();
        self.match_next.clearRetainingCapacity();
        try self.match_next.resize(self.allocator, self.previous.items.len);
        @memset(self.match_next.items, none);

        for (self.previous.items, 0..) |previous, index| {
            const entry = try self.match_buckets.getOrPut(self.allocator, previous.fingerprint);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{ .head = index, .tail = index };
                continue;
            }
            self.match_next.items[entry.value_ptr.tail] = index;
            entry.value_ptr.tail = index;
        }
    }

    fn takeMatch(self: *Bridge, fingerprint: u64) ?usize {
        const none = std.math.maxInt(usize);
        const bucket = self.match_buckets.getPtr(fingerprint) orelse return null;
        if (bucket.head == none) return null;
        const index = bucket.head;
        bucket.head = self.match_next.items[index];
        return index;
    }

    fn allocateId(self: *Bridge) display.CommandId {
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        return .init(id);
    }

    fn assignStableOrders(self: *Bridge) void {
        if (self.commands.items.len == 0) return;

        var previous_order: ?u32 = null;
        for (self.matches.items) |matched_order| {
            const order = matched_order orelse continue;
            if (previous_order) |previous| {
                if (order <= previous) {
                    self.rebaseOrders();
                    return;
                }
            }
            previous_order = order;
        }

        var run_start: usize = 0;
        var left_order: u32 = 0;
        while (run_start < self.commands.items.len) {
            if (self.matches.items[run_start]) |matched_order| {
                self.commands.items[run_start].order = matched_order;
                left_order = matched_order;
                run_start += 1;
                continue;
            }

            var run_end = run_start;
            while (run_end < self.commands.items.len and self.matches.items[run_end] == null) {
                run_end += 1;
            }
            const right_order = if (run_end < self.commands.items.len)
                self.matches.items[run_end].?
            else
                std.math.maxInt(u32);
            const run_len: u64 = @intCast(run_end - run_start);
            const available = @as(u64, right_order) - @as(u64, left_order);
            if (available <= run_len) {
                self.rebaseOrders();
                return;
            }
            const step = available / (run_len + 1);
            for (run_start..run_end, 1..) |index, offset| {
                self.commands.items[index].order = @intCast(
                    @as(u64, left_order) + step * @as(u64, @intCast(offset)),
                );
            }
            if (run_end < self.commands.items.len) {
                self.commands.items[run_end].order = right_order;
                left_order = right_order;
            }
            run_start = run_end + @intFromBool(run_end < self.commands.items.len);
        }
    }

    fn rebaseOrders(self: *Bridge) void {
        const step = @as(u64, std.math.maxInt(u32)) /
            (@as(u64, @intCast(self.commands.items.len)) + 1);
        for (self.commands.items, 1..) |*command, index| {
            command.order = @intCast(step * @as(u64, @intCast(index)));
        }
    }

    fn rememberCurrent(self: *Bridge) !void {
        self.previous.clearRetainingCapacity();
        try self.previous.ensureTotalCapacity(self.allocator, self.commands.items.len);
        for (self.commands.items) |command| {
            self.previous.appendAssumeCapacity(.{
                .id = command.id,
                .fingerprint = command.fingerprint,
                .order = command.order,
            });
        }
    }
};

const PreviousCommand = struct {
    id: display.CommandId,
    fingerprint: u64,
    order: u32,
};

const MatchBucket = struct {
    head: usize,
    tail: usize,
};

fn convertPaint(source: goop.PaintCommand, scale: f32) display.PaintCommand {
    return switch (source) {
        .surface => |surface| .{ .surface = .{
            .bounds = scaledRect(surface.bounds, scale),
            .role = @enumFromInt(@intFromEnum(surface.role)),
            .state = @bitCast(surface.state),
            .color = color(surface.color),
            .border_color = color(surface.border_color),
            .border_width = surface.border_width * scale,
            .corner_radius = surface.corner_radius * scale,
        } },
        .text => |text| .{ .text = .{
            .bounds = scaledRect(text.bounds, scale),
            .text = text.text,
            .color = color(text.color),
            .font_size = text.font_size * scale,
            .text_align = @enumFromInt(@intFromEnum(text.text_align)),
            .overflow = @enumFromInt(@intFromEnum(text.overflow)),
        } },
        .clip => |clip| .{ .clip = .{
            .bounds = if (clip.bounds) |bounds| scaledRect(bounds, scale) else null,
        } },
        .icon => |icon| .{ .icon = .{
            .bounds = scaledRect(icon.bounds, scale),
            .kind = icon.kind,
            .color = color(icon.color),
        } },
        .custom => |custom| .{ .custom = .{
            .id = (@as(u64, custom.handle.generation) << 32) | custom.handle.index,
            .bounds = scaledRect(custom.bounds, scale),
        } },
    };
}

fn scaledRect(rect: goop.paint.Rect, scale: f32) display.Rect {
    return .{
        .x = rect.x * scale,
        .y = rect.y * scale,
        .w = rect.w * scale,
        .h = rect.h * scale,
    };
}

fn color(value: goop.Color) display.Color {
    return .rgba(value.r, value.g, value.b, value.a);
}

test "bridge preserves the complete semantic paint vocabulary" {
    const allocator = std.testing.allocator;
    var bridge = Bridge.init(allocator);
    defer bridge.deinit();

    const commands = [_]goop.PaintCommand{
        .{ .surface = .{
            .bounds = .{ .x = 1, .y = 2, .w = 3, .h = 4 },
            .color = .rgb(1, 2, 3),
            .border_color = .rgb(4, 5, 6),
            .border_width = 1,
            .corner_radius = 2,
        } },
        .{ .clip = .{ .bounds = null } },
    };
    const delta = try bridge.frame(.{ .commands = &commands }, 2);
    try std.testing.expect(delta.damage == .full);
    try std.testing.expectEqual(@as(usize, 2), delta.operations.len);
}

test "inserting transient chrome does not churn unchanged paint commands" {
    const allocator = std.testing.allocator;
    var bridge = Bridge.init(allocator);
    defer bridge.deinit();

    const background = goop.PaintCommand{ .surface = .{
        .bounds = .{ .x = 0, .y = 0, .w = 200, .h = 100 },
        .color = .rgb(255, 255, 255),
        .border_color = .rgb(255, 255, 255),
        .border_width = 0,
        .corner_radius = 0,
    } };
    const first_text = goop.PaintCommand{ .text = .{
        .bounds = .{ .x = 10, .y = 10, .w = 80, .h = 20 },
        .text = "first",
        .color = .rgb(10, 10, 10),
        .font_size = 14,
    } };
    const second_text = goop.PaintCommand{ .text = .{
        .bounds = .{ .x = 10, .y = 40, .w = 80, .h = 20 },
        .text = "second",
        .color = .rgb(10, 10, 10),
        .font_size = 14,
    } };
    const highlight = goop.PaintCommand{ .surface = .{
        .bounds = .{ .x = 8, .y = 8, .w = 100, .h = 24 },
        .color = .rgb(230, 238, 248),
        .border_color = .rgb(230, 238, 248),
        .border_width = 0,
        .corner_radius = 0,
    } };

    const initial_commands = [_]goop.PaintCommand{ background, first_text, second_text };
    _ = try bridge.frame(.{ .commands = &initial_commands }, 1);
    const initial_first_id = bridge.commands.items[1].id;
    const initial_first_order = bridge.commands.items[1].order;
    const initial_second_id = bridge.commands.items[2].id;
    const initial_second_order = bridge.commands.items[2].order;

    const hovered_commands = [_]goop.PaintCommand{ background, highlight, first_text, second_text };
    const hovered = try bridge.frame(.{ .commands = &hovered_commands }, 1);
    try std.testing.expectEqual(@as(usize, 1), hovered.operations.len);
    try std.testing.expect(hovered.operations[0] == .put);
    try std.testing.expectEqual(initial_first_id, bridge.commands.items[2].id);
    try std.testing.expectEqual(initial_first_order, bridge.commands.items[2].order);
    try std.testing.expectEqual(initial_second_id, bridge.commands.items[3].id);
    try std.testing.expectEqual(initial_second_order, bridge.commands.items[3].order);

    const unhovered = try bridge.frame(.{ .commands = &initial_commands }, 1);
    try std.testing.expectEqual(@as(usize, 1), unhovered.operations.len);
    try std.testing.expect(unhovered.operations[0] == .remove);
}

test "moving row selection removes the old highlight and preserves row text" {
    const allocator = std.testing.allocator;
    var bridge = Bridge.init(allocator);
    defer bridge.deinit();

    const background = goop.PaintCommand{ .surface = .{
        .bounds = .{ .x = 0, .y = 0, .w = 200, .h = 100 },
        .color = .rgb(255, 255, 255),
        .border_color = .rgb(255, 255, 255),
        .border_width = 0,
        .corner_radius = 0,
    } };
    const first_highlight = goop.PaintCommand{ .surface = .{
        .bounds = .{ .x = 0, .y = 0, .w = 200, .h = 30 },
        .color = .rgba(58, 126, 219, 84),
        .border_color = .rgba(58, 126, 219, 84),
        .border_width = 0,
        .corner_radius = 0,
    } };
    const second_highlight = goop.PaintCommand{ .surface = .{
        .bounds = .{ .x = 0, .y = 30, .w = 200, .h = 30 },
        .color = .rgba(58, 126, 219, 84),
        .border_color = .rgba(58, 126, 219, 84),
        .border_width = 0,
        .corner_radius = 0,
    } };
    const first_text = goop.PaintCommand{ .text = .{
        .bounds = .{ .x = 10, .y = 0, .w = 180, .h = 30 },
        .text = "first",
        .color = .rgb(10, 10, 10),
        .font_size = 14,
    } };
    const second_text = goop.PaintCommand{ .text = .{
        .bounds = .{ .x = 10, .y = 30, .w = 180, .h = 30 },
        .text = "second",
        .color = .rgb(10, 10, 10),
        .font_size = 14,
    } };

    const first_selected = [_]goop.PaintCommand{
        background,
        first_highlight,
        first_text,
        second_text,
    };
    _ = try bridge.frame(.{ .commands = &first_selected }, 1);
    const first_text_id = bridge.commands.items[2].id;
    const first_text_order = bridge.commands.items[2].order;
    const second_text_id = bridge.commands.items[3].id;
    const second_text_order = bridge.commands.items[3].order;

    const second_selected = [_]goop.PaintCommand{
        background,
        first_text,
        second_highlight,
        second_text,
    };
    const moved = try bridge.frame(.{ .commands = &second_selected }, 1);
    try std.testing.expectEqual(@as(usize, 2), moved.operations.len);

    var put_count: usize = 0;
    var remove_count: usize = 0;
    for (moved.operations) |operation| {
        switch (operation) {
            .put => put_count += 1,
            .remove => remove_count += 1,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), put_count);
    try std.testing.expectEqual(@as(usize, 1), remove_count);
    try std.testing.expectEqual(first_text_id, bridge.commands.items[1].id);
    try std.testing.expectEqual(first_text_order, bridge.commands.items[1].order);
    try std.testing.expectEqual(second_text_id, bridge.commands.items[3].id);
    try std.testing.expectEqual(second_text_order, bridge.commands.items[3].order);
}
