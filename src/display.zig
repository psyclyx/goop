//! Backend-neutral display output vocabulary.
//!
//! This module is the only rendering vocabulary exposed to the UI layers.
//! Backends consume it; components never name a graphics API.

const types = @import("display/types.zig");

pub const Rect = types.Rect;
pub const Color = types.Color;
pub const PaintCommand = types.PaintCommand;
pub const PaintList = types.PaintList;
pub const TextAlign = types.TextAlign;
pub const TextOverflow = types.TextOverflow;
pub const IconId = types.IconId;
pub const CustomId = types.CustomId;

pub fn commandBounds(command: PaintCommand) ?Rect {
    return switch (command) {
        .surface => |value| value.bounds,
        .text => |value| value.bounds,
        .icon => |value| value.bounds,
        .custom => |value| value.bounds,
        .clip => |value| value.bounds,
    };
}
