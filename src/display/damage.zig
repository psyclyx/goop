const std = @import("std");
const Rect = @import("types.zig").Rect;

/// A small coalescing set of logical-pixel damage rectangles.
///
/// Damage is deliberately bounded. Once a frame becomes fragmented enough
/// that many scissors would cost more than a full redraw, `DamageSet`
/// promotes itself to `.full`.
pub const DamageSet = struct {
    regions: std.ArrayListUnmanaged(Rect) = .empty,
    full: bool = false,

    pub const max_regions = 24;

    pub fn deinit(self: *DamageSet, allocator: std.mem.Allocator) void {
        self.regions.deinit(allocator);
        self.* = .{};
    }

    pub fn clear(self: *DamageSet) void {
        self.regions.clearRetainingCapacity();
        self.full = false;
    }

    pub fn markFull(self: *DamageSet) void {
        self.regions.clearRetainingCapacity();
        self.full = true;
    }

    pub fn isEmpty(self: *const DamageSet) bool {
        return !self.full and self.regions.items.len == 0;
    }

    pub fn add(
        self: *DamageSet,
        allocator: std.mem.Allocator,
        rect: Rect,
    ) std.mem.Allocator.Error!void {
        if (self.full or rect.w <= 0 or rect.h <= 0) return;

        var merged = rect;
        var index: usize = 0;
        while (index < self.regions.items.len) {
            const candidate = self.regions.items[index];
            if (!touches(candidate, merged)) {
                index += 1;
                continue;
            }
            merged = unionRects(candidate, merged);
            _ = self.regions.swapRemove(index);
            index = 0;
        }

        if (self.regions.items.len >= max_regions) {
            self.markFull();
            return;
        }
        try self.regions.append(allocator, merged);
    }

    pub fn addOldAndNew(
        self: *DamageSet,
        allocator: std.mem.Allocator,
        old_bounds: ?Rect,
        new_bounds: ?Rect,
    ) std.mem.Allocator.Error!void {
        if (old_bounds) |bounds| try self.add(allocator, bounds);
        if (new_bounds) |bounds| try self.add(allocator, bounds);
    }

    fn touches(a: Rect, b: Rect) bool {
        return a.x <= b.x + b.w and b.x <= a.x + a.w and
            a.y <= b.y + b.h and b.y <= a.y + a.h;
    }

    fn unionRects(a: Rect, b: Rect) Rect {
        const left = @min(a.x, b.x);
        const top = @min(a.y, b.y);
        const right = @max(a.x + a.w, b.x + b.w);
        const bottom = @max(a.y + a.h, b.y + b.h);
        return .{
            .x = left,
            .y = top,
            .w = right - left,
            .h = bottom - top,
        };
    }
};

test "damage coalesces touching regions and tracks disjoint regions" {
    const allocator = std.testing.allocator;
    var damage = DamageSet{};
    defer damage.deinit(allocator);

    try damage.add(allocator, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try damage.add(allocator, .{ .x = 10, .y = 0, .w = 5, .h = 10 });
    try std.testing.expectEqual(@as(usize, 1), damage.regions.items.len);
    try std.testing.expectEqual(@as(f32, 15), damage.regions.items[0].w);

    try damage.add(allocator, .{ .x = 100, .y = 100, .w = 4, .h = 4 });
    try std.testing.expectEqual(@as(usize, 2), damage.regions.items.len);
}

test "fragmented damage promotes to full" {
    const allocator = std.testing.allocator;
    var damage = DamageSet{};
    defer damage.deinit(allocator);

    for (0..DamageSet.max_regions + 1) |index| {
        const x: f32 = @floatFromInt(index * 3);
        try damage.add(allocator, .{ .x = x, .y = 0, .w = 1, .h = 1 });
    }
    try std.testing.expect(damage.full);
    try std.testing.expectEqual(@as(usize, 0), damage.regions.items.len);
}
