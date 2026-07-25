const std = @import("std");
const goop = @import("goop");

const types = @import("types.zig");
const state_module = @import("state.zig");
const transfer = @import("transfer.zig");
const style = @import("style.zig");

pub const uiScaleValue = style.uiScaleValue;
pub const uiPx = style.uiPx;
pub const uiEdgesAll = style.uiEdgesAll;
pub const uiEdgesSymmetric = style.uiEdgesSymmetric;
pub const fileManagerThemeForScale = style.fileManagerThemeForScale;
pub const fileManagerTheme = style.fileManagerTheme;
pub const fileManagerShellColor = style.fileManagerShellColor;
pub const fileManagerChromeColor = style.fileManagerChromeColor;
pub const fileManagerSurfaceColor = style.fileManagerSurfaceColor;
pub const fileManagerPanelHeaderColor = style.fileManagerPanelHeaderColor;
pub const fileManagerSidebarColor = style.fileManagerSidebarColor;
pub const fileManagerMutedTextColor = style.fileManagerMutedTextColor;
pub const fileManagerToolbarButtonStyle = style.fileManagerToolbarButtonStyle;
pub const fileManagerTextInputStyle = style.fileManagerTextInputStyle;
pub const fileManagerRenameInputStyle = style.fileManagerRenameInputStyle;
pub const fileManagerMenuBarStyle = style.fileManagerMenuBarStyle;
pub const fileManagerMenuStyle = style.fileManagerMenuStyle;
pub const fileManagerMenuRootButtonStyle = style.fileManagerMenuRootButtonStyle;
pub const fileManagerMenuPopupStyle = style.fileManagerMenuPopupStyle;
pub const fileManagerMenuItemStyle = style.fileManagerMenuItemStyle;
pub const fileManagerSectionLabelStyle = style.fileManagerSectionLabelStyle;
pub const fileManagerFolderTreeStyle = style.fileManagerFolderTreeStyle;
pub const fileManagerFolderTreeItemStyle = style.fileManagerFolderTreeItemStyle;
pub const fileManagerPlaceItemStyle = style.fileManagerPlaceItemStyle;
pub const fileManagerStatusTextStyle = style.fileManagerStatusTextStyle;
pub const fileManagerShellStyle = style.fileManagerShellStyle;
pub const fileManagerToolbarStyle = style.fileManagerToolbarStyle;
pub const fileManagerPaneStyle = style.fileManagerPaneStyle;
pub const fileManagerPaneHeaderStyle = style.fileManagerPaneHeaderStyle;
pub const fileManagerDetailContentStyle = style.fileManagerDetailContentStyle;
pub const fileManagerPreviewFrameStyle = style.fileManagerPreviewFrameStyle;
pub const fileManagerDetailTitleStyle = style.fileManagerDetailTitleStyle;
pub const fileManagerDetailMetaStyle = style.fileManagerDetailMetaStyle;
pub const fileManagerDetailHintStyle = style.fileManagerDetailHintStyle;
pub const fileManagerPreviewBodyStyle = style.fileManagerPreviewBodyStyle;
pub const fileManagerGutterStyle = style.fileManagerGutterStyle;

const preview = @import("preview.zig");

pub const SelectionPreview = preview.SelectionPreview;
pub const allocSelectionPreview = preview.allocSelectionPreview;
pub const appendDirectoryPreviewSummary = preview.appendDirectoryPreviewSummary;
pub const bytesLookLikeTextPreview = preview.bytesLookLikeTextPreview;

const fs = @import("fs.zig");

pub const homePath = fs.homePath;
pub const currentWorkingDirectoryAlloc = fs.currentWorkingDirectoryAlloc;
pub const normalizeDirectoryPath = fs.normalizeDirectoryPath;
pub const ensureDirectoryOpenable = fs.ensureDirectoryOpenable;
pub const joinPath = fs.joinPath;
pub const parentPathAlloc = fs.parentPathAlloc;
pub const pathHasDirectoryPrefix = fs.pathHasDirectoryPrefix;
pub const folderTreeChildLessThan = fs.folderTreeChildLessThan;
pub const clearFolderTreeChildren = fs.clearFolderTreeChildren;
pub const collectFolderTreeChildren = fs.collectFolderTreeChildren;
pub const folderTreeDirectoryHasChildren = fs.folderTreeDirectoryHasChildren;
pub const resolveSymlinkTargetAlloc = fs.resolveSymlinkTargetAlloc;
pub const fileTypeLabel = fs.fileTypeLabel;
pub const browserEntryKind = fs.browserEntryKind;
pub const unixSecondsFromTimestamp = fs.unixSecondsFromTimestamp;
pub const DecodedTimestamp = fs.DecodedTimestamp;
pub const decodeUnixSecondsUtc = fs.decodeUnixSecondsUtc;
pub const timestampMonthAbbrev = fs.timestampMonthAbbrev;
pub const formatTimestampCompactText = fs.formatTimestampCompactText;
pub const formatTimestampDetailText = fs.formatTimestampDetailText;
pub const formatSizeText = fs.formatSizeText;
pub const sortColumnLabel = fs.sortColumnLabel;
pub const sortDirectionLabel = fs.sortDirectionLabel;
pub const allocAssetEntryNameText = fs.allocAssetEntryNameText;
pub const currentUnixSeconds = fs.currentUnixSeconds;
pub const allocFormattedTimestamp = fs.allocFormattedTimestamp;
pub const allocAssetFormattedTimestamp = fs.allocAssetFormattedTimestamp;
pub const allocFormattedTimestampDetail = fs.allocFormattedTimestampDetail;
pub const allocFormattedSize = fs.allocFormattedSize;
pub const allocAssetFormattedSize = fs.allocAssetFormattedSize;
pub const appendPlaceIfDirectory = fs.appendPlaceIfDirectory;
pub const refreshPlaces = fs.refreshPlaces;
pub const sortFieldLess = fs.sortFieldLess;
pub const browserEntryLessThan = fs.browserEntryLessThan;
pub const sortDirectoryEntries = fs.sortDirectoryEntries;
pub const pathIsSameOrInside = fs.pathIsSameOrInside;
pub const moveDestinationPath = fs.moveDestinationPath;
pub const MovePreflight = fs.MovePreflight;
pub const preflightMovePathToDirectory = fs.preflightMovePathToDirectory;
pub const renamePathIntoDirectory = fs.renamePathIntoDirectory;
pub const movePathsToDirectory = fs.movePathsToDirectory;
pub const moveDropPathsToDirectory = fs.moveDropPathsToDirectory;
pub const preflightCopyPathToDirectory = fs.preflightCopyPathToDirectory;
pub const copyPathToDirectory = fs.copyPathToDirectory;
pub const copyPathAbsolute = fs.copyPathAbsolute;
pub const copyDirectoryAbsolute = fs.copyDirectoryAbsolute;
pub const copySymlinkAbsolute = fs.copySymlinkAbsolute;
pub const copyPathsToDirectory = fs.copyPathsToDirectory;
pub const deletePaths = fs.deletePaths;
pub const loadDirectoryEntries = fs.loadDirectoryEntries;
pub const setCurrentDirectory = fs.setCurrentDirectory;
pub const navigateBack = fs.navigateBack;
pub const navigateForward = fs.navigateForward;
pub const navigateUp = fs.navigateUp;
pub const refreshCurrentDirectory = fs.refreshCurrentDirectory;
pub const selectedSymlinkDirectoryEntry = fs.selectedSymlinkDirectoryEntry;
pub const entryForPath = fs.entryForPath;
pub const entryIndexForPath = fs.entryIndexForPath;

pub const allocator = std.heap.smp_allocator;
pub fn appendFileUri(
    buffer: *std.ArrayListUnmanaged(u8),
    path: []const u8,
    line_end: []const u8,
) !void {
    return transfer.appendFileUri(allocator, buffer, path, line_end);
}
pub fn appendClipboardPathFromFileUri(
    paths: *std.ArrayListUnmanaged([]u8),
    line: []const u8,
) !void {
    return transfer.appendClipboardPathFromFileUri(allocator, paths, line);
}
pub fn percentDecodeAlloc(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    return transfer.percentDecodeAlloc(alloc, text);
}
pub const uriPathByteCanPass = transfer.uriPathByteCanPass;
pub const hexValue = transfer.hexValue;

const view = @import("view.zig");

pub const captureFilePanelViewport = view.captureFilePanelViewport;
pub const captureSidebarScroll = view.captureSidebarScroll;
pub const browserViewportWidthEstimate = view.browserViewportWidthEstimate;
pub const browserViewportHeightEstimate = view.browserViewportHeightEstimate;
pub const browserVirtualGap = view.browserVirtualGap;
pub const browserListRowHeight = view.browserListRowHeight;
pub const browserGridColumnsForViewport = view.browserGridColumnsForViewport;
pub const browserVisibleCount = view.browserVisibleCount;
pub const browserVirtualChunkRows = view.browserVirtualChunkRows;
pub const browserVirtualRange = view.browserVirtualRange;
pub const browserListWindow = view.browserListWindow;
pub const browserGridWindow = view.browserGridWindow;

pub const addTextCell = view.addTextCell;
pub const addNameHeaderCell = view.addNameHeaderCell;
pub const addNameCell = view.addNameCell;

pub const detailTitleFontSizePx = view.detailTitleFontSizePx;
pub const detailCaptionFontSizePx = view.detailCaptionFontSizePx;
pub const previewBodyFontSizePx = view.previewBodyFontSizePx;
pub const clampDetailSplitterRatio = view.clampDetailSplitterRatio;
pub const browserBodyWidthPx = view.browserBodyWidthPx;
pub const inspectorPanelWidthPx = view.inspectorPanelWidthPx;
pub const detailTextWrapWidthPx = view.detailTextWrapWidthPx;
pub const measureDetailTextWidth = view.measureDetailTextWidth;
pub const isDetailWrapBoundary = view.isDetailWrapBoundary;
pub const flushDetailWrappedLine = view.flushDetailWrappedLine;
pub const appendDetailForcedWrappedToken = view.appendDetailForcedWrappedToken;
pub const appendDetailWrappedToken = view.appendDetailWrappedToken;
pub const wrapTextOwnedForWidth = view.wrapTextOwnedForWidth;
pub const wrapDetailTextOwned = view.wrapDetailTextOwned;
pub const allocUiDetailWrappedUtf8Lossy = view.allocUiDetailWrappedUtf8Lossy;
pub const allocUiWrappedOwnedText = view.allocUiWrappedOwnedText;
pub const addDetailText = view.addDetailText;
pub const addStyledDetailText = view.addStyledDetailText;

pub const applyAssetTableColumns = view.applyAssetTableColumns;
pub const buildListHeaderTable = view.buildListHeaderTable;
pub const buildListAssetView = view.buildListAssetView;
pub const buildGridAssetView = view.buildGridAssetView;
pub const buildAssetView = view.buildAssetView;
pub const rebuildAssetView = view.rebuildAssetView;
pub const refreshAssetViewportIfNeeded = view.refreshAssetViewportIfNeeded;

pub const browserEntryIconKind = view.browserEntryIconKind;
pub const browserEntryIconColor = view.browserEntryIconColor;
pub const browserEntryLinkBadgeColor = view.browserEntryLinkBadgeColor;
pub const iconRectInTableCell = view.iconRectInTableCell;
pub const iconRectInGridItem = view.iconRectInGridItem;
pub const symlinkBadgeRect = view.symlinkBadgeRect;
pub const appendEntryIconCommands = view.appendEntryIconCommands;
pub const composeFileBrowserPaintList = view.composeFileBrowserPaintList;
pub const debugWidgetKindName = view.debugWidgetKindName;
pub const entryNameTextRect = view.entryNameTextRect;
pub const pointInRect = view.pointInRect;
pub const pointHitsEntryNameText = view.pointHitsEntryNameText;
pub const pointHitsVisibleAssetItem = view.pointHitsVisibleAssetItem;
pub const pointInFilePanelBlankSpace = view.pointInFilePanelBlankSpace;
pub const collectRowCellWidths = view.collectRowCellWidths;
pub const sameWidths = view.sameWidths;
pub const debugLogFilePanelLayout = view.debugLogFilePanelLayout;

pub const addToolbarButton = view.addToolbarButton;
pub const addToolbarCommandButton = view.addToolbarCommandButton;
pub const addMenuCommandItem = view.addMenuCommandItem;
pub const addContextMenuItem = view.addContextMenuItem;
pub const buildContextPopup = view.buildContextPopup;

pub const folderTreeLabel = view.folderTreeLabel;
pub const addFolderTreeItem = view.addFolderTreeItem;
pub const buildFolderTreeBranch = view.buildFolderTreeBranch;
pub const buildFolderTree = view.buildFolderTree;

pub const buildWidgetTree = view.buildWidgetTree;

const BrowserSortColumn = types.BrowserSortColumn;
const BrowserSortDirection = types.BrowserSortDirection;
const BrowserViewMode = types.BrowserViewMode;
const BrowserCommand = types.BrowserCommand;

const FileClipboardAction = types.FileClipboardAction;

const widgetUserKind = types.widgetUserKind;
const widgetUserIndex = types.widgetUserIndex;

const BrowserPlace = types.BrowserPlace;
const BrowserEntry = types.BrowserEntry;
const browser_double_click_time_ms = types.browser_double_click_time_ms;
const folder_tree_max_visible_children = types.folder_tree_max_visible_children;

fn envFlag(env: *const std.process.Environ.Map, name: []const u8) bool {
    const raw = env.get(name) orelse return false;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    if (std.ascii.eqlIgnoreCase(value, "off")) return false;
    if (std.ascii.eqlIgnoreCase(value, "no")) return false;
    return true;
}

fn envScale(env: *const std.process.Environ.Map, name: []const u8, fallback: f32) f32 {
    const raw = env.get(name) orelse return fallback;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return fallback;
    const parsed = std.fmt.parseFloat(f32, value) catch return fallback;
    if (!std.math.isFinite(parsed) or parsed <= 0) return fallback;
    return parsed;
}

pub const State = state_module.State;

pub fn clipboard(state: *State) goop.Clipboard {
    return .{
        .ptr = state,
        .getTextFn = @ptrCast(&clipboardGetText),
        .setTextFn = @ptrCast(&clipboardSetText),
    };
}

fn clipboardGetText(pointer: *anyopaque) ?[]const u8 {
    const state: *State = @ptrCast(@alignCast(pointer));
    return if (state.transfer.clipboard_buf.items.len == 0)
        null
    else
        state.transfer.clipboard_buf.items;
}

fn clipboardSetText(pointer: *anyopaque, text: []const u8) void {
    const state: *State = @ptrCast(@alignCast(pointer));
    setClipboardSelection(state, text) catch {};
}

pub fn setClipboardSelection(state: *State, text: []const u8) !void {
    clearClipboardFilePayload(state);
    state.transfer.clipboard_buf.clearRetainingCapacity();
    try state.transfer.clipboard_buf.appendSlice(allocator, text);
}

pub fn clearClipboardFilePayload(state: *State) void {
    state.transfer.clipboard_uri_list_buf.clearRetainingCapacity();
    state.transfer.clipboard_gnome_files_buf.clearRetainingCapacity();
    state.transfer.clipboard_file_action = null;
}

pub fn setFileClipboardSelection(
    state: *State,
    paths: []const []const u8,
    action: FileClipboardAction,
) !void {
    if (paths.len == 0) return;
    state.transfer.clipboard_buf.clearRetainingCapacity();
    state.transfer.clipboard_uri_list_buf.clearRetainingCapacity();
    state.transfer.clipboard_gnome_files_buf.clearRetainingCapacity();
    state.transfer.clipboard_file_action = action;

    try state.transfer.clipboard_gnome_files_buf.appendSlice(
        allocator,
        if (action == .cut) "cut\n" else "copy\n",
    );
    for (paths) |path| {
        try appendFileUri(&state.transfer.clipboard_uri_list_buf, path, "\r\n");
        try appendFileUri(&state.transfer.clipboard_gnome_files_buf, path, "\n");
        try state.transfer.clipboard_buf.appendSlice(allocator, path);
        try state.transfer.clipboard_buf.append(allocator, '\n');
    }
}

pub fn browserViewModeLabel(mode: BrowserViewMode) []const u8 {
    return switch (mode) {
        .list => "list",
        .grid => "grid",
    };
}

pub fn scrollDebug(state: *const State, comptime fmt: []const u8, args: anytype) void {
    if (!state.view.layout.scroll_debug_enabled) return;
    std.debug.print("scroll-debug: " ++ fmt ++ "\n", args);
}

pub fn layoutDebug(state: *const State, comptime fmt: []const u8, args: anytype) void {
    if (!state.view.layout.layout_debug_enabled) return;
    std.debug.print("layout-debug: " ++ fmt ++ "\n", args);
}

pub fn freeOptionalOwnedSlice(buf: *?[]u8) void {
    if (buf.*) |slice| allocator.free(slice);
    buf.* = null;
}

fn clearUiStrings(state: *State) void {
    for (state.view.ui_strings.items) |text| allocator.free(text);
    state.view.ui_strings.clearRetainingCapacity();
}

fn clearAssetUiStrings(state: *State) void {
    for (state.view.asset_ui_strings.items) |text| allocator.free(text);
    state.view.asset_ui_strings.clearRetainingCapacity();
}

pub fn clearTrackedPaths(paths: *std.ArrayListUnmanaged([]u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.clearRetainingCapacity();
}

fn trackedPathIndex(paths: []const []u8, path: []const u8) ?usize {
    for (paths, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, path)) return index;
    }
    return null;
}

pub fn isFolderTreePathExpanded(state: *const State, path: []const u8) bool {
    return trackedPathIndex(state.view.assets.folder_tree_expanded_paths.items, path) != null;
}

const FolderTreeExpansion = types.FolderTreeExpansion;

pub fn folderTreeExpansion(state: *const State, path: []const u8) FolderTreeExpansion {
    if (isFolderTreePathExpanded(state, path)) return .expanded;
    if (std.mem.eql(u8, path, state.model.current_dir)) return .expanded;
    if (pathHasDirectoryPrefix(state.model.current_dir, path)) return .partial;
    return .collapsed;
}

pub fn setFolderTreePathExpanded(state: *State, path: []const u8, expanded: bool) !bool {
    if (trackedPathIndex(state.view.assets.folder_tree_expanded_paths.items, path)) |index| {
        if (expanded) return false;
        allocator.free(state.view.assets.folder_tree_expanded_paths.swapRemove(index));
        return true;
    }
    if (!expanded) return false;
    try state.view.assets.folder_tree_expanded_paths.append(allocator, try allocator.dupe(u8, path));
    return true;
}

pub fn preserveFolderTreeContextForNavigation(state: *State, next_dir: []const u8) !void {
    if (state.model.current_dir.len == 0) return;
    if (std.mem.eql(u8, state.model.current_dir, next_dir)) return;
    if (!pathHasDirectoryPrefix(state.model.current_dir, next_dir)) return;
    _ = try setFolderTreePathExpanded(state, state.model.current_dir, true);
}

pub fn shouldRenderFolderTreeChildForExpansion(
    state: *const State,
    parent_expansion: FolderTreeExpansion,
    index: usize,
    child_path: []const u8,
) bool {
    return switch (parent_expansion) {
        .collapsed => false,
        .partial => pathHasDirectoryPrefix(state.model.current_dir, child_path),
        .expanded => index < folder_tree_max_visible_children or
            pathHasDirectoryPrefix(state.model.current_dir, child_path) or
            isFolderTreePathExpanded(state, child_path),
    };
}

pub fn clearPlaces(state: *State) void {
    for (state.model.places.items) |place| allocator.free(place.path);
    state.model.places.clearRetainingCapacity();
}

pub fn clearSelectedPaths(state: *State) void {
    for (state.model.selected_paths.items) |path| allocator.free(path);
    state.model.selected_paths.clearRetainingCapacity();
}

pub fn clearEntries(state: *State) void {
    for (state.model.entries.items) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.path);
        if (entry.target_path) |target_path| allocator.free(target_path);
    }
    state.model.entries.clearRetainingCapacity();
}

fn clearAssetTracking(state: *State) void {
    state.view.assets.asset_view_root = null;
    state.view.assets.asset_table = null;
    state.view.assets.asset_table_body = null;
    state.view.assets.asset_grid = null;
    state.interaction.rename_input_handle = null;
    state.view.assets.asset_visible_start = 0;
    state.view.assets.asset_visible_end = 0;
    state.view.assets.asset_visible_columns = 0;
    state.view.assets.row_handles.clearRetainingCapacity();
    state.view.assets.name_cell_handles.clearRetainingCapacity();
    state.view.assets.grid_handles.clearRetainingCapacity();
    clearAssetUiStrings(state);
}

pub fn clearAssetBodyTracking(state: *State) void {
    state.view.assets.asset_view_root = null;
    state.view.assets.asset_table_body = null;
    state.view.assets.asset_grid = null;
    state.interaction.rename_input_handle = null;
    state.view.assets.asset_visible_start = 0;
    state.view.assets.asset_visible_end = 0;
    state.view.assets.asset_visible_columns = 0;
    state.view.assets.row_handles.clearRetainingCapacity();
    state.view.assets.name_cell_handles.clearRetainingCapacity();
    state.view.assets.grid_handles.clearRetainingCapacity();
    clearAssetUiStrings(state);
}

pub fn clearUiTracking(state: *State) void {
    state.view.chrome.ui_root = null;
    state.view.chrome.btn_back = null;
    state.view.chrome.btn_forward = null;
    state.view.chrome.btn_up = null;
    state.view.chrome.btn_home = null;
    state.view.chrome.btn_refresh = null;
    state.view.chrome.btn_toggle_sidebar = null;
    state.view.chrome.btn_toggle_preview = null;
    state.view.chrome.btn_toggle_info = null;
    state.view.chrome.btn_list_view = null;
    state.view.chrome.btn_grid_view = null;
    state.view.chrome.btn_address_go = null;
    state.view.chrome.address_input_handle = null;
    state.view.chrome.nav_splitter = null;
    state.view.chrome.detail_splitter = null;
    state.view.chrome.preview_splitter = null;
    state.view.chrome.sidebar_scroll = null;
    state.view.chrome.file_panel_scroll = null;
    state.view.menus.file.refresh = null;
    state.view.menus.file.button = null;
    state.view.menus.edit.button = null;
    state.view.menus.view.button = null;
    state.view.menus.go.button = null;
    state.view.menus.help.button = null;
    state.view.menus.file.popup = null;
    state.view.menus.edit.popup = null;
    state.view.menus.view.popup = null;
    state.view.menus.go.popup = null;
    state.view.menus.help.popup = null;
    state.view.menus.file.copy_path = null;
    state.view.menus.file.open_target = null;
    state.view.menus.file.quit = null;
    state.view.menus.edit.copy = null;
    state.view.menus.edit.cut = null;
    state.view.menus.edit.paste = null;
    state.view.menus.edit.delete = null;
    state.view.menus.edit.rename = null;
    state.view.menus.edit.move_parent = null;
    state.view.menus.edit.select_all = null;
    state.view.menus.edit.clear_selection = null;
    state.view.menus.view.sidebar = null;
    state.view.menus.view.preview = null;
    state.view.menus.view.info = null;
    state.view.menus.view.status_bar = null;
    state.view.menus.view.list = null;
    state.view.menus.view.grid = null;
    state.view.menus.view.sort_directories = null;
    state.view.menus.go.back = null;
    state.view.menus.go.forward = null;
    state.view.menus.go.up = null;
    state.view.menus.go.home = null;
    state.view.menus.help.about = null;
    state.view.context_menu.context_popup = null;
    state.view.context_menu.context_open = null;
    state.view.context_menu.context_copy = null;
    state.view.context_menu.context_cut = null;
    state.view.context_menu.context_paste = null;
    state.view.context_menu.context_delete = null;
    state.view.context_menu.context_rename = null;
    state.view.context_menu.context_move_parent = null;
    state.view.context_menu.context_copy_path = null;
    state.view.context_menu.context_open_link_target = null;
    state.interaction.rename_input_handle = null;
    clearAssetTracking(state);
    state.view.assets.place_handles.clearRetainingCapacity();
    state.view.assets.folder_tree_handles.clearRetainingCapacity();
    state.view.assets.breadcrumb_handles.clearRetainingCapacity();
    clearUiStrings(state);
    clearTrackedPaths(&state.view.assets.folder_tree_paths);
    clearTrackedPaths(&state.view.assets.breadcrumb_paths);
}

pub fn deinitBrowserState(state: *State) void {
    clearUiTracking(state);
    clearEntries(state);
    clearPlaces(state);
    clearSelectedPaths(state);
    for (state.model.history.items) |path| allocator.free(path);
    state.model.history.deinit(allocator);
    state.model.places.deinit(allocator);
    state.model.entries.deinit(allocator);
    state.model.selected_paths.deinit(allocator);
    state.view.assets.place_handles.deinit(allocator);
    state.view.assets.folder_tree_handles.deinit(allocator);
    state.view.assets.breadcrumb_handles.deinit(allocator);
    state.view.assets.folder_tree_paths.deinit(allocator);
    clearTrackedPaths(&state.view.assets.folder_tree_expanded_paths);
    state.view.assets.folder_tree_expanded_paths.deinit(allocator);
    state.view.assets.breadcrumb_paths.deinit(allocator);
    state.view.assets.row_handles.deinit(allocator);
    state.view.assets.name_cell_handles.deinit(allocator);
    state.view.assets.grid_handles.deinit(allocator);
    state.view.ui_strings.deinit(allocator);
    state.view.asset_ui_strings.deinit(allocator);
    state.view.composed_paint_commands.deinit(allocator);
    if (state.model.current_dir.len > 0) allocator.free(state.model.current_dir);
    state.model.current_dir = &.{};
    freeOptionalOwnedSlice(&state.model.selected_path);
    freeOptionalOwnedSlice(&state.model.last_click_path);
    freeOptionalOwnedSlice(&state.interaction.context_target_path);
    freeOptionalOwnedSlice(&state.interaction.rename_path);
}

pub fn trackUiString(state: *State, text: []u8) ![]const u8 {
    try state.view.ui_strings.append(allocator, text);
    return text;
}

fn trackAssetUiString(state: *State, text: []u8) ![]const u8 {
    try state.view.asset_ui_strings.append(allocator, text);
    return text;
}

pub fn allocUiString(state: *State, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return trackUiString(state, try std.fmt.allocPrint(allocator, fmt, args));
}

pub fn allocAssetUiString(state: *State, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return trackAssetUiString(state, try std.fmt.allocPrint(allocator, fmt, args));
}

pub fn allocUtf8LossyOwned(bytes: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.unicode.fmtUtf8(bytes)});
}

pub fn allocUiUtf8Lossy(state: *State, bytes: []const u8) ![]const u8 {
    return trackUiString(state, try allocUtf8LossyOwned(bytes));
}

fn allocAssetUiUtf8Lossy(state: *State, bytes: []const u8) ![]const u8 {
    return trackAssetUiString(state, try allocUtf8LossyOwned(bytes));
}

fn allocUiEllipsizedUtf8Lossy(state: *State, bytes: []const u8, max_width: f32, font_size: f32) ![]const u8 {
    const full = try allocUtf8LossyOwned(bytes);
    errdefer allocator.free(full);

    const text_ctx = state.runtime.text_measure_ctx;
    if (text_ctx == null or goop.layout.measureTextDimensions(full, font_size, text_ctx).width <= max_width) {
        return trackUiString(state, full);
    }

    const ellipsis = "...";
    const ellipsis_width = goop.layout.measureTextDimensions(ellipsis, font_size, text_ctx).width;
    if (ellipsis_width >= max_width) {
        allocator.free(full);
        return allocUiString(state, "{s}", .{ellipsis});
    }

    var codepoint_ends: std.ArrayListUnmanaged(usize) = .empty;
    defer codepoint_ends.deinit(allocator);

    var total_bytes: usize = 0;
    var utf8_view = std.unicode.Utf8View.init(full) catch unreachable;
    var it = utf8_view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        total_bytes += slice.len;
        try codepoint_ends.append(allocator, total_bytes);
    }

    var keep = codepoint_ends.items.len;
    while (keep > 0) : (keep -= 1) {
        const prefix_len = codepoint_ends.items[keep - 1];
        const prefix_width = goop.layout.measureTextDimensions(full[0..prefix_len], font_size, text_ctx).width;
        if (prefix_width + ellipsis_width <= max_width) {
            const truncated = try std.fmt.allocPrint(allocator, "{s}{s}", .{ full[0..prefix_len], ellipsis });
            allocator.free(full);
            return trackUiString(state, truncated);
        }
    }

    allocator.free(full);
    return allocUiString(state, "{s}", .{ellipsis});
}

pub fn allocAssetUiEllipsizedUtf8Lossy(state: *State, bytes: []const u8, max_width: f32, font_size: f32) ![]const u8 {
    const full = try allocUtf8LossyOwned(bytes);
    errdefer allocator.free(full);

    const text_ctx = state.runtime.text_measure_ctx;
    if (text_ctx == null or goop.layout.measureTextDimensions(full, font_size, text_ctx).width <= max_width) {
        return trackAssetUiString(state, full);
    }

    const ellipsis = "...";
    const ellipsis_width = goop.layout.measureTextDimensions(ellipsis, font_size, text_ctx).width;
    if (ellipsis_width >= max_width) {
        allocator.free(full);
        return allocAssetUiString(state, "{s}", .{ellipsis});
    }

    var codepoint_ends: std.ArrayListUnmanaged(usize) = .empty;
    defer codepoint_ends.deinit(allocator);

    var total_bytes: usize = 0;
    var utf8_view = std.unicode.Utf8View.init(full) catch unreachable;
    var it = utf8_view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        total_bytes += slice.len;
        try codepoint_ends.append(allocator, total_bytes);
    }

    var keep = codepoint_ends.items.len;
    while (keep > 0) : (keep -= 1) {
        const prefix_len = codepoint_ends.items[keep - 1];
        const prefix_width = goop.layout.measureTextDimensions(full[0..prefix_len], font_size, text_ctx).width;
        if (prefix_width + ellipsis_width <= max_width) {
            const truncated = try std.fmt.allocPrint(allocator, "{s}{s}", .{ full[0..prefix_len], ellipsis });
            allocator.free(full);
            return trackAssetUiString(state, truncated);
        }
    }

    allocator.free(full);
    return allocAssetUiString(state, "{s}", .{ellipsis});
}

pub fn stateIo(state: *const State) !std.Io {
    return state.runtime.io orelse error.IoUnavailable;
}

fn setAddressInputText(state: *State, text: []const u8) void {
    state.view.address_input = .{ .placeholder = "Path" };
    state.view.address_input.insertSlice(text);
    state.view.address_input.cursor = state.view.address_input.len;
}

pub fn syncAddressInputToCurrentDir(state: *State) void {
    setAddressInputText(state, state.model.current_dir);
}

fn syncAddressInputFromWidget(state: *State, ctx: *goop.Context) void {
    const handle = state.view.chrome.address_input_handle orelse return;
    if (!ctx.tree.isAlive(handle)) return;
    if (ctx.tree.getConst(handle).kind != .text_input) return;
    state.view.address_input = ctx.tree.getConst(handle).kind.text_input;
}

fn syncRenameInputFromWidget(state: *State, ctx: *goop.Context) void {
    const handle = state.interaction.rename_input_handle orelse return;
    if (!ctx.tree.isAlive(handle)) return;
    if (ctx.tree.getConst(handle).kind != .text_input) return;
    state.interaction.rename_input = ctx.tree.getConst(handle).kind.text_input;
}

fn addressInputPathAlloc(state: *const State) ![]u8 {
    const typed = std.mem.trim(u8, state.view.address_input.content(), " \t\r\n");
    if (typed.len == 0) return allocator.dupe(u8, state.model.current_dir);

    if (typed[0] == '~') {
        if (typed.len == 1 or typed[1] == '/') {
            if (homePath(state)) |home| {
                if (typed.len == 1) return normalizeDirectoryPath(allocator, home);
                const joined = try std.fs.path.resolve(allocator, &.{ home, typed[2..] });
                defer allocator.free(joined);
                return normalizeDirectoryPath(allocator, joined);
            }
        }
    }

    if (std.fs.path.isAbsolute(typed)) return normalizeDirectoryPath(allocator, typed);
    const joined = try std.fs.path.resolve(allocator, &.{ state.model.current_dir, typed });
    defer allocator.free(joined);
    return normalizeDirectoryPath(allocator, joined);
}

fn selectedPathForClipboard(state: *const State) []const u8 {
    if (state.model.selected_path) |selected_path| return selected_path;
    return state.model.current_dir;
}

pub fn isPathSelected(state: *const State, path: []const u8) bool {
    for (state.model.selected_paths.items) |selected| {
        if (std.mem.eql(u8, selected, path)) return true;
    }
    return false;
}

pub fn selectedPathCount(state: *const State) usize {
    return state.model.selected_paths.items.len;
}

pub fn selectedEntryExists(state: *const State, path: []const u8) bool {
    for (state.model.entries.items) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return true;
    }
    return false;
}

pub fn setSelectedPath(state: *State, path: ?[]const u8) !void {
    freeOptionalOwnedSlice(&state.model.selected_path);
    if (path) |value| state.model.selected_path = try allocator.dupe(u8, value);
}

fn setContextTargetPath(state: *State, path: ?[]const u8) !void {
    freeOptionalOwnedSlice(&state.interaction.context_target_path);
    if (path) |value| state.interaction.context_target_path = try allocator.dupe(u8, value);
}

fn setLastClickPath(state: *State, path: ?[]const u8) !void {
    freeOptionalOwnedSlice(&state.model.last_click_path);
    if (path) |value| state.model.last_click_path = try allocator.dupe(u8, value);
}

fn clearRenameState(state: *State) void {
    freeOptionalOwnedSlice(&state.interaction.rename_path);
    state.interaction.rename_input = .{};
    state.interaction.rename_input_handle = null;
    state.interaction.rename_commit_requested = false;
    state.interaction.rename_cancel_requested = false;
}

pub fn isRenamingPath(state: *const State, path: []const u8) bool {
    const rename_path = state.interaction.rename_path orelse return false;
    return std.mem.eql(u8, rename_path, path);
}

pub fn beginRenameEntry(state: *State, ctx: *goop.Context, entry: BrowserEntry) !void {
    clearRenameState(state);
    state.interaction.rename_path = try allocator.dupe(u8, entry.path);
    state.interaction.rename_input = .{};
    state.interaction.rename_input.insertSlice(entry.name);
    state.interaction.rename_input.selection_anchor = 0;
    state.interaction.rename_input.cursor = state.interaction.rename_input.len;
    state.interaction.status_note = null;
    ctx.invalidate();
}

fn cancelActiveRename(state: *State) bool {
    if (state.interaction.rename_path == null) return false;
    clearRenameState(state);
    state.interaction.status_note = null;
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

fn commitActiveRename(state: *State) !RenameFinish {
    const old_path = state.interaction.rename_path orelse return .inactive;
    const new_name = state.interaction.rename_input.content();
    if (!validRenameFileName(new_name)) {
        state.interaction.status_note = "File names cannot be empty or contain '/'.";
        return .blocked;
    }

    if (std.mem.eql(u8, new_name, std.fs.path.basename(old_path))) {
        clearRenameState(state);
        state.interaction.status_note = null;
        return .closed;
    }

    const new_path = try joinPath(allocator, state.model.current_dir, new_name);
    defer allocator.free(new_path);

    const io = state.runtime.io orelse {
        state.interaction.status_note = "Unable to rename this file.";
        return .blocked;
    };
    if (std.Io.Dir.cwd().statFile(io, new_path, .{ .follow_symlinks = false })) |_| {
        state.interaction.status_note = "A file with that name already exists.";
        return .blocked;
    } else |_| {}

    std.Io.Dir.renameAbsolute(old_path, new_path, io) catch {
        state.interaction.status_note = "Unable to rename this file.";
        return .blocked;
    };

    clearSelectedPaths(state);
    try appendSelectedPathIfMissing(state, new_path);
    try setSelectedPath(state, new_path);
    freeOptionalOwnedSlice(&state.model.last_click_path);
    state.model.last_click_ms = 0;
    clearRenameState(state);
    try loadDirectoryEntries(state);
    state.interaction.status_note = "Renamed file.";
    return .closed;
}

fn currentPrimaryClickTimestampMs(ctx: *const goop.Context, io: std.Io) u64 {
    const event_ms = ctx.frame().last_primary_press_ms;
    if (event_ms != 0) return event_ms;
    return getMonotonicNs(io) / std.time.ns_per_ms;
}

fn getMonotonicNs(io: std.Io) u64 {
    const value = std.Io.Clock.awake.now(io).nanoseconds;
    return if (value <= 0) 0 else @intCast(value);
}

fn isRepeatedEntryClick(state: *const State, entry: *const BrowserEntry, click_ms: u64) bool {
    const last_path = state.model.last_click_path orelse return false;
    if (state.model.last_click_ms == 0 or click_ms < state.model.last_click_ms) return false;
    if (!std.mem.eql(u8, last_path, entry.path)) return false;
    return click_ms - state.model.last_click_ms <= browser_double_click_time_ms;
}

pub fn syncPrimarySelection(state: *State) !void {
    if (state.model.selected_path) |selected_path| {
        if (isPathSelected(state, selected_path)) return;
        freeOptionalOwnedSlice(&state.model.selected_path);
    }

    if (state.model.selected_paths.items.len > 0) {
        try setSelectedPath(state, state.model.selected_paths.items[0]);
    }
}

fn selectedPathIndex(state: *const State, path: []const u8) ?usize {
    for (state.model.selected_paths.items, 0..) |selected, index| {
        if (std.mem.eql(u8, selected, path)) return index;
    }
    return null;
}

pub fn appendSelectedPathIfMissing(state: *State, path: []const u8) !void {
    if (selectedPathIndex(state, path) != null) return;
    try state.model.selected_paths.append(allocator, try allocator.dupe(u8, path));
}

fn removeSelectedPath(state: *State, path: []const u8) bool {
    const index = selectedPathIndex(state, path) orelse return false;
    allocator.free(state.model.selected_paths.orderedRemove(index));
    return true;
}

pub fn syncSelectionAnchor(state: *State) void {
    state.model.selection_anchor_index = selectedEntryIndex(state);
}

fn applyEntrySelectionClick(state: *State, entry_index: usize) !void {
    if (entry_index >= state.model.entries.items.len) return;
    const entry = state.model.entries.items[entry_index];

    if (state.interaction.shift_down) {
        const anchor = state.model.selection_anchor_index orelse entry_index;
        if (!state.interaction.ctrl_down) clearSelectedPaths(state);

        const start = @min(anchor, entry_index);
        const end = @max(anchor, entry_index);
        for (start..end + 1) |index| {
            try appendSelectedPathIfMissing(state, state.model.entries.items[index].path);
        }
        state.model.selection_anchor_index = anchor;
    } else if (state.interaction.ctrl_down) {
        state.model.selection_anchor_index = entry_index;
        if (!removeSelectedPath(state, entry.path)) {
            try appendSelectedPathIfMissing(state, entry.path);
        }
    } else {
        clearSelectedPaths(state);
        try appendSelectedPathIfMissing(state, entry.path);
        state.model.selection_anchor_index = entry_index;
    }

    if (isPathSelected(state, entry.path)) {
        try setSelectedPath(state, entry.path);
    } else {
        try syncPrimarySelection(state);
    }
}

pub fn syncSelectedPathsFromTable(state: *State, ctx: *goop.Context, handle: goop.NodeHandle) !void {
    clearSelectedPaths(state);

    var row_index: u16 = 0;
    var iter = ctx.tree.children(handle);
    while (iter.next()) |child| {
        const v = ctx.tree.node(child) orelse continue;
        if (v.kind != .table_row or v.kind.table_row.header) continue;
        if (v.kind.table_row.selected) {
            const user_id = ctx.tree.userId(child);
            const entry_index = assetEntryIndexFromUserId(state, user_id) orelse state.view.assets.asset_visible_start + row_index;
            if (entry_index < state.model.entries.items.len) {
                try state.model.selected_paths.append(allocator, try allocator.dupe(u8, state.model.entries.items[entry_index].path));
            }
        }
        row_index += 1;
    }

    try syncPrimarySelection(state);
}

pub fn syncSelectedPathsFromGrid(state: *State, ctx: *goop.Context, handle: goop.NodeHandle) !void {
    clearSelectedPaths(state);

    var item_index: u16 = 0;
    var iter = ctx.tree.children(handle);
    while (iter.next()) |child| {
        const v = ctx.tree.node(child) orelse continue;
        if (v.kind != .grid_item) continue;
        if (v.kind.grid_item.selected) {
            const user_id = ctx.tree.userId(child);
            const entry_index = assetEntryIndexFromUserId(state, user_id) orelse state.view.assets.asset_visible_start + item_index;
            if (entry_index < state.model.entries.items.len) {
                try state.model.selected_paths.append(allocator, try allocator.dupe(u8, state.model.entries.items[entry_index].path));
            }
        }
        item_index += 1;
    }

    try syncPrimarySelection(state);
}

fn assetEntryIndexFromUserId(state: *const State, user_id: u64) ?usize {
    if (widgetUserKind(user_id) != .asset_entry) return null;
    const entry_index = widgetUserIndex(user_id);
    if (entry_index < state.model.entries.items.len) return entry_index;
    return null;
}

fn borrowedDropDestinationPathForUserId(state: *const State, user_id: u64) ?[]const u8 {
    const index = widgetUserIndex(user_id);
    return switch (widgetUserKind(user_id)) {
        .place => if (index < state.model.places.items.len) state.model.places.items[index].path else null,
        .folder_tree => if (index < state.view.assets.folder_tree_paths.items.len) state.view.assets.folder_tree_paths.items[index] else null,
        .breadcrumb => if (index < state.view.assets.breadcrumb_paths.items.len) state.view.assets.breadcrumb_paths.items[index] else null,
        else => null,
    };
}

fn handleAssetTableDrop(state: *State, ctx: *const goop.Context, drop: goop.ContainerDrop) !bool {
    if (drop.position != .item) return false;
    const source_index = assetEntryIndexFromUserId(state, ctx.tree.userId(drop.source)) orelse return false;
    const target_index = assetEntryIndexFromUserId(state, ctx.tree.userId(drop.target)) orelse return false;
    if (source_index == target_index) return false;

    const source_path = state.model.entries.items[source_index].path;
    const target_entry = state.model.entries.items[target_index];
    if (!target_entry.canEnter()) {
        state.interaction.status_note = "Drop files on a directory.";
        return true;
    }

    return moveDropPathsToDirectory(state, source_path, target_entry.navigationPath());
}

fn handleAssetGridDrop(state: *State, ctx: *const goop.Context, drop: goop.ContainerDrop) !bool {
    if (drop.position != .item) return false;
    const source_index = assetEntryIndexFromUserId(state, ctx.tree.userId(drop.source)) orelse return false;
    const target_index = assetEntryIndexFromUserId(state, ctx.tree.userId(drop.target)) orelse return false;
    if (source_index == target_index) return false;

    const source_path = state.model.entries.items[source_index].path;
    const target_entry = state.model.entries.items[target_index];
    if (!target_entry.canEnter()) {
        state.interaction.status_note = "Drop files on a directory.";
        return true;
    }

    return moveDropPathsToDirectory(state, source_path, target_entry.navigationPath());
}

fn handleAssetWidgetDrop(state: *State, ctx: *const goop.Context, drop: goop.WidgetDrop) !bool {
    const source_index = assetEntryIndexFromUserId(state, ctx.tree.userId(drop.source)) orelse return false;
    const source_path = state.model.entries.items[source_index].path;

    const target_user_id = ctx.tree.userId(drop.target);
    if (widgetUserKind(target_user_id) == .toolbar_up) {
        const parent = try parentPathAlloc(allocator, state.model.current_dir);
        defer if (parent) |path| allocator.free(path);
        const parent_path = parent orelse return false;
        return moveDropPathsToDirectory(state, source_path, parent_path);
    }

    const target_dir = borrowedDropDestinationPathForUserId(state, target_user_id) orelse return false;
    return moveDropPathsToDirectory(state, source_path, target_dir);
}

fn selectedEntryIndex(state: *const State) ?usize {
    const selected_path = state.model.selected_path orelse return null;
    for (state.model.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.path, selected_path)) return index;
    }
    return null;
}

pub fn selectedEntry(state: *const State) ?*const BrowserEntry {
    const index = selectedEntryIndex(state) orelse return null;
    return &state.model.entries.items[index];
}

pub fn clearSelectionState(state: *State) bool {
    if (state.model.selected_paths.items.len == 0 and state.model.selected_path == null) return false;
    clearSelectedPaths(state);
    freeOptionalOwnedSlice(&state.model.selected_path);
    freeOptionalOwnedSlice(&state.model.last_click_path);
    state.model.last_click_ms = 0;
    state.model.selection_anchor_index = null;
    return true;
}

fn selectAllEntries(state: *State) !bool {
    if (state.model.entries.items.len == 0) return false;
    if (state.model.selected_paths.items.len == state.model.entries.items.len) return false;

    clearSelectedPaths(state);
    for (state.model.entries.items) |entry| {
        try state.model.selected_paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    try setSelectedPath(state, state.model.entries.items[0].path);
    syncSelectionAnchor(state);
    freeOptionalOwnedSlice(&state.model.last_click_path);
    state.model.last_click_ms = 0;
    return true;
}

fn contextTargetEntry(state: *const State) ?*const BrowserEntry {
    const path = state.interaction.context_target_path orelse return null;
    return entryForPath(state, path);
}

pub fn contextOpenEnabled(state: *const State) bool {
    const path = state.interaction.context_target_path orelse return false;
    const entry = entryForPath(state, path) orelse return true;
    return entry.canEnter();
}

pub fn contextCopyPathEnabled(state: *const State) bool {
    return state.interaction.context_target_path != null;
}

pub fn contextOpenLinkTargetEnabled(state: *const State) bool {
    const entry = contextTargetEntry(state) orelse return false;
    return entry.isSymlinkToDirectory();
}

fn contextClickPosition(state: *const State, ctx: *const goop.Context) struct { x: f32, y: f32 } {
    if (ctx.frame().last_secondary_click) |click| {
        return .{ .x = click.x, .y = click.y };
    }
    return .{ .x = state.interaction.mouse_x, .y = state.interaction.mouse_y };
}

fn showContextMenuForPath(state: *State, ctx: *goop.Context, path: []const u8) !void {
    setTopMenuPopupVisible(state, ctx, null);
    try setContextTargetPath(state, path);
    const position = contextClickPosition(state, ctx);
    state.interaction.context_x = position.x;
    state.interaction.context_y = position.y;
    state.interaction.context_visible = true;
    ctx.invalidate();
}

fn hideContextMenu(state: *State, ctx: *goop.Context) void {
    state.interaction.context_visible = false;
    if (state.view.context_menu.context_popup) |popup| {
        if (ctx.tree.isAlive(popup) and ctx.tree.getConst(popup).kind == .popup) {
            if (ctx.mutateKind(popup)) |__k| {
                __k.popup.visible = false;
            }
        }
    }
    ctx.invalidate();
}

fn syncContextPopupVisibleFromWidget(state: *State, ctx: *const goop.Context) void {
    const popup = state.view.context_menu.context_popup orelse return;
    if (!ctx.tree.isAlive(popup) or ctx.tree.getConst(popup).kind != .popup) return;
    state.interaction.context_visible = ctx.tree.getConst(popup).kind.popup.visible;
}

fn selectEntryForContextMenu(state: *State, entry_index: usize) !void {
    if (entry_index >= state.model.entries.items.len) return;
    const entry = state.model.entries.items[entry_index];
    if (!isPathSelected(state, entry.path)) {
        clearSelectedPaths(state);
        try appendSelectedPathIfMissing(state, entry.path);
    }
    try setSelectedPath(state, entry.path);
    state.model.selection_anchor_index = entry_index;
}

fn openContextTarget(state: *State) !bool {
    const path = state.interaction.context_target_path orelse return false;
    if (entryForPath(state, path)) |entry| {
        if (!entry.canEnter()) return false;
        state.interaction.status_note = null;
        return setCurrentDirectory(state, entry.navigationPath(), true);
    }
    state.interaction.status_note = null;
    return setCurrentDirectory(state, path, true);
}

fn copyContextTargetPath(state: *State) !bool {
    const path = state.interaction.context_target_path orelse return false;
    try setClipboardSelection(state, path);
    state.interaction.status_note = "Copied path to clipboard.";
    return false;
}

fn openContextLinkTarget(state: *State) !bool {
    const entry = contextTargetEntry(state) orelse return false;
    if (!entry.isSymlinkToDirectory()) return false;
    state.interaction.status_note = null;
    return setCurrentDirectory(state, entry.target_path.?, true);
}

pub fn selectionFileCommandEnabled(state: *const State) bool {
    return state.model.selected_paths.items.len > 0;
}

pub fn renameSelectionEnabled(state: *const State) bool {
    return state.model.selected_paths.items.len == 1 and selectedEntry(state) != null;
}

pub fn moveSelectionToParentEnabled(state: *const State) bool {
    return selectionFileCommandEnabled(state) and !std.mem.eql(u8, state.model.current_dir, "/");
}

pub fn fileClipboardAvailable(state: *const State) bool {
    return state.transfer.clipboard_file_action != null and
        state.transfer.clipboard_buf.items.len > 0;
}

pub fn targetPathCanAcceptPaste(state: *const State, path: []const u8) bool {
    if (!fileClipboardAvailable(state)) return false;
    if (entryForPath(state, path)) |entry| return entry.canEnter();
    const io = state.runtime.io orelse return false;
    ensureDirectoryOpenable(io, path) catch return false;
    return true;
}

pub fn contextSelectionCommandEnabled(state: *const State) bool {
    const path = state.interaction.context_target_path orelse return false;
    return entryForPath(state, path) != null and state.model.selected_paths.items.len > 0;
}

pub fn contextRenameEnabled(state: *const State) bool {
    const path = state.interaction.context_target_path orelse return false;
    return entryForPath(state, path) != null and renameSelectionEnabled(state);
}

pub fn contextMoveParentEnabled(state: *const State) bool {
    const path = state.interaction.context_target_path orelse return false;
    return entryForPath(state, path) != null and moveSelectionToParentEnabled(state);
}

pub fn contextPasteEnabled(state: *const State) bool {
    const path = state.interaction.context_target_path orelse return false;
    return targetPathCanAcceptPaste(state, path);
}

fn copyOrCutSelection(state: *State, action: FileClipboardAction) !bool {
    if (state.model.selected_paths.items.len == 0) return false;
    try setFileClipboardSelection(state, state.model.selected_paths.items, action);
    state.interaction.status_note = if (action == .cut) "Cut files to clipboard." else "Copied files to clipboard.";
    return false;
}

fn collectClipboardFilePaths(state: *State, paths: *std.ArrayListUnmanaged([]u8)) !?FileClipboardAction {
    clearTrackedPaths(paths);

    if (state.transfer.clipboard_file_action) |action| {
        var lines = std.mem.splitScalar(u8, state.transfer.clipboard_buf.items, '\n');
        while (lines.next()) |line| {
            const path = std.mem.trimEnd(u8, line, "\r");
            if (path.len == 0) continue;
            try paths.append(allocator, try allocator.dupe(u8, path));
        }
        return if (paths.items.len > 0) action else null;
    }

    return null;
}

fn pasteFilesToDirectory(state: *State, target_dir: []const u8) !bool {
    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        clearTrackedPaths(&paths);
        paths.deinit(allocator);
    }

    const action = (try collectClipboardFilePaths(state, &paths)) orelse {
        state.interaction.status_note = "Clipboard does not contain files.";
        return false;
    };

    const changed = switch (action) {
        .copy => try copyPathsToDirectory(state, paths.items, target_dir),
        .cut => try movePathsToDirectory(state, paths.items, target_dir),
    };
    if (changed and action == .cut and state.transfer.clipboard_file_action != null) {
        clearClipboardFilePayload(state);
    }
    return changed;
}

fn pasteContextTarget(state: *State) !bool {
    const path = state.interaction.context_target_path orelse return false;
    const target_dir = if (entryForPath(state, path)) |entry| blk: {
        if (!entry.canEnter()) return false;
        break :blk entry.navigationPath();
    } else path;
    return pasteFilesToDirectory(state, target_dir);
}

fn deleteSelection(state: *State) !bool {
    if (state.model.selected_paths.items.len == 0) return false;
    return deletePaths(state, state.model.selected_paths.items);
}

fn moveSelectionToParent(state: *State) !bool {
    if (!moveSelectionToParentEnabled(state)) return false;
    const parent = try parentPathAlloc(allocator, state.model.current_dir);
    defer if (parent) |path| allocator.free(path);
    const parent_path = parent orelse return false;
    return movePathsToDirectory(state, state.model.selected_paths.items, parent_path);
}

fn beginRenameSelection(state: *State, ctx: *goop.Context) !bool {
    if (!renameSelectionEnabled(state)) return false;
    const entry = selectedEntry(state) orelse return false;
    try beginRenameEntry(state, ctx, entry.*);
    return true;
}

pub fn browserCommandChecked(state: *const State, command: BrowserCommand) bool {
    return switch (command) {
        .toggle_sidebar => state.model.show_sidebar,
        .toggle_preview => state.model.show_preview,
        .toggle_info => state.model.show_info,
        .toggle_status_bar => state.model.show_status_bar,
        .view_list => state.model.view_mode == .list,
        .view_grid => state.model.view_mode == .grid,
        .toggle_sort_directories => state.model.sort_directories_together,
        else => false,
    };
}

pub fn browserCommandEnabled(state: *const State, command: BrowserCommand) bool {
    return switch (command) {
        .back => state.model.history_index > 0 and state.model.history.items.len > 0,
        .forward => state.model.history.items.len > 0 and state.model.history_index + 1 < state.model.history.items.len,
        .up => !std.mem.eql(u8, state.model.current_dir, "/"),
        .home => homePath(state) != null,
        .refresh => true,
        .copy, .cut, .delete => selectionFileCommandEnabled(state),
        .paste => fileClipboardAvailable(state),
        .rename => renameSelectionEnabled(state),
        .move_parent => moveSelectionToParentEnabled(state),
        .copy_path => true,
        .open_link_target => selectedSymlinkDirectoryEntry(state) != null,
        .quit => true,
        .select_all => state.model.entries.items.len > 0,
        .clear_selection => state.model.selected_paths.items.len > 0,
        .toggle_sidebar,
        .toggle_preview,
        .toggle_info,
        .toggle_status_bar,
        .view_list,
        .view_grid,
        .toggle_sort_directories,
        .about,
        => true,
    };
}

fn runBrowserCommand(state: *State, command: BrowserCommand) !bool {
    switch (command) {
        .back => {
            state.interaction.status_note = null;
            return navigateBack(state);
        },
        .forward => {
            state.interaction.status_note = null;
            return navigateForward(state);
        },
        .up => {
            state.interaction.status_note = null;
            return navigateUp(state);
        },
        .home => {
            if (homePath(state)) |home| {
                state.interaction.status_note = null;
                return setCurrentDirectory(state, home, true);
            }
            return false;
        },
        .refresh => {
            state.interaction.status_note = null;
            try refreshCurrentDirectory(state);
            return true;
        },
        .copy => return copyOrCutSelection(state, .copy),
        .cut => return copyOrCutSelection(state, .cut),
        .paste => return pasteFilesToDirectory(state, state.model.current_dir),
        .delete => return deleteSelection(state),
        .rename => return false,
        .move_parent => return moveSelectionToParent(state),
        .copy_path => {
            try setClipboardSelection(state, selectedPathForClipboard(state));
            state.interaction.status_note = "Copied path to clipboard.";
            return false;
        },
        .open_link_target => {
            const entry = selectedSymlinkDirectoryEntry(state) orelse return false;
            state.interaction.status_note = null;
            return setCurrentDirectory(state, entry.target_path.?, true);
        },
        .quit => {
            state.runtime.running = false;
            return false;
        },
        .select_all => {
            state.interaction.status_note = null;
            return selectAllEntries(state);
        },
        .clear_selection => {
            state.interaction.status_note = null;
            return clearSelectionState(state);
        },
        .toggle_sidebar => {
            state.model.show_sidebar = !state.model.show_sidebar;
            return true;
        },
        .toggle_preview => {
            state.model.show_preview = !state.model.show_preview;
            return true;
        },
        .toggle_info => {
            state.model.show_info = !state.model.show_info;
            return true;
        },
        .toggle_status_bar => {
            state.model.show_status_bar = !state.model.show_status_bar;
            return true;
        },
        .view_list => {
            if (state.model.view_mode == .list) return false;
            state.model.view_mode = .list;
            return true;
        },
        .view_grid => {
            if (state.model.view_mode == .grid) return false;
            state.model.view_mode = .grid;
            return true;
        },
        .toggle_sort_directories => {
            state.model.sort_directories_together = !state.model.sort_directories_together;
            sortDirectoryEntries(state);
            syncSelectionAnchor(state);
            return true;
        },
        .about => {
            state.interaction.status_note = "goop files: a retained file manager component demo.";
            return false;
        },
    }
}

fn setTopMenuPopupVisible(state: *const State, ctx: *goop.Context, target: ?goop.NodeHandle) void {
    const popups = [_]?goop.NodeHandle{
        state.view.menus.file.popup,
        state.view.menus.edit.popup,
        state.view.menus.view.popup,
        state.view.menus.go.popup,
        state.view.menus.help.popup,
    };

    var changed = false;
    for (popups) |popup_handle| {
        const popup = popup_handle orelse continue;
        if (!ctx.tree.isAlive(popup) or ctx.tree.getConst(popup).kind != .popup) continue;
        const visible = if (target) |selected| selected.eql(popup) else false;
        if (ctx.tree.getConst(popup).kind.popup.visible == visible) continue;
        if (ctx.mutateKind(popup)) |__k| {
            __k.popup.visible = visible;
        }
        changed = true;
    }
    if (changed) ctx.invalidate();
}

fn toggleTopMenuPopup(state: *const State, ctx: *goop.Context, popup: ?goop.NodeHandle) void {
    const target = popup orelse {
        setTopMenuPopupVisible(state, ctx, null);
        return;
    };
    if (!ctx.tree.isAlive(target) or ctx.tree.getConst(target).kind != .popup) return;
    const should_open = !ctx.tree.getConst(target).kind.popup.visible;
    setTopMenuPopupVisible(state, ctx, if (should_open) target else null);
}

pub fn initializeBrowserState(state: *State) !void {
    const cwd = try currentWorkingDirectoryAlloc(allocator, try stateIo(state));
    defer allocator.free(cwd);
    _ = try setCurrentDirectory(state, cwd, true);
    try refreshPlaces(state);
}

// ── Font loading ──

// SESSION_BOUNDARY

pub fn initSession(
    state: *State,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    context: *goop.Context,
    text_measure: *const goop.TextMeasureCtx,
) !void {
    state.runtime.io = io;
    state.runtime.env = environment;
    state.runtime.ctx = context;
    state.runtime.text_measure_ctx = text_measure;
    state.runtime.ui_scale = envScale(environment, "GOOP_FILE_MANAGER_UI_SCALE", 1);
    state.view.layout.scroll_debug_enabled = envFlag(
        environment,
        "GOOP_FILE_BROWSER_SCROLL_DEBUG",
    );
    state.view.layout.layout_debug_enabled = envFlag(
        environment,
        "GOOP_FILE_BROWSER_LAYOUT_DEBUG",
    );

    context.theme = fileManagerTheme(state);
    context.setClipboard(clipboard(state));
    try initializeBrowserState(state);
    try buildWidgetTree(state);
}

pub fn deinitSession(state: *State) void {
    deinitBrowserState(state);
    state.transfer.clipboard_buf.deinit(allocator);
    state.transfer.clipboard_uri_list_buf.deinit(allocator);
    state.transfer.clipboard_gnome_files_buf.deinit(allocator);
    state.transfer.drag_uri_list_buf.deinit(allocator);
    state.transfer.drag_plain_buf.deinit(allocator);
    state.transfer.drag_gnome_files_buf.deinit(allocator);
    state.* = undefined;
}

pub fn resize(state: *State, context: *goop.Context, width: u32, height: u32) void {
    state.runtime.logical_width = @max(width, 1);
    state.runtime.logical_height = @max(height, 1);
    context.setDimensions(state.runtime.logical_width, state.runtime.logical_height);
}

pub fn pointerPosition(state: *State, x: f32, y: f32) void {
    state.interaction.mouse_x = x;
    state.interaction.mouse_y = y;
}

pub fn primaryReleased(state: *State, x: f32, y: f32) void {
    state.interaction.primary_release_pending = true;
    state.interaction.primary_release_x = x;
    state.interaction.primary_release_y = y;
}

pub fn keyInput(
    state: *State,
    context: *const goop.Context,
    keycode_value: goop.Event.Keycode,
    pressed: bool,
    mods: goop.Event.Modifiers,
) void {
    state.interaction.ctrl_down = mods.ctrl;
    state.interaction.shift_down = mods.shift;
    if (!pressed) return;

    const focused = context.frame().focused;
    const focused_is_text_input = if (focused) |handle|
        context.tree.getConst(handle).kind == .text_input
    else
        false;
    const focused_is_rename = if (focused) |handle|
        if (state.interaction.rename_input_handle) |rename_handle|
            handle.eql(rename_handle)
        else
            false
    else
        false;

    switch (keycode_value) {
        .enter => {
            if (focused_is_rename) {
                state.interaction.rename_commit_requested = true;
            } else if (state.view.chrome.address_input_handle) |handle| {
                if (context.tree.isAlive(handle) and
                    context.tree.getConst(handle).interaction.focused)
                {
                    state.interaction.address_submit_requested = true;
                }
            }
        },
        .a => if (mods.ctrl and !focused_is_text_input) {
            state.interaction.pending_command = .select_all;
        },
        .c => if (mods.ctrl and !focused_is_text_input) {
            state.interaction.pending_command = .copy;
        },
        .x => if (mods.ctrl and !focused_is_text_input) {
            state.interaction.pending_command = .cut;
        },
        .v => if (mods.ctrl and !focused_is_text_input) {
            state.interaction.pending_command = .paste;
        },
        .delete => if (!focused_is_text_input) {
            state.interaction.pending_command = .delete;
        },
        .up => if (mods.ctrl and mods.shift and !focused_is_text_input) {
            state.interaction.pending_command = .move_parent;
        },
        .escape => {
            if (state.interaction.rename_path != null) {
                state.interaction.rename_cancel_requested = true;
            } else if (!focused_is_text_input) {
                state.interaction.pending_command = .clear_selection;
            }
        },
        else => {},
    }
}

pub fn paint(
    state: *State,
    context: *goop.Context,
    text_measure: *const goop.TextMeasureCtx,
) !goop.PaintList {
    context.doLayout(text_measure);
    if (try refreshAssetViewportIfNeeded(state)) context.doLayout(text_measure);
    debugLogFilePanelLayout(state);

    var base = try goop.paint.generatePaint(
        &context.tree,
        context.theme,
        allocator,
        state.runtime.text_measure_ctx,
        .{ .scope = .{ .full = .{ .include_floating = true } } },
    );
    defer goop.paint.freePaintList(&base, allocator);
    return composeFileBrowserPaintList(state, base);
}

fn widgetClicked(ctx: *const goop.Context, handle: ?goop.NodeHandle) bool {
    const h = handle orelse return false;
    return ctx.tree.node(h).?.clicked;
}

fn widgetSecondaryClicked(ctx: *const goop.Context, handle: ?goop.NodeHandle) bool {
    const h = handle orelse return false;
    return ctx.tree.node(h).?.secondary_clicked;
}

fn runMenuCommands(state: *State, ctx: *goop.Context, rebuild_ui: *bool) !void {
    const Item = struct {
        handle: ?goop.NodeHandle,
        command: BrowserCommand,
    };
    const items = [_]Item{
        .{ .handle = state.view.menus.file.refresh, .command = .refresh },
        .{ .handle = state.view.menus.file.copy_path, .command = .copy_path },
        .{ .handle = state.view.menus.file.open_target, .command = .open_link_target },
        .{ .handle = state.view.menus.file.quit, .command = .quit },
        .{ .handle = state.view.menus.edit.copy, .command = .copy },
        .{ .handle = state.view.menus.edit.cut, .command = .cut },
        .{ .handle = state.view.menus.edit.paste, .command = .paste },
        .{ .handle = state.view.menus.edit.delete, .command = .delete },
        .{ .handle = state.view.menus.edit.move_parent, .command = .move_parent },
        .{ .handle = state.view.menus.edit.select_all, .command = .select_all },
        .{ .handle = state.view.menus.edit.clear_selection, .command = .clear_selection },
        .{ .handle = state.view.menus.view.sidebar, .command = .toggle_sidebar },
        .{ .handle = state.view.menus.view.preview, .command = .toggle_preview },
        .{ .handle = state.view.menus.view.info, .command = .toggle_info },
        .{ .handle = state.view.menus.view.status_bar, .command = .toggle_status_bar },
        .{ .handle = state.view.menus.view.list, .command = .view_list },
        .{ .handle = state.view.menus.view.grid, .command = .view_grid },
        .{ .handle = state.view.menus.view.sort_directories, .command = .toggle_sort_directories },
        .{ .handle = state.view.menus.go.back, .command = .back },
        .{ .handle = state.view.menus.go.forward, .command = .forward },
        .{ .handle = state.view.menus.go.up, .command = .up },
        .{ .handle = state.view.menus.go.home, .command = .home },
        .{ .handle = state.view.menus.help.about, .command = .about },
    };

    for (items) |item| {
        if (!widgetClicked(ctx, item.handle)) continue;
        setTopMenuPopupVisible(state, ctx, null);
        rebuild_ui.* = try runBrowserCommand(state, item.command) or rebuild_ui.*;
    }

    if (widgetClicked(ctx, state.view.menus.edit.rename)) {
        setTopMenuPopupVisible(state, ctx, null);
        rebuild_ui.* = try beginRenameSelection(state, ctx) or rebuild_ui.*;
    }
}

fn runToolbarCommands(state: *State, ctx: *goop.Context, rebuild_ui: *bool) !void {
    const Item = struct {
        handle: ?goop.NodeHandle,
        command: BrowserCommand,
    };
    const items = [_]Item{
        .{ .handle = state.view.chrome.btn_back, .command = .back },
        .{ .handle = state.view.chrome.btn_forward, .command = .forward },
        .{ .handle = state.view.chrome.btn_up, .command = .up },
        .{ .handle = state.view.chrome.btn_home, .command = .home },
        .{ .handle = state.view.chrome.btn_refresh, .command = .refresh },
        .{ .handle = state.view.chrome.btn_toggle_sidebar, .command = .toggle_sidebar },
        .{ .handle = state.view.chrome.btn_toggle_preview, .command = .toggle_preview },
        .{ .handle = state.view.chrome.btn_toggle_info, .command = .toggle_info },
    };

    for (items) |item| {
        if (widgetClicked(ctx, item.handle)) {
            rebuild_ui.* = try runBrowserCommand(state, item.command) or rebuild_ui.*;
        }
    }
    if (widgetClicked(ctx, state.view.chrome.btn_address_go)) state.interaction.address_submit_requested = true;
    if (widgetClicked(ctx, state.view.chrome.btn_list_view) and state.model.view_mode != .list) {
        rebuild_ui.* = try runBrowserCommand(state, .view_list) or rebuild_ui.*;
    }
    if (widgetClicked(ctx, state.view.chrome.btn_grid_view) and state.model.view_mode != .grid) {
        rebuild_ui.* = try runBrowserCommand(state, .view_grid) or rebuild_ui.*;
    }
}

fn runContextMenuCommands(state: *State, ctx: *goop.Context, rebuild_ui: *bool) !void {
    const Item = struct {
        handle: ?goop.NodeHandle,
        command: BrowserCommand,
    };
    const command_items = [_]Item{
        .{ .handle = state.view.context_menu.context_copy, .command = .copy },
        .{ .handle = state.view.context_menu.context_cut, .command = .cut },
        .{ .handle = state.view.context_menu.context_delete, .command = .delete },
        .{ .handle = state.view.context_menu.context_move_parent, .command = .move_parent },
    };

    if (widgetClicked(ctx, state.view.context_menu.context_open)) {
        hideContextMenu(state, ctx);
        rebuild_ui.* = try openContextTarget(state) or rebuild_ui.*;
    }
    for (command_items) |item| {
        if (!widgetClicked(ctx, item.handle)) continue;
        hideContextMenu(state, ctx);
        rebuild_ui.* = try runBrowserCommand(state, item.command) or rebuild_ui.*;
    }
    if (widgetClicked(ctx, state.view.context_menu.context_paste)) {
        hideContextMenu(state, ctx);
        rebuild_ui.* = try pasteContextTarget(state) or rebuild_ui.*;
    }
    if (widgetClicked(ctx, state.view.context_menu.context_rename)) {
        hideContextMenu(state, ctx);
        rebuild_ui.* = try beginRenameSelection(state, ctx) or rebuild_ui.*;
    }
    if (widgetClicked(ctx, state.view.context_menu.context_copy_path)) {
        hideContextMenu(state, ctx);
        rebuild_ui.* = try copyContextTargetPath(state) or rebuild_ui.*;
    }
    if (widgetClicked(ctx, state.view.context_menu.context_open_link_target)) {
        hideContextMenu(state, ctx);
        rebuild_ui.* = try openContextLinkTarget(state) or rebuild_ui.*;
    }
}

fn beginBrowserFrame(state: *State, ctx: *goop.Context, text_measure_ctx: *const goop.TextMeasureCtx) !bool {
    ctx.clearClickedFlags();
    ctx.doLayout(text_measure_ctx);
    ctx.processEvents();
    syncContextPopupVisibleFromWidget(state, ctx);
    syncAddressInputFromWidget(state, ctx);
    syncRenameInputFromWidget(state, ctx);

    var rebuild_ui = false;
    if (state.interaction.rename_cancel_requested) {
        state.interaction.rename_cancel_requested = false;
        rebuild_ui = cancelActiveRename(state) or rebuild_ui;
    }
    if (state.interaction.rename_commit_requested) {
        state.interaction.rename_commit_requested = false;
        switch (try commitActiveRename(state)) {
            .inactive => {},
            .closed, .blocked => rebuild_ui = true,
        }
    }
    return rebuild_ui;
}

fn syncRetainedWidgetState(state: *State, ctx: *goop.Context, rebuild_ui: *bool) void {
    if (state.view.chrome.nav_splitter) |h| if (ctx.tree.node(h).?.changed) {
        state.model.nav_ratio = ctx.tree.node(h).?.kind.splitter.ratio;
    };
    if (state.view.chrome.detail_splitter) |h| if (ctx.tree.node(h).?.changed) {
        state.model.detail_ratio = ctx.tree.node(h).?.kind.splitter.ratio;
    };
    if (state.view.chrome.preview_splitter) |h| if (ctx.tree.node(h).?.changed) {
        state.model.preview_ratio = ctx.tree.node(h).?.kind.splitter.ratio;
    };

    if (state.view.assets.asset_table) |h| if (ctx.tree.node(h).?.changed) {
        state.model.table_column_weights[0] = ctx.tree.tableColumnFraction(h, 0) orelse state.model.table_column_weights[0];
        state.model.table_column_weights[1] = ctx.tree.tableColumnFraction(h, 1) orelse state.model.table_column_weights[1];
        state.model.table_column_weights[2] = ctx.tree.tableColumnFraction(h, 2) orelse state.model.table_column_weights[2];
        state.model.table_column_weights[3] = ctx.tree.tableColumnFraction(h, 3) orelse state.model.table_column_weights[3];
        if (state.view.assets.asset_table_body) |body| {
            if (ctx.tree.isAlive(body)) {
                applyAssetTableColumns(&ctx.mutateKind(body).?.table, state);
                ctx.invalidate();
            }
        }
    };

    if (state.view.assets.asset_table) |h| if (ctx.tree.node(h).?.kind.table.sort_changed) {
        if (ctx.tree.node(h).?.kind.table.sorted_column) |sorted_column| {
            const previous_sort_column = state.model.sort_column;
            state.model.sort_column = @enumFromInt(sorted_column);
            state.model.sort_direction = switch (ctx.tree.node(h).?.kind.table.sort_direction) {
                .ascending => .ascending,
                .descending => .descending,
            };
            if (previous_sort_column != state.model.sort_column and state.model.sort_column == .modified) {
                state.model.sort_direction = .descending;
            }
            sortDirectoryEntries(state);
            syncSelectionAnchor(state);
            rebuild_ui.* = true;
        }
    };
}

fn runPendingCommands(state: *State, rebuild_ui: *bool) !void {
    if (state.interaction.pending_command) |command| {
        state.interaction.pending_command = null;
        rebuild_ui.* = try runBrowserCommand(state, command) or rebuild_ui.*;
    }
    if (state.interaction.address_submit_requested) {
        state.interaction.address_submit_requested = false;
        const path = try addressInputPathAlloc(state);
        defer allocator.free(path);
        rebuild_ui.* = try setCurrentDirectory(state, path, true) or rebuild_ui.*;
    }
}

fn openContextMenuFromSecondaryClick(state: *State, ctx: *goop.Context, rebuild_ui: *bool) !void {
    for (state.view.assets.place_handles.items, 0..) |handle, index| {
        if (!widgetSecondaryClicked(ctx, handle)) continue;
        if (index >= state.model.places.items.len) continue;
        try showContextMenuForPath(state, ctx, state.model.places.items[index].path);
        rebuild_ui.* = true;
        return;
    }

    for (state.view.assets.folder_tree_handles.items, 0..) |handle, index| {
        if (!widgetSecondaryClicked(ctx, handle)) continue;
        if (index >= state.view.assets.folder_tree_paths.items.len) continue;
        try showContextMenuForPath(state, ctx, state.view.assets.folder_tree_paths.items[index]);
        rebuild_ui.* = true;
        return;
    }

    for (state.view.assets.breadcrumb_handles.items, 0..) |handle, index| {
        if (!widgetSecondaryClicked(ctx, handle)) continue;
        if (index >= state.view.assets.breadcrumb_paths.items.len) continue;
        try showContextMenuForPath(state, ctx, state.view.assets.breadcrumb_paths.items[index]);
        rebuild_ui.* = true;
        return;
    }

    for (state.view.assets.row_handles.items, 0..) |handle, index| {
        if (!widgetSecondaryClicked(ctx, handle)) continue;
        const entry_index = state.view.assets.asset_visible_start + index;
        if (entry_index >= state.model.entries.items.len) continue;
        try selectEntryForContextMenu(state, entry_index);
        try showContextMenuForPath(state, ctx, state.model.entries.items[entry_index].path);
        rebuild_ui.* = true;
        return;
    }

    for (state.view.assets.grid_handles.items, 0..) |handle, index| {
        if (!widgetSecondaryClicked(ctx, handle)) continue;
        const entry_index = state.view.assets.asset_visible_start + index;
        if (entry_index >= state.model.entries.items.len) continue;
        try selectEntryForContextMenu(state, entry_index);
        try showContextMenuForPath(state, ctx, state.model.entries.items[entry_index].path);
        rebuild_ui.* = true;
        return;
    }

    if (widgetSecondaryClicked(ctx, state.view.chrome.file_panel_scroll)) {
        try showContextMenuForPath(state, ctx, state.model.current_dir);
        rebuild_ui.* = true;
    }
}

fn handleAssetDropFrame(state: *State, ctx: *const goop.Context, rebuild_ui: *bool) !bool {
    const drop = ctx.frame().last_drop orelse return false;
    const asset_drop = switch (drop) {
        .widget => |widget_drop| assetEntryIndexFromUserId(state, ctx.tree.userId(widget_drop.source)) != null,
        .table => |table_drop| assetEntryIndexFromUserId(state, ctx.tree.userId(table_drop.source)) != null,
        .grid => |grid_drop| assetEntryIndexFromUserId(state, ctx.tree.userId(grid_drop.source)) != null,
        else => false,
    };
    if (!asset_drop) return false;

    if (state.interaction.rename_path != null) {
        switch (try commitActiveRename(state)) {
            .inactive => {},
            .closed => rebuild_ui.* = true,
            .blocked => rebuild_ui.* = true,
        }
    }
    if (state.interaction.rename_path == null) {
        rebuild_ui.* = switch (drop) {
            .widget => |widget_drop| try handleAssetWidgetDrop(state, ctx, widget_drop),
            .table => |table_drop| try handleAssetTableDrop(state, ctx, table_drop),
            .grid => |grid_drop| try handleAssetGridDrop(state, ctx, grid_drop),
            else => false,
        } or rebuild_ui.*;
    }
    return true;
}

fn handleNavigationClicks(state: *State, ctx: *const goop.Context, rebuild_ui: *bool) !void {
    for (state.view.assets.place_handles.items, 0..) |handle, index| {
        if (!ctx.tree.node(handle).?.clicked) continue;
        if (index >= state.model.places.items.len) continue;
        rebuild_ui.* = try setCurrentDirectory(state, state.model.places.items[index].path, true) or rebuild_ui.*;
        break;
    }

    for (state.view.assets.folder_tree_handles.items, 0..) |handle, index| {
        if (!ctx.tree.node(handle).?.toggled) continue;
        if (index >= state.view.assets.folder_tree_paths.items.len) continue;
        const path = state.view.assets.folder_tree_paths.items[index];
        const previous_expansion = folderTreeExpansion(state, path);
        if (previous_expansion == .partial) {
            rebuild_ui.* = try setFolderTreePathExpanded(state, path, true) or rebuild_ui.*;
        } else {
            const expanded = ctx.tree.node(handle).?.kind.tree_item.expanded;
            rebuild_ui.* = try setFolderTreePathExpanded(state, path, expanded) or rebuild_ui.*;
            if (!expanded and std.mem.eql(u8, path, state.model.current_dir)) rebuild_ui.* = true;
        }
    }

    for (state.view.assets.folder_tree_handles.items, 0..) |handle, index| {
        if (!ctx.tree.node(handle).?.clicked or ctx.tree.node(handle).?.toggled) continue;
        if (index >= state.view.assets.folder_tree_paths.items.len) continue;
        rebuild_ui.* = try setCurrentDirectory(state, state.view.assets.folder_tree_paths.items[index], true) or rebuild_ui.*;
        break;
    }

    for (state.view.assets.breadcrumb_handles.items, 0..) |handle, index| {
        if (!ctx.tree.node(handle).?.clicked) continue;
        if (index >= state.view.assets.breadcrumb_paths.items.len) continue;
        rebuild_ui.* = try setCurrentDirectory(state, state.view.assets.breadcrumb_paths.items[index], true) or rebuild_ui.*;
        break;
    }
}

fn handleAssetEntryPrimaryClick(
    state: *State,
    ctx: *goop.Context,
    io: std.Io,
    visible_index: usize,
    allow_inline_rename: bool,
    rebuild_ui: *bool,
) !bool {
    var entry_index = state.view.assets.asset_visible_start + visible_index;
    if (entry_index >= state.model.entries.items.len) return false;

    const entry = state.model.entries.items[entry_index];
    if (allow_inline_rename and
        !state.interaction.ctrl_down and
        !state.interaction.shift_down and
        isPathSelected(state, entry.path) and
        pointHitsEntryNameText(state, ctx, visible_index, entry, state.interaction.primary_release_x, state.interaction.primary_release_y))
    {
        try beginRenameEntry(state, ctx, entry);
        rebuild_ui.* = true;
        return true;
    }

    const clicked_path = try allocator.dupe(u8, entry.path);
    defer allocator.free(clicked_path);
    if (state.interaction.rename_path != null) {
        switch (try commitActiveRename(state)) {
            .inactive => {},
            .closed => {
                rebuild_ui.* = true;
                entry_index = entryIndexForPath(state, clicked_path) orelse return true;
            },
            .blocked => {
                rebuild_ui.* = true;
                return true;
            },
        }
    }

    const selected_entry = state.model.entries.items[entry_index];
    const click_ms = currentPrimaryClickTimestampMs(ctx, io);
    const repeated_click = isRepeatedEntryClick(state, &selected_entry, click_ms);

    try applyEntrySelectionClick(state, entry_index);
    try setLastClickPath(state, selected_entry.path);
    state.model.last_click_ms = click_ms;
    rebuild_ui.* = true;

    if (repeated_click and selected_entry.canEnter()) {
        rebuild_ui.* = try setCurrentDirectory(state, selected_entry.navigationPath(), true) or rebuild_ui.*;
    }
    return true;
}

fn handleAssetPrimaryClicks(state: *State, ctx: *goop.Context, io: std.Io, rebuild_ui: *bool) !bool {
    for (state.view.assets.row_handles.items, 0..) |handle, index| {
        if (!widgetClicked(ctx, handle)) continue;
        return try handleAssetEntryPrimaryClick(state, ctx, io, index, true, rebuild_ui);
    }

    for (state.view.assets.grid_handles.items, 0..) |handle, index| {
        if (!widgetClicked(ctx, handle)) continue;
        return try handleAssetEntryPrimaryClick(state, ctx, io, index, false, rebuild_ui);
    }

    return false;
}

fn syncAssetSelectionWidgets(state: *State, ctx: *goop.Context, rebuild_ui: *bool) !bool {
    var selection_widget_changed = false;
    const selection_drag_active = ctx.frame().buttons.left;
    if (state.model.view_mode == .list) {
        if (state.view.assets.asset_table_body) |table| {
            if (ctx.tree.isAlive(table) and ctx.tree.node(table).?.kind.table.selection_changed) {
                selection_widget_changed = true;
                if (state.interaction.rename_path != null) {
                    switch (try commitActiveRename(state)) {
                        .inactive => {},
                        .closed => rebuild_ui.* = true,
                        .blocked => {
                            rebuild_ui.* = true;
                            selection_widget_changed = false;
                        },
                    }
                }
                if (selection_widget_changed) {
                    try syncSelectedPathsFromTable(state, ctx, table);
                    if (selection_drag_active) {
                        state.interaction.asset_selection_rebuild_pending = true;
                    } else {
                        rebuild_ui.* = true;
                    }
                }
            }
        }
    } else if (state.model.view_mode == .grid) {
        if (state.view.assets.asset_grid) |grid| {
            if (ctx.tree.isAlive(grid) and ctx.tree.node(grid).?.changed) {
                selection_widget_changed = true;
                if (state.interaction.rename_path != null) {
                    switch (try commitActiveRename(state)) {
                        .inactive => {},
                        .closed => rebuild_ui.* = true,
                        .blocked => {
                            rebuild_ui.* = true;
                            selection_widget_changed = false;
                        },
                    }
                }
                if (selection_widget_changed) {
                    try syncSelectedPathsFromGrid(state, ctx, grid);
                    if (selection_drag_active) {
                        state.interaction.asset_selection_rebuild_pending = true;
                    } else {
                        rebuild_ui.* = true;
                    }
                }
            }
        }
    }
    return selection_widget_changed;
}

fn finishAssetSelectionFrame(state: *State, ctx: *goop.Context, asset_primary_handled: bool, rebuild_ui: *bool) !void {
    var handled = asset_primary_handled;
    if (!handled) {
        handled = try syncAssetSelectionWidgets(state, ctx, rebuild_ui);
    }

    if (!ctx.frame().buttons.left and state.interaction.asset_selection_rebuild_pending) {
        state.interaction.asset_selection_rebuild_pending = false;
        rebuild_ui.* = true;
    }

    if (state.interaction.primary_release_pending) {
        defer state.interaction.primary_release_pending = false;
        if (!handled and pointInFilePanelBlankSpace(state, ctx, state.interaction.primary_release_x, state.interaction.primary_release_y)) {
            var rename_blocks_deselect = false;
            if (state.interaction.rename_path != null) {
                switch (try commitActiveRename(state)) {
                    .inactive => {},
                    .closed => rebuild_ui.* = true,
                    .blocked => {
                        rebuild_ui.* = true;
                        rename_blocks_deselect = true;
                    },
                }
            }
            if (!rename_blocks_deselect) {
                rebuild_ui.* = clearSelectionState(state) or rebuild_ui.*;
            }
        }
    }
}

// APP_BOUNDARY

pub fn update(
    state: *State,
    context: *goop.Context,
    text_measure: *const goop.TextMeasureCtx,
    io: std.Io,
) !void {
    var rebuild_ui = try beginBrowserFrame(state, context, text_measure);
    syncRetainedWidgetState(state, context, &rebuild_ui);

    try runMenuCommands(state, context, &rebuild_ui);
    try runContextMenuCommands(state, context, &rebuild_ui);
    try runToolbarCommands(state, context, &rebuild_ui);
    try runPendingCommands(state, &rebuild_ui);
    try openContextMenuFromSecondaryClick(state, context, &rebuild_ui);

    var asset_primary_handled = try handleAssetDropFrame(
        state,
        context,
        &rebuild_ui,
    );
    try handleNavigationClicks(state, context, &rebuild_ui);
    asset_primary_handled = try handleAssetPrimaryClicks(
        state,
        context,
        io,
        &rebuild_ui,
    ) or asset_primary_handled;
    try finishAssetSelectionFrame(
        state,
        context,
        asset_primary_handled,
        &rebuild_ui,
    );

    if (rebuild_ui) try buildWidgetTree(state);
}

test {
    _ = @import("browser_test.zig");
}
