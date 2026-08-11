//! Application-owned commands and allocation-free routing helpers.

const std = @import("std");
const goop = @import("goop");
const input = @import("goop_input");

pub const ActionId = goop.ActionId;
pub const ElementId = goop.ElementId;
pub const ControlEvent = goop.ControlEvent;
pub const Shortcut = input.Shortcut;

/// One semantic application command. Presentation and execution remain the
/// caller's responsibility.
pub const Command = struct {
    id: ActionId,
    title: []const u8,
    shortcut: ?Shortcut = null,
    enabled: bool = true,
    checked: bool = false,
};

/// Associates one presentation element with an application command.
pub const Binding = struct {
    element: ElementId,
    command: ActionId,
};

/// Resolve a key press against a caller-owned command slice.
///
/// Commands are considered in slice order and the first enabled match wins.
/// Releases and repeats do not activate commands. Lock state is ignored: caps
/// lock and num lock do not change the meaning of a shortcut.
pub fn resolveShortcut(commands: []const Command, key: input.Key) ?ActionId {
    if (key.state != .pressed) return null;

    for (commands) |item| {
        const shortcut = item.shortcut orelse continue;
        if (item.enabled and shortcutMatches(shortcut, key)) return item.id;
    }
    return null;
}

/// Borrow the activation payload from a core event. Calling this while walking
/// `ControlEvents.items` preserves journal order and does not copy its payload.
pub fn activated(event: *const ControlEvent) ?*const goop.Activation {
    return switch (event.*) {
        .activated => |*activation| activation,
        else => null,
    };
}

/// Return the action carried by a primary activation, if it has one.
pub fn activatedAction(event: *const ControlEvent) ?ActionId {
    const activation = activated(event) orelse return null;
    return activation.action;
}

/// Resolve the source element of a primary activation through caller-owned
/// presentation bindings. The first matching binding wins.
pub fn resolveBinding(bindings: []const Binding, event: *const ControlEvent) ?ActionId {
    const activation = activated(event) orelse return null;
    for (bindings) |binding| {
        if (binding.element == activation.element) return binding.command;
    }
    return null;
}

fn shortcutMatches(shortcut: Shortcut, key: input.Key) bool {
    return shortcut.keycode == key.keycode and
        shortcut.modifiers.shift == key.mods.shift and
        shortcut.modifiers.ctrl == key.mods.ctrl and
        shortcut.modifiers.alt == key.mods.alt and
        shortcut.modifiers.super == key.mods.super;
}

test "command types use exact core and input identities" {
    comptime {
        if (ActionId != goop.ActionId) @compileError("command action IDs must be core action IDs");
        if (ElementId != goop.ElementId) @compileError("binding element IDs must be core element IDs");
        if (ControlEvent != goop.ControlEvent) @compileError("command routing must consume core events");
        if (Shortcut != input.Shortcut) @compileError("shortcuts must use normalized input values");
    }
}

test "shortcut resolution is allocation-free caller-order policy" {
    const commands = [_]Command{
        .{
            .id = .init(1),
            .title = "Disabled duplicate",
            .shortcut = .{ .keycode = .o, .modifiers = .{ .ctrl = true } },
            .enabled = false,
        },
        .{
            .id = .init(2),
            .title = "Open",
            .shortcut = .{ .keycode = .o, .modifiers = .{ .ctrl = true } },
        },
        .{
            .id = .init(3),
            .title = "Later duplicate",
            .shortcut = .{ .keycode = .o, .modifiers = .{ .ctrl = true } },
        },
    };

    const pressed = input.Key{
        .keycode = .o,
        .mods = .{ .ctrl = true, .caps_lock = true },
        .state = .pressed,
    };
    try std.testing.expectEqual(ActionId.init(2), resolveShortcut(&commands, pressed).?);

    var released = pressed;
    released.state = .released;
    try std.testing.expectEqual(@as(?ActionId, null), resolveShortcut(&commands, released));

    var repeated = pressed;
    repeated.state = .repeat;
    try std.testing.expectEqual(@as(?ActionId, null), resolveShortcut(&commands, repeated));
}

test "activation helpers consume exact core events one at a time" {
    const event = ControlEvent{ .activated = .{
        .element = .init(41),
        .action = .init(7),
    } };
    const other = ControlEvent{ .toggle_changed = .{
        .element = .init(41),
        .value = true,
    } };
    const bindings = [_]Binding{.{ .element = .init(41), .command = .init(9) }};

    const activation = activated(&event).?;
    try std.testing.expect(activation == &event.activated);
    try std.testing.expectEqual(ElementId.init(41), activation.element);
    try std.testing.expectEqual(ActionId.init(7), activatedAction(&event).?);
    try std.testing.expectEqual(ActionId.init(9), resolveBinding(&bindings, &event).?);
    try std.testing.expect(activated(&other) == null);
    try std.testing.expect(resolveBinding(&bindings, &other) == null);
}
