//! Backend-neutral visual operations and the structural encoder seam.
//!
//! Looks emit these values. A renderer may consume them directly, a game may
//! implement the same structural encoder methods against its own render queue, and
//! tests may opt into the explicitly allocating `Recorder` below. The
//! contract owns no GPU objects, resources, frame lifecycle, or allocator.

const std = @import("std");
const geometry = @import("goop_geometry");
const image_data = @import("goop_image");

pub const Point = geometry.Point;
pub const Rect = geometry.Rect;
pub const ImageSource = image_data.View;

pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
};

pub const TextAlign = enum {
    start,
    center,
    end,
};

pub const TextOverflow = enum {
    visible,
    wrap,
    clip,
    ellipsis,
};

/// Opaque icon identity interpreted by the look or renderer.
pub const IconId = u32;

/// Stable vocabulary provided by the stock desktop look. Applications remain
/// free to use other opaque IDs with a renderer that understands them.
pub const StockIcon = enum(IconId) {
    folder = 0,
    file = 1,
    symlink = 2,
    home = 3,
    back = 4,
    up = 5,
    refresh = 6,
    list = 7,
    grid = 8,
    info = 9,
    folder_symlink = 10,
    file_symlink = 11,
    forward = 12,
    sidebar = 13,
    preview = 14,
    zoom_in = 15,
    zoom_out = 16,
    zoom_reset = 17,
    hidden = 18,
    close = 19,
    go = 20,
    collapse_left = 21,
    collapse_right = 22,
    check = 23,
};

/// Semantic identity for an application-supplied visual. This is deliberately
/// not a tree-storage handle: it survives reconciliation and can be understood
/// by a renderer that has never imported Goop core.
pub const CustomId = struct {
    namespace: Namespace,
    value: u64,

    pub const Namespace = enum(u8) {
        /// Identity inherited from a semantic UI element.
        element,
        /// Identity chosen directly by a look/application visual.
        visual,
    };

    /// `element_value` is the scalar value of the caller's ElementId. Visual
    /// stays a leaf module and therefore does not import the UI description
    /// layer merely to name that type.
    pub fn fromElementId(element_value: u64) CustomId {
        return .{ .namespace = .element, .value = element_value };
    }

    pub fn init(value: u64) CustomId {
        return .{ .namespace = .visual, .value = value };
    }
};

pub const Surface = struct {
    bounds: Rect,
    color: Color,
    border_color: Color = .rgba(0, 0, 0, 0),
    border_width: f32 = 0,
    corner_radius: f32 = 0,
};

/// Text content with resolved geometry and appearance. Shaping and resource
/// selection remain explicit capabilities of the consuming renderer.
pub const Text = struct {
    bounds: Rect,
    text: []const u8,
    color: Color,
    font_size: f32,
    text_align: TextAlign = .start,
    overflow: TextOverflow = .visible,
};

pub const Icon = struct {
    bounds: Rect,
    kind: IconId,
    color: Color,
};

pub const ImageFit = enum { contain, cover, stretch };

/// Decoded application image data with resolved layout. Pixels are borrowed;
/// resource upload and caching belong to the consuming renderer.
pub const Image = struct {
    bounds: Rect,
    source: ImageSource,
    fit: ImageFit = .contain,
};

pub const Custom = struct {
    id: CustomId,
    bounds: Rect,
};

/// Optional retained representation. Direct looks and renderers can call the
/// structural encoder methods without constructing or translating this union.
pub const Operation = union(enum) {
    push_clip: Rect,
    pop_clip,
    surface: Surface,
    text: Text,
    icon: Icon,
    image: Image,
    custom: Custom,

    pub fn bounds(self: Operation) ?Rect {
        return switch (self) {
            .push_clip => |rect| rect,
            .pop_clip => null,
            .surface => |value| value.bounds,
            .text => |value| value.bounds,
            .icon => |value| value.bounds,
            .image => |value| value.bounds,
            .custom => |value| value.bounds,
        };
    }
};

pub const List = struct {
    commands: []const Operation,
};

/// Emit one operation into a structural encoder. `encoder` supplies
/// `pushClip`, `popClip`, `surface`, `text`, `icon`, `image`, and `custom`, each
/// returning an error union. No allocation or type erasure occurs here.
pub fn emit(encoder: anytype, operation: Operation) !void {
    switch (operation) {
        .push_clip => |rect| try encoder.pushClip(rect),
        .pop_clip => try encoder.popClip(),
        .surface => |value| try encoder.surface(value),
        .text => |value| try encoder.text(value),
        .icon => |value| try encoder.icon(value),
        .image => |value| try encoder.image(value),
        .custom => |value| try encoder.custom(value),
    }
}

/// Allocation-free replay into a caller-owned encoder.
pub fn emitAll(encoder: anytype, operations: []const Operation) !void {
    for (operations) |operation| try emit(encoder, operation);
}

/// Explicitly allocating optional recorder. Text bytes are borrowed; callers
/// choose whether and where to copy them.
pub const Recorder = struct {
    allocator: std.mem.Allocator,
    operations: std.ArrayListUnmanaged(Operation) = .empty,

    pub fn init(allocator: std.mem.Allocator) Recorder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Recorder) void {
        self.operations.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *Recorder) void {
        self.operations.clearRetainingCapacity();
    }

    pub fn items(self: *const Recorder) []const Operation {
        return self.operations.items;
    }

    pub fn pushClip(self: *Recorder, rect: Rect) !void {
        try self.operations.append(self.allocator, .{ .push_clip = rect });
    }

    pub fn popClip(self: *Recorder) !void {
        try self.operations.append(self.allocator, .pop_clip);
    }

    pub fn surface(self: *Recorder, value: Surface) !void {
        try self.operations.append(self.allocator, .{ .surface = value });
    }

    pub fn text(self: *Recorder, value: Text) !void {
        try self.operations.append(self.allocator, .{ .text = value });
    }

    pub fn icon(self: *Recorder, value: Icon) !void {
        try self.operations.append(self.allocator, .{ .icon = value });
    }

    pub fn image(self: *Recorder, value: Image) !void {
        try self.operations.append(self.allocator, .{ .image = value });
    }

    pub fn custom(self: *Recorder, value: Custom) !void {
        try self.operations.append(self.allocator, .{ .custom = value });
    }
};

test "recorder is an optional implementation of the visual contract" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();

    try recorder.pushClip(.{ .x = 0, .y = 0, .w = 320, .h = 200 });
    try recorder.surface(.{
        .bounds = .{ .x = 4, .y = 8, .w = 80, .h = 24 },
        .color = .rgb(20, 30, 40),
    });
    try recorder.popClip();

    try std.testing.expectEqual(@as(usize, 3), recorder.items().len);
    try std.testing.expect(recorder.items()[0] == .push_clip);
    try std.testing.expect(recorder.items()[1] == .surface);
    try std.testing.expect(recorder.items()[2] == .pop_clip);
}

test "retained operations replay without intermediate allocation" {
    const CountingEncoder = struct {
        count: usize = 0,

        pub fn pushClip(self: *@This(), _: Rect) !void {
            self.count += 1;
        }
        pub fn popClip(self: *@This()) !void {
            self.count += 1;
        }
        pub fn surface(self: *@This(), _: Surface) !void {
            self.count += 1;
        }
        pub fn text(self: *@This(), _: Text) !void {
            self.count += 1;
        }
        pub fn icon(self: *@This(), _: Icon) !void {
            self.count += 1;
        }
        pub fn image(self: *@This(), _: Image) !void {
            self.count += 1;
        }
        pub fn custom(self: *@This(), _: Custom) !void {
            self.count += 1;
        }
    };

    var counter = CountingEncoder{};
    try emitAll(&counter, &.{
        .{ .surface = .{
            .bounds = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
            .color = .rgb(1, 2, 3),
        } },
        .{ .custom = .{
            .id = .fromElementId(7),
            .bounds = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        } },
    });
    try std.testing.expectEqual(@as(usize, 2), counter.count);
}
