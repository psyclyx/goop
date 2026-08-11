const std = @import("std");
const goop = @import("goop");

const types = @import("types.zig");
const state_module = @import("state.zig");
const model_ops = @import("model.zig");
const presentation = @import("presentation.zig");
const presentation_refresh = @import("presentation_refresh.zig");
const transfer_ops = @import("transfer.zig");
const ids = @import("ids.zig");
const capabilities = @import("capabilities.zig");
const desktop = @import("goop_desktop");
const commands = @import("commands.zig");
const fs = @import("fs.zig");

const allocator = std.heap.smp_allocator;
const BrowserCommand = types.BrowserCommand;
const FileClipboardAction = types.FileClipboardAction;
const BrowserEntry = types.BrowserEntry;
const browser_double_click_time_ms = types.browser_double_click_time_ms;

fn envScale(env: *const std.process.Environ.Map, name: []const u8, fallback: f32) f32 {
    const raw = env.get(name) orelse return fallback;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return fallback;
    const parsed = std.fmt.parseFloat(f32, value) catch return fallback;
    if (!std.math.isFinite(parsed) or parsed <= 0) return fallback;
    return parsed;
}

const Scope = capabilities.Behavior;

fn presentationInput(scope: *const Scope) presentation.Input {
    return .{
        .model = &scope.domain.model,
        .interaction = &scope.domain.interaction,
        .home_available = fs.homePath(filesystemScope(scope)) != null,
        .file_clipboard_available = scope.effects.transfer.clipboard_file_action != null and
            scope.effects.transfer.clipboard_buf.items.len > 0,
    };
}

fn filesystemScope(scope: *const Scope) capabilities.Filesystem {
    return capabilities.filesystem(
        scope.session,
        &scope.domain.model,
        &scope.domain.interaction,
    );
}

pub fn clipboard(transfer: *state_module.Transfer) goop.Clipboard {
    return transfer_ops.clipboard(transfer);
}

fn stateIo(state: *const Scope) !std.Io {
    return state.session.io orelse error.IoUnavailable;
}

fn refreshPresentation(state: *Scope) !void {
    try presentation_refresh.refresh(
        &state.domain.presentation,
        state.session.io,
        state.session.env,
        &state.domain.model,
        &state.effects.transfer,
        state.image_decoder,
    );
}

fn addressInputPathAlloc(state: *const Scope) ![]u8 {
    const typed = std.mem.trim(u8, state.domain.interaction.address_input.content(), " \t\r\n");
    if (typed.len == 0) return allocator.dupe(u8, state.domain.model.current_dir);

    if (typed[0] == '~') {
        if (typed.len == 1 or typed[1] == '/') {
            if (fs.homePath(filesystemScope(state))) |home| {
                if (typed.len == 1) return fs.normalizeDirectoryPath(allocator, home);
                const joined = try std.fs.path.resolve(allocator, &.{ home, typed[2..] });
                defer allocator.free(joined);
                return fs.normalizeDirectoryPath(allocator, joined);
            }
        }
    }

    if (std.fs.path.isAbsolute(typed)) return fs.normalizeDirectoryPath(allocator, typed);
    const joined = try std.fs.path.resolve(allocator, &.{ state.domain.model.current_dir, typed });
    defer allocator.free(joined);
    return fs.normalizeDirectoryPath(allocator, joined);
}

fn selectedPathForClipboard(state: *const Scope) []const u8 {
    if (state.domain.model.selected_path) |selected_path| return selected_path;
    return state.domain.model.current_dir;
}

fn beginRenameEntry(state: *Scope, entry: BrowserEntry) !void {
    model_ops.clearRename(&state.domain.interaction);
    state.domain.interaction.rename_path = try allocator.dupe(u8, entry.path);
    state.domain.interaction.rename_input = .{};
    state.domain.interaction.rename_input.insertSlice(entry.name);
    state.domain.interaction.rename_input.selection_anchor = 0;
    state.domain.interaction.rename_input.cursor = state.domain.interaction.rename_input.len;
    state.domain.interaction.status_note = null;
}

fn cancelActiveRename(state: *Scope) bool {
    if (state.domain.interaction.rename_path == null) return false;
    model_ops.clearRename(&state.domain.interaction);
    state.domain.interaction.status_note = null;
    return true;
}

const RenameFinish = enum {
    inactive,
    closed,
    blocked,
};

fn validRenameFileName(name: []const u8) bool {
    return name.len > 0 and
        std.mem.indexOfScalar(u8, name, '/') == null and
        std.mem.indexOfScalar(u8, name, 0) == null;
}

fn commitActiveRename(state: *Scope) !RenameFinish {
    const old_path = state.domain.interaction.rename_path orelse return .inactive;
    const new_name = state.domain.interaction.rename_input.content();
    if (!validRenameFileName(new_name)) {
        state.domain.interaction.status_note = "File names cannot be empty or contain '/'.";
        return .blocked;
    }

    if (std.mem.eql(u8, new_name, std.fs.path.basename(old_path))) {
        model_ops.clearRename(&state.domain.interaction);
        state.domain.interaction.status_note = null;
        return .closed;
    }

    const new_path = try fs.joinPath(allocator, state.domain.model.current_dir, new_name);
    defer allocator.free(new_path);

    const io = state.session.io orelse {
        state.domain.interaction.status_note = "Unable to rename this file.";
        return .blocked;
    };
    if (std.Io.Dir.cwd().statFile(io, new_path, .{ .follow_symlinks = false })) |_| {
        state.domain.interaction.status_note = "A file with that name already exists.";
        return .blocked;
    } else |_| {}

    std.Io.Dir.renameAbsolute(old_path, new_path, io) catch {
        state.domain.interaction.status_note = "Unable to rename this file.";
        return .blocked;
    };

    model_ops.clearSelectedPaths(&state.domain.model);
    try model_ops.appendSelectedPathIfMissing(&state.domain.model, new_path);
    try model_ops.setSelectedPath(&state.domain.model, new_path);
    model_ops.freeOptionalOwnedSlice(&state.domain.model.last_click_path);
    state.domain.model.last_click_ms = 0;
    model_ops.clearRename(&state.domain.interaction);
    try fs.loadDirectoryEntries(filesystemScope(state));
    state.domain.interaction.status_note = "Renamed file.";
    return .closed;
}

fn currentPrimaryClickTimestampMs(io: std.Io) u64 {
    return getMonotonicNs(io) / std.time.ns_per_ms;
}

fn getMonotonicNs(io: std.Io) u64 {
    const value = std.Io.Clock.awake.now(io).nanoseconds;
    return if (value <= 0) 0 else @intCast(value);
}

fn isRepeatedEntryClick(state: *const Scope, entry: *const BrowserEntry, click_ms: u64) bool {
    const last_path = state.domain.model.last_click_path orelse return false;
    if (state.domain.model.last_click_ms == 0 or click_ms < state.domain.model.last_click_ms) return false;
    if (!std.mem.eql(u8, last_path, entry.path)) return false;
    return click_ms - state.domain.model.last_click_ms <= browser_double_click_time_ms;
}

fn syncSelectedPathsFromEvents(state: *Scope, selected: []const goop.ElementId) !void {
    model_ops.clearSelectedPaths(&state.domain.model);
    for (selected) |element| {
        if (ids.family(element) != .asset) continue;
        const path = state.domain.identities.path(element) orelse continue;
        if (model_ops.entryForPath(&state.domain.model, path) == null) continue;
        try model_ops.appendSelectedPathIfMissing(&state.domain.model, path);
    }
    try model_ops.syncPrimarySelection(&state.domain.model);
}

fn currentPathForElement(state: *const Scope, element: goop.ElementId) ?[]const u8 {
    const path = state.domain.identities.path(element) orelse return null;
    return switch (ids.family(element)) {
        .asset => if (model_ops.entryForPath(&state.domain.model, path) != null) path else null,
        .place => for (state.domain.model.places.items) |place| {
            if (std.mem.eql(u8, place.path, path)) break path;
        } else null,
        .folder, .breadcrumb => path,
        else => null,
    };
}

fn handleAssetDrop(state: *Scope, drop: goop.ControlDrop) !bool {
    if (ids.family(drop.source) != .asset) return false;
    const source_path = currentPathForElement(state, drop.source) orelse return false;

    if (drop.target == ids.commandElement(.toolbar, .up)) {
        const parent = try fs.parentPathAlloc(allocator, state.domain.model.current_dir);
        defer if (parent) |path| allocator.free(path);
        const parent_path = parent orelse return false;
        return fs.moveDropPathsToDirectory(filesystemScope(state), source_path, parent_path);
    }

    const target_path = currentPathForElement(state, drop.target) orelse return false;
    const target_dir = if (ids.family(drop.target) == .asset) blk: {
        if (std.meta.activeTag(drop.position) != .item) return false;
        const target_entry = model_ops.entryForPath(&state.domain.model, target_path) orelse return false;
        if (!target_entry.canEnter()) {
            state.domain.interaction.status_note = "Drop files on a directory.";
            return true;
        }
        break :blk target_entry.navigationPath();
    } else target_path;
    if (std.mem.eql(u8, source_path, target_dir)) return false;
    return fs.moveDropPathsToDirectory(filesystemScope(state), source_path, target_dir);
}

fn contextTargetEntry(state: *const Scope) ?*const BrowserEntry {
    const path = state.domain.interaction.context_target_path orelse return null;
    return model_ops.entryForPath(&state.domain.model, path);
}

fn showContextMenuForPath(state: *Scope, path: []const u8, x: f32, y: f32) !void {
    try model_ops.setContextTargetPath(&state.domain.interaction, path);
    state.domain.interaction.context_x = x;
    state.domain.interaction.context_y = y;
    state.domain.interaction.context_visible = true;
}

fn hideContextMenu(state: *Scope) void {
    state.domain.interaction.context_visible = false;
}

fn selectEntryForContextMenu(state: *Scope, entry_index: usize) !void {
    if (entry_index >= state.domain.model.entries.items.len) return;
    const entry = state.domain.model.entries.items[entry_index];
    if (!model_ops.isPathSelected(&state.domain.model, entry.path)) {
        model_ops.clearSelectedPaths(&state.domain.model);
        try model_ops.appendSelectedPathIfMissing(&state.domain.model, entry.path);
    }
    try model_ops.setSelectedPath(&state.domain.model, entry.path);
    state.domain.model.selection_anchor_index = entry_index;
}

fn openContextTarget(state: *Scope) !bool {
    const path = state.domain.interaction.context_target_path orelse return false;
    if (model_ops.entryForPath(&state.domain.model, path)) |entry| {
        if (!entry.canEnter()) return false;
        state.domain.interaction.status_note = null;
        return fs.setCurrentDirectory(filesystemScope(state), entry.navigationPath(), true);
    }
    state.domain.interaction.status_note = null;
    return fs.setCurrentDirectory(filesystemScope(state), path, true);
}

fn copyContextTargetPath(state: *Scope) !bool {
    const path = state.domain.interaction.context_target_path orelse return false;
    try transfer_ops.setClipboardText(&state.effects.transfer, path);
    state.domain.interaction.status_note = "Copied path to clipboard.";
    return false;
}

fn openContextLinkTarget(state: *Scope) !bool {
    const entry = contextTargetEntry(state) orelse return false;
    if (!entry.isSymlinkToDirectory()) return false;
    state.domain.interaction.status_note = null;
    return fs.setCurrentDirectory(filesystemScope(state), entry.target_path.?, true);
}

fn copyOrCutSelection(state: *Scope, action: FileClipboardAction) !bool {
    if (state.domain.model.selected_paths.items.len == 0) return false;
    try transfer_ops.setFileSelection(&state.effects.transfer, state.domain.model.selected_paths.items, action);
    state.domain.interaction.status_note = if (action == .cut) "Cut files to clipboard." else "Copied files to clipboard.";
    return false;
}

fn pasteFilesToDirectory(state: *Scope, target_dir: []const u8) !bool {
    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        model_ops.clearTrackedPaths(&paths);
        paths.deinit(allocator);
    }

    const action = (try transfer_ops.collectFilePaths(&state.effects.transfer, &paths)) orelse {
        state.domain.interaction.status_note = "Clipboard does not contain files.";
        return false;
    };

    const changed = switch (action) {
        .copy => try fs.copyPathsToDirectory(filesystemScope(state), paths.items, target_dir),
        .cut => try fs.movePathsToDirectory(filesystemScope(state), paths.items, target_dir),
    };
    if (changed and action == .cut and state.effects.transfer.clipboard_file_action != null) {
        transfer_ops.clearFilePayload(&state.effects.transfer);
    }
    return changed;
}

fn pasteContextTarget(state: *Scope) !bool {
    const path = state.domain.interaction.context_target_path orelse return false;
    const target_dir = if (model_ops.entryForPath(&state.domain.model, path)) |entry| blk: {
        if (!entry.canEnter()) return false;
        break :blk entry.navigationPath();
    } else path;
    return pasteFilesToDirectory(state, target_dir);
}

fn deleteSelection(state: *Scope) !bool {
    if (state.domain.model.selected_paths.items.len == 0) return false;
    return fs.deletePaths(filesystemScope(state), state.domain.model.selected_paths.items);
}

fn moveSelectionToParent(state: *Scope) !bool {
    if (!presentation.browserCommandEnabled(presentationInput(state), .move_parent)) return false;
    const parent = try fs.parentPathAlloc(allocator, state.domain.model.current_dir);
    defer if (parent) |path| allocator.free(path);
    const parent_path = parent orelse return false;
    return fs.movePathsToDirectory(filesystemScope(state), state.domain.model.selected_paths.items, parent_path);
}

fn beginRenameSelection(state: *Scope) !bool {
    if (!presentation.browserCommandEnabled(presentationInput(state), .rename)) return false;
    const entry = model_ops.selectedEntry(&state.domain.model) orelse return false;
    try beginRenameEntry(state, entry.*);
    return true;
}

fn runBrowserCommand(state: *Scope, command: BrowserCommand) !bool {
    switch (command) {
        .back => {
            state.domain.interaction.status_note = null;
            return fs.navigateBack(filesystemScope(state));
        },
        .forward => {
            state.domain.interaction.status_note = null;
            return fs.navigateForward(filesystemScope(state));
        },
        .up => {
            state.domain.interaction.status_note = null;
            return fs.navigateUp(filesystemScope(state));
        },
        .home => {
            if (fs.homePath(filesystemScope(state))) |home| {
                state.domain.interaction.status_note = null;
                return fs.setCurrentDirectory(filesystemScope(state), home, true);
            }
            return false;
        },
        .refresh => {
            state.domain.interaction.status_note = null;
            try fs.refreshCurrentDirectory(filesystemScope(state));
            return true;
        },
        .copy => return copyOrCutSelection(state, .copy),
        .cut => return copyOrCutSelection(state, .cut),
        .paste => return pasteFilesToDirectory(state, state.domain.model.current_dir),
        .delete => return deleteSelection(state),
        .rename => return false,
        .move_parent => return moveSelectionToParent(state),
        .copy_path => {
            try transfer_ops.setClipboardText(&state.effects.transfer, selectedPathForClipboard(state));
            state.domain.interaction.status_note = "Copied path to clipboard.";
            return false;
        },
        .open_link_target => {
            const entry = fs.selectedSymlinkDirectoryEntry(filesystemScope(state)) orelse return false;
            state.domain.interaction.status_note = null;
            return fs.setCurrentDirectory(filesystemScope(state), entry.target_path.?, true);
        },
        .quit => {
            state.session.running = false;
            return false;
        },
        .select_all => {
            state.domain.interaction.status_note = null;
            return model_ops.selectAllEntries(&state.domain.model);
        },
        .clear_selection => {
            state.domain.interaction.status_note = null;
            return model_ops.clearSelection(&state.domain.model);
        },
        .toggle_sidebar => {
            state.domain.model.show_sidebar = !state.domain.model.show_sidebar;
            return true;
        },
        .toggle_preview => {
            state.domain.model.show_preview = !state.domain.model.show_preview;
            return true;
        },
        .toggle_info => {
            state.domain.model.show_info = !state.domain.model.show_info;
            return true;
        },
        .toggle_status_bar => {
            state.domain.model.show_status_bar = !state.domain.model.show_status_bar;
            return true;
        },
        .view_list => {
            if (state.domain.model.view_mode == .list) return false;
            state.domain.model.view_mode = .list;
            return true;
        },
        .view_grid => {
            if (state.domain.model.view_mode == .grid) return false;
            state.domain.model.view_mode = .grid;
            return true;
        },
        .toggle_sort_directories => {
            state.domain.model.sort_directories_together = !state.domain.model.sort_directories_together;
            fs.sortDirectoryEntries(filesystemScope(state));
            model_ops.syncSelectionAnchor(&state.domain.model);
            return true;
        },
        .about => {
            state.domain.interaction.status_note = "goop files: a retained file manager component demo.";
            return false;
        },
    }
}

fn initializeBrowserState(state: *Scope) !void {
    const cwd = try fs.currentWorkingDirectoryAlloc(allocator, try stateIo(state));
    defer allocator.free(cwd);
    _ = try fs.setCurrentDirectory(filesystemScope(state), cwd, true);
    try fs.refreshPlaces(filesystemScope(state));
    try refreshPresentation(state);
}

// ── Font loading ──

// SESSION_BOUNDARY

pub fn init(
    state: *Scope,
    io: std.Io,
    environment: *const std.process.Environ.Map,
) !void {
    state.session.io = io;
    state.session.env = environment;
    state.viewport.ui_scale = envScale(environment, "GOOP_FILE_MANAGER_UI_SCALE", 1);
    errdefer {
        presentation_refresh.deinit(&state.domain.presentation);
        model_ops.deinit(&state.domain.model, &state.domain.interaction);
        transfer_ops.deinit(&state.effects.transfer);
    }
    try initializeBrowserState(state);
}

pub fn deinit(state: *Scope) void {
    presentation_refresh.deinit(&state.domain.presentation);
    model_ops.deinit(&state.domain.model, &state.domain.interaction);
    transfer_ops.deinit(&state.effects.transfer);
    state.* = undefined;
}

pub fn resize(viewport: *state_module.Viewport, width: u32, height: u32) void {
    viewport.logical_width = @max(width, 1);
    viewport.logical_height = @max(height, 1);
}

pub fn keyInput(
    interaction: *state_module.Interaction,
    key: desktop.input.Key,
    focused: ?goop.ElementId,
) void {
    interaction.ctrl_down = key.mods.ctrl;
    interaction.shift_down = key.mods.shift;
    if (key.state != .pressed) return;

    const focused_is_address = focused == ids.fixed(.address_input);
    const focused_is_rename = focused == ids.fixed(.rename_input);
    const focused_is_text_input = focused_is_address or focused_is_rename;

    switch (key.keycode) {
        .enter => {
            if (focused_is_rename) {
                interaction.rename_commit_requested = true;
            } else if (focused_is_address) {
                interaction.address_submit_requested = true;
            }
        },
        .escape => {
            if (interaction.rename_path != null) {
                interaction.rename_cancel_requested = true;
            } else if (!focused_is_text_input) {
                interaction.pending_command = .clear_selection;
            }
        },
        else => {},
    }
    if (!focused_is_text_input) {
        if (commands.resolveShortcut(key)) |command| interaction.pending_command = command;
    }
}

fn replaceTextInput(input: *goop.TextEditState, placeholder: []const u8, text: []const u8) void {
    input.* = .{ .placeholder = placeholder };
    input.insertSlice(text);
    input.cursor = input.len;
}

fn applySelectionOutput(state: *Scope, events: goop.ControlEvents, changed: goop.SelectionChanged) !bool {
    if (changed.element != ids.fixed(.asset_body_table) and
        changed.element != ids.fixed(.asset_grid))
    {
        return false;
    }
    if (state.domain.interaction.rename_path != null) {
        switch (try commitActiveRename(state)) {
            .inactive => {},
            .closed, .blocked => {},
        }
    }
    try syncSelectedPathsFromEvents(state, events.selection(changed));
    return true;
}

fn applyValueOutput(state: *Scope, changed: goop.ValueChanged) bool {
    if (changed.value == .scalar) {
        const value = changed.value.scalar;
        if (changed.element == ids.fixed(.nav_splitter)) {
            state.domain.model.nav_ratio = value;
            return true;
        }
        if (changed.element == ids.fixed(.detail_splitter)) {
            state.domain.model.detail_ratio = value;
            return true;
        }
        if (changed.element == ids.fixed(.preview_splitter)) {
            state.domain.model.preview_ratio = value;
            return true;
        }
    }
    if (changed.element == ids.fixed(.asset_header_table) and changed.value == .column_fraction) {
        const column = changed.value.column_fraction.column;
        if (column < state.domain.model.table_column_weights.len) {
            state.domain.model.table_column_weights[column] = changed.value.column_fraction.fraction;
            return true;
        }
    }
    return false;
}

fn applySortOutput(state: *Scope, changed: goop.SortChanged) bool {
    if (changed.element != ids.fixed(.asset_header_table)) return false;
    if (changed.column >= state.domain.model.table_column_weights.len) return false;
    const previous = state.domain.model.sort_column;
    state.domain.model.sort_column = @enumFromInt(changed.column);
    state.domain.model.sort_direction = switch (changed.direction) {
        .ascending => .ascending,
        .descending => .descending,
    };
    if (previous != state.domain.model.sort_column and state.domain.model.sort_column == .modified) {
        state.domain.model.sort_direction = .descending;
    }
    fs.sortDirectoryEntries(filesystemScope(state));
    model_ops.syncSelectionAnchor(&state.domain.model);
    return true;
}

fn applyScrollOutput(state: *Scope, changed: goop.ScrollChanged) void {
    if (changed.element == ids.fixed(.file_panel_scroll)) {
        state.domain.model.file_panel_scroll_y = changed.y;
    } else if (changed.element == ids.fixed(.sidebar_scroll)) {
        state.domain.model.sidebar_scroll_x = changed.x;
        state.domain.model.sidebar_scroll_y = changed.y;
    }
}

fn applyTextOutput(state: *Scope, events: goop.ControlEvents, changed: goop.TextChanged) !bool {
    const text = events.text(changed);
    if (changed.element == ids.fixed(.address_input)) {
        replaceTextInput(&state.domain.interaction.address_input, "Path", text);
        if (changed.committed) state.domain.interaction.address_submit_requested = true;
        return changed.committed;
    }
    if (changed.element == ids.fixed(.rename_input)) {
        replaceTextInput(&state.domain.interaction.rename_input, "", text);
        if (changed.committed) state.domain.interaction.rename_commit_requested = true;
        return changed.committed;
    }
    return false;
}

fn applyToggleOutput(state: *Scope, changed: goop.ToggleChanged) !bool {
    if (ids.family(changed.element) != .folder) return false;
    const path = currentPathForElement(state, changed.element) orelse return false;
    const expansion = model_ops.folderTreeExpansion(&state.domain.model, path);
    if (expansion == .partial) {
        return model_ops.setFolderTreePathExpanded(&state.domain.model, path, true);
    }
    return model_ops.setFolderTreePathExpanded(&state.domain.model, path, changed.value);
}

fn activateAsset(state: *Scope, element: goop.ElementId, io: std.Io) !bool {
    const path = currentPathForElement(state, element) orelse return false;
    const entry_index = model_ops.entryIndexForPath(&state.domain.model, path) orelse return false;
    const entry = state.domain.model.entries.items[entry_index];
    const click_ms = currentPrimaryClickTimestampMs(io);
    const repeated = isRepeatedEntryClick(state, &entry, click_ms);

    if (!model_ops.isPathSelected(&state.domain.model, path)) {
        try model_ops.applyEntrySelectionClick(
            &state.domain.model,
            &state.domain.interaction,
            entry_index,
        );
    }
    try model_ops.setLastClickPath(&state.domain.model, path);
    state.domain.model.last_click_ms = click_ms;
    if (repeated and entry.canEnter()) {
        return fs.setCurrentDirectory(filesystemScope(state), entry.navigationPath(), true);
    }
    return true;
}

fn applyActivation(
    state: *Scope,
    activation: goop.Activation,
    io: std.Io,
) !bool {
    if (activation.action) |action| {
        const command = ids.commandFromAction(action) orelse return false;
        hideContextMenu(state);
        if (command == .rename) return beginRenameSelection(state);
        return runBrowserCommand(state, command);
    }

    const element = activation.element;
    switch (ids.family(element)) {
        .asset => return activateAsset(state, element, io),
        .place, .breadcrumb => {
            const path = currentPathForElement(state, element) orelse return false;
            return fs.setCurrentDirectory(filesystemScope(state), path, true);
        },
        .folder => {
            const path = currentPathForElement(state, element) orelse return false;
            return fs.setCurrentDirectory(filesystemScope(state), path, true);
        },
        .fixed => {},
        else => return false,
    }

    if (element == ids.fixed(.address_go)) {
        state.domain.interaction.address_submit_requested = true;
        return false;
    }
    if (element == ids.fixed(.context_open)) {
        hideContextMenu(state);
        return openContextTarget(state);
    }
    if (element == ids.fixed(.context_paste)) {
        hideContextMenu(state);
        return pasteContextTarget(state);
    }
    if (element == ids.fixed(.context_rename)) {
        hideContextMenu(state);
        return beginRenameSelection(state);
    }
    if (element == ids.fixed(.context_copy_path)) {
        hideContextMenu(state);
        return copyContextTargetPath(state);
    }
    if (element == ids.fixed(.context_open_link_target)) {
        hideContextMenu(state);
        return openContextLinkTarget(state);
    }
    return false;
}

fn applySecondaryActivation(state: *Scope, activation: goop.SecondaryActivation) !bool {
    const element = activation.element;
    const path = switch (ids.family(element)) {
        .asset => blk: {
            const asset_path = currentPathForElement(state, element) orelse return false;
            const entry_index = model_ops.entryIndexForPath(&state.domain.model, asset_path) orelse return false;
            try selectEntryForContextMenu(state, entry_index);
            break :blk asset_path;
        },
        .place, .folder, .breadcrumb => currentPathForElement(state, element) orelse return false,
        .fixed => if (element == ids.fixed(.file_panel_scroll)) state.domain.model.current_dir else return false,
        else => return false,
    };
    try showContextMenuForPath(state, path, activation.x, activation.y);
    return true;
}

fn finishRequestedActions(state: *Scope) !bool {
    var rebuild = false;
    if (state.domain.interaction.rename_cancel_requested) {
        state.domain.interaction.rename_cancel_requested = false;
        rebuild = cancelActiveRename(state) or rebuild;
    }
    if (state.domain.interaction.rename_commit_requested) {
        state.domain.interaction.rename_commit_requested = false;
        switch (try commitActiveRename(state)) {
            .inactive => {},
            .closed, .blocked => rebuild = true,
        }
    }
    if (state.domain.interaction.pending_command) |command| {
        state.domain.interaction.pending_command = null;
        rebuild = try runBrowserCommand(state, command) or rebuild;
    }
    if (state.domain.interaction.address_submit_requested) {
        state.domain.interaction.address_submit_requested = false;
        const path = try addressInputPathAlloc(state);
        defer allocator.free(path);
        rebuild = try fs.setCurrentDirectory(filesystemScope(state), path, true) or rebuild;
    }
    return rebuild;
}

/// Reduce one borrowed semantic control batch into browser-domain state.
///
/// No tree, node handle, transient widget flag, renderer, or platform object is
/// visible at this boundary. The caller rebuilds the view when this returns
/// true.
pub fn update(state: *Scope, events: goop.ControlEvents, io: std.Io) !bool {
    var rebuild = false;
    for (events.items) |event| switch (event) {
        .activated => |activation| rebuild = try applyActivation(state, activation, io) or rebuild,
        .secondary_activated => |activation| rebuild = try applySecondaryActivation(state, activation) or rebuild,
        .selection_changed => |changed| rebuild = try applySelectionOutput(state, events, changed) or rebuild,
        .value_changed => |changed| rebuild = applyValueOutput(state, changed) or rebuild,
        .sort_changed => |changed| rebuild = applySortOutput(state, changed) or rebuild,
        .scroll_changed => |changed| applyScrollOutput(state, changed),
        .text_changed => |changed| rebuild = try applyTextOutput(state, events, changed) or rebuild,
        .toggle_changed => |changed| rebuild = try applyToggleOutput(state, changed) or rebuild,
        .drop => |drop| rebuild = try handleAssetDrop(state, drop) or rebuild,
    };

    rebuild = try finishRequestedActions(state) or rebuild;
    if (rebuild) try refreshPresentation(state);
    return rebuild;
}
