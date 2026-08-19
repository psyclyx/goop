//! Read-only presentation queries for the file-browser view.

const std = @import("std");
const state = @import("state.zig");
const types = @import("types.zig");
const model_ops = @import("model.zig");

pub const Input = struct {
    model: *const state.Model,
    interaction: *const state.Interaction,
    home_available: bool,
    file_clipboard_available: bool,
};

pub fn browserViewModeLabel(mode: types.BrowserViewMode) []const u8 {
    return switch (mode) {
        .list => "list",
        .grid => "grid",
    };
}

pub fn isRenamingPath(input: Input, path: []const u8) bool {
    const rename_path = input.interaction.rename_path orelse return false;
    return std.mem.eql(u8, rename_path, path);
}

fn contextTargetEntry(input: Input) ?*const types.BrowserEntry {
    const path = input.interaction.context_target_path orelse return null;
    return model_ops.entryForPath(input.model, path);
}

pub fn contextOpenEnabled(input: Input) bool {
    const path = input.interaction.context_target_path orelse return false;
    const entry = model_ops.entryForPath(input.model, path) orelse return true;
    return entry.canEnter();
}

pub fn contextCopyPathEnabled(input: Input) bool {
    return input.interaction.context_target_path != null;
}

pub fn contextOpenLinkTargetEnabled(input: Input) bool {
    const entry = contextTargetEntry(input) orelse return false;
    return entry.isSymlinkToDirectory();
}

fn selectionFileCommandEnabled(input: Input) bool {
    return input.model.selected_paths.items.len > 0;
}

fn renameSelectionEnabled(input: Input) bool {
    return input.model.selected_paths.items.len == 1 and model_ops.selectedEntry(input.model) != null;
}

fn moveSelectionToParentEnabled(input: Input) bool {
    return selectionFileCommandEnabled(input) and !std.mem.eql(u8, input.model.current_dir, "/");
}

fn fileClipboardAvailable(input: Input) bool {
    return input.file_clipboard_available;
}

fn targetPathCanAcceptPaste(input: Input, path: []const u8) bool {
    if (!fileClipboardAvailable(input)) return false;
    if (model_ops.entryForPath(input.model, path)) |entry| return entry.canEnter();
    // Non-entry targets are current-directory, place, breadcrumb, or folder
    // paths admitted by the controller's semantic-ID projection. Whether an
    // actual file operation succeeds belongs to the filesystem reducer; a
    // read-only presentation query must not probe the host filesystem.
    return true;
}

pub fn contextSelectionCommandEnabled(input: Input) bool {
    const path = input.interaction.context_target_path orelse return false;
    return model_ops.entryForPath(input.model, path) != null and input.model.selected_paths.items.len > 0;
}

pub fn contextRenameEnabled(input: Input) bool {
    const path = input.interaction.context_target_path orelse return false;
    return model_ops.entryForPath(input.model, path) != null and renameSelectionEnabled(input);
}

pub fn contextMoveParentEnabled(input: Input) bool {
    const path = input.interaction.context_target_path orelse return false;
    return model_ops.entryForPath(input.model, path) != null and moveSelectionToParentEnabled(input);
}

pub fn contextPasteEnabled(input: Input) bool {
    const path = input.interaction.context_target_path orelse return false;
    return targetPathCanAcceptPaste(input, path);
}

pub fn browserCommandChecked(input: Input, command: types.BrowserCommand) bool {
    return switch (command) {
        .toggle_sidebar => input.model.show_sidebar,
        .toggle_preview => input.model.show_preview,
        .toggle_info => input.model.show_info,
        .toggle_status_bar => input.model.show_status_bar,
        .view_list => input.model.view_mode == .list,
        .view_grid => input.model.view_mode == .grid,
        .toggle_sort_directories => input.model.sort_directories_together,
        .toggle_hidden => input.model.show_hidden,
        else => false,
    };
}

pub fn browserCommandEnabled(input: Input, command: types.BrowserCommand) bool {
    return switch (command) {
        .back => input.model.history_index > 0 and input.model.history.items.len > 0,
        .forward => input.model.history.items.len > 0 and input.model.history_index + 1 < input.model.history.items.len,
        .up => !std.mem.eql(u8, input.model.current_dir, "/"),
        .home => input.home_available,
        .refresh => true,
        .copy, .cut, .delete => selectionFileCommandEnabled(input),
        .paste => fileClipboardAvailable(input),
        .rename => renameSelectionEnabled(input),
        .move_parent => moveSelectionToParentEnabled(input),
        .copy_path => true,
        .open_link_target => if (model_ops.selectedEntry(input.model)) |entry| entry.isSymlinkToDirectory() else false,
        .quit => true,
        .select_all => input.model.entries.items.len > 0,
        .clear_selection => input.model.selected_paths.items.len > 0,
        .toggle_sidebar,
        .toggle_preview,
        .toggle_info,
        .toggle_status_bar,
        .view_list,
        .view_grid,
        .toggle_sort_directories,
        .toggle_hidden,
        .zoom_in,
        .zoom_out,
        .zoom_reset,
        .about,
        => true,
    };
}

test "presentation queries do not perform filesystem work" {
    const source = @embedFile("presentation.zig");
    const forbidden = [_][]const u8{
        "@im" ++ "port(\"fs.zig\")",
        "std." ++ "Io." ++ "Dir",
        "open" ++ "Dir(",
        "stat" ++ "File(",
    };
    for (forbidden) |name| {
        try std.testing.expect(std.mem.indexOf(u8, source, name) == null);
    }
}
