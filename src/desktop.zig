//! Desktop application conventions layered over goop core.
//!
//! This module does not own a tree, retain node handles, dispatch callbacks,
//! or describe a second event vocabulary. It gives applications a small
//! command layer and constructors for core control descriptions. Input and
//! semantic output remain the exact types used by the layers below it.

const std = @import("std");
const goop = @import("goop");

pub const input = @import("goop_input");
pub const command = @import("desktop/command.zig");
pub const control = @import("desktop/control.zig");

pub const ElementId = goop.ElementId;
pub const ActionId = goop.ActionId;
pub const ControlDesc = goop.ControlDesc;
pub const WidgetDesc = goop.WidgetDesc;
pub const ControlEvent = goop.ControlEvent;
pub const ControlEvents = goop.ControlEvents;

pub const Command = command.Command;
pub const Binding = command.Binding;
pub const Shortcut = command.Shortcut;
pub const resolveShortcut = command.resolveShortcut;
pub const activated = command.activated;
pub const activatedAction = command.activatedAction;
pub const resolveBinding = command.resolveBinding;

test {
    _ = command;
    _ = control;
}

test "desktop semantic types are core types, not compatible copies" {
    comptime {
        if (input.Event != goop.Event) @compileError("desktop and core must consume the same normalized event type");
        if (input.Key != goop.Event.Key) @compileError("desktop and core must consume the same normalized key type");
        if (ElementId != goop.ElementId) @compileError("ElementId must be an exact alias");
        if (ActionId != goop.ActionId) @compileError("ActionId must be an exact alias");
        if (ControlDesc != goop.ControlDesc) @compileError("ControlDesc must be an exact alias");
        if (WidgetDesc != goop.WidgetDesc) @compileError("WidgetDesc must be an exact alias");
        if (ControlEvent != goop.ControlEvent) @compileError("ControlEvent must be an exact alias");
        if (ControlEvents != goop.ControlEvents) @compileError("ControlEvents must be an exact alias");
    }
}

test "desktop surface exposes data rather than framework machinery" {
    comptime {
        if (@hasDecl(@This(), "NodeHandle")) @compileError("desktop must not expose retained handles");
        if (@hasDecl(@This(), "Context")) @compileError("desktop must not own or wrap core context");
        if (@hasDecl(@This(), "Callback")) @compileError("desktop must not expose callbacks");
        if (@hasDecl(@This(), "Visual")) @compileError("desktop must not expose visuals");
        if (@hasDecl(@This(), "Renderer")) @compileError("desktop must not expose renderers");
        if (@hasDecl(@This(), "Platform")) @compileError("desktop must not expose platforms");
        if (containsFunctionPointer(Command)) @compileError("commands must be plain data");
        if (containsFunctionPointer(Binding)) @compileError("bindings must be plain data");
    }

    try std.testing.expect(@sizeOf(Binding) == @sizeOf(ElementId) + @sizeOf(ActionId));
}

test "desktop has no direct visual renderer or platform dependency" {
    const sources = [_][]const u8{
        @embedFile("desktop.zig"),
        @embedFile("desktop/command.zig"),
        @embedFile("desktop/control.zig"),
    };
    const forbidden_imports = [_][]const u8{
        "@im" ++ "port(\"goop_ui\")",
        "@im" ++ "port(\"goop_geometry\")",
        "@im" ++ "port(\"goop_visual\")",
        "@im" ++ "port(\"goop_render",
        "@im" ++ "port(\"goop_graphics",
        "@im" ++ "port(\"goop_present",
        "@im" ++ "port(\"goop_platform",
        "@im" ++ "port(\"goop_wayland",
    };

    for (sources) |source| {
        for (forbidden_imports) |forbidden| {
            try std.testing.expect(std.mem.indexOf(u8, source, forbidden) == null);
        }
    }
}

fn containsFunctionPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => true,
            else => false,
        },
        .optional => |optional| containsFunctionPointer(optional.child),
        .array => |array| containsFunctionPointer(array.child),
        .@"struct" => |structure| has_function: {
            inline for (structure.fields) |field| {
                if (containsFunctionPointer(field.type)) break :has_function true;
            }
            break :has_function false;
        },
        .@"union" => |union_info| has_function: {
            inline for (union_info.fields) |field| {
                if (containsFunctionPointer(field.type)) break :has_function true;
            }
            break :has_function false;
        },
        else => false,
    };
}
