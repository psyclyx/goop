//! Allocation-free, time-driven scalar transitions.
//!
//! Animation owns interpolation only. Layout, paint, frame scheduling, and
//! application policy remain with their respective callers.

const std = @import("std");

pub const Curve = enum {
    linear,
    ease_out_cubic,
    ease_in_out_cubic,
};

pub const Value = struct {
    value: f32 = 0,
    target: f32 = 0,
    from: f32 = 0,
    started_ns: u64 = 0,
    duration_ns: u64 = 0,
    curve: Curve = .ease_out_cubic,

    pub fn init(value: f32) Value {
        return .{ .value = value, .target = value, .from = value };
    }

    /// Retarget continuously from the value at `now_ns`.
    pub fn setTarget(self: *Value, target: f32, now_ns: u64, duration_ns: u64) void {
        if (target == self.target) return;
        _ = self.sample(now_ns);
        self.from = self.value;
        self.target = target;
        self.started_ns = now_ns;
        self.duration_ns = duration_ns;
        if (duration_ns == 0) self.value = target;
    }

    pub fn sample(self: *Value, now_ns: u64) f32 {
        if (!self.active(now_ns)) {
            self.value = self.target;
            return self.value;
        }
        const elapsed = now_ns -| self.started_ns;
        const raw = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.duration_ns));
        const t = applyCurve(self.curve, std.math.clamp(raw, 0, 1));
        self.value = self.from + (self.target - self.from) * t;
        return self.value;
    }

    pub fn active(self: *const Value, now_ns: u64) bool {
        return self.value != self.target and self.duration_ns > 0 and now_ns -| self.started_ns < self.duration_ns;
    }
};

pub fn applyCurve(curve: Curve, t: f32) f32 {
    const x = std.math.clamp(t, 0, 1);
    return switch (curve) {
        .linear => x,
        .ease_out_cubic => 1 - (1 - x) * (1 - x) * (1 - x),
        .ease_in_out_cubic => if (x < 0.5)
            4 * x * x * x
        else
            1 - std.math.pow(f32, -2 * x + 2, 3) / 2,
    };
}

test "animation values stay bounded and monotonic for every curve" {
    inline for (std.meta.tags(Curve)) |curve| {
        var value = Value.init(0);
        value.curve = curve;
        value.setTarget(1, 100, 1000);
        var previous: f32 = 0;
        for (0..101) |step| {
            const current = value.sample(100 + step * 10);
            try std.testing.expect(current >= previous - 0.0001);
            try std.testing.expect(current >= 0 and current <= 1);
            previous = current;
        }
        try std.testing.expectEqual(@as(f32, 1), value.sample(1100));
    }
}

test "retargeting is continuous and zero duration snaps" {
    var value = Value.init(0);
    value.setTarget(1, 0, 1000);
    const midpoint = value.sample(400);
    value.setTarget(0, 400, 200);
    try std.testing.expectApproxEqAbs(midpoint, value.value, 0.0001);
    try std.testing.expectEqual(@as(f32, 0), value.sample(600));
    value.setTarget(1, 700, 0);
    try std.testing.expectEqual(@as(f32, 1), value.value);
}
