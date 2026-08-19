//! File-manager command metadata and desktop shortcut routing.

const desktop = @import("goop_desktop");
const ids = @import("ids.zig");
const types = @import("types.zig");

pub const shortcut_commands = [_]desktop.Command{
    .{ .id = ids.commandAction(.select_all), .title = "Select All", .shortcut = .{ .keycode = .a, .modifiers = .{ .ctrl = true } } },
    .{ .id = ids.commandAction(.copy), .title = "Copy", .shortcut = .{ .keycode = .c, .modifiers = .{ .ctrl = true } } },
    .{ .id = ids.commandAction(.cut), .title = "Cut", .shortcut = .{ .keycode = .x, .modifiers = .{ .ctrl = true } } },
    .{ .id = ids.commandAction(.paste), .title = "Paste", .shortcut = .{ .keycode = .v, .modifiers = .{ .ctrl = true } } },
    .{ .id = ids.commandAction(.delete), .title = "Delete", .shortcut = .{ .keycode = .delete } },
    .{ .id = ids.commandAction(.move_parent), .title = "Move to Parent", .shortcut = .{ .keycode = .up, .modifiers = .{ .ctrl = true, .shift = true } } },
    .{ .id = ids.commandAction(.zoom_in), .title = "Zoom In", .shortcut = .{ .keycode = .equal, .modifiers = .{ .ctrl = true } } },
    .{ .id = ids.commandAction(.zoom_in), .title = "Zoom In", .shortcut = .{ .keycode = .equal, .modifiers = .{ .ctrl = true, .shift = true } } },
    .{ .id = ids.commandAction(.zoom_out), .title = "Zoom Out", .shortcut = .{ .keycode = .minus, .modifiers = .{ .ctrl = true } } },
    .{ .id = ids.commandAction(.zoom_reset), .title = "Reset Zoom", .shortcut = .{ .keycode = .digit_0, .modifiers = .{ .ctrl = true } } },
    .{ .id = ids.commandAction(.toggle_hidden), .title = "Show Hidden Files", .shortcut = .{ .keycode = .h, .modifiers = .{ .ctrl = true } } },
    // Explorer navigation/action accelerators.
    .{ .id = ids.commandAction(.rename), .title = "Rename", .shortcut = .{ .keycode = .f2 } },
    .{ .id = ids.commandAction(.refresh), .title = "Refresh", .shortcut = .{ .keycode = .f5 } },
    .{ .id = ids.commandAction(.back), .title = "Back", .shortcut = .{ .keycode = .left, .modifiers = .{ .alt = true } } },
    .{ .id = ids.commandAction(.forward), .title = "Forward", .shortcut = .{ .keycode = .right, .modifiers = .{ .alt = true } } },
    .{ .id = ids.commandAction(.up), .title = "Up", .shortcut = .{ .keycode = .up, .modifiers = .{ .alt = true } } },
    .{ .id = ids.commandAction(.up), .title = "Up", .shortcut = .{ .keycode = .backspace } },
};

pub fn resolveShortcut(key: desktop.input.Key) ?types.BrowserCommand {
    const action = desktop.resolveShortcut(&shortcut_commands, key) orelse return null;
    return ids.commandFromAction(action);
}
