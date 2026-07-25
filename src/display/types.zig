//! Value types shared inside the `goop_display` module.

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

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

pub const IconId = u32;
pub const CustomId = u64;

pub const PaintCommand = union(enum) {
    surface: Surface,
    text: Text,
    clip: ClipRect,
    icon: Icon,
    custom: Custom,

    pub const SurfaceRole = enum {
        generic,
        container,
        control,
        selection,
        indicator,
        focus_ring,
        drop_target,
        guide,
        divider,
        overlay,
    };

    pub const SurfaceState = packed struct {
        hovered: bool = false,
        pressed: bool = false,
        focused: bool = false,
        selected: bool = false,
        active: bool = false,
        disabled: bool = false,
    };

    pub const Surface = struct {
        bounds: Rect,
        role: SurfaceRole = .generic,
        state: SurfaceState = .{},
        color: Color,
        border_color: Color,
        border_width: f32,
        corner_radius: f32,
    };

    pub const Text = struct {
        bounds: Rect,
        text: []const u8,
        color: Color,
        font_size: f32,
        text_align: TextAlign = .start,
        overflow: TextOverflow = .visible,
    };

    pub const ClipRect = struct {
        bounds: ?Rect,
    };

    pub const Icon = struct {
        bounds: Rect,
        kind: IconId,
        color: Color,
    };

    pub const Custom = struct {
        id: CustomId,
        bounds: Rect,
    };
};

pub const PaintList = struct {
    commands: []const PaintCommand,
};
