const style = @import("style.zig");
const handle = @import("handle.zig");

/// Axis-aligned rectangle.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
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

/// Opaque icon identity. The core does not interpret this value; it is
/// passed through from widgets to the embedder, which maps it to whatever
/// asset or vector path it wants to draw.
pub const IconId = u32;

/// A semantic paint command emitted by the core.
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
        color: style.Color,
        border_color: style.Color,
        border_width: f32,
        corner_radius: f32,
    };

    pub const Text = struct {
        bounds: Rect,
        text: []const u8,
        color: style.Color,
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
        color: style.Color,
    };

    pub const Custom = struct {
        handle: handle.NodeHandle,
        bounds: Rect,
    };
};

/// Accumulated semantic paint output from a frame.
pub const PaintList = struct {
    commands: []const PaintCommand,
};

/// What slice of the widget tree to paint.
pub const PaintScope = union(enum) {
    /// Whole tree from every root.
    full: Full,
    /// Only the subtree rooted at this handle, with the popup origin
    /// translated to (0, 0). Used to paint a popup into its own surface.
    popup: handle.NodeHandle,

    pub const Full = struct {
        /// Include floating subtrees (popups, tooltips) and active drag
        /// ghosts. Embedders that paint floating layers separately
        /// (e.g. via per-popup surfaces) set this to false.
        include_floating: bool = true,
    };
};

pub const PaintOptions = struct {
    scope: PaintScope = .{ .full = .{} },
};
