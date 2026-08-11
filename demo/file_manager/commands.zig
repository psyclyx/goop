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
};

pub fn resolveShortcut(key: desktop.input.Key) ?types.BrowserCommand {
    const action = desktop.resolveShortcut(&shortcut_commands, key) orelse return null;
    return ids.commandFromAction(action);
}
