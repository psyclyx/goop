const std = @import("std");
const goop = @import("goop");
const snail = @import("snail");
const render = @import("goop_demo_render");
const posix = std.posix;

const types = @import("file_manager/types.zig");
const style = @import("file_manager/style.zig");

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

const preview = @import("file_manager/preview.zig");

pub const SelectionPreview = preview.SelectionPreview;
pub const allocSelectionPreview = preview.allocSelectionPreview;
pub const appendDirectoryPreviewSummary = preview.appendDirectoryPreviewSummary;
pub const bytesLookLikeTextPreview = preview.bytesLookLikeTextPreview;

const fs = @import("file_manager/fs.zig");

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

pub const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-cursor.h");
    @cInclude("wayland-egl.h");
    @cInclude("xdg-shell-client-protocol.h");
});

pub const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

pub const egl_util = @import("goop_demo_egl");
pub const egl = egl_util.egl;

pub const allocator = std.heap.smp_allocator;

const wayland = @import("file_manager/wayland.zig");

pub const clipboard_mime_utf8 = wayland.clipboard_mime_utf8;
pub const clipboard_mime_utf8_string = wayland.clipboard_mime_utf8_string;
pub const clipboard_mime_text = wayland.clipboard_mime_text;
pub const dnd_mime_uri_list = wayland.dnd_mime_uri_list;
pub const dnd_mime_gnome_copied_files = wayland.dnd_mime_gnome_copied_files;

pub const SnailTextCtx = wayland.SnailTextCtx;
pub const OutputState = wayland.OutputState;
pub const CursorKind = wayland.CursorKind;
pub const PopupSurface = wayland.PopupSurface;
pub const PopupParentInfo = wayland.PopupParentInfo;
pub const DataOfferState = wayland.DataOfferState;

pub const snailMeasureText = wayland.snailMeasureText;
pub const fontLineMetrics = wayland.fontLineMetrics;
pub const isPrintableTextCodepoint = wayland.isPrintableTextCodepoint;
pub const ensureAtlasForPaintList = wayland.ensureAtlasForPaintList;

pub const cursorNames = wayland.cursorNames;
pub const lookupCursor = wayland.lookupCursor;
pub const desiredCursorKind = wayland.desiredCursorKind;
pub const applyCursorKind = wayland.applyCursorKind;
pub const updatePointerCursor = wayland.updatePointerCursor;

pub const registry_listener = wayland.registry_listener;
pub const wm_base_listener = wayland.wm_base_listener;
pub const xdg_surface_listener = wayland.xdg_surface_listener;
pub const xdg_toplevel_listener = wayland.xdg_toplevel_listener;
pub const popup_xdg_surface_listener = wayland.popup_xdg_surface_listener;
pub const xdg_popup_listener = wayland.xdg_popup_listener;
pub const output_listener = wayland.output_listener;
pub const surface_listener = wayland.surface_listener;
pub const seat_listener = wayland.seat_listener;
pub const data_offer_listener = wayland.data_offer_listener;
pub const data_source_listener = wayland.data_source_listener;
pub const data_device_listener = wayland.data_device_listener;
pub const pointer_listener = wayland.pointer_listener;
pub const keyboard_listener = wayland.keyboard_listener;
pub const frame_listener = wayland.frame_listener;

pub const syncNativePopupSurfaces = wayland.syncNativePopupSurfaces;
pub const popupNeedsNativeSurface = wayland.popupNeedsNativeSurface;
pub const popupParentInfo = wayland.popupParentInfo;
pub const ancestorPopupForOwner = wayland.ancestorPopupForOwner;
pub const createNativePopupSurface = wayland.createNativePopupSurface;
pub const setPopupPositionerPlacement = wayland.setPopupPositionerPlacement;
pub const popupConstraintAdjustment = wayland.popupConstraintAdjustment;
pub const resizePopupBuffer = wayland.resizePopupBuffer;
pub const renderNativePopupSurfaces = wayland.renderNativePopupSurfaces;

pub const offerSupportsMime = wayland.offerSupportsMime;
pub const preferredFileOfferMime = wayland.preferredFileOfferMime;
pub const preferredTextOfferMime = wayland.preferredTextOfferMime;
pub const appendFileUri = wayland.appendFileUri;
pub const uriPathByteCanPass = wayland.uriPathByteCanPass;
pub const appendClipboardPathFromFileUri = wayland.appendClipboardPathFromFileUri;
pub const percentDecodeAlloc = wayland.percentDecodeAlloc;
pub const hexValue = wayland.hexValue;
pub const closeFd = wayland.closeFd;
pub const writeAll = wayland.writeAll;

pub const ensureDataDevice = wayland.ensureDataDevice;
pub const fixedToF32 = wayland.fixedToF32;
pub const rootPointerX = wayland.rootPointerX;
pub const rootPointerY = wayland.rootPointerY;
pub const ceilPositiveU32 = wayland.ceilPositiveU32;
pub const roundI32 = wayland.roundI32;
pub const optionalHandleChanged = wayland.optionalHandleChanged;
pub const rectsNearlyEqual = wayland.rectsNearlyEqual;
pub const nearlyEqual = wayland.nearlyEqual;

pub const evdevToKeycode = wayland.evdevToKeycode;
pub const requestFrame = wayland.requestFrame;
pub const frameDone = wayland.frameDone;
pub const initEgl = wayland.initEgl;
pub const deinitEgl = wayland.deinitEgl;

const view = @import("file_manager/view.zig");

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

const FileClipboardAction = enum {
    copy,
    cut,
};

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

pub const State = struct {
    running: bool = true,
    configured: bool = false,
    logical_width: u32 = 800,
    logical_height: u32 = 600,
    buffer_width: u32 = 800,
    buffer_height: u32 = 600,
    buffer_scale: u32 = 1,
    compositor_version: u32 = 0,
    surface_preferred_scale: ?u32 = null,
    needs_redraw: bool = true,
    frame_pending: bool = false,
    timeout_ns: ?u64 = null,
    start_time_ns: u64 = 0,
    io: ?std.Io = null,
    env: ?*const std.process.Environ.Map = null,
    ui_scale: f32 = 1,

    // Wayland globals
    display: ?*wl.wl_display = null,
    compositor: ?*wl.wl_compositor = null,
    wm_base: ?*wl.xdg_wm_base = null,
    seat: ?*wl.wl_seat = null,
    shm: ?*wl.wl_shm = null,
    data_device_manager: ?*wl.wl_data_device_manager = null,
    data_device_manager_version: u32 = 0,
    outputs: ?*OutputState = null,

    // Wayland surface chain
    surface: ?*wl.wl_surface = null,
    cursor_surface: ?*wl.wl_surface = null,
    xdg_surface: ?*wl.xdg_surface = null,
    xdg_toplevel: ?*wl.xdg_toplevel = null,
    egl_window: ?*wl.wl_egl_window = null,
    popup_surfaces: ?*PopupSurface = null,
    pointer: ?*wl.wl_pointer = null,
    cursor_theme: ?*wl.wl_cursor_theme = null,
    cursor_theme_scale: u32 = 0,
    pointer_enter_serial: u32 = 0,
    pointer_inside: bool = false,
    pointer_surface_offset_x: f32 = 0,
    pointer_surface_offset_y: f32 = 0,
    cursor_kind: CursorKind = .default,
    keyboard: ?*wl.wl_keyboard = null,
    data_device: ?*wl.wl_data_device = null,
    clipboard_source: ?*wl.wl_data_source = null,
    drag_source: ?*wl.wl_data_source = null,
    selection_offer: ?*DataOfferState = null,
    drag_offer: ?*DataOfferState = null,
    data_offers: ?*DataOfferState = null,
    last_input_serial: u32 = 0,
    last_pointer_button_serial: u32 = 0,

    // EGL
    egl_display: egl.EGLDisplay = egl.EGL_NO_DISPLAY,
    egl_config: egl.EGLConfig = null,
    egl_surface: egl.EGLSurface = egl.EGL_NO_SURFACE,
    egl_context: egl.EGLContext = egl.EGL_NO_CONTEXT,
    egl_surface_srgb: bool = false,

    // goop
    ctx: ?*goop.Context = null,

    // File browser model
    current_dir: []u8 = &.{},
    history: std.ArrayListUnmanaged([]u8) = .empty,
    history_index: usize = 0,
    places: std.ArrayListUnmanaged(BrowserPlace) = .empty,
    entries: std.ArrayListUnmanaged(BrowserEntry) = .empty,
    selected_paths: std.ArrayListUnmanaged([]u8) = .empty,
    selected_path: ?[]u8 = null,
    last_click_path: ?[]u8 = null,
    last_click_ms: u64 = 0,
    selection_anchor_index: ?usize = null,
    sort_column: BrowserSortColumn = .name,
    sort_direction: BrowserSortDirection = .ascending,
    sort_directories_together: bool = true,
    view_mode: BrowserViewMode = .list,
    show_sidebar: bool = true,
    show_preview: bool = true,
    show_info: bool = true,
    show_status_bar: bool = true,
    nav_ratio: f32 = 0.22,
    detail_ratio: f32 = 0.72,
    preview_ratio: f32 = 0.58,
    table_column_weights: [4]f32 = .{ 0.50, 0.22, 0.16, 0.12 },
    sidebar_scroll_x: f32 = 0,
    sidebar_scroll_y: f32 = 0,
    file_panel_scroll_y: f32 = 0,
    file_panel_viewport_width: f32 = 0,
    file_panel_viewport_height: f32 = 0,
    scroll_debug_enabled: bool = false,
    layout_debug_enabled: bool = false,
    scroll_debug_last_scroll_y: f32 = -1000000,
    scroll_debug_last_visible_start: usize = std.math.maxInt(usize),
    scroll_debug_last_visible_end: usize = std.math.maxInt(usize),
    layout_debug_last_focus_index: u32 = std.math.maxInt(u32),
    layout_debug_last_header_x: f32 = -1000000,
    layout_debug_last_header_w: f32 = -1000000,
    layout_debug_last_body_x: f32 = -1000000,
    layout_debug_last_body_w: f32 = -1000000,
    layout_debug_last_header_widths: [4]f32 = .{ -1, -1, -1, -1 },
    layout_debug_last_body_widths: [4]f32 = .{ -1, -1, -1, -1 },

    // Dynamic UI state
    ui_root: ?goop.NodeHandle = null,
    btn_back: ?goop.NodeHandle = null,
    btn_forward: ?goop.NodeHandle = null,
    btn_up: ?goop.NodeHandle = null,
    btn_home: ?goop.NodeHandle = null,
    btn_refresh: ?goop.NodeHandle = null,
    btn_toggle_sidebar: ?goop.NodeHandle = null,
    btn_toggle_preview: ?goop.NodeHandle = null,
    btn_toggle_info: ?goop.NodeHandle = null,
    btn_list_view: ?goop.NodeHandle = null,
    btn_grid_view: ?goop.NodeHandle = null,
    btn_address_go: ?goop.NodeHandle = null,
    address_input_handle: ?goop.NodeHandle = null,
    nav_splitter: ?goop.NodeHandle = null,
    detail_splitter: ?goop.NodeHandle = null,
    preview_splitter: ?goop.NodeHandle = null,
    sidebar_scroll: ?goop.NodeHandle = null,
    file_panel_scroll: ?goop.NodeHandle = null,
    asset_view_root: ?goop.NodeHandle = null,
    asset_table: ?goop.NodeHandle = null,
    asset_table_body: ?goop.NodeHandle = null,
    asset_grid: ?goop.NodeHandle = null,
    asset_visible_start: usize = 0,
    asset_visible_end: usize = 0,
    asset_visible_columns: usize = 0,
    place_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    folder_tree_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    breadcrumb_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    folder_tree_paths: std.ArrayListUnmanaged([]u8) = .empty,
    folder_tree_expanded_paths: std.ArrayListUnmanaged([]u8) = .empty,
    breadcrumb_paths: std.ArrayListUnmanaged([]u8) = .empty,
    menu_file_refresh: ?goop.NodeHandle = null,
    menu_file_button: ?goop.NodeHandle = null,
    menu_edit_button: ?goop.NodeHandle = null,
    menu_view_button: ?goop.NodeHandle = null,
    menu_go_button: ?goop.NodeHandle = null,
    menu_help_button: ?goop.NodeHandle = null,
    menu_file_popup: ?goop.NodeHandle = null,
    menu_edit_popup: ?goop.NodeHandle = null,
    menu_view_popup: ?goop.NodeHandle = null,
    menu_go_popup: ?goop.NodeHandle = null,
    menu_help_popup: ?goop.NodeHandle = null,
    menu_file_copy_path: ?goop.NodeHandle = null,
    menu_file_open_target: ?goop.NodeHandle = null,
    menu_file_quit: ?goop.NodeHandle = null,
    menu_edit_copy: ?goop.NodeHandle = null,
    menu_edit_cut: ?goop.NodeHandle = null,
    menu_edit_paste: ?goop.NodeHandle = null,
    menu_edit_delete: ?goop.NodeHandle = null,
    menu_edit_rename: ?goop.NodeHandle = null,
    menu_edit_move_parent: ?goop.NodeHandle = null,
    menu_edit_select_all: ?goop.NodeHandle = null,
    menu_edit_clear_selection: ?goop.NodeHandle = null,
    menu_view_sidebar: ?goop.NodeHandle = null,
    menu_view_preview: ?goop.NodeHandle = null,
    menu_view_info: ?goop.NodeHandle = null,
    menu_view_status_bar: ?goop.NodeHandle = null,
    menu_view_list: ?goop.NodeHandle = null,
    menu_view_grid: ?goop.NodeHandle = null,
    menu_view_sort_directories: ?goop.NodeHandle = null,
    menu_go_back: ?goop.NodeHandle = null,
    menu_go_forward: ?goop.NodeHandle = null,
    menu_go_up: ?goop.NodeHandle = null,
    menu_go_home: ?goop.NodeHandle = null,
    menu_help_about: ?goop.NodeHandle = null,
    context_popup: ?goop.NodeHandle = null,
    context_open: ?goop.NodeHandle = null,
    context_copy: ?goop.NodeHandle = null,
    context_cut: ?goop.NodeHandle = null,
    context_paste: ?goop.NodeHandle = null,
    context_delete: ?goop.NodeHandle = null,
    context_rename: ?goop.NodeHandle = null,
    context_move_parent: ?goop.NodeHandle = null,
    context_copy_path: ?goop.NodeHandle = null,
    context_open_link_target: ?goop.NodeHandle = null,
    context_visible: bool = false,
    context_x: f32 = 0,
    context_y: f32 = 0,
    context_target_path: ?[]u8 = null,
    rename_input_handle: ?goop.NodeHandle = null,
    rename_path: ?[]u8 = null,
    rename_input: goop.widget.WidgetKind.TextInput = .{},
    rename_commit_requested: bool = false,
    rename_cancel_requested: bool = false,
    asset_selection_rebuild_pending: bool = false,
    asset_drag_source_path: ?[]u8 = null,
    asset_drop_target_path: ?[]u8 = null,
    primary_release_pending: bool = false,
    primary_release_x: f32 = 0,
    primary_release_y: f32 = 0,
    row_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    name_cell_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    grid_handles: std.ArrayListUnmanaged(goop.NodeHandle) = .empty,
    ui_strings: std.ArrayListUnmanaged([]u8) = .empty,
    asset_ui_strings: std.ArrayListUnmanaged([]u8) = .empty,
    composed_paint_commands: std.ArrayListUnmanaged(goop.PaintCommand) = .empty,
    address_input: goop.widget.WidgetKind.TextInput = .{ .placeholder = "Path" },
    status_note: ?[]const u8 = null,
    pending_command: ?BrowserCommand = null,
    address_submit_requested: bool = false,

    // Last known mouse position from Wayland pointer events
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    left_ctrl_down: bool = false,
    right_ctrl_down: bool = false,
    left_shift_down: bool = false,
    right_shift_down: bool = false,
    ctrl_down: bool = false,
    shift_down: bool = false,
    text_measure_ctx: ?*const goop.TextMeasureCtx = null,

    // xkbcommon state for keymap → text conversion
    xkb_ctx: ?*xkb.xkb_context = null,
    xkb_keymap: ?*xkb.xkb_keymap = null,
    xkb_state: ?*xkb.xkb_state = null,

    // Clipboard text for self-owned selections and the most recent external paste.
    clipboard_buf: std.ArrayListUnmanaged(u8) = .empty,
    clipboard_uri_list_buf: std.ArrayListUnmanaged(u8) = .empty,
    clipboard_gnome_files_buf: std.ArrayListUnmanaged(u8) = .empty,
    clipboard_file_action: ?FileClipboardAction = null,
    drag_uri_list_buf: std.ArrayListUnmanaged(u8) = .empty,
    drag_plain_buf: std.ArrayListUnmanaged(u8) = .empty,
    drag_gnome_files_buf: std.ArrayListUnmanaged(u8) = .empty,

    pub fn clipboard(self: *State) goop.Clipboard {
        return .{
            .ptr = @ptrCast(self),
            .getTextFn = @ptrCast(&clipboardGetText),
            .setTextFn = @ptrCast(&clipboardSetText),
        };
    }

    fn clipboardGetText(ptr: *anyopaque) ?[]const u8 {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.clipboard_source != null) {
            if (self.clipboard_buf.items.len == 0) return null;
            return self.clipboard_buf.items;
        }
        self.fetchClipboardSelection(false) catch return null;
        if (self.clipboard_buf.items.len == 0) return null;
        return self.clipboard_buf.items;
    }

    fn clipboardSetText(ptr: *anyopaque, text: []const u8) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.setClipboardSelection(text) catch {};
    }

    pub fn setClipboardSelection(self: *State, text: []const u8) !void {
        self.clearClipboardFilePayload();
        try self.setClipboardBuffer(text);
        if (self.data_device_manager == null or self.data_device == null or self.last_input_serial == 0) return;

        self.destroyClipboardSource();

        const source = wl.wl_data_device_manager_create_data_source(self.data_device_manager) orelse return;
        self.clipboard_source = source;
        _ = wl.wl_data_source_add_listener(source, &data_source_listener, self);
        wl.wl_data_source_offer(source, clipboard_mime_utf8);
        wl.wl_data_source_offer(source, clipboard_mime_utf8_string);
        wl.wl_data_source_offer(source, clipboard_mime_text);
        wl.wl_data_device_set_selection(self.data_device, source, self.last_input_serial);
        if (self.display) |display| _ = wl.wl_display_flush(display);
    }

    pub fn setFileClipboardSelection(self: *State, paths: []const []const u8, action: FileClipboardAction) !void {
        if (paths.len == 0) return;
        try self.setClipboardFilePayload(paths, action);
        if (self.data_device_manager == null or self.data_device == null or self.last_input_serial == 0) return;

        self.destroyClipboardSource();

        const source = wl.wl_data_device_manager_create_data_source(self.data_device_manager) orelse return;
        self.clipboard_source = source;
        _ = wl.wl_data_source_add_listener(source, &data_source_listener, self);
        wl.wl_data_source_offer(source, dnd_mime_uri_list);
        wl.wl_data_source_offer(source, dnd_mime_gnome_copied_files);
        wl.wl_data_source_offer(source, clipboard_mime_utf8);
        wl.wl_data_source_offer(source, clipboard_mime_utf8_string);
        wl.wl_data_source_offer(source, clipboard_mime_text);
        wl.wl_data_device_set_selection(self.data_device, source, self.last_input_serial);
        if (self.display) |display| _ = wl.wl_display_flush(display);
    }

    pub fn fetchClipboardSelection(self: *State, prefer_files: bool) !void {
        const offer = self.selection_offer orelse return;
        const mime = (if (prefer_files) preferredFileOfferMime(offer) else preferredTextOfferMime(offer)) orelse return;

        var fds: [2]posix.fd_t = undefined;
        if (posix.system.pipe(&fds) != 0) return error.PipeFailed;
        errdefer closeFd(fds[0]);
        errdefer closeFd(fds[1]);

        wl.wl_data_offer_receive(offer.offer, mime, fds[1]);
        closeFd(fds[1]);
        if (self.display) |display| _ = wl.wl_display_flush(display);

        self.clipboard_buf.clearRetainingCapacity();
        var chunk: [4096]u8 = undefined;
        while (true) {
            const read_count = posix.read(fds[0], &chunk) catch break;
            if (read_count == 0) break;
            try self.clipboard_buf.appendSlice(allocator, chunk[0..read_count]);
        }
        closeFd(fds[0]);
    }

    pub fn setClipboardBuffer(self: *State, text: []const u8) !void {
        self.clipboard_buf.clearRetainingCapacity();
        try self.clipboard_buf.appendSlice(allocator, text);
    }

    pub fn clearClipboardFilePayload(self: *State) void {
        self.clipboard_uri_list_buf.clearRetainingCapacity();
        self.clipboard_gnome_files_buf.clearRetainingCapacity();
        self.clipboard_file_action = null;
    }

    pub fn setClipboardFilePayload(self: *State, paths: []const []const u8, action: FileClipboardAction) !void {
        self.clipboard_buf.clearRetainingCapacity();
        self.clipboard_uri_list_buf.clearRetainingCapacity();
        self.clipboard_gnome_files_buf.clearRetainingCapacity();
        self.clipboard_file_action = action;

        try self.clipboard_gnome_files_buf.appendSlice(allocator, if (action == .cut) "cut\n" else "copy\n");
        for (paths) |path| {
            try appendFileUri(&self.clipboard_uri_list_buf, path, "\r\n");
            try appendFileUri(&self.clipboard_gnome_files_buf, path, "\n");
            try self.clipboard_buf.appendSlice(allocator, path);
            try self.clipboard_buf.append(allocator, '\n');
        }
    }

    pub fn clearDragPayload(self: *State) void {
        self.drag_uri_list_buf.clearRetainingCapacity();
        self.drag_plain_buf.clearRetainingCapacity();
        self.drag_gnome_files_buf.clearRetainingCapacity();
    }

    pub fn setDragPayloadPaths(self: *State, paths: []const []const u8) !void {
        self.clearDragPayload();
        try self.drag_gnome_files_buf.appendSlice(allocator, "copy\n");
        for (paths) |path| {
            try appendFileUri(&self.drag_uri_list_buf, path, "\r\n");
            try appendFileUri(&self.drag_gnome_files_buf, path, "\n");
            try self.drag_plain_buf.appendSlice(allocator, path);
            try self.drag_plain_buf.append(allocator, '\n');
        }
    }

    pub fn destroyDragSource(self: *State) void {
        if (self.drag_source) |source| {
            wl.wl_data_source_destroy(source);
            self.drag_source = null;
        }
        self.clearDragPayload();
    }

    pub fn clearFinishedDragSource(self: *State, source: ?*wl.wl_data_source) void {
        if (self.drag_source != source) return;
        self.drag_source = null;
        self.clearDragPayload();
    }

    pub fn startWaylandFileDrag(self: *State, paths: []const []const u8) !bool {
        if (paths.len == 0) return false;
        if (self.drag_source != null) return false;
        if (self.data_device_manager == null or self.data_device == null or self.surface == null) return false;
        const serial = if (self.last_pointer_button_serial != 0) self.last_pointer_button_serial else self.last_input_serial;
        if (serial == 0) return false;

        try self.setDragPayloadPaths(paths);
        const source = wl.wl_data_device_manager_create_data_source(self.data_device_manager) orelse return false;
        errdefer wl.wl_data_source_destroy(source);

        self.drag_source = source;
        _ = wl.wl_data_source_add_listener(source, &data_source_listener, self);
        wl.wl_data_source_offer(source, dnd_mime_uri_list);
        wl.wl_data_source_offer(source, dnd_mime_gnome_copied_files);
        wl.wl_data_source_offer(source, clipboard_mime_text);
        if (self.data_device_manager_version >= 3) {
            wl.wl_data_source_set_actions(source, wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
        }
        wl.wl_data_device_start_drag(self.data_device, source, self.surface, null, serial);
        if (self.display) |display| _ = wl.wl_display_flush(display);
        return true;
    }

    pub fn addDataOffer(self: *State, offer: *wl.wl_data_offer) !void {
        const entry = try allocator.create(DataOfferState);
        entry.* = .{
            .owner = self,
            .offer = offer,
            .next = self.data_offers,
        };
        self.data_offers = entry;
        _ = wl.wl_data_offer_add_listener(offer, &data_offer_listener, entry);
    }

    pub fn findDataOffer(self: *State, offer: *wl.wl_data_offer) ?*DataOfferState {
        var it = self.data_offers;
        while (it) |entry| : (it = entry.next) {
            if (entry.offer == offer) return entry;
        }
        return null;
    }

    pub fn destroyDataOffer(self: *State, target: *DataOfferState) void {
        if (self.selection_offer == target) self.selection_offer = null;
        if (self.drag_offer == target) self.drag_offer = null;

        if (self.data_offers == target) {
            self.data_offers = target.next;
        } else {
            var it = self.data_offers;
            while (it) |entry| : (it = entry.next) {
                if (entry.next == target) {
                    entry.next = target.next;
                    break;
                }
            }
        }

        wl.wl_data_offer_destroy(target.offer);
        allocator.destroy(target);
    }

    pub fn destroyAllDataOffers(self: *State) void {
        while (self.data_offers) |entry| {
            self.destroyDataOffer(entry);
        }
    }

    pub fn destroyClipboardSource(self: *State) void {
        if (self.clipboard_source) |source| {
            wl.wl_data_source_destroy(source);
            self.clipboard_source = null;
        }
    }

    pub fn addOutput(self: *State, global_name: u32, output: *wl.wl_output) !void {
        const entry = try allocator.create(OutputState);
        entry.* = .{
            .global_name = global_name,
            .output = output,
            .next = self.outputs,
        };
        self.outputs = entry;
        _ = wl.wl_output_add_listener(output, &output_listener, self);
    }

    pub fn findOutput(self: *State, output: *wl.wl_output) ?*OutputState {
        var it = self.outputs;
        while (it) |entry| : (it = entry.next) {
            if (entry.output == output) return entry;
        }
        return null;
    }

    pub fn destroyOutputEntry(self: *State, target: *OutputState) void {
        if (self.outputs == target) {
            self.outputs = target.next;
        } else {
            var it = self.outputs;
            while (it) |entry| : (it = entry.next) {
                if (entry.next == target) {
                    entry.next = target.next;
                    break;
                }
            }
        }
        wl.wl_output_destroy(target.output);
        allocator.destroy(target);
    }

    pub fn removeOutputByGlobalName(self: *State, global_name: u32) void {
        var it = self.outputs;
        while (it) |entry| : (it = entry.next) {
            if (entry.global_name == global_name) {
                const was_entered = entry.entered;
                self.destroyOutputEntry(entry);
                if (was_entered and self.surface_preferred_scale == null) self.updateBufferMetrics();
                return;
            }
        }
    }

    pub fn destroyAllOutputs(self: *State) void {
        while (self.outputs) |entry| {
            self.destroyOutputEntry(entry);
        }
    }

    pub fn effectiveBufferScale(self: *const State) u32 {
        if (self.surface_preferred_scale) |preferred| return @max(preferred, 1);

        var scale: u32 = 1;
        var it = self.outputs;
        while (it) |entry| : (it = entry.next) {
            if (entry.entered) scale = @max(scale, entry.scale);
        }
        return scale;
    }

    pub fn setLogicalSize(self: *State, width: u32, height: u32) void {
        const previous_width = self.logical_width;
        const previous_height = self.logical_height;
        self.logical_width = @max(width, 1);
        self.logical_height = @max(height, 1);
        scrollDebug(self, "logical size {}x{} -> {}x{}", .{
            previous_width,
            previous_height,
            self.logical_width,
            self.logical_height,
        });
        if (self.ctx) |ctx| ctx.setDimensions(self.logical_width, self.logical_height);
        self.updateBufferMetrics();
    }

    pub fn updateBufferMetrics(self: *State) void {
        const next_scale = self.effectiveBufferScale();
        const next_width = self.logical_width * next_scale;
        const next_height = self.logical_height * next_scale;
        const changed = self.buffer_scale != next_scale or self.buffer_width != next_width or self.buffer_height != next_height;

        self.buffer_scale = next_scale;
        self.buffer_width = next_width;
        self.buffer_height = next_height;

        if (self.surface) |surface| {
            if (self.compositor_version >= 3) {
                wl.wl_surface_set_buffer_scale(surface, @intCast(self.buffer_scale));
            }
        }
        if (changed) {
            self.destroyAllPopupSurfaces();
            if (self.egl_window) |window| {
                wl.wl_egl_window_resize(window, @intCast(self.buffer_width), @intCast(self.buffer_height), 0, 0);
            }
            self.resetCursorTheme();
        }
        if (changed) self.needs_redraw = true;
    }

    pub fn ensureCursorSurface(self: *State) void {
        if (self.cursor_surface != null or self.compositor == null) return;
        self.cursor_surface = wl.wl_compositor_create_surface(self.compositor);
    }

    pub fn ensureCursorTheme(self: *State) void {
        if (self.shm == null) return;
        if (self.cursor_theme != null and self.cursor_theme_scale == self.buffer_scale) return;
        self.resetCursorTheme();
        const size = @as(c_int, @intCast(24 * @max(self.buffer_scale, 1)));
        self.cursor_theme = wl.wl_cursor_theme_load(null, size, self.shm);
        self.cursor_theme_scale = self.buffer_scale;
    }

    pub fn resetCursorTheme(self: *State) void {
        if (self.cursor_theme) |theme| wl.wl_cursor_theme_destroy(theme);
        self.cursor_theme = null;
        self.cursor_theme_scale = 0;
    }

    pub fn popupSurfaceForHandle(self: *State, handle: goop.NodeHandle) ?*PopupSurface {
        var it = self.popup_surfaces;
        while (it) |popup| : (it = popup.next) {
            if (popup.handle.eql(handle)) return popup;
        }
        return null;
    }

    pub fn popupSurfaceForWlSurface(self: *State, surface: ?*wl.wl_surface) ?*PopupSurface {
        const target = surface orelse return null;
        var it = self.popup_surfaces;
        while (it) |popup| : (it = popup.next) {
            if (popup.surface == target) return popup;
        }
        return null;
    }

    pub fn destroyPopupSurface(self: *State, target: *PopupSurface) void {
        var descendant_it = self.popup_surfaces;
        while (descendant_it) |popup| {
            const next = popup.next;
            if (popup != target and self.popupSurfaceDescendsFrom(popup, target.handle)) {
                self.destroyPopupSurface(popup);
            }
            descendant_it = next;
        }

        if (self.popup_surfaces == target) {
            self.popup_surfaces = target.next;
        } else {
            var it = self.popup_surfaces;
            while (it) |popup| : (it = popup.next) {
                if (popup.next == target) {
                    popup.next = target.next;
                    break;
                }
            }
        }

        if (self.egl_display != egl.EGL_NO_DISPLAY and self.egl_surface != egl.EGL_NO_SURFACE) {
            _ = egl.eglMakeCurrent(self.egl_display, self.egl_surface, self.egl_surface, self.egl_context);
        }
        if (target.egl_surface != egl.EGL_NO_SURFACE) _ = egl.eglDestroySurface(self.egl_display, target.egl_surface);
        wl.wl_egl_window_destroy(target.egl_window);
        wl.xdg_popup_destroy(target.xdg_popup);
        wl.xdg_surface_destroy(target.xdg_surface);
        wl.wl_surface_destroy(target.surface);
        allocator.destroy(target);
    }

    pub fn popupSurfaceDescendsFrom(self: *State, popup: *const PopupSurface, ancestor: goop.NodeHandle) bool {
        var current = popup.parent_popup;
        while (current) |handle| {
            if (handle.eql(ancestor)) return true;
            const parent = self.popupSurfaceForHandle(handle) orelse return false;
            current = parent.parent_popup;
        }
        return false;
    }

    pub fn destroyAllPopupSurfaces(self: *State) void {
        while (self.popup_surfaces) |popup| {
            self.destroyPopupSurface(popup);
        }
    }
};

pub fn browserViewModeLabel(mode: BrowserViewMode) []const u8 {
    return switch (mode) {
        .list => "list",
        .grid => "grid",
    };
}

pub fn scrollDebug(state: *const State, comptime fmt: []const u8, args: anytype) void {
    if (!state.scroll_debug_enabled) return;
    std.debug.print("scroll-debug: " ++ fmt ++ "\n", args);
}

pub fn layoutDebug(state: *const State, comptime fmt: []const u8, args: anytype) void {
    if (!state.layout_debug_enabled) return;
    std.debug.print("layout-debug: " ++ fmt ++ "\n", args);
}

pub fn freeOptionalOwnedSlice(buf: *?[]u8) void {
    if (buf.*) |slice| allocator.free(slice);
    buf.* = null;
}

fn clearUiStrings(state: *State) void {
    for (state.ui_strings.items) |text| allocator.free(text);
    state.ui_strings.clearRetainingCapacity();
}

fn clearAssetUiStrings(state: *State) void {
    for (state.asset_ui_strings.items) |text| allocator.free(text);
    state.asset_ui_strings.clearRetainingCapacity();
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
    return trackedPathIndex(state.folder_tree_expanded_paths.items, path) != null;
}

const FolderTreeExpansion = types.FolderTreeExpansion;

pub fn folderTreeExpansion(state: *const State, path: []const u8) FolderTreeExpansion {
    if (isFolderTreePathExpanded(state, path)) return .expanded;
    if (std.mem.eql(u8, path, state.current_dir)) return .expanded;
    if (pathHasDirectoryPrefix(state.current_dir, path)) return .partial;
    return .collapsed;
}

pub fn setFolderTreePathExpanded(state: *State, path: []const u8, expanded: bool) !bool {
    if (trackedPathIndex(state.folder_tree_expanded_paths.items, path)) |index| {
        if (expanded) return false;
        allocator.free(state.folder_tree_expanded_paths.swapRemove(index));
        return true;
    }
    if (!expanded) return false;
    try state.folder_tree_expanded_paths.append(allocator, try allocator.dupe(u8, path));
    return true;
}

pub fn preserveFolderTreeContextForNavigation(state: *State, next_dir: []const u8) !void {
    if (state.current_dir.len == 0) return;
    if (std.mem.eql(u8, state.current_dir, next_dir)) return;
    if (!pathHasDirectoryPrefix(state.current_dir, next_dir)) return;
    _ = try setFolderTreePathExpanded(state, state.current_dir, true);
}

pub fn shouldRenderFolderTreeChildForExpansion(
    state: *const State,
    parent_expansion: FolderTreeExpansion,
    index: usize,
    child_path: []const u8,
) bool {
    return switch (parent_expansion) {
        .collapsed => false,
        .partial => pathHasDirectoryPrefix(state.current_dir, child_path),
        .expanded => index < folder_tree_max_visible_children or
            pathHasDirectoryPrefix(state.current_dir, child_path) or
            isFolderTreePathExpanded(state, child_path),
    };
}

pub fn clearPlaces(state: *State) void {
    for (state.places.items) |place| allocator.free(place.path);
    state.places.clearRetainingCapacity();
}

pub fn clearSelectedPaths(state: *State) void {
    for (state.selected_paths.items) |path| allocator.free(path);
    state.selected_paths.clearRetainingCapacity();
}

pub fn clearEntries(state: *State) void {
    for (state.entries.items) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.path);
        if (entry.target_path) |target_path| allocator.free(target_path);
    }
    state.entries.clearRetainingCapacity();
}

fn clearAssetTracking(state: *State) void {
    state.asset_view_root = null;
    state.asset_table = null;
    state.asset_table_body = null;
    state.asset_grid = null;
    state.rename_input_handle = null;
    state.asset_visible_start = 0;
    state.asset_visible_end = 0;
    state.asset_visible_columns = 0;
    state.row_handles.clearRetainingCapacity();
    state.name_cell_handles.clearRetainingCapacity();
    state.grid_handles.clearRetainingCapacity();
    clearAssetUiStrings(state);
}

pub fn clearAssetBodyTracking(state: *State) void {
    state.asset_view_root = null;
    state.asset_table_body = null;
    state.asset_grid = null;
    state.rename_input_handle = null;
    state.asset_visible_start = 0;
    state.asset_visible_end = 0;
    state.asset_visible_columns = 0;
    state.row_handles.clearRetainingCapacity();
    state.name_cell_handles.clearRetainingCapacity();
    state.grid_handles.clearRetainingCapacity();
    clearAssetUiStrings(state);
}

pub fn clearUiTracking(state: *State) void {
    state.ui_root = null;
    state.btn_back = null;
    state.btn_forward = null;
    state.btn_up = null;
    state.btn_home = null;
    state.btn_refresh = null;
    state.btn_toggle_sidebar = null;
    state.btn_toggle_preview = null;
    state.btn_toggle_info = null;
    state.btn_list_view = null;
    state.btn_grid_view = null;
    state.btn_address_go = null;
    state.address_input_handle = null;
    state.nav_splitter = null;
    state.detail_splitter = null;
    state.preview_splitter = null;
    state.sidebar_scroll = null;
    state.file_panel_scroll = null;
    state.menu_file_refresh = null;
    state.menu_file_button = null;
    state.menu_edit_button = null;
    state.menu_view_button = null;
    state.menu_go_button = null;
    state.menu_help_button = null;
    state.menu_file_popup = null;
    state.menu_edit_popup = null;
    state.menu_view_popup = null;
    state.menu_go_popup = null;
    state.menu_help_popup = null;
    state.menu_file_copy_path = null;
    state.menu_file_open_target = null;
    state.menu_file_quit = null;
    state.menu_edit_copy = null;
    state.menu_edit_cut = null;
    state.menu_edit_paste = null;
    state.menu_edit_delete = null;
    state.menu_edit_rename = null;
    state.menu_edit_move_parent = null;
    state.menu_edit_select_all = null;
    state.menu_edit_clear_selection = null;
    state.menu_view_sidebar = null;
    state.menu_view_preview = null;
    state.menu_view_info = null;
    state.menu_view_status_bar = null;
    state.menu_view_list = null;
    state.menu_view_grid = null;
    state.menu_view_sort_directories = null;
    state.menu_go_back = null;
    state.menu_go_forward = null;
    state.menu_go_up = null;
    state.menu_go_home = null;
    state.menu_help_about = null;
    state.context_popup = null;
    state.context_open = null;
    state.context_copy = null;
    state.context_cut = null;
    state.context_paste = null;
    state.context_delete = null;
    state.context_rename = null;
    state.context_move_parent = null;
    state.context_copy_path = null;
    state.context_open_link_target = null;
    state.rename_input_handle = null;
    clearAssetTracking(state);
    state.place_handles.clearRetainingCapacity();
    state.folder_tree_handles.clearRetainingCapacity();
    state.breadcrumb_handles.clearRetainingCapacity();
    clearUiStrings(state);
    clearTrackedPaths(&state.folder_tree_paths);
    clearTrackedPaths(&state.breadcrumb_paths);
}

pub fn deinitBrowserState(state: *State) void {
    clearUiTracking(state);
    clearEntries(state);
    clearPlaces(state);
    clearSelectedPaths(state);
    for (state.history.items) |path| allocator.free(path);
    state.history.deinit(allocator);
    state.places.deinit(allocator);
    state.entries.deinit(allocator);
    state.selected_paths.deinit(allocator);
    state.place_handles.deinit(allocator);
    state.folder_tree_handles.deinit(allocator);
    state.breadcrumb_handles.deinit(allocator);
    state.folder_tree_paths.deinit(allocator);
    clearTrackedPaths(&state.folder_tree_expanded_paths);
    state.folder_tree_expanded_paths.deinit(allocator);
    state.breadcrumb_paths.deinit(allocator);
    state.row_handles.deinit(allocator);
    state.name_cell_handles.deinit(allocator);
    state.grid_handles.deinit(allocator);
    state.ui_strings.deinit(allocator);
    state.asset_ui_strings.deinit(allocator);
    state.composed_paint_commands.deinit(allocator);
    if (state.current_dir.len > 0) allocator.free(state.current_dir);
    state.current_dir = &.{};
    freeOptionalOwnedSlice(&state.selected_path);
    freeOptionalOwnedSlice(&state.last_click_path);
    freeOptionalOwnedSlice(&state.context_target_path);
    freeOptionalOwnedSlice(&state.rename_path);
}

pub fn trackUiString(state: *State, text: []u8) ![]const u8 {
    try state.ui_strings.append(allocator, text);
    return text;
}

fn trackAssetUiString(state: *State, text: []u8) ![]const u8 {
    try state.asset_ui_strings.append(allocator, text);
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

    const text_ctx = state.text_measure_ctx;
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

    const text_ctx = state.text_measure_ctx;
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
    return state.io orelse error.IoUnavailable;
}

fn setAddressInputText(state: *State, text: []const u8) void {
    state.address_input = .{ .placeholder = "Path" };
    state.address_input.insertSlice(text);
    state.address_input.cursor = state.address_input.len;
}

pub fn syncAddressInputToCurrentDir(state: *State) void {
    setAddressInputText(state, state.current_dir);
}

fn syncAddressInputFromWidget(state: *State, ctx: *goop.Context) void {
    const handle = state.address_input_handle orelse return;
    if (!ctx.tree.isAlive(handle)) return;
    if (ctx.tree.getConst(handle).kind != .text_input) return;
    state.address_input = ctx.tree.getConst(handle).kind.text_input;
}

fn syncRenameInputFromWidget(state: *State, ctx: *goop.Context) void {
    const handle = state.rename_input_handle orelse return;
    if (!ctx.tree.isAlive(handle)) return;
    if (ctx.tree.getConst(handle).kind != .text_input) return;
    state.rename_input = ctx.tree.getConst(handle).kind.text_input;
}

fn addressInputPathAlloc(state: *const State) ![]u8 {
    const typed = std.mem.trim(u8, state.address_input.content(), " \t\r\n");
    if (typed.len == 0) return allocator.dupe(u8, state.current_dir);

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
    const joined = try std.fs.path.resolve(allocator, &.{ state.current_dir, typed });
    defer allocator.free(joined);
    return normalizeDirectoryPath(allocator, joined);
}

fn selectedPathForClipboard(state: *const State) []const u8 {
    if (state.selected_path) |selected_path| return selected_path;
    return state.current_dir;
}

pub fn isPathSelected(state: *const State, path: []const u8) bool {
    for (state.selected_paths.items) |selected| {
        if (std.mem.eql(u8, selected, path)) return true;
    }
    return false;
}

pub fn selectedPathCount(state: *const State) usize {
    return state.selected_paths.items.len;
}

pub fn selectedEntryExists(state: *const State, path: []const u8) bool {
    for (state.entries.items) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return true;
    }
    return false;
}

pub fn setSelectedPath(state: *State, path: ?[]const u8) !void {
    freeOptionalOwnedSlice(&state.selected_path);
    if (path) |value| state.selected_path = try allocator.dupe(u8, value);
}

fn setContextTargetPath(state: *State, path: ?[]const u8) !void {
    freeOptionalOwnedSlice(&state.context_target_path);
    if (path) |value| state.context_target_path = try allocator.dupe(u8, value);
}

fn setLastClickPath(state: *State, path: ?[]const u8) !void {
    freeOptionalOwnedSlice(&state.last_click_path);
    if (path) |value| state.last_click_path = try allocator.dupe(u8, value);
}

fn clearRenameState(state: *State) void {
    freeOptionalOwnedSlice(&state.rename_path);
    state.rename_input = .{};
    state.rename_input_handle = null;
    state.rename_commit_requested = false;
    state.rename_cancel_requested = false;
}

pub fn isRenamingPath(state: *const State, path: []const u8) bool {
    const rename_path = state.rename_path orelse return false;
    return std.mem.eql(u8, rename_path, path);
}

pub fn beginRenameEntry(state: *State, ctx: *goop.Context, entry: BrowserEntry) !void {
    clearRenameState(state);
    state.rename_path = try allocator.dupe(u8, entry.path);
    state.rename_input = .{};
    state.rename_input.insertSlice(entry.name);
    state.rename_input.selection_anchor = 0;
    state.rename_input.cursor = state.rename_input.len;
    state.status_note = null;
    ctx.invalidate();
}

fn cancelActiveRename(state: *State) bool {
    if (state.rename_path == null) return false;
    clearRenameState(state);
    state.status_note = null;
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
    const old_path = state.rename_path orelse return .inactive;
    const new_name = state.rename_input.content();
    if (!validRenameFileName(new_name)) {
        state.status_note = "File names cannot be empty or contain '/'.";
        return .blocked;
    }

    if (std.mem.eql(u8, new_name, std.fs.path.basename(old_path))) {
        clearRenameState(state);
        state.status_note = null;
        return .closed;
    }

    const new_path = try joinPath(allocator, state.current_dir, new_name);
    defer allocator.free(new_path);

    const io = state.io orelse {
        state.status_note = "Unable to rename this file.";
        return .blocked;
    };
    if (std.Io.Dir.cwd().statFile(io, new_path, .{ .follow_symlinks = false })) |_| {
        state.status_note = "A file with that name already exists.";
        return .blocked;
    } else |_| {}

    std.Io.Dir.renameAbsolute(old_path, new_path, io) catch {
        state.status_note = "Unable to rename this file.";
        return .blocked;
    };

    clearSelectedPaths(state);
    try appendSelectedPathIfMissing(state, new_path);
    try setSelectedPath(state, new_path);
    freeOptionalOwnedSlice(&state.last_click_path);
    state.last_click_ms = 0;
    clearRenameState(state);
    try loadDirectoryEntries(state);
    state.status_note = "Renamed file.";
    return .closed;
}

fn currentPrimaryClickTimestampMs(ctx: *const goop.Context, io: std.Io) u64 {
    const event_ms = ctx.frame().last_primary_press_ms;
    if (event_ms != 0) return event_ms;
    return getMonotonicNs(io) / std.time.ns_per_ms;
}

fn isRepeatedEntryClick(state: *const State, entry: *const BrowserEntry, click_ms: u64) bool {
    const last_path = state.last_click_path orelse return false;
    if (state.last_click_ms == 0 or click_ms < state.last_click_ms) return false;
    if (!std.mem.eql(u8, last_path, entry.path)) return false;
    return click_ms - state.last_click_ms <= browser_double_click_time_ms;
}

pub fn syncPrimarySelection(state: *State) !void {
    if (state.selected_path) |selected_path| {
        if (isPathSelected(state, selected_path)) return;
        freeOptionalOwnedSlice(&state.selected_path);
    }

    if (state.selected_paths.items.len > 0) {
        try setSelectedPath(state, state.selected_paths.items[0]);
    }
}

fn selectedPathIndex(state: *const State, path: []const u8) ?usize {
    for (state.selected_paths.items, 0..) |selected, index| {
        if (std.mem.eql(u8, selected, path)) return index;
    }
    return null;
}

pub fn appendSelectedPathIfMissing(state: *State, path: []const u8) !void {
    if (selectedPathIndex(state, path) != null) return;
    try state.selected_paths.append(allocator, try allocator.dupe(u8, path));
}

fn removeSelectedPath(state: *State, path: []const u8) bool {
    const index = selectedPathIndex(state, path) orelse return false;
    allocator.free(state.selected_paths.orderedRemove(index));
    return true;
}

pub fn syncSelectionAnchor(state: *State) void {
    state.selection_anchor_index = selectedEntryIndex(state);
}

fn applyEntrySelectionClick(state: *State, entry_index: usize) !void {
    if (entry_index >= state.entries.items.len) return;
    const entry = state.entries.items[entry_index];

    if (state.shift_down) {
        const anchor = state.selection_anchor_index orelse entry_index;
        if (!state.ctrl_down) clearSelectedPaths(state);

        const start = @min(anchor, entry_index);
        const end = @max(anchor, entry_index);
        for (start..end + 1) |index| {
            try appendSelectedPathIfMissing(state, state.entries.items[index].path);
        }
        state.selection_anchor_index = anchor;
    } else if (state.ctrl_down) {
        state.selection_anchor_index = entry_index;
        if (!removeSelectedPath(state, entry.path)) {
            try appendSelectedPathIfMissing(state, entry.path);
        }
    } else {
        clearSelectedPaths(state);
        try appendSelectedPathIfMissing(state, entry.path);
        state.selection_anchor_index = entry_index;
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
            const entry_index = assetEntryIndexFromUserId(state, user_id) orelse state.asset_visible_start + row_index;
            if (entry_index < state.entries.items.len) {
                try state.selected_paths.append(allocator, try allocator.dupe(u8, state.entries.items[entry_index].path));
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
            const entry_index = assetEntryIndexFromUserId(state, user_id) orelse state.asset_visible_start + item_index;
            if (entry_index < state.entries.items.len) {
                try state.selected_paths.append(allocator, try allocator.dupe(u8, state.entries.items[entry_index].path));
            }
        }
        item_index += 1;
    }

    try syncPrimarySelection(state);
}

fn assetEntryIndexFromUserId(state: *const State, user_id: u64) ?usize {
    if (widgetUserKind(user_id) != .asset_entry) return null;
    const entry_index = widgetUserIndex(user_id);
    if (entry_index < state.entries.items.len) return entry_index;
    return null;
}

fn borrowedDropDestinationPathForUserId(state: *const State, user_id: u64) ?[]const u8 {
    const index = widgetUserIndex(user_id);
    return switch (widgetUserKind(user_id)) {
        .place => if (index < state.places.items.len) state.places.items[index].path else null,
        .folder_tree => if (index < state.folder_tree_paths.items.len) state.folder_tree_paths.items[index] else null,
        .breadcrumb => if (index < state.breadcrumb_paths.items.len) state.breadcrumb_paths.items[index] else null,
        else => null,
    };
}

fn handleAssetTableDrop(state: *State, ctx: *const goop.Context, drop: goop.ContainerDrop) !bool {
    if (drop.position != .item) return false;
    const source_index = assetEntryIndexFromUserId(state, ctx.tree.userId(drop.source)) orelse return false;
    const target_index = assetEntryIndexFromUserId(state, ctx.tree.userId(drop.target)) orelse return false;
    if (source_index == target_index) return false;

    const source_path = state.entries.items[source_index].path;
    const target_entry = state.entries.items[target_index];
    if (!target_entry.canEnter()) {
        state.status_note = "Drop files on a directory.";
        return true;
    }

    return moveDropPathsToDirectory(state, source_path, target_entry.navigationPath());
}

fn handleAssetGridDrop(state: *State, ctx: *const goop.Context, drop: goop.ContainerDrop) !bool {
    if (drop.position != .item) return false;
    const source_index = assetEntryIndexFromUserId(state, ctx.tree.userId(drop.source)) orelse return false;
    const target_index = assetEntryIndexFromUserId(state, ctx.tree.userId(drop.target)) orelse return false;
    if (source_index == target_index) return false;

    const source_path = state.entries.items[source_index].path;
    const target_entry = state.entries.items[target_index];
    if (!target_entry.canEnter()) {
        state.status_note = "Drop files on a directory.";
        return true;
    }

    return moveDropPathsToDirectory(state, source_path, target_entry.navigationPath());
}

fn handleAssetWidgetDrop(state: *State, ctx: *const goop.Context, drop: goop.WidgetDrop) !bool {
    const source_index = assetEntryIndexFromUserId(state, ctx.tree.userId(drop.source)) orelse return false;
    const source_path = state.entries.items[source_index].path;

    const target_user_id = ctx.tree.userId(drop.target);
    if (widgetUserKind(target_user_id) == .toolbar_up) {
        const parent = try parentPathAlloc(allocator, state.current_dir);
        defer if (parent) |path| allocator.free(path);
        const parent_path = parent orelse return false;
        return moveDropPathsToDirectory(state, source_path, parent_path);
    }

    const target_dir = borrowedDropDestinationPathForUserId(state, target_user_id) orelse return false;
    return moveDropPathsToDirectory(state, source_path, target_dir);
}

fn maybeStartWaylandAssetDrag(state: *State, ctx: *goop.Context) !bool {
    if (state.drag_source != null) return false;
    const f = ctx.frame();
    if (!f.buttons.left) return false;
    const drag_target = f.drag_source orelse return false;
    const pointer = f.pointer;
    const pointer_outside_window = !state.pointer_inside or
        pointer.x < 0 or
        pointer.y < 0 or
        pointer.x >= @as(f32, @floatFromInt(state.logical_width)) or
        pointer.y >= @as(f32, @floatFromInt(state.logical_height));
    if (!pointer_outside_window) return false;

    const entry_index = assetEntryIndexFromUserId(state, ctx.tree.userId(drag_target)) orelse return false;

    const source_path = state.entries.items[entry_index].path;
    const started = if (isPathSelected(state, source_path) and state.selected_paths.items.len > 0)
        try state.startWaylandFileDrag(state.selected_paths.items)
    else blk: {
        const single_path = [_][]const u8{source_path};
        break :blk try state.startWaylandFileDrag(single_path[0..]);
    };

    if (started) {
        ctx.cancelPointerGesture();
        state.asset_selection_rebuild_pending = false;
        state.needs_redraw = true;
    }
    return started;
}

fn selectedEntryIndex(state: *const State) ?usize {
    const selected_path = state.selected_path orelse return null;
    for (state.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.path, selected_path)) return index;
    }
    return null;
}

pub fn selectedEntry(state: *const State) ?*const BrowserEntry {
    const index = selectedEntryIndex(state) orelse return null;
    return &state.entries.items[index];
}

pub fn clearSelectionState(state: *State) bool {
    if (state.selected_paths.items.len == 0 and state.selected_path == null) return false;
    clearSelectedPaths(state);
    freeOptionalOwnedSlice(&state.selected_path);
    freeOptionalOwnedSlice(&state.last_click_path);
    state.last_click_ms = 0;
    state.selection_anchor_index = null;
    return true;
}

fn selectAllEntries(state: *State) !bool {
    if (state.entries.items.len == 0) return false;
    if (state.selected_paths.items.len == state.entries.items.len) return false;

    clearSelectedPaths(state);
    for (state.entries.items) |entry| {
        try state.selected_paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    try setSelectedPath(state, state.entries.items[0].path);
    syncSelectionAnchor(state);
    freeOptionalOwnedSlice(&state.last_click_path);
    state.last_click_ms = 0;
    return true;
}

fn contextTargetEntry(state: *const State) ?*const BrowserEntry {
    const path = state.context_target_path orelse return null;
    return entryForPath(state, path);
}

pub fn contextOpenEnabled(state: *const State) bool {
    const path = state.context_target_path orelse return false;
    const entry = entryForPath(state, path) orelse return true;
    return entry.canEnter();
}

pub fn contextCopyPathEnabled(state: *const State) bool {
    return state.context_target_path != null;
}

pub fn contextOpenLinkTargetEnabled(state: *const State) bool {
    const entry = contextTargetEntry(state) orelse return false;
    return entry.isSymlinkToDirectory();
}

fn contextClickPosition(state: *const State, ctx: *const goop.Context) struct { x: f32, y: f32 } {
    if (ctx.frame().last_secondary_click) |click| {
        return .{ .x = click.x, .y = click.y };
    }
    return .{ .x = state.mouse_x, .y = state.mouse_y };
}

fn showContextMenuForPath(state: *State, ctx: *goop.Context, path: []const u8) !void {
    setTopMenuPopupVisible(state, ctx, null);
    try setContextTargetPath(state, path);
    const position = contextClickPosition(state, ctx);
    state.context_x = position.x;
    state.context_y = position.y;
    state.context_visible = true;
    ctx.invalidate();
}

fn hideContextMenu(state: *State, ctx: *goop.Context) void {
    state.context_visible = false;
    if (state.context_popup) |popup| {
        if (ctx.tree.isAlive(popup) and ctx.tree.getConst(popup).kind == .popup) {
            if (ctx.mutateKind(popup)) |__k| {
                __k.popup.visible = false;
            }
        }
    }
    ctx.invalidate();
}

fn syncContextPopupVisibleFromWidget(state: *State, ctx: *const goop.Context) void {
    const popup = state.context_popup orelse return;
    if (!ctx.tree.isAlive(popup) or ctx.tree.getConst(popup).kind != .popup) return;
    state.context_visible = ctx.tree.getConst(popup).kind.popup.visible;
}

fn selectEntryForContextMenu(state: *State, entry_index: usize) !void {
    if (entry_index >= state.entries.items.len) return;
    const entry = state.entries.items[entry_index];
    if (!isPathSelected(state, entry.path)) {
        clearSelectedPaths(state);
        try appendSelectedPathIfMissing(state, entry.path);
    }
    try setSelectedPath(state, entry.path);
    state.selection_anchor_index = entry_index;
}

fn openContextTarget(state: *State) !bool {
    const path = state.context_target_path orelse return false;
    if (entryForPath(state, path)) |entry| {
        if (!entry.canEnter()) return false;
        state.status_note = null;
        return setCurrentDirectory(state, entry.navigationPath(), true);
    }
    state.status_note = null;
    return setCurrentDirectory(state, path, true);
}

fn copyContextTargetPath(state: *State) !bool {
    const path = state.context_target_path orelse return false;
    try state.setClipboardSelection(path);
    state.status_note = "Copied path to clipboard.";
    return false;
}

fn openContextLinkTarget(state: *State) !bool {
    const entry = contextTargetEntry(state) orelse return false;
    if (!entry.isSymlinkToDirectory()) return false;
    state.status_note = null;
    return setCurrentDirectory(state, entry.target_path.?, true);
}

pub fn selectionFileCommandEnabled(state: *const State) bool {
    return state.selected_paths.items.len > 0;
}

pub fn renameSelectionEnabled(state: *const State) bool {
    return state.selected_paths.items.len == 1 and selectedEntry(state) != null;
}

pub fn moveSelectionToParentEnabled(state: *const State) bool {
    return selectionFileCommandEnabled(state) and !std.mem.eql(u8, state.current_dir, "/");
}

pub fn fileClipboardAvailable(state: *const State) bool {
    if (state.clipboard_file_action != null and state.clipboard_buf.items.len > 0) return true;
    const offer = state.selection_offer orelse return false;
    return preferredFileOfferMime(offer) != null;
}

pub fn targetPathCanAcceptPaste(state: *const State, path: []const u8) bool {
    if (!fileClipboardAvailable(state)) return false;
    if (entryForPath(state, path)) |entry| return entry.canEnter();
    const io = state.io orelse return false;
    ensureDirectoryOpenable(io, path) catch return false;
    return true;
}

pub fn contextSelectionCommandEnabled(state: *const State) bool {
    const path = state.context_target_path orelse return false;
    return entryForPath(state, path) != null and state.selected_paths.items.len > 0;
}

pub fn contextRenameEnabled(state: *const State) bool {
    const path = state.context_target_path orelse return false;
    return entryForPath(state, path) != null and renameSelectionEnabled(state);
}

pub fn contextMoveParentEnabled(state: *const State) bool {
    const path = state.context_target_path orelse return false;
    return entryForPath(state, path) != null and moveSelectionToParentEnabled(state);
}

pub fn contextPasteEnabled(state: *const State) bool {
    const path = state.context_target_path orelse return false;
    return targetPathCanAcceptPaste(state, path);
}

fn copyOrCutSelection(state: *State, action: FileClipboardAction) !bool {
    if (state.selected_paths.items.len == 0) return false;
    try state.setFileClipboardSelection(state.selected_paths.items, action);
    state.status_note = if (action == .cut) "Cut files to clipboard." else "Copied files to clipboard.";
    return false;
}

fn collectClipboardFilePaths(state: *State, paths: *std.ArrayListUnmanaged([]u8)) !?FileClipboardAction {
    clearTrackedPaths(paths);

    if (state.clipboard_file_action) |action| {
        var lines = std.mem.splitScalar(u8, state.clipboard_buf.items, '\n');
        while (lines.next()) |line| {
            const path = std.mem.trimEnd(u8, line, "\r");
            if (path.len == 0) continue;
            try paths.append(allocator, try allocator.dupe(u8, path));
        }
        return if (paths.items.len > 0) action else null;
    }

    const offer = state.selection_offer orelse return null;
    const mime = preferredFileOfferMime(offer) orelse return null;
    try state.fetchClipboardSelection(true);

    var action: FileClipboardAction = .copy;
    var lines = std.mem.splitScalar(u8, state.clipboard_buf.items, '\n');
    if (std.mem.eql(u8, std.mem.span(mime), dnd_mime_gnome_copied_files)) {
        const first = lines.next() orelse return null;
        const command = std.mem.trimEnd(u8, first, "\r");
        action = if (std.mem.eql(u8, command, "cut")) .cut else .copy;
    }

    while (lines.next()) |line| {
        try appendClipboardPathFromFileUri(paths, line);
    }

    return if (paths.items.len > 0) action else null;
}

fn pasteFilesToDirectory(state: *State, target_dir: []const u8) !bool {
    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        clearTrackedPaths(&paths);
        paths.deinit(allocator);
    }

    const action = (try collectClipboardFilePaths(state, &paths)) orelse {
        state.status_note = "Clipboard does not contain files.";
        return false;
    };

    const changed = switch (action) {
        .copy => try copyPathsToDirectory(state, paths.items, target_dir),
        .cut => try movePathsToDirectory(state, paths.items, target_dir),
    };
    if (changed and action == .cut and state.clipboard_file_action != null) {
        state.destroyClipboardSource();
        state.clearClipboardFilePayload();
    }
    return changed;
}

fn pasteContextTarget(state: *State) !bool {
    const path = state.context_target_path orelse return false;
    const target_dir = if (entryForPath(state, path)) |entry| blk: {
        if (!entry.canEnter()) return false;
        break :blk entry.navigationPath();
    } else path;
    return pasteFilesToDirectory(state, target_dir);
}

fn deleteSelection(state: *State) !bool {
    if (state.selected_paths.items.len == 0) return false;
    return deletePaths(state, state.selected_paths.items);
}

fn moveSelectionToParent(state: *State) !bool {
    if (!moveSelectionToParentEnabled(state)) return false;
    const parent = try parentPathAlloc(allocator, state.current_dir);
    defer if (parent) |path| allocator.free(path);
    const parent_path = parent orelse return false;
    return movePathsToDirectory(state, state.selected_paths.items, parent_path);
}

fn beginRenameSelection(state: *State, ctx: *goop.Context) !bool {
    if (!renameSelectionEnabled(state)) return false;
    const entry = selectedEntry(state) orelse return false;
    try beginRenameEntry(state, ctx, entry.*);
    return true;
}

pub fn browserCommandChecked(state: *const State, command: BrowserCommand) bool {
    return switch (command) {
        .toggle_sidebar => state.show_sidebar,
        .toggle_preview => state.show_preview,
        .toggle_info => state.show_info,
        .toggle_status_bar => state.show_status_bar,
        .view_list => state.view_mode == .list,
        .view_grid => state.view_mode == .grid,
        .toggle_sort_directories => state.sort_directories_together,
        else => false,
    };
}

pub fn browserCommandEnabled(state: *const State, command: BrowserCommand) bool {
    return switch (command) {
        .back => state.history_index > 0 and state.history.items.len > 0,
        .forward => state.history.items.len > 0 and state.history_index + 1 < state.history.items.len,
        .up => !std.mem.eql(u8, state.current_dir, "/"),
        .home => homePath(state) != null,
        .refresh => true,
        .copy, .cut, .delete => selectionFileCommandEnabled(state),
        .paste => fileClipboardAvailable(state),
        .rename => renameSelectionEnabled(state),
        .move_parent => moveSelectionToParentEnabled(state),
        .copy_path => true,
        .open_link_target => selectedSymlinkDirectoryEntry(state) != null,
        .quit => true,
        .select_all => state.entries.items.len > 0,
        .clear_selection => state.selected_paths.items.len > 0,
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
            state.status_note = null;
            return navigateBack(state);
        },
        .forward => {
            state.status_note = null;
            return navigateForward(state);
        },
        .up => {
            state.status_note = null;
            return navigateUp(state);
        },
        .home => {
            if (homePath(state)) |home| {
                state.status_note = null;
                return setCurrentDirectory(state, home, true);
            }
            return false;
        },
        .refresh => {
            state.status_note = null;
            try refreshCurrentDirectory(state);
            return true;
        },
        .copy => return copyOrCutSelection(state, .copy),
        .cut => return copyOrCutSelection(state, .cut),
        .paste => return pasteFilesToDirectory(state, state.current_dir),
        .delete => return deleteSelection(state),
        .rename => return false,
        .move_parent => return moveSelectionToParent(state),
        .copy_path => {
            try state.setClipboardSelection(selectedPathForClipboard(state));
            state.status_note = "Copied path to clipboard.";
            return false;
        },
        .open_link_target => {
            const entry = selectedSymlinkDirectoryEntry(state) orelse return false;
            state.status_note = null;
            return setCurrentDirectory(state, entry.target_path.?, true);
        },
        .quit => {
            state.running = false;
            return false;
        },
        .select_all => {
            state.status_note = null;
            return selectAllEntries(state);
        },
        .clear_selection => {
            state.status_note = null;
            return clearSelectionState(state);
        },
        .toggle_sidebar => {
            state.show_sidebar = !state.show_sidebar;
            return true;
        },
        .toggle_preview => {
            state.show_preview = !state.show_preview;
            return true;
        },
        .toggle_info => {
            state.show_info = !state.show_info;
            return true;
        },
        .toggle_status_bar => {
            state.show_status_bar = !state.show_status_bar;
            return true;
        },
        .view_list => {
            if (state.view_mode == .list) return false;
            state.view_mode = .list;
            return true;
        },
        .view_grid => {
            if (state.view_mode == .grid) return false;
            state.view_mode = .grid;
            return true;
        },
        .toggle_sort_directories => {
            state.sort_directories_together = !state.sort_directories_together;
            sortDirectoryEntries(state);
            syncSelectionAnchor(state);
            return true;
        },
        .about => {
            state.status_note = "goop files: a Wayland/EGL/snail file manager demo.";
            return false;
        },
    }
}

fn setTopMenuPopupVisible(state: *const State, ctx: *goop.Context, target: ?goop.NodeHandle) void {
    const popups = [_]?goop.NodeHandle{
        state.menu_file_popup,
        state.menu_edit_popup,
        state.menu_view_popup,
        state.menu_go_popup,
        state.menu_help_popup,
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

pub fn loadFont(alloc: std.mem.Allocator, env: *const std.process.Environ.Map, io: std.Io) ![]u8 {
    if (fontPathFromEnv(env)) |path| {
        return readFile(alloc, io, path);
    }

    if (try fontPathFromFontconfig(alloc, io)) |path| {
        defer alloc.free(path);
        if (readFile(alloc, io, path)) |font_data| {
            return font_data;
        } else |_| {}
    }

    const fallback_paths = [_][]const u8{
        "/run/current-system/sw/share/X11/fonts/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
    };
    for (fallback_paths) |path| {
        return readFile(alloc, io, path) catch continue;
    }

    std.debug.print("font not found; set GOOP_DEMO_FONT_PATH to a TTF file\n", .{});
    return error.FontNotFound;
}

fn fontPathFromEnv(env: *const std.process.Environ.Map) ?[]const u8 {
    return env.get("GOOP_DEMO_FONT_PATH");
}

fn fontPathFromFontconfig(alloc: std.mem.Allocator, io: std.Io) !?[]u8 {
    const patterns = [_][]const u8{
        "Noto Sans:style=Regular",
        "sans-serif:style=Regular",
    };

    for (patterns) |pattern| {
        const result = std.process.run(alloc, io, .{
            .argv = &.{ "fc-match", "-f", "%{file}\n", pattern },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        }) catch continue;
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) continue,
            else => continue,
        }

        const line = std.mem.trimEnd(u8, result.stdout, "\r\n");
        if (line.len == 0) continue;
        return @as(?[]u8, try alloc.dupe(u8, line));
    }

    return null;
}

fn readFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const buf = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(256 * 1024 * 1024));
    std.debug.print("loaded font: {s} ({} bytes)\n", .{ path, buf.len });
    return buf;
}

// ── Main ──

fn parseTimeout(env: *const std.process.Environ.Map) ?u64 {
    const val = env.get("GOOP_DEMO_TIMEOUT") orelse return null;
    const secs = std.fmt.parseFloat(f64, val) catch return null;
    if (secs <= 0) return null;
    return @intFromFloat(secs * @as(f64, @floatFromInt(std.time.ns_per_s)));
}

fn getMonotonicNs(io: std.Io) u64 {
    const ns = std.Io.Clock.awake.now(io).nanoseconds;
    return if (ns <= 0) 0 else @intCast(ns);
}

fn initStateFromEnvironment(state: *State, display: *wl.wl_display, init: std.process.Init) void {
    state.display = display;
    state.io = init.io;
    state.env = init.environ_map;
    state.timeout_ns = parseTimeout(init.environ_map);
    state.ui_scale = envScale(init.environ_map, "GOOP_FILE_MANAGER_UI_SCALE", 1);
    state.scroll_debug_enabled = envFlag(init.environ_map, "GOOP_FILE_BROWSER_SCROLL_DEBUG");
    state.layout_debug_enabled = envFlag(init.environ_map, "GOOP_FILE_BROWSER_LAYOUT_DEBUG");
    if (state.timeout_ns != null) state.start_time_ns = getMonotonicNs(init.io);
}

fn logStartupOptions(state: *const State) void {
    if (state.timeout_ns) |t| {
        std.debug.print("demo will exit after {d:.1}s\n", .{@as(f64, @floatFromInt(t)) / std.time.ns_per_s});
    }
    if (state.scroll_debug_enabled) {
        std.debug.print("scroll-debug enabled via GOOP_FILE_BROWSER_SCROLL_DEBUG\n", .{});
    }
    if (state.layout_debug_enabled) {
        std.debug.print("layout-debug enabled via GOOP_FILE_BROWSER_LAYOUT_DEBUG\n", .{});
    }
    if (@abs(state.ui_scale - 1) > 0.001) {
        std.debug.print("ui-scale enabled via GOOP_FILE_MANAGER_UI_SCALE={d:.2}\n", .{state.ui_scale});
    }
}

fn createWaylandWindow(state: *State, display: *wl.wl_display) !void {
    const registry = wl.wl_display_get_registry(display) orelse return error.NoRegistry;
    _ = wl.wl_registry_add_listener(registry, &registry_listener, state);
    _ = wl.wl_display_roundtrip(display);

    if (state.compositor == null) return error.NoCompositor;
    if (state.wm_base == null) return error.NoXdgWmBase;

    state.surface = wl.wl_compositor_create_surface(state.compositor) orelse return error.NoSurface;
    _ = wl.wl_surface_add_listener(state.surface, &surface_listener, state);
    state.xdg_surface = wl.xdg_wm_base_get_xdg_surface(state.wm_base, state.surface) orelse return error.NoXdgSurface;
    _ = wl.xdg_surface_add_listener(state.xdg_surface, &xdg_surface_listener, state);
    state.xdg_toplevel = wl.xdg_surface_get_toplevel(state.xdg_surface) orelse return error.NoToplevel;
    _ = wl.xdg_toplevel_add_listener(state.xdg_toplevel, &xdg_toplevel_listener, state);
    wl.xdg_toplevel_set_title(state.xdg_toplevel, "goop files");
    wl.xdg_toplevel_set_app_id(state.xdg_toplevel, "goop-files");
    wl.wl_surface_commit(state.surface.?);
    _ = wl.wl_display_roundtrip(display);
}

fn timeoutReached(state: *const State, io: std.Io) bool {
    const timeout = state.timeout_ns orelse return false;
    const now = getMonotonicNs(io);
    return now - state.start_time_ns >= timeout;
}

fn dispatchWaylandEvents(state: *State, display: *wl.wl_display) bool {
    // Pending redraws must not block here; the first frame callback is
    // only requested after the first render.
    if (state.needs_redraw and !state.frame_pending) {
        _ = wl.wl_display_dispatch_pending(display);
        _ = wl.wl_display_flush(display);
        return true;
    }

    if (state.timeout_ns != null) {
        while (wl.wl_display_prepare_read(display) != 0)
            _ = wl.wl_display_dispatch_pending(display);
        _ = wl.wl_display_flush(display);

        var pfd = [_]posix.pollfd{.{
            .fd = wl.wl_display_get_fd(display),
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const poll_ret = posix.poll(&pfd, 100) catch return false;
        if (poll_ret > 0) {
            _ = wl.wl_display_read_events(display);
            _ = wl.wl_display_dispatch_pending(display);
        } else {
            wl.wl_display_cancel_read(display);
        }
        return true;
    }

    return wl.wl_display_dispatch(display) != -1;
}

fn cleanupPlatformState(state: *State) void {
    state.destroyAllPopupSurfaces();
    state.destroyAllDataOffers();
    state.destroyAllOutputs();
    state.destroyDragSource();
    state.destroyClipboardSource();
    deinitBrowserState(state);
    state.clipboard_buf.deinit(allocator);
    state.clipboard_uri_list_buf.deinit(allocator);
    state.clipboard_gnome_files_buf.deinit(allocator);
    state.drag_uri_list_buf.deinit(allocator);
    state.drag_plain_buf.deinit(allocator);
    state.drag_gnome_files_buf.deinit(allocator);
    if (state.data_device) |data_device| wl.wl_data_device_release(data_device);
    if (state.data_device_manager) |manager| wl.wl_data_device_manager_destroy(manager);
    state.resetCursorTheme();
    if (state.cursor_surface) |cursor_surface| wl.wl_surface_destroy(cursor_surface);
    if (state.shm) |shm| wl.wl_shm_destroy(shm);
    if (state.xkb_state) |s| xkb.xkb_state_unref(s);
    if (state.xkb_keymap) |k| xkb.xkb_keymap_unref(k);
    if (state.xkb_ctx) |c| xkb.xkb_context_unref(c);
}

fn layoutAndRenderFrame(
    state: *State,
    ctx: *goop.Context,
    renderer: *render.Renderer,
    text_atlas: *snail.TextAtlas,
    text_measure: *SnailTextCtx,
    ensured_text: *std.BufSet,
    text_measure_ctx: *const goop.TextMeasureCtx,
) !void {
    // Event handlers can rebuild the widget tree after the initial hit-test
    // layout pass, so run layout again if the tree became dirty.
    ctx.doLayout(text_measure_ctx);
    if (try refreshAssetViewportIfNeeded(state)) {
        ctx.doLayout(text_measure_ctx);
    }
    debugLogFilePanelLayout(state);
    updatePointerCursor(state);

    var atlas_paint_list = try goop.paint.generatePaint(&ctx.tree, ctx.theme, allocator, state.text_measure_ctx, .{});
    defer goop.paint.freePaintList(&atlas_paint_list, allocator);
    if (try ensureAtlasForPaintList(ensured_text, text_atlas, renderer, atlas_paint_list)) {
        const updated_metrics = fontLineMetrics(text_atlas);
        text_measure.ascent_units = updated_metrics.ascent;
        text_measure.descent_units = updated_metrics.descent;
        ctx.setDimensions(state.logical_width, state.logical_height);
        ctx.doLayout(text_measure_ctx);
    }

    try syncNativePopupSurfaces(state, ctx);
    var base_paint_list = try goop.paint.generatePaint(&ctx.tree, ctx.theme, allocator, state.text_measure_ctx, .{ .scope = .{ .full = .{ .include_floating = false } } });
    defer goop.paint.freePaintList(&base_paint_list, allocator);
    const paint_list = try composeFileBrowserPaintList(state, base_paint_list);

    renderer.beginFrame(state.buffer_width, state.buffer_height, @floatFromInt(state.buffer_scale));
    renderer.renderPaintList(paint_list);

    // Request frame callback BEFORE swap — the callback must be
    // registered before the surface commit that eglSwapBuffers triggers.
    requestFrame(state);
    _ = egl.eglSwapBuffers(state.egl_display, state.egl_surface);
    try renderNativePopupSurfaces(state, renderer);
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
        .{ .handle = state.menu_file_refresh, .command = .refresh },
        .{ .handle = state.menu_file_copy_path, .command = .copy_path },
        .{ .handle = state.menu_file_open_target, .command = .open_link_target },
        .{ .handle = state.menu_file_quit, .command = .quit },
        .{ .handle = state.menu_edit_copy, .command = .copy },
        .{ .handle = state.menu_edit_cut, .command = .cut },
        .{ .handle = state.menu_edit_paste, .command = .paste },
        .{ .handle = state.menu_edit_delete, .command = .delete },
        .{ .handle = state.menu_edit_move_parent, .command = .move_parent },
        .{ .handle = state.menu_edit_select_all, .command = .select_all },
        .{ .handle = state.menu_edit_clear_selection, .command = .clear_selection },
        .{ .handle = state.menu_view_sidebar, .command = .toggle_sidebar },
        .{ .handle = state.menu_view_preview, .command = .toggle_preview },
        .{ .handle = state.menu_view_info, .command = .toggle_info },
        .{ .handle = state.menu_view_status_bar, .command = .toggle_status_bar },
        .{ .handle = state.menu_view_list, .command = .view_list },
        .{ .handle = state.menu_view_grid, .command = .view_grid },
        .{ .handle = state.menu_view_sort_directories, .command = .toggle_sort_directories },
        .{ .handle = state.menu_go_back, .command = .back },
        .{ .handle = state.menu_go_forward, .command = .forward },
        .{ .handle = state.menu_go_up, .command = .up },
        .{ .handle = state.menu_go_home, .command = .home },
        .{ .handle = state.menu_help_about, .command = .about },
    };

    for (items) |item| {
        if (!widgetClicked(ctx, item.handle)) continue;
        setTopMenuPopupVisible(state, ctx, null);
        rebuild_ui.* = try runBrowserCommand(state, item.command) or rebuild_ui.*;
    }

    if (widgetClicked(ctx, state.menu_edit_rename)) {
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
        .{ .handle = state.btn_back, .command = .back },
        .{ .handle = state.btn_forward, .command = .forward },
        .{ .handle = state.btn_up, .command = .up },
        .{ .handle = state.btn_home, .command = .home },
        .{ .handle = state.btn_refresh, .command = .refresh },
        .{ .handle = state.btn_toggle_sidebar, .command = .toggle_sidebar },
        .{ .handle = state.btn_toggle_preview, .command = .toggle_preview },
        .{ .handle = state.btn_toggle_info, .command = .toggle_info },
    };

    for (items) |item| {
        if (widgetClicked(ctx, item.handle)) {
            rebuild_ui.* = try runBrowserCommand(state, item.command) or rebuild_ui.*;
        }
    }
    if (widgetClicked(ctx, state.btn_address_go)) state.address_submit_requested = true;
    if (widgetClicked(ctx, state.btn_list_view) and state.view_mode != .list) {
        rebuild_ui.* = try runBrowserCommand(state, .view_list) or rebuild_ui.*;
    }
    if (widgetClicked(ctx, state.btn_grid_view) and state.view_mode != .grid) {
        rebuild_ui.* = try runBrowserCommand(state, .view_grid) or rebuild_ui.*;
    }
}

fn runContextMenuCommands(state: *State, ctx: *goop.Context, rebuild_ui: *bool) !void {
    const Item = struct {
        handle: ?goop.NodeHandle,
        command: BrowserCommand,
    };
    const command_items = [_]Item{
        .{ .handle = state.context_copy, .command = .copy },
        .{ .handle = state.context_cut, .command = .cut },
        .{ .handle = state.context_delete, .command = .delete },
        .{ .handle = state.context_move_parent, .command = .move_parent },
    };

    if (widgetClicked(ctx, state.context_open)) {
        hideContextMenu(state, ctx);
        rebuild_ui.* = try openContextTarget(state) or rebuild_ui.*;
    }
    for (command_items) |item| {
        if (!widgetClicked(ctx, item.handle)) continue;
        hideContextMenu(state, ctx);
        rebuild_ui.* = try runBrowserCommand(state, item.command) or rebuild_ui.*;
    }
    if (widgetClicked(ctx, state.context_paste)) {
        hideContextMenu(state, ctx);
        rebuild_ui.* = try pasteContextTarget(state) or rebuild_ui.*;
    }
    if (widgetClicked(ctx, state.context_rename)) {
        hideContextMenu(state, ctx);
        rebuild_ui.* = try beginRenameSelection(state, ctx) or rebuild_ui.*;
    }
    if (widgetClicked(ctx, state.context_copy_path)) {
        hideContextMenu(state, ctx);
        rebuild_ui.* = try copyContextTargetPath(state) or rebuild_ui.*;
    }
    if (widgetClicked(ctx, state.context_open_link_target)) {
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
    _ = try maybeStartWaylandAssetDrag(state, ctx);

    var rebuild_ui = false;
    if (state.rename_cancel_requested) {
        state.rename_cancel_requested = false;
        rebuild_ui = cancelActiveRename(state) or rebuild_ui;
    }
    if (state.rename_commit_requested) {
        state.rename_commit_requested = false;
        switch (try commitActiveRename(state)) {
            .inactive => {},
            .closed, .blocked => rebuild_ui = true,
        }
    }
    return rebuild_ui;
}

fn syncRetainedWidgetState(state: *State, ctx: *goop.Context, rebuild_ui: *bool) void {
    if (state.nav_splitter) |h| if (ctx.tree.node(h).?.changed) {
        state.nav_ratio = ctx.tree.node(h).?.kind.splitter.ratio;
    };
    if (state.detail_splitter) |h| if (ctx.tree.node(h).?.changed) {
        state.detail_ratio = ctx.tree.node(h).?.kind.splitter.ratio;
    };
    if (state.preview_splitter) |h| if (ctx.tree.node(h).?.changed) {
        state.preview_ratio = ctx.tree.node(h).?.kind.splitter.ratio;
    };

    if (state.asset_table) |h| if (ctx.tree.node(h).?.changed) {
        state.table_column_weights[0] = ctx.tree.tableColumnFraction(h, 0) orelse state.table_column_weights[0];
        state.table_column_weights[1] = ctx.tree.tableColumnFraction(h, 1) orelse state.table_column_weights[1];
        state.table_column_weights[2] = ctx.tree.tableColumnFraction(h, 2) orelse state.table_column_weights[2];
        state.table_column_weights[3] = ctx.tree.tableColumnFraction(h, 3) orelse state.table_column_weights[3];
        if (state.asset_table_body) |body| {
            if (ctx.tree.isAlive(body)) {
                applyAssetTableColumns(&ctx.mutateKind(body).?.table, state);
                ctx.invalidate();
            }
        }
    };

    if (state.asset_table) |h| if (ctx.tree.node(h).?.kind.table.sort_changed) {
        if (ctx.tree.node(h).?.kind.table.sorted_column) |sorted_column| {
            const previous_sort_column = state.sort_column;
            state.sort_column = @enumFromInt(sorted_column);
            state.sort_direction = switch (ctx.tree.node(h).?.kind.table.sort_direction) {
                .ascending => .ascending,
                .descending => .descending,
            };
            if (previous_sort_column != state.sort_column and state.sort_column == .modified) {
                state.sort_direction = .descending;
            }
            sortDirectoryEntries(state);
            syncSelectionAnchor(state);
            rebuild_ui.* = true;
        }
    };
}

fn runPendingCommands(state: *State, rebuild_ui: *bool) !void {
    if (state.pending_command) |command| {
        state.pending_command = null;
        rebuild_ui.* = try runBrowserCommand(state, command) or rebuild_ui.*;
    }
    if (state.address_submit_requested) {
        state.address_submit_requested = false;
        const path = try addressInputPathAlloc(state);
        defer allocator.free(path);
        rebuild_ui.* = try setCurrentDirectory(state, path, true) or rebuild_ui.*;
    }
}

fn openContextMenuFromSecondaryClick(state: *State, ctx: *goop.Context, rebuild_ui: *bool) !void {
    for (state.place_handles.items, 0..) |handle, index| {
        if (!widgetSecondaryClicked(ctx, handle)) continue;
        if (index >= state.places.items.len) continue;
        try showContextMenuForPath(state, ctx, state.places.items[index].path);
        rebuild_ui.* = true;
        return;
    }

    for (state.folder_tree_handles.items, 0..) |handle, index| {
        if (!widgetSecondaryClicked(ctx, handle)) continue;
        if (index >= state.folder_tree_paths.items.len) continue;
        try showContextMenuForPath(state, ctx, state.folder_tree_paths.items[index]);
        rebuild_ui.* = true;
        return;
    }

    for (state.breadcrumb_handles.items, 0..) |handle, index| {
        if (!widgetSecondaryClicked(ctx, handle)) continue;
        if (index >= state.breadcrumb_paths.items.len) continue;
        try showContextMenuForPath(state, ctx, state.breadcrumb_paths.items[index]);
        rebuild_ui.* = true;
        return;
    }

    for (state.row_handles.items, 0..) |handle, index| {
        if (!widgetSecondaryClicked(ctx, handle)) continue;
        const entry_index = state.asset_visible_start + index;
        if (entry_index >= state.entries.items.len) continue;
        try selectEntryForContextMenu(state, entry_index);
        try showContextMenuForPath(state, ctx, state.entries.items[entry_index].path);
        rebuild_ui.* = true;
        return;
    }

    for (state.grid_handles.items, 0..) |handle, index| {
        if (!widgetSecondaryClicked(ctx, handle)) continue;
        const entry_index = state.asset_visible_start + index;
        if (entry_index >= state.entries.items.len) continue;
        try selectEntryForContextMenu(state, entry_index);
        try showContextMenuForPath(state, ctx, state.entries.items[entry_index].path);
        rebuild_ui.* = true;
        return;
    }

    if (widgetSecondaryClicked(ctx, state.file_panel_scroll)) {
        try showContextMenuForPath(state, ctx, state.current_dir);
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

    if (state.rename_path != null) {
        switch (try commitActiveRename(state)) {
            .inactive => {},
            .closed => rebuild_ui.* = true,
            .blocked => rebuild_ui.* = true,
        }
    }
    if (state.rename_path == null) {
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
    for (state.place_handles.items, 0..) |handle, index| {
        if (!ctx.tree.node(handle).?.clicked) continue;
        if (index >= state.places.items.len) continue;
        rebuild_ui.* = try setCurrentDirectory(state, state.places.items[index].path, true) or rebuild_ui.*;
        break;
    }

    for (state.folder_tree_handles.items, 0..) |handle, index| {
        if (!ctx.tree.node(handle).?.toggled) continue;
        if (index >= state.folder_tree_paths.items.len) continue;
        const path = state.folder_tree_paths.items[index];
        const previous_expansion = folderTreeExpansion(state, path);
        if (previous_expansion == .partial) {
            rebuild_ui.* = try setFolderTreePathExpanded(state, path, true) or rebuild_ui.*;
        } else {
            const expanded = ctx.tree.node(handle).?.kind.tree_item.expanded;
            rebuild_ui.* = try setFolderTreePathExpanded(state, path, expanded) or rebuild_ui.*;
            if (!expanded and std.mem.eql(u8, path, state.current_dir)) rebuild_ui.* = true;
        }
    }

    for (state.folder_tree_handles.items, 0..) |handle, index| {
        if (!ctx.tree.node(handle).?.clicked or ctx.tree.node(handle).?.toggled) continue;
        if (index >= state.folder_tree_paths.items.len) continue;
        rebuild_ui.* = try setCurrentDirectory(state, state.folder_tree_paths.items[index], true) or rebuild_ui.*;
        break;
    }

    for (state.breadcrumb_handles.items, 0..) |handle, index| {
        if (!ctx.tree.node(handle).?.clicked) continue;
        if (index >= state.breadcrumb_paths.items.len) continue;
        rebuild_ui.* = try setCurrentDirectory(state, state.breadcrumb_paths.items[index], true) or rebuild_ui.*;
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
    var entry_index = state.asset_visible_start + visible_index;
    if (entry_index >= state.entries.items.len) return false;

    const entry = state.entries.items[entry_index];
    if (allow_inline_rename and
        !state.ctrl_down and
        !state.shift_down and
        isPathSelected(state, entry.path) and
        pointHitsEntryNameText(state, ctx, visible_index, entry, state.primary_release_x, state.primary_release_y))
    {
        try beginRenameEntry(state, ctx, entry);
        rebuild_ui.* = true;
        return true;
    }

    const clicked_path = try allocator.dupe(u8, entry.path);
    defer allocator.free(clicked_path);
    if (state.rename_path != null) {
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

    const selected_entry = state.entries.items[entry_index];
    const click_ms = currentPrimaryClickTimestampMs(ctx, io);
    const repeated_click = isRepeatedEntryClick(state, &selected_entry, click_ms);

    try applyEntrySelectionClick(state, entry_index);
    try setLastClickPath(state, selected_entry.path);
    state.last_click_ms = click_ms;
    rebuild_ui.* = true;

    if (repeated_click and selected_entry.canEnter()) {
        rebuild_ui.* = try setCurrentDirectory(state, selected_entry.navigationPath(), true) or rebuild_ui.*;
    }
    return true;
}

fn handleAssetPrimaryClicks(state: *State, ctx: *goop.Context, io: std.Io, rebuild_ui: *bool) !bool {
    for (state.row_handles.items, 0..) |handle, index| {
        if (!widgetClicked(ctx, handle)) continue;
        return try handleAssetEntryPrimaryClick(state, ctx, io, index, true, rebuild_ui);
    }

    for (state.grid_handles.items, 0..) |handle, index| {
        if (!widgetClicked(ctx, handle)) continue;
        return try handleAssetEntryPrimaryClick(state, ctx, io, index, false, rebuild_ui);
    }

    return false;
}

fn syncAssetSelectionWidgets(state: *State, ctx: *goop.Context, rebuild_ui: *bool) !bool {
    var selection_widget_changed = false;
    const selection_drag_active = ctx.frame().buttons.left;
    if (state.view_mode == .list) {
        if (state.asset_table_body) |table| {
            if (ctx.tree.isAlive(table) and ctx.tree.node(table).?.kind.table.selection_changed) {
                selection_widget_changed = true;
                if (state.rename_path != null) {
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
                        state.asset_selection_rebuild_pending = true;
                    } else {
                        rebuild_ui.* = true;
                    }
                }
            }
        }
    } else if (state.view_mode == .grid) {
        if (state.asset_grid) |grid| {
            if (ctx.tree.isAlive(grid) and ctx.tree.node(grid).?.changed) {
                selection_widget_changed = true;
                if (state.rename_path != null) {
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
                        state.asset_selection_rebuild_pending = true;
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

    if (!ctx.frame().buttons.left and state.asset_selection_rebuild_pending) {
        state.asset_selection_rebuild_pending = false;
        rebuild_ui.* = true;
    }

    if (state.primary_release_pending) {
        defer state.primary_release_pending = false;
        if (!handled and pointInFilePanelBlankSpace(state, ctx, state.primary_release_x, state.primary_release_y)) {
            var rename_blocks_deselect = false;
            if (state.rename_path != null) {
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

pub fn main(init: std.process.Init) !void {
    // Connect to Wayland
    const display = wl.wl_display_connect(null) orelse {
        std.debug.print("failed to connect to wayland display\n", .{});
        return error.NoDisplay;
    };
    defer wl.wl_display_disconnect(display);

    var state = State{};
    initStateFromEnvironment(&state, display, init);
    logStartupOptions(&state);
    try createWaylandWindow(&state, display);

    // EGL + OpenGL
    try initEgl(&state, display);
    defer deinitEgl(&state);

    // Load font
    const font_data = loadFont(allocator, init.environ_map, init.io) catch |err| {
        std.debug.print("failed to load font: {}\n", .{err});
        return err;
    };
    defer allocator.free(font_data);

    var text_atlas = try snail.TextAtlas.init(allocator, &.{.{ .data = font_data }});
    defer text_atlas.deinit();
    var ensured_text = std.BufSet.init(allocator);
    defer ensured_text.deinit();

    const line_metrics = fontLineMetrics(&text_atlas);
    var text_measure = SnailTextCtx{
        .allocator = allocator,
        .text_atlas = &text_atlas,
        .scratch_buf = try allocator.alloc(u8, 64),
        .ascent_units = line_metrics.ascent,
        .descent_units = line_metrics.descent,
    };
    defer allocator.free(text_measure.scratch_buf);
    const text_measure_ctx = goop.TextMeasureCtx{
        .measureFn = &snailMeasureText,
        .user_data = @ptrCast(&text_measure),
    };
    state.text_measure_ctx = &text_measure_ctx;

    // goop context + widget tree
    var ctx = try goop.Context.init(allocator, .{
        .width = state.logical_width,
        .height = state.logical_height,
        .theme = fileManagerTheme(&state),
    });
    defer ctx.deinit();
    state.ctx = &ctx;
    ctx.setClipboard(state.clipboard());
    try initializeBrowserState(&state);
    try buildWidgetTree(&state);

    // GL renderer (with snail text support)
    var renderer = try render.Renderer.init(state.buffer_width, state.buffer_height, &text_atlas);
    defer renderer.deinit();
    renderer.target_encoding = if (state.egl_surface_srgb) .srgb else .srgb_pixels_on_linear_framebuffer;
    renderer.clear_color = .{ 0.95, 0.96, 0.97, 1.0 };

    std.debug.print("goop file manager running (logical {}x{}, scale {}, ui-scale {d:.2}, buffer {}x{})\n", .{
        state.logical_width,
        state.logical_height,
        state.buffer_scale,
        state.ui_scale,
        state.buffer_width,
        state.buffer_height,
    });

    // Wayland dispatch/render loop. Redraws are paced by frame callbacks.
    while (state.running) {
        if (timeoutReached(&state, init.io)) {
            std.debug.print("demo timeout reached, exiting\n", .{});
            break;
        }

        if (!dispatchWaylandEvents(&state, display)) break;

        if (!state.configured or !state.needs_redraw or state.frame_pending) continue;
        state.needs_redraw = false;

        var rebuild_ui = try beginBrowserFrame(&state, &ctx, &text_measure_ctx);
        syncRetainedWidgetState(&state, &ctx, &rebuild_ui);

        try runMenuCommands(&state, &ctx, &rebuild_ui);
        try runContextMenuCommands(&state, &ctx, &rebuild_ui);
        try runToolbarCommands(&state, &ctx, &rebuild_ui);

        try runPendingCommands(&state, &rebuild_ui);

        try openContextMenuFromSecondaryClick(&state, &ctx, &rebuild_ui);

        var asset_primary_handled = try handleAssetDropFrame(&state, &ctx, &rebuild_ui);

        try handleNavigationClicks(&state, &ctx, &rebuild_ui);

        asset_primary_handled = try handleAssetPrimaryClicks(&state, &ctx, init.io, &rebuild_ui) or asset_primary_handled;

        try finishAssetSelectionFrame(&state, &ctx, asset_primary_handled, &rebuild_ui);

        if (rebuild_ui) {
            try buildWidgetTree(&state);
        }

        try layoutAndRenderFrame(&state, &ctx, &renderer, &text_atlas, &text_measure, &ensured_text, &text_measure_ctx);
    }

    cleanupPlatformState(&state);
    std.debug.print("goop file manager exiting\n", .{});
}

test {
    _ = @import("file_manager/browser_test.zig");
}
