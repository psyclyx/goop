//! Explicit capability bundles used by the demo's independent seams.

const state = @import("state.zig");
const image = @import("goop_image");

/// Browser behavior plus its externally-owned effects. No view or GUI state.
pub const Behavior = struct {
    session: *state.Session,
    viewport: *state.Viewport,
    domain: *state.Domain,
    effects: *state.Effects,
    image_decoder: ?image.Decoder = null,
};

pub fn behavior(session: *state.Session, viewport: *state.Viewport, domain: *state.Domain, effects: *state.Effects) Behavior {
    return .{ .session = session, .viewport = viewport, .domain = domain, .effects = effects };
}

pub fn behaviorWithImages(
    session: *state.Session,
    viewport: *state.Viewport,
    domain: *state.Domain,
    effects: *state.Effects,
    decoder: image.Decoder,
) Behavior {
    return .{
        .session = session,
        .viewport = viewport,
        .domain = domain,
        .effects = effects,
        .image_decoder = decoder,
    };
}

/// File operations need session I/O and browser domain state, but no effects,
/// identities, view projection, or GUI ownership.
pub const Filesystem = struct {
    session: *state.Session,
    model: *state.Model,
    interaction: *state.Interaction,
};

pub fn filesystem(
    session: *state.Session,
    model: *state.Model,
    interaction: *state.Interaction,
) Filesystem {
    return .{ .session = session, .model = model, .interaction = interaction };
}

test "filesystem capability excludes unrelated browser owners" {
    comptime {
        if (@hasField(Filesystem, "effects")) @compileError("filesystem gained transfer effects");
        if (@hasField(Filesystem, "identities")) @compileError("filesystem gained semantic identities");
        if (@hasField(Filesystem, "projection")) @compileError("filesystem gained view projection");
        if (@hasField(Filesystem, "domain")) @compileError("filesystem gained aggregate domain access");
    }
}

/// Read-only browser data supplied to visual projection.
pub const ViewInput = struct {
    viewport: *const state.Viewport,
    model: *const state.Model,
    interaction: *const state.Interaction,
    presentation: *const state.Presentation,
};

pub fn viewInput(
    viewport: *const state.Viewport,
    model: *const state.Model,
    interaction: *const state.Interaction,
    presentation: *const state.Presentation,
) ViewInput {
    return .{
        .viewport = viewport,
        .model = model,
        .interaction = interaction,
        .presentation = presentation,
    };
}

test "view input exposes data without ambient session capabilities" {
    comptime {
        if (@hasField(ViewInput, "session")) @compileError("view input gained session I/O and environment access");
        if (@hasField(ViewInput, "transfer")) @compileError("view input gained transfer ownership");
        if (@hasField(ViewInput, "io")) @compileError("view input gained I/O");
        if (@hasField(ViewInput, "env")) @compileError("view input gained environment access");
    }
}

/// Scratch and identity assignment written by visual projection.
pub const ViewOutput = struct {
    projection: *state.View,
    identities: *@import("ids.zig").Registry,
};

pub fn viewOutput(projection: *state.View, identities: *@import("ids.zig").Registry) ViewOutput {
    return .{ .projection = projection, .identities = identities };
}
