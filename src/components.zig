//! Allocation-free visual components.
//!
//! Components consume fully resolved geometry and appearance and emit
//! backend-neutral visual operations into a caller-owned structural encoder.
//! They own no application behavior, retained state, renderer resources, or
//! allocation. A game renderer can implement the encoder methods directly.

const visual = @import("goop_visual");

pub const Surface = struct {
    bounds: visual.Rect,
    color: visual.Color,
    border_color: visual.Color = .rgba(0, 0, 0, 0),
    border_width: f32 = 0,
    corner_radius: f32 = 0,

    pub fn emit(self: Surface, encoder: anytype) !void {
        try encoder.surface(.{
            .bounds = self.bounds,
            .color = self.color,
            .border_color = self.border_color,
            .border_width = self.border_width,
            .corner_radius = self.corner_radius,
        });
    }
};

pub const Text = struct {
    bounds: visual.Rect,
    content: []const u8,
    color: visual.Color,
    font_size: f32,
    text_align: visual.TextAlign = .start,
    overflow: visual.TextOverflow = .visible,

    pub fn emit(self: Text, encoder: anytype) !void {
        try encoder.text(.{
            .bounds = self.bounds,
            .text = self.content,
            .color = self.color,
            .font_size = self.font_size,
            .text_align = self.text_align,
            .overflow = self.overflow,
        });
    }
};

/// A resolved passive icon. `kind` remains opaque to the component and is
/// interpreted only by the consuming renderer.
pub const Icon = struct {
    bounds: visual.Rect,
    kind: visual.IconId,
    color: visual.Color,

    pub fn emit(self: Icon, encoder: anytype) !void {
        try encoder.icon(.{
            .bounds = self.bounds,
            .kind = self.kind,
            .color = self.color,
        });
    }
};

/// A passive decoded image. Fit is appearance data; decoding, identity, and
/// resource lifetime remain caller-owned.
pub const Image = struct {
    bounds: visual.Rect,
    source: visual.ImageSource,
    fit: visual.ImageFit = .contain,

    pub fn emit(self: Image, encoder: anytype) !void {
        try encoder.image(.{ .bounds = self.bounds, .source = self.source, .fit = self.fit });
    }
};

pub const FocusRing = struct {
    bounds: visual.Rect,
    color: visual.Color,
    corner_radius: f32,
    visible: bool,
    width: f32 = 2,
    /// Stock focus adornments are contained by default. This keeps sibling
    /// backgrounds and scroll clips from erasing an owning control's ring.
    outset: f32 = 0,

    pub fn emit(self: FocusRing, encoder: anytype) !void {
        if (!self.visible) return;
        try (Surface{
            .bounds = .{
                .x = self.bounds.x - self.outset,
                .y = self.bounds.y - self.outset,
                .w = self.bounds.w + self.outset * 2,
                .h = self.bounds.h + self.outset * 2,
            },
            .color = .rgba(0, 0, 0, 0),
            .border_color = self.color,
            .border_width = self.width,
            .corner_radius = self.corner_radius + self.outset,
        }).emit(encoder);
    }
};

/// A resolved button look. Field order is also emission order.
pub const Button = struct {
    background: Surface,
    label: Text,
    focus: FocusRing,

    pub fn emit(self: Button, encoder: anytype) !void {
        try self.background.emit(encoder);
        try self.label.emit(encoder);
        try self.focus.emit(encoder);
    }
};

/// A resolved checkbox look. `indicator = null` draws an unchecked box.
pub const Checkbox = struct {
    box: Surface,
    indicator: ?Surface,
    label: Text,
    focus: FocusRing,

    pub fn emit(self: Checkbox, encoder: anytype) !void {
        try self.box.emit(encoder);
        if (self.indicator) |indicator| try indicator.emit(encoder);
        try self.label.emit(encoder);
        try self.focus.emit(encoder);
    }
};

/// A resolved radio-button look. Geometry is supplied by the caller.
pub const RadioButton = struct {
    outer: Surface,
    indicator: ?Surface,
    label: Text,
    focus: FocusRing,

    pub fn emit(self: RadioButton, encoder: anytype) !void {
        try self.outer.emit(encoder);
        if (self.indicator) |indicator| try indicator.emit(encoder);
        try self.label.emit(encoder);
        try self.focus.emit(encoder);
    }
};

test "components emit resolved visuals in structural order" {
    const std = @import("std");
    const Capture = struct {
        operations: [8]visual.Operation = undefined,
        len: usize = 0,

        fn append(self: *@This(), operation: visual.Operation) error{Overflow}!void {
            if (self.len == self.operations.len) return error.Overflow;
            self.operations[self.len] = operation;
            self.len += 1;
        }

        pub fn surface(self: *@This(), value: visual.Surface) !void {
            try self.append(.{ .surface = value });
        }

        pub fn text(self: *@This(), value: visual.Text) !void {
            try self.append(.{ .text = value });
        }
    };

    const bounds = visual.Rect{ .x = 4, .y = 8, .w = 80, .h = 24 };
    var capture = Capture{};
    try (Button{
        .background = .{ .bounds = bounds, .color = .rgb(20, 30, 40) },
        .label = .{
            .bounds = bounds,
            .content = "Open",
            .color = .rgb(220, 220, 220),
            .font_size = 14,
        },
        .focus = .{
            .bounds = bounds,
            .color = .rgb(80, 140, 220),
            .corner_radius = 4,
            .visible = true,
        },
    }).emit(&capture);

    try std.testing.expectEqual(@as(usize, 3), capture.len);
    try std.testing.expect(capture.operations[0] == .surface);
    try std.testing.expect(capture.operations[1] == .text);
    try std.testing.expect(capture.operations[2] == .surface);
    try std.testing.expectEqual(@as(f32, 2), capture.operations[2].surface.border_width);
    try std.testing.expectEqual(bounds, capture.operations[2].surface.bounds);
}

test "unchecked and unfocused controls emit no hidden operations" {
    const std = @import("std");
    const CountingEncoder = struct {
        surfaces: usize = 0,
        texts: usize = 0,

        pub fn surface(self: *@This(), _: visual.Surface) !void {
            self.surfaces += 1;
        }

        pub fn text(self: *@This(), _: visual.Text) !void {
            self.texts += 1;
        }
    };

    const bounds = visual.Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    const label = Text{
        .bounds = bounds,
        .content = "Choice",
        .color = .rgb(255, 255, 255),
        .font_size = 14,
    };
    const focus = FocusRing{
        .bounds = bounds,
        .color = .rgb(0, 120, 255),
        .corner_radius = 4,
        .visible = false,
    };
    var counter = CountingEncoder{};
    try (Checkbox{
        .box = .{ .bounds = bounds, .color = .rgb(30, 30, 30) },
        .indicator = null,
        .label = label,
        .focus = focus,
    }).emit(&counter);

    try std.testing.expectEqual(@as(usize, 1), counter.surfaces);
    try std.testing.expectEqual(@as(usize, 1), counter.texts);
}

test "stock focus rings stay inside their owner for varied geometry" {
    const std = @import("std");
    const Capture = struct {
        value: ?visual.Surface = null,

        pub fn surface(self: *@This(), value: visual.Surface) !void {
            self.value = value;
        }
    };

    for ([_]f32{ -13, 0, 2.5, 101 }) |x| {
        for ([_]f32{ 1, 8, 37.5, 240 }) |width| {
            const owner = visual.Rect{ .x = x, .y = x * 0.5, .w = width, .h = width * 0.75 + 1 };
            var capture = Capture{};
            try (FocusRing{
                .bounds = owner,
                .color = .rgb(0, 120, 255),
                .corner_radius = 3,
                .visible = true,
            }).emit(&capture);
            const ring = capture.value.?.bounds;
            try std.testing.expect(ring.x >= owner.x);
            try std.testing.expect(ring.y >= owner.y);
            try std.testing.expect(ring.x + ring.w <= owner.x + owner.w);
            try std.testing.expect(ring.y + ring.h <= owner.y + owner.h);
        }
    }
}

test "source boundary excludes core, behavior, and backend concerns" {
    const std = @import("std");
    const source = @embedFile("components.zig");
    const forbidden = [_][]const u8{
        "@im" ++ "port(\"goop\")",
        "goop_" ++ "ui",
        "Node" ++ "Handle",
        "Widget" ++ "Kind",
        "Tr" ++ "ee",
        "Beha" ++ "vior",
        "Element" ++ "Id",
        "Action" ++ "Id",
        "any" ++ "opaque",
        "std.mem." ++ "Allocator",
        "call" ++ "back",
        "Vul" ++ "kan",
        "Way" ++ "land",
        "Render" ++ "er",
    };
    inline for (forbidden) |name| {
        try std.testing.expect(std.mem.indexOf(u8, source, name) == null);
    }
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "@im" ++ "port(\"goop_"),
    );
}
