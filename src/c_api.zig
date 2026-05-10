const std = @import("std");
const api = @import("goop.zig");
const widget = @import("core/widget.zig");
const event = @import("core/event.zig");
const style = @import("core/style.zig");
const draw = @import("core/draw.zig");
const layout = @import("core/layout.zig");
const dispatch = @import("core/dispatch.zig");

const allocator = std.heap.c_allocator;

const CStr = extern struct {
    ptr: [*c]const u8 = null,
    len: usize = 0,
};

const CHandle = extern struct {
    index: u32 = 0,
    generation: u32 = 0,
};

const CRect = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

const CColor = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,
};

const CEdges = extern struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
};

const CTheme = extern struct {
    bg: CColor = .{},
    fg: CColor = .{},
    accent: CColor = .{},
    border: CColor = .{},
    bg_hover: CColor = .{},
    bg_active: CColor = .{},
    focus_ring: CColor = .{},
    placeholder_fg: CColor = .{},
    selection_bg: CColor = .{},
    tree_guide: CColor = .{},
    font_size: f32 = 14,
    padding: CEdges = .{},
    border_radius: f32 = 4,
    border_width: f32 = 1,
    spacing: f32 = 4,
    thumb_width: f32 = 16,
};

const CStyle = extern struct {
    has_bg: bool = false,
    bg: CColor = .{},
    has_fg: bool = false,
    fg: CColor = .{},
    has_accent: bool = false,
    accent: CColor = .{},
    has_border: bool = false,
    border: CColor = .{},
    has_bg_hover: bool = false,
    bg_hover: CColor = .{},
    has_bg_active: bool = false,
    bg_active: CColor = .{},
    has_focus_ring: bool = false,
    focus_ring: CColor = .{},
    has_placeholder_fg: bool = false,
    placeholder_fg: CColor = .{},
    has_selection_bg: bool = false,
    selection_bg: CColor = .{},
    has_tree_guide: bool = false,
    tree_guide: CColor = .{},
    has_font_size: bool = false,
    font_size: f32 = 0,
    has_padding: bool = false,
    padding: CEdges = .{},
    has_border_radius: bool = false,
    border_radius: f32 = 0,
    has_border_width: bool = false,
    border_width: f32 = 0,
    has_spacing: bool = false,
    spacing: f32 = 0,
    has_thumb_width: bool = false,
    thumb_width: f32 = 0,
};

const CDirection = enum(c_int) {
    row = 0,
    column = 1,
};

const CRenameTrigger = enum(c_int) {
    none = 0,
    selected_click = 1,
    double_click = 2,
};

const CPopupPlacement = enum(c_int) {
    absolute = 0,
    below_start = 1,
    below_end = 2,
    right_start = 3,
};

const CListSelectionMode = enum(c_int) {
    single = 0,
    multiple = 1,
};

const CTableSelectionMode = enum(c_int) {
    none = 0,
    single = 1,
    multiple = 2,
};

const CSortDirection = enum(c_int) {
    ascending = 0,
    descending = 1,
};

const CTreeDropPosition = enum(c_int) {
    before = 0,
    into = 1,
    after = 2,
};

const CGridDropPosition = enum(c_int) {
    item = 0,
    background = 1,
};

const CWidgetKind = enum(c_int) {
    container = 0,
    text = 1,
    button = 2,
    checkbox = 3,
    radio_button = 4,
    tree_item = 5,
    dropdown = 6,
    list_box = 7,
    selectable = 8,
    grid_selector = 9,
    grid_item = 10,
    table = 11,
    table_row = 12,
    table_cell = 13,
    toolbar = 14,
    status_bar = 15,
    menu_bar = 16,
    menu = 17,
    popup = 18,
    tooltip = 19,
    menu_item = 20,
    drag_value = 21,
    spinbox = 22,
    tab_bar = 23,
    tab_item = 24,
    splitter = 25,
    slider = 26,
    scroll_area = 27,
    text_input = 28,
    spacer = 29,
};

const COptionalU16 = extern struct {
    has_value: bool = false,
    value: u16 = 0,
};

const COptionalU8 = extern struct {
    has_value: bool = false,
    value: u8 = 0,
};

const CContainerWidget = extern struct {
    direction: CDirection = .column,
};

const CTextWidget = extern struct {
    content: CStr = .{},
};

const CButtonWidget = extern struct {
    label: CStr = .{},
};

const CCheckboxWidget = extern struct {
    label: CStr = .{},
    checked: bool = false,
};

const CRadioButtonWidget = extern struct {
    label: CStr = .{},
    group: u32 = 0,
    selected: bool = false,
};

const CTreeItemWidget = extern struct {
    label: CStr = .{},
    group: u32 = 0,
    editable: bool = false,
    rename_trigger: CRenameTrigger = .none,
    expanded: bool = true,
    selected: bool = false,
};

const CDropdownWidget = extern struct {
    placeholder: CStr = .{},
    selected_text: CStr = .{},
    selected_index: COptionalU16 = .{},
    open: bool = false,
};

const CListBoxWidget = extern struct {
    selection_mode: CListSelectionMode = .single,
};

const CSelectableWidget = extern struct {
    label: CStr = .{},
    group: u32 = 0,
    selected: bool = false,
};

const CGridSelectorWidget = extern struct {
    selection_mode: CListSelectionMode = .single,
    item_width: f32 = 96,
    item_height: f32 = 96,
    column_gap: f32 = 8,
    row_gap: f32 = 8,
};

const CGridItemWidget = extern struct {
    label: CStr = .{},
    selected: bool = false,
};

const CTableWidget = extern struct {
    columns: u8 = 0,
    striped: bool = true,
    resizable: bool = false,
    sortable: bool = false,
    selection_mode: CTableSelectionMode = .none,
    min_column_width: f32 = 96,
    sorted_column: COptionalU8 = .{},
    sort_direction: CSortDirection = .ascending,
};

const CTableRowWidget = extern struct {
    header: bool = false,
    selected: bool = false,
};

const CPopupWidget = extern struct {
    placement: CPopupPlacement = .absolute,
    x: f32 = 0,
    y: f32 = 0,
    visible: bool = true,
    close_on_outside_click: bool = true,
    z_index: i16 = 100,
    pointer_passthrough: bool = false,
};

const CTooltipWidget = extern struct {
    placement: CPopupPlacement = .below_start,
    x: f32 = 0,
    y: f32 = 0,
    z_index: i16 = 120,
};

const CMenuWidget = extern struct {
    label: CStr = .{},
};

const CMenuItemWidget = extern struct {
    label: CStr = .{},
    shortcut: CStr = .{},
    checked: bool = false,
    disabled: bool = false,
};

const CDragValueWidget = extern struct {
    value: f32 = 0,
    min: f32 = -1000000,
    max: f32 = 1000000,
    speed: f32 = 0.1,
    precision: u8 = 2,
};

const CSpinboxWidget = extern struct {
    value: f32 = 0,
    min: f32 = -1000000,
    max: f32 = 1000000,
    step: f32 = 1,
    precision: u8 = 2,
};

const CTabItemWidget = extern struct {
    label: CStr = .{},
    selected: bool = false,
};

const CSplitterWidget = extern struct {
    direction: CDirection = .row,
    ratio: f32 = 0.5,
    min_first: f32 = 120,
    min_second: f32 = 120,
    thickness: f32 = 6,
    keyboard_step: f32 = 0.02,
};

const CSliderWidget = extern struct {
    value: f32 = 0,
    min: f32 = 0,
    max: f32 = 1,
};

const CScrollAreaWidget = extern struct {
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    disable_horizontal_scroll: bool = false,
    disable_vertical_scroll: bool = false,
};

const CTextInputWidget = extern struct {
    placeholder: CStr = .{},
    value: CStr = .{},
};

const CSpacerWidget = extern struct {
    width: f32 = 0,
    height: f32 = 0,
};

const CUnitWidget = extern struct {
    _reserved: u8 = 0,
};

const CWidget = extern struct {
    kind: CWidgetKind = .container,
    data: extern union {
        container: CContainerWidget,
        text: CTextWidget,
        button: CButtonWidget,
        checkbox: CCheckboxWidget,
        radio_button: CRadioButtonWidget,
        tree_item: CTreeItemWidget,
        dropdown: CDropdownWidget,
        list_box: CListBoxWidget,
        selectable: CSelectableWidget,
        grid_selector: CGridSelectorWidget,
        grid_item: CGridItemWidget,
        table: CTableWidget,
        table_row: CTableRowWidget,
        table_cell: CUnitWidget,
        toolbar: CUnitWidget,
        status_bar: CUnitWidget,
        menu_bar: CUnitWidget,
        menu: CMenuWidget,
        popup: CPopupWidget,
        tooltip: CTooltipWidget,
        menu_item: CMenuItemWidget,
        drag_value: CDragValueWidget,
        spinbox: CSpinboxWidget,
        tab_bar: CUnitWidget,
        tab_item: CTabItemWidget,
        splitter: CSplitterWidget,
        slider: CSliderWidget,
        scroll_area: CScrollAreaWidget,
        text_input: CTextInputWidget,
        spacer: CSpacerWidget,
    } = .{ .container = .{} },
};

// Read-only views into widget state. Mirrors api.WidgetView one-for-one.

const CContainerView = extern struct { direction: CDirection = .row };

const CTextView = extern struct { content: CStr = .{} };

const CButtonView = extern struct {
    label: CStr = .{},
    clicked: bool = false,
};

const CCheckboxView = extern struct {
    label: CStr = .{},
    checked: bool = false,
    clicked: bool = false,
};

const CRadioButtonView = extern struct {
    label: CStr = .{},
    group: u32 = 0,
    selected: bool = false,
    clicked: bool = false,
};

const CTreeItemView = extern struct {
    label: CStr = .{},
    group: u32 = 0,
    has_children: bool = false,
    expanded: bool = false,
    selected: bool = false,
    editing: bool = false,
    clicked: bool = false,
    toggled: bool = false,
    dragging: bool = false,
    drop_received: bool = false,
    rename_committed: bool = false,
};

const CDropdownView = extern struct {
    placeholder: CStr = .{},
    selected_text: CStr = .{},
    selected_index: COptionalU16 = .{},
    open: bool = false,
    clicked: bool = false,
    changed: bool = false,
};

const CListBoxView = extern struct { changed: bool = false };

const CSelectableView = extern struct {
    label: CStr = .{},
    group: u32 = 0,
    selected: bool = false,
    clicked: bool = false,
    dragging: bool = false,
};

const CGridSelectorView = extern struct {
    changed: bool = false,
    computed_columns: u16 = 0,
};

const CGridItemView = extern struct {
    label: CStr = .{},
    selected: bool = false,
    clicked: bool = false,
    dragging: bool = false,
};

const CTableView = extern struct {
    active_columns: u8 = 0,
    changed: bool = false,
    resized_column: COptionalU8 = .{},
    sorted_column: COptionalU8 = .{},
    sort_direction: CSortDirection = .ascending,
    sort_changed: bool = false,
    selection_changed: bool = false,
};

const CTableRowView = extern struct {
    header: bool = false,
    selected: bool = false,
    dragging: bool = false,
};

const CMenuView = extern struct {
    label: CStr = .{},
    clicked: bool = false,
};

const CPopupView = extern struct {
    placement: CPopupPlacement = .absolute,
    x: f32 = 0,
    y: f32 = 0,
    visible: bool = false,
    z_index: i16 = 0,
};

const CTooltipView = extern struct {
    placement: CPopupPlacement = .absolute,
    x: f32 = 0,
    y: f32 = 0,
    z_index: i16 = 0,
};

const CMenuItemView = extern struct {
    label: CStr = .{},
    shortcut: CStr = .{},
    checked: bool = false,
    disabled: bool = false,
    clicked: bool = false,
};

const CDragValueView = extern struct {
    value: f32 = 0,
    changed: bool = false,
    editing: bool = false,
    display_text: CStr = .{},
};

const CSpinboxView = extern struct {
    value: f32 = 0,
    changed: bool = false,
    editing: bool = false,
    display_text: CStr = .{},
};

const CTabItemView = extern struct {
    label: CStr = .{},
    selected: bool = false,
    clicked: bool = false,
};

const CSplitterView = extern struct {
    ratio: f32 = 0,
    changed: bool = false,
};

const CSliderView = extern struct { value: f32 = 0 };

const CScrollAreaView = extern struct {
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
};

const CTextInputView = extern struct {
    content: CStr = .{},
    cursor: u8 = 0,
    selection_anchor: COptionalU8 = .{},
};

const CWidgetView = extern struct {
    kind: CWidgetKind = .container,
    data: extern union {
        container: CContainerView,
        text: CTextView,
        button: CButtonView,
        checkbox: CCheckboxView,
        radio_button: CRadioButtonView,
        tree_item: CTreeItemView,
        dropdown: CDropdownView,
        list_box: CListBoxView,
        selectable: CSelectableView,
        grid_selector: CGridSelectorView,
        grid_item: CGridItemView,
        table: CTableView,
        table_row: CTableRowView,
        table_cell: CUnitWidget,
        toolbar: CUnitWidget,
        status_bar: CUnitWidget,
        menu_bar: CUnitWidget,
        menu: CMenuView,
        popup: CPopupView,
        tooltip: CTooltipView,
        menu_item: CMenuItemView,
        drag_value: CDragValueView,
        spinbox: CSpinboxView,
        tab_bar: CUnitWidget,
        tab_item: CTabItemView,
        splitter: CSplitterView,
        slider: CSliderView,
        scroll_area: CScrollAreaView,
        text_input: CTextInputView,
        spacer: CUnitWidget,
    } = .{ .container = .{} },
};

const CNodeView = extern struct {
    rect: CRect = .{},
    user_id: u64 = 0,
    custom_draw: bool = false,
    focused: bool = false,
    accepts_drop: bool = false,
    drop_hovered: bool = false,
    drop_received: bool = false,
    clicked: bool = false,
    secondary_clicked: bool = false,
    changed: bool = false,
    toggled: bool = false,
    kind: CWidgetView = .{},
};

const CFrameButtons = extern struct {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
};

const CFrameSnapshot = extern struct {
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    buttons: CFrameButtons = .{},
    has_focused: bool = false,
    focused: CHandle = .{},
    has_drag_source: bool = false,
    drag_source: CHandle = .{},
    has_last_drop: bool = false,
    last_drop: CDrop = .{},
    has_last_secondary_click: bool = false,
    last_secondary_click: CSecondaryClick = .{},
    last_primary_press_ms: u64 = 0,
};

const CMouseButton = enum(c_int) {
    left = 0,
    right = 1,
    middle = 2,
};

const CMouseButtonState = enum(c_int) {
    pressed = 0,
    released = 1,
};

const CKeyState = enum(c_int) {
    pressed = 0,
    released = 1,
    repeat = 2,
};

const CKeycode = enum(c_int) {
    a = 0, b, c, d, e, f, g, h, i, j, k, l, m,
    n, o, p, q, r, s, t, u, v, w, x, y, z,
    digit_0, digit_1, digit_2, digit_3, digit_4,
    digit_5, digit_6, digit_7, digit_8, digit_9,
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24,
    space, tab, enter,
    backspace, delete, insert,
    left, right, up, down, home, end, page_up, page_down,
    escape,
    minus, equal, left_bracket, right_bracket,
    backslash, semicolon, apostrophe, comma, period, slash, grave,
    left_shift, right_shift,
    left_ctrl, right_ctrl,
    left_alt, right_alt,
    left_super, right_super,
    caps_lock, num_lock,
    unknown,
};

const CModifiers = packed struct(u32) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _padding: u26 = 0,
};

const CEventKind = enum(c_int) {
    mouse_move = 0,
    mouse_button = 1,
    mouse_scroll = 2,
    key = 3,
    text = 4,
    focus = 5,
    resize = 6,
};

const CMouseMoveEvent = extern struct {
    x: f32 = 0,
    y: f32 = 0,
};

const CMouseButtonEvent = extern struct {
    button: CMouseButton = .left,
    state: CMouseButtonState = .pressed,
    x: f32 = 0,
    y: f32 = 0,
    timestamp_ms: u64 = 0,
    mods: CModifiers = .{},
};

const CMouseScrollEvent = extern struct {
    dx: f32 = 0,
    dy: f32 = 0,
    mods: CModifiers = .{},
};

const CKeyEvent = extern struct {
    keycode: CKeycode = .unknown,
    mods: CModifiers = .{},
    state: CKeyState = .pressed,
    scancode: u32 = 0,
};

const CTextEvent = extern struct {
    codepoint: u32 = 0,
};

const CFocusEvent = extern struct {
    focused: bool = false,
};

const CResizeEvent = extern struct {
    width: u32 = 0,
    height: u32 = 0,
};

const CEvent = extern struct {
    kind: CEventKind = .mouse_move,
    data: extern union {
        mouse_move: CMouseMoveEvent,
        mouse_button: CMouseButtonEvent,
        mouse_scroll: CMouseScrollEvent,
        key: CKeyEvent,
        text: CTextEvent,
        focus: CFocusEvent,
        resize: CResizeEvent,
    } = .{ .mouse_move = .{} },
};

const CDrawCommandKind = enum(c_int) {
    rect = 0,
    text = 1,
    clip = 2,
    icon = 3,
    custom = 4,
};

const CTextAlign = enum(c_int) {
    start = 0,
    center = 1,
    end = 2,
};

const CTextOverflow = enum(c_int) {
    visible = 0,
    clip = 1,
    ellipsis = 2,
    wrap = 3,
};

const CDrawRect = extern struct {
    bounds: CRect = .{},
    color: CColor = .{},
    border_color: CColor = .{},
    border_width: f32 = 0,
    corner_radius: f32 = 0,
};

const CDrawText = extern struct {
    bounds: CRect = .{},
    baseline_y: f32 = 0,
    text: CStr = .{},
    color: CColor = .{},
    font_size: f32 = 0,
    text_align: CTextAlign = .start,
    overflow: CTextOverflow = .visible,
};

const CClipRect = extern struct {
    has_bounds: bool = false,
    bounds: CRect = .{},
};

const CDrawCustom = extern struct {
    handle: CHandle = .{},
    bounds: CRect = .{},
};

const CDrawIcon = extern struct {
    bounds: CRect = .{},
    kind: u32 = 0,
    color: CColor = .{},
};

const CDrawCommand = extern struct {
    kind: CDrawCommandKind = .rect,
    data: extern union {
        rect: CDrawRect,
        text: CDrawText,
        clip: CClipRect,
        icon: CDrawIcon,
        custom: CDrawCustom,
    } = .{ .rect = .{} },
};

const CDrawList = extern struct {
    commands: [*c]const CDrawCommand = null,
    len: usize = 0,
};

const CTextDimensions = extern struct {
    width: f32 = 0,
    height: f32 = 0,
    ascent: f32 = 0,
    descent: f32 = 0,
};

const CMeasureTextFn = *const fn (text: CStr, font_size: f32, user_data: ?*anyopaque) callconv(.c) CTextDimensions;

const CTextMeasureCtx = extern struct {
    measure_fn: ?CMeasureTextFn = null,
    user_data: ?*anyopaque = null,
};

const CClipboardGetTextFn = *const fn (ptr: ?*anyopaque) callconv(.c) CStr;
const CClipboardSetTextFn = *const fn (ptr: ?*anyopaque, text: CStr) callconv(.c) void;

const CClipboard = extern struct {
    ptr: ?*anyopaque = null,
    get_text_fn: ?CClipboardGetTextFn = null,
    set_text_fn: ?CClipboardSetTextFn = null,
};

const CContextOptions = extern struct {
    width: u32 = 800,
    height: u32 = 600,
    has_theme: bool = false,
    theme: CTheme = .{},
};

const CSecondaryClick = extern struct {
    target: CHandle = .{},
    x: f32 = 0,
    y: f32 = 0,
};

const CTreeDrop = extern struct {
    source: CHandle = .{},
    target: CHandle = .{},
    position: CTreeDropPosition = .into,
};

const CGridDrop = extern struct {
    source: CHandle = .{},
    target: CHandle = .{},
    position: CGridDropPosition = .item,
};

const CListDrop = extern struct {
    source: CHandle = .{},
    target: CHandle = .{},
};

const CTableDrop = extern struct {
    source: CHandle = .{},
    target: CHandle = .{},
};

const CWidgetDrop = extern struct {
    source: CHandle = .{},
    target: CHandle = .{},
};

const CDropKind = enum(c_int) {
    tree = 0,
    grid = 1,
    list = 2,
    table = 3,
    widget = 4,
};

const CDrop = extern struct {
    kind: CDropKind = .tree,
    data: extern union {
        tree: CTreeDrop,
        grid: CGridDrop,
        list: CListDrop,
        table: CTableDrop,
        widget: CWidgetDrop,
    } = .{ .tree = .{} },
};

const CContext = struct {
    ctx: api.Context,
    draw_commands: std.ArrayListUnmanaged(CDrawCommand) = .empty,
    clipboard_provider: CClipboard = .{},
    clipboard_enabled: bool = false,
    measure_provider: CTextMeasureCtx = .{},
    measure_enabled: bool = false,
    measure_bridge: layout.TextMeasureCtx = .{
        .measureFn = &measureTextBridge,
        .user_data = null,
    },
};

fn fromCStr(str: CStr) []const u8 {
    if (str.ptr == null or str.len == 0) return "";
    const ptr = str.ptr orelse return "";
    return @as([*]const u8, @ptrCast(ptr))[0..str.len];
}

fn toCStr(str: []const u8) CStr {
    if (str.len == 0) return .{};
    return .{ .ptr = @ptrCast(str.ptr), .len = str.len };
}

fn handleFromC(handle: CHandle) widget.NodeHandle {
    return .{ .index = handle.index, .generation = handle.generation };
}

fn handleToC(handle: widget.NodeHandle) CHandle {
    return .{ .index = handle.index, .generation = handle.generation };
}

fn rectToC(rect: draw.Rect) CRect {
    return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
}

fn colorFromC(color: CColor) style.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

fn colorToC(color: style.Color) CColor {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

fn edgesFromC(edges: CEdges) style.Edges {
    return .{
        .top = edges.top,
        .right = edges.right,
        .bottom = edges.bottom,
        .left = edges.left,
    };
}

fn edgesToC(edges: style.Edges) CEdges {
    return .{
        .top = edges.top,
        .right = edges.right,
        .bottom = edges.bottom,
        .left = edges.left,
    };
}

fn themeFromC(theme: CTheme) style.Theme {
    return .{
        .bg = colorFromC(theme.bg),
        .fg = colorFromC(theme.fg),
        .accent = colorFromC(theme.accent),
        .border = colorFromC(theme.border),
        .bg_hover = colorFromC(theme.bg_hover),
        .bg_active = colorFromC(theme.bg_active),
        .focus_ring = colorFromC(theme.focus_ring),
        .placeholder_fg = colorFromC(theme.placeholder_fg),
        .selection_bg = colorFromC(theme.selection_bg),
        .tree_guide = colorFromC(theme.tree_guide),
        .font_size = theme.font_size,
        .padding = edgesFromC(theme.padding),
        .border_radius = theme.border_radius,
        .border_width = theme.border_width,
        .spacing = theme.spacing,
        .thumb_width = theme.thumb_width,
    };
}

fn themeToC(theme: style.Theme) CTheme {
    return .{
        .bg = colorToC(theme.bg),
        .fg = colorToC(theme.fg),
        .accent = colorToC(theme.accent),
        .border = colorToC(theme.border),
        .bg_hover = colorToC(theme.bg_hover),
        .bg_active = colorToC(theme.bg_active),
        .focus_ring = colorToC(theme.focus_ring),
        .placeholder_fg = colorToC(theme.placeholder_fg),
        .selection_bg = colorToC(theme.selection_bg),
        .tree_guide = colorToC(theme.tree_guide),
        .font_size = theme.font_size,
        .padding = edgesToC(theme.padding),
        .border_radius = theme.border_radius,
        .border_width = theme.border_width,
        .spacing = theme.spacing,
        .thumb_width = theme.thumb_width,
    };
}

fn styleFromC(c_style: CStyle) style.Style {
    return .{
        .bg = if (c_style.has_bg) colorFromC(c_style.bg) else null,
        .fg = if (c_style.has_fg) colorFromC(c_style.fg) else null,
        .accent = if (c_style.has_accent) colorFromC(c_style.accent) else null,
        .border = if (c_style.has_border) colorFromC(c_style.border) else null,
        .bg_hover = if (c_style.has_bg_hover) colorFromC(c_style.bg_hover) else null,
        .bg_active = if (c_style.has_bg_active) colorFromC(c_style.bg_active) else null,
        .focus_ring = if (c_style.has_focus_ring) colorFromC(c_style.focus_ring) else null,
        .placeholder_fg = if (c_style.has_placeholder_fg) colorFromC(c_style.placeholder_fg) else null,
        .selection_bg = if (c_style.has_selection_bg) colorFromC(c_style.selection_bg) else null,
        .tree_guide = if (c_style.has_tree_guide) colorFromC(c_style.tree_guide) else null,
        .font_size = if (c_style.has_font_size) c_style.font_size else null,
        .padding = if (c_style.has_padding) edgesFromC(c_style.padding) else null,
        .border_radius = if (c_style.has_border_radius) c_style.border_radius else null,
        .border_width = if (c_style.has_border_width) c_style.border_width else null,
        .spacing = if (c_style.has_spacing) c_style.spacing else null,
        .thumb_width = if (c_style.has_thumb_width) c_style.thumb_width else null,
    };
}

fn directionFromC(direction: CDirection) widget.WidgetKind.Container.Direction {
    return switch (direction) {
        .row => .row,
        .column => .column,
    };
}

fn placementFromC(placement: CPopupPlacement) widget.WidgetKind.Popup.Placement {
    return switch (placement) {
        .absolute => .absolute,
        .below_start => .below_start,
        .below_end => .below_end,
        .right_start => .right_start,
    };
}

fn renameTriggerFromC(trigger: CRenameTrigger) widget.WidgetKind.TreeItem.RenameTrigger {
    return switch (trigger) {
        .none => .none,
        .selected_click => .selected_click,
        .double_click => .double_click,
    };
}

fn listSelectionModeFromC(mode: CListSelectionMode) widget.WidgetKind.ListBox.SelectionMode {
    return switch (mode) {
        .single => .single,
        .multiple => .multiple,
    };
}

fn tableSelectionModeFromC(mode: CTableSelectionMode) widget.WidgetKind.Table.SelectionMode {
    return switch (mode) {
        .none => .none,
        .single => .single,
        .multiple => .multiple,
    };
}

fn sortDirectionFromC(direction: CSortDirection) widget.WidgetKind.Table.SortDirection {
    return switch (direction) {
        .ascending => .ascending,
        .descending => .descending,
    };
}

fn sortDirectionToC(direction: widget.WidgetKind.Table.SortDirection) CSortDirection {
    return switch (direction) {
        .ascending => .ascending,
        .descending => .descending,
    };
}

fn treeDropPositionToC(position: widget.WidgetKind.TreeItem.DropPosition) CTreeDropPosition {
    return switch (position) {
        .before => .before,
        .into => .into,
        .after => .after,
    };
}

fn gridDropPositionToC(position: dispatch.GridDrop.Position) CGridDropPosition {
    return switch (position) {
        .item => .item,
        .background => .background,
    };
}

fn directionToC(direction: widget.WidgetKind.Container.Direction) CDirection {
    return switch (direction) {
        .row => .row,
        .column => .column,
    };
}

fn placementToC(placement: widget.WidgetKind.Popup.Placement) CPopupPlacement {
    return switch (placement) {
        .absolute => .absolute,
        .below_start => .below_start,
        .below_end => .below_end,
        .right_start => .right_start,
    };
}

fn optionalU16(value: ?u16) COptionalU16 {
    return if (value) |v| .{ .has_value = true, .value = v } else .{};
}

fn optionalU8(value: ?u8) COptionalU8 {
    return if (value) |v| .{ .has_value = true, .value = v } else .{};
}

fn widgetViewToC(node: api.NodeView) CWidgetView {
    return switch (node.kind) {
        .container => |v| .{ .kind = .container, .data = .{ .container = .{ .direction = directionToC(v.direction) } } },
        .text => |v| .{ .kind = .text, .data = .{ .text = .{ .content = toCStr(v.content) } } },
        .button => |v| .{ .kind = .button, .data = .{ .button = .{ .label = toCStr(v.label), .clicked = node.clicked } } },
        .checkbox => |v| .{ .kind = .checkbox, .data = .{ .checkbox = .{
            .label = toCStr(v.label),
            .checked = v.checked,
            .clicked = node.clicked,
        } } },
        .radio_button => |v| .{ .kind = .radio_button, .data = .{ .radio_button = .{
            .label = toCStr(v.label),
            .group = v.group,
            .selected = v.selected,
            .clicked = node.clicked,
        } } },
        .tree_item => |v| .{ .kind = .tree_item, .data = .{ .tree_item = .{
            .label = toCStr(v.label),
            .group = v.group,
            .has_children = v.has_children,
            .expanded = v.expanded,
            .selected = v.selected,
            .editing = v.editing,
            .clicked = node.clicked,
            .toggled = node.toggled,
            .dragging = v.dragging,
            .drop_received = node.drop_received,
            .rename_committed = v.rename_committed,
        } } },
        .dropdown => |v| .{ .kind = .dropdown, .data = .{ .dropdown = .{
            .placeholder = toCStr(v.placeholder),
            .selected_text = toCStr(v.selected_text),
            .selected_index = optionalU16(v.selected_index),
            .open = v.open,
            .clicked = node.clicked,
            .changed = node.changed,
        } } },
        .list_box => .{ .kind = .list_box, .data = .{ .list_box = .{ .changed = node.changed } } },
        .selectable => |v| .{ .kind = .selectable, .data = .{ .selectable = .{
            .label = toCStr(v.label),
            .group = v.group,
            .selected = v.selected,
            .clicked = node.clicked,
            .dragging = v.dragging,
        } } },
        .grid_selector => |v| .{ .kind = .grid_selector, .data = .{ .grid_selector = .{
            .changed = node.changed,
            .computed_columns = v.computed_columns,
        } } },
        .grid_item => |v| .{ .kind = .grid_item, .data = .{ .grid_item = .{
            .label = toCStr(v.label),
            .selected = v.selected,
            .clicked = node.clicked,
            .dragging = v.dragging,
        } } },
        .table => |v| .{ .kind = .table, .data = .{ .table = .{
            .active_columns = v.active_columns,
            .changed = node.changed,
            .resized_column = optionalU8(v.resized_column),
            .sorted_column = optionalU8(v.sorted_column),
            .sort_direction = sortDirectionToC(v.sort_direction),
            .sort_changed = v.sort_changed,
            .selection_changed = v.selection_changed,
        } } },
        .table_row => |v| .{ .kind = .table_row, .data = .{ .table_row = .{
            .header = v.header,
            .selected = v.selected,
            .dragging = v.dragging,
        } } },
        .table_cell => .{ .kind = .table_cell, .data = .{ .table_cell = .{} } },
        .toolbar => .{ .kind = .toolbar, .data = .{ .toolbar = .{} } },
        .status_bar => .{ .kind = .status_bar, .data = .{ .status_bar = .{} } },
        .menu_bar => .{ .kind = .menu_bar, .data = .{ .menu_bar = .{} } },
        .menu => |v| .{ .kind = .menu, .data = .{ .menu = .{ .label = toCStr(v.label), .clicked = node.clicked } } },
        .popup => |v| .{ .kind = .popup, .data = .{ .popup = .{
            .placement = placementToC(v.placement),
            .x = v.x,
            .y = v.y,
            .visible = v.visible,
            .z_index = v.z_index,
        } } },
        .tooltip => |v| .{ .kind = .tooltip, .data = .{ .tooltip = .{
            .placement = placementToC(v.placement),
            .x = v.x,
            .y = v.y,
            .z_index = v.z_index,
        } } },
        .menu_item => |v| .{ .kind = .menu_item, .data = .{ .menu_item = .{
            .label = toCStr(v.label),
            .shortcut = toCStr(v.shortcut),
            .checked = v.checked,
            .disabled = v.disabled,
            .clicked = node.clicked,
        } } },
        .drag_value => |v| .{ .kind = .drag_value, .data = .{ .drag_value = .{
            .value = v.value,
            .changed = node.changed,
            .editing = v.editing,
            .display_text = toCStr(v.display_text),
        } } },
        .spinbox => |v| .{ .kind = .spinbox, .data = .{ .spinbox = .{
            .value = v.value,
            .changed = node.changed,
            .editing = v.editing,
            .display_text = toCStr(v.display_text),
        } } },
        .tab_bar => .{ .kind = .tab_bar, .data = .{ .tab_bar = .{} } },
        .tab_item => |v| .{ .kind = .tab_item, .data = .{ .tab_item = .{
            .label = toCStr(v.label),
            .selected = v.selected,
            .clicked = node.clicked,
        } } },
        .splitter => |v| .{ .kind = .splitter, .data = .{ .splitter = .{ .ratio = v.ratio, .changed = node.changed } } },
        .slider => |v| .{ .kind = .slider, .data = .{ .slider = .{ .value = v.value } } },
        .spacer => .{ .kind = .spacer, .data = .{ .spacer = .{} } },
        .scroll_area => |v| .{ .kind = .scroll_area, .data = .{ .scroll_area = .{
            .scroll_x = v.scroll_x,
            .scroll_y = v.scroll_y,
        } } },
        .text_input => |v| .{ .kind = .text_input, .data = .{ .text_input = .{
            .content = toCStr(v.content),
            .cursor = v.cursor,
            .selection_anchor = optionalU8(v.selection_anchor),
        } } },
    };
}

fn nodeViewToC(node: api.NodeView) CNodeView {
    return .{
        .rect = rectToC(node.rect),
        .user_id = node.user_id,
        .custom_draw = node.custom_draw,
        .focused = node.focused,
        .accepts_drop = node.accepts_drop,
        .drop_hovered = node.drop_hovered,
        .drop_received = node.drop_received,
        .clicked = node.clicked,
        .secondary_clicked = node.secondary_clicked,
        .changed = node.changed,
        .toggled = node.toggled,
        .kind = widgetViewToC(node),
    };
}

fn dropToC(drop: dispatch.Drop) CDrop {
    return switch (drop) {
        .tree => |d| .{ .kind = .tree, .data = .{ .tree = .{
            .source = handleToC(d.source),
            .target = handleToC(d.target),
            .position = treeDropPositionToC(d.position),
        } } },
        .grid => |d| .{ .kind = .grid, .data = .{ .grid = .{
            .source = handleToC(d.source),
            .target = handleToC(d.target),
            .position = gridDropPositionToC(d.position),
        } } },
        .list => |d| .{ .kind = .list, .data = .{ .list = .{
            .source = handleToC(d.source),
            .target = handleToC(d.target),
        } } },
        .table => |d| .{ .kind = .table, .data = .{ .table = .{
            .source = handleToC(d.source),
            .target = handleToC(d.target),
        } } },
        .widget => |d| .{ .kind = .widget, .data = .{ .widget = .{
            .source = handleToC(d.source),
            .target = handleToC(d.target),
        } } },
    };
}

fn frameSnapshotToC(snap: api.FrameSnapshot) CFrameSnapshot {
    return .{
        .pointer_x = snap.pointer.x,
        .pointer_y = snap.pointer.y,
        .buttons = .{
            .left = snap.buttons.left,
            .right = snap.buttons.right,
            .middle = snap.buttons.middle,
        },
        .has_focused = snap.focused != null,
        .focused = if (snap.focused) |h| handleToC(h) else .{},
        .has_drag_source = snap.drag_source != null,
        .drag_source = if (snap.drag_source) |h| handleToC(h) else .{},
        .has_last_drop = snap.last_drop != null,
        .last_drop = if (snap.last_drop) |d| dropToC(d) else .{},
        .has_last_secondary_click = snap.last_secondary_click != null,
        .last_secondary_click = if (snap.last_secondary_click) |c| .{
            .target = handleToC(c.target),
            .x = c.x,
            .y = c.y,
        } else .{},
        .last_primary_press_ms = snap.last_primary_press_ms,
    };
}

fn keycodeFromC(keycode: CKeycode) event.Event.Keycode {
    // CKeycode and Event.Keycode share tag names; cast through the
    // shared name list rather than maintaining a giant switch.
    const tag_name = @tagName(keycode);
    return std.meta.stringToEnum(event.Event.Keycode, tag_name) orelse .unknown;
}

fn modifiersFromC(mods: CModifiers) event.Event.Modifiers {
    return .{
        .shift = mods.shift,
        .ctrl = mods.ctrl,
        .alt = mods.alt,
        .super = mods.super,
        .caps_lock = mods.caps_lock,
        .num_lock = mods.num_lock,
    };
}

fn setTextInputValue(ti: *widget.WidgetKind.TextInput, placeholder: []const u8, value: []const u8) void {
    ti.* = .{ .placeholder = placeholder };
    if (value.len > 0) ti.insertSlice(value);
}

/// Apply the C-side text-input initial value to the constructed widget.
/// The desc-only path leaves the buffer empty; for parity with the
/// previous C API we insert the seed value here.
fn applyTextInputSeedValue(node_kind: *widget.WidgetKind, desc: CWidget) void {
    if (desc.kind != .text_input) return;
    const value = fromCStr(desc.data.text_input.value);
    if (value.len == 0) return;
    node_kind.text_input.insertSlice(value);
}

fn buildWidgetDesc(desc: CWidget) widget.WidgetDesc {
    return switch (desc.kind) {
        .container => .{ .container = .{ .direction = directionFromC(desc.data.container.direction) } },
        .text => .{ .text = .{ .content = fromCStr(desc.data.text.content) } },
        .button => .{ .button = .{ .label = fromCStr(desc.data.button.label) } },
        .checkbox => .{ .checkbox = .{
            .label = fromCStr(desc.data.checkbox.label),
            .checked = desc.data.checkbox.checked,
        } },
        .radio_button => .{ .radio_button = .{
            .label = fromCStr(desc.data.radio_button.label),
            .group = desc.data.radio_button.group,
            .selected = desc.data.radio_button.selected,
        } },
        .tree_item => .{ .tree_item = .{
            .label = fromCStr(desc.data.tree_item.label),
            .group = desc.data.tree_item.group,
            .editable = desc.data.tree_item.editable,
            .rename_trigger = renameTriggerFromC(desc.data.tree_item.rename_trigger),
            .expanded = desc.data.tree_item.expanded,
            .selected = desc.data.tree_item.selected,
        } },
        .dropdown => .{ .dropdown = .{
            .placeholder = fromCStr(desc.data.dropdown.placeholder),
            .selected_text = fromCStr(desc.data.dropdown.selected_text),
            .selected_index = if (desc.data.dropdown.selected_index.has_value) desc.data.dropdown.selected_index.value else null,
            .open = desc.data.dropdown.open,
        } },
        .list_box => .{ .list_box = .{
            .selection_mode = listSelectionModeFromC(desc.data.list_box.selection_mode),
        } },
        .selectable => .{ .selectable = .{
            .label = fromCStr(desc.data.selectable.label),
            .group = desc.data.selectable.group,
            .selected = desc.data.selectable.selected,
        } },
        .grid_selector => .{ .grid_selector = .{
            .selection_mode = listSelectionModeFromC(desc.data.grid_selector.selection_mode),
            .item_width = desc.data.grid_selector.item_width,
            .item_height = desc.data.grid_selector.item_height,
            .column_gap = desc.data.grid_selector.column_gap,
            .row_gap = desc.data.grid_selector.row_gap,
        } },
        .grid_item => .{ .grid_item = .{
            .label = fromCStr(desc.data.grid_item.label),
            .selected = desc.data.grid_item.selected,
        } },
        .table => .{ .table = .{
            .columns = desc.data.table.columns,
            .striped = desc.data.table.striped,
            .resizable = desc.data.table.resizable,
            .sortable = desc.data.table.sortable,
            .selection_mode = tableSelectionModeFromC(desc.data.table.selection_mode),
            .min_column_width = desc.data.table.min_column_width,
            .sorted_column = if (desc.data.table.sorted_column.has_value) desc.data.table.sorted_column.value else null,
            .sort_direction = sortDirectionFromC(desc.data.table.sort_direction),
        } },
        .table_row => .{ .table_row = .{
            .header = desc.data.table_row.header,
            .selected = desc.data.table_row.selected,
        } },
        .table_cell => .{ .table_cell = .{} },
        .toolbar => .{ .toolbar = .{} },
        .status_bar => .{ .status_bar = .{} },
        .menu_bar => .{ .menu_bar = .{} },
        .menu => .{ .menu = .{ .label = fromCStr(desc.data.menu.label) } },
        .popup => .{ .popup = .{
            .placement = placementFromC(desc.data.popup.placement),
            .x = desc.data.popup.x,
            .y = desc.data.popup.y,
            .visible = desc.data.popup.visible,
            .close_on_outside_click = desc.data.popup.close_on_outside_click,
            .z_index = desc.data.popup.z_index,
            .pointer_passthrough = desc.data.popup.pointer_passthrough,
        } },
        .tooltip => .{ .tooltip = .{
            .placement = placementFromC(desc.data.tooltip.placement),
            .x = desc.data.tooltip.x,
            .y = desc.data.tooltip.y,
            .z_index = desc.data.tooltip.z_index,
        } },
        .menu_item => .{ .menu_item = .{
            .label = fromCStr(desc.data.menu_item.label),
            .shortcut = fromCStr(desc.data.menu_item.shortcut),
            .checked = desc.data.menu_item.checked,
            .disabled = desc.data.menu_item.disabled,
        } },
        .drag_value => .{ .drag_value = .{
            .value = desc.data.drag_value.value,
            .min = desc.data.drag_value.min,
            .max = desc.data.drag_value.max,
            .speed = desc.data.drag_value.speed,
            .precision = desc.data.drag_value.precision,
        } },
        .spinbox => .{ .spinbox = .{
            .value = desc.data.spinbox.value,
            .min = desc.data.spinbox.min,
            .max = desc.data.spinbox.max,
            .step = desc.data.spinbox.step,
            .precision = desc.data.spinbox.precision,
        } },
        .tab_bar => .{ .tab_bar = .{} },
        .tab_item => .{ .tab_item = .{
            .label = fromCStr(desc.data.tab_item.label),
            .selected = desc.data.tab_item.selected,
        } },
        .splitter => .{ .splitter = .{
            .direction = directionFromC(desc.data.splitter.direction),
            .ratio = desc.data.splitter.ratio,
            .min_first = desc.data.splitter.min_first,
            .min_second = desc.data.splitter.min_second,
            .thickness = desc.data.splitter.thickness,
            .keyboard_step = desc.data.splitter.keyboard_step,
        } },
        .slider => .{ .slider = .{
            .value = desc.data.slider.value,
            .min = desc.data.slider.min,
            .max = desc.data.slider.max,
        } },
        .scroll_area => .{ .scroll_area = .{
            .scroll_x = desc.data.scroll_area.scroll_x,
            .scroll_y = desc.data.scroll_area.scroll_y,
            .disable_horizontal_scroll = desc.data.scroll_area.disable_horizontal_scroll,
            .disable_vertical_scroll = desc.data.scroll_area.disable_vertical_scroll,
        } },
        .text_input => .{ .text_input = .{
            .placeholder = fromCStr(desc.data.text_input.placeholder),
        } },
        .spacer => .{ .spacer = .{
            .width = desc.data.spacer.width,
            .height = desc.data.spacer.height,
        } },
    };
}

fn updateWidgetKind(kind: *widget.WidgetKind, desc: CWidget) bool {
    switch (kind.*) {
        .container => |*container| {
            if (desc.kind != .container) return false;
            container.direction = directionFromC(desc.data.container.direction);
        },
        .text => |*text| {
            if (desc.kind != .text) return false;
            text.content = fromCStr(desc.data.text.content);
        },
        .button => |*button| {
            if (desc.kind != .button) return false;
            button.label = fromCStr(desc.data.button.label);
        },
        .checkbox => |*checkbox| {
            if (desc.kind != .checkbox) return false;
            checkbox.label = fromCStr(desc.data.checkbox.label);
            checkbox.checked = desc.data.checkbox.checked;
        },
        .radio_button => |*radio_button| {
            if (desc.kind != .radio_button) return false;
            radio_button.label = fromCStr(desc.data.radio_button.label);
            radio_button.group = desc.data.radio_button.group;
            radio_button.selected = desc.data.radio_button.selected;
        },
        .tree_item => |*tree_item| {
            if (desc.kind != .tree_item) return false;
            tree_item.label = fromCStr(desc.data.tree_item.label);
            tree_item.group = desc.data.tree_item.group;
            tree_item.editable = desc.data.tree_item.editable;
            tree_item.rename_trigger = renameTriggerFromC(desc.data.tree_item.rename_trigger);
            tree_item.expanded = desc.data.tree_item.expanded;
            tree_item.selected = desc.data.tree_item.selected;
        },
        .dropdown => |*dropdown| {
            if (desc.kind != .dropdown) return false;
            dropdown.placeholder = fromCStr(desc.data.dropdown.placeholder);
            dropdown.selected_text = fromCStr(desc.data.dropdown.selected_text);
            dropdown.selected_index = if (desc.data.dropdown.selected_index.has_value) desc.data.dropdown.selected_index.value else null;
            dropdown.open = desc.data.dropdown.open;
        },
        .list_box => |*list_box| {
            if (desc.kind != .list_box) return false;
            list_box.selection_mode = listSelectionModeFromC(desc.data.list_box.selection_mode);
        },
        .selectable => |*selectable| {
            if (desc.kind != .selectable) return false;
            selectable.label = fromCStr(desc.data.selectable.label);
            selectable.group = desc.data.selectable.group;
            selectable.selected = desc.data.selectable.selected;
        },
        .grid_selector => |*grid_selector| {
            if (desc.kind != .grid_selector) return false;
            grid_selector.selection_mode = listSelectionModeFromC(desc.data.grid_selector.selection_mode);
            grid_selector.item_width = desc.data.grid_selector.item_width;
            grid_selector.item_height = desc.data.grid_selector.item_height;
            grid_selector.column_gap = desc.data.grid_selector.column_gap;
            grid_selector.row_gap = desc.data.grid_selector.row_gap;
        },
        .grid_item => |*grid_item| {
            if (desc.kind != .grid_item) return false;
            grid_item.label = fromCStr(desc.data.grid_item.label);
            grid_item.selected = desc.data.grid_item.selected;
        },
        .table => |*table| {
            if (desc.kind != .table) return false;
            table.columns = desc.data.table.columns;
            table.striped = desc.data.table.striped;
            table.resizable = desc.data.table.resizable;
            table.sortable = desc.data.table.sortable;
            table.selection_mode = tableSelectionModeFromC(desc.data.table.selection_mode);
            table.min_column_width = desc.data.table.min_column_width;
            table.syncColumns(desc.data.table.columns);
            table.sorted_column = if (desc.data.table.sorted_column.has_value) desc.data.table.sorted_column.value else null;
            table.sort_direction = sortDirectionFromC(desc.data.table.sort_direction);
        },
        .table_row => |*table_row| {
            if (desc.kind != .table_row) return false;
            table_row.header = desc.data.table_row.header;
            table_row.selected = desc.data.table_row.selected;
        },
        .table_cell => {
            if (desc.kind != .table_cell) return false;
        },
        .toolbar => {
            if (desc.kind != .toolbar) return false;
        },
        .status_bar => {
            if (desc.kind != .status_bar) return false;
        },
        .menu_bar => {
            if (desc.kind != .menu_bar) return false;
        },
        .menu => |*menu| {
            if (desc.kind != .menu) return false;
            menu.label = fromCStr(desc.data.menu.label);
        },
        .popup => |*popup| {
            if (desc.kind != .popup) return false;
            popup.placement = placementFromC(desc.data.popup.placement);
            popup.x = desc.data.popup.x;
            popup.y = desc.data.popup.y;
            popup.visible = desc.data.popup.visible;
            popup.close_on_outside_click = desc.data.popup.close_on_outside_click;
            popup.z_index = desc.data.popup.z_index;
            popup.pointer_passthrough = desc.data.popup.pointer_passthrough;
        },
        .tooltip => |*tooltip| {
            if (desc.kind != .tooltip) return false;
            tooltip.placement = placementFromC(desc.data.tooltip.placement);
            tooltip.x = desc.data.tooltip.x;
            tooltip.y = desc.data.tooltip.y;
            tooltip.z_index = desc.data.tooltip.z_index;
        },
        .menu_item => |*menu_item| {
            if (desc.kind != .menu_item) return false;
            menu_item.label = fromCStr(desc.data.menu_item.label);
            menu_item.shortcut = fromCStr(desc.data.menu_item.shortcut);
            menu_item.checked = desc.data.menu_item.checked;
            menu_item.disabled = desc.data.menu_item.disabled;
        },
        .drag_value => |*drag_value| {
            if (desc.kind != .drag_value) return false;
            drag_value.value = desc.data.drag_value.value;
            drag_value.min = desc.data.drag_value.min;
            drag_value.max = desc.data.drag_value.max;
            drag_value.speed = desc.data.drag_value.speed;
            drag_value.precision = desc.data.drag_value.precision;
            drag_value.syncLabel();
        },
        .spinbox => |*spinbox| {
            if (desc.kind != .spinbox) return false;
            spinbox.value = desc.data.spinbox.value;
            spinbox.min = desc.data.spinbox.min;
            spinbox.max = desc.data.spinbox.max;
            spinbox.step = desc.data.spinbox.step;
            spinbox.precision = desc.data.spinbox.precision;
            spinbox.syncLabel();
        },
        .tab_bar => {
            if (desc.kind != .tab_bar) return false;
        },
        .tab_item => |*tab_item| {
            if (desc.kind != .tab_item) return false;
            tab_item.label = fromCStr(desc.data.tab_item.label);
            tab_item.selected = desc.data.tab_item.selected;
        },
        .splitter => |*splitter| {
            if (desc.kind != .splitter) return false;
            splitter.direction = directionFromC(desc.data.splitter.direction);
            splitter.ratio = desc.data.splitter.ratio;
            splitter.min_first = desc.data.splitter.min_first;
            splitter.min_second = desc.data.splitter.min_second;
            splitter.thickness = desc.data.splitter.thickness;
            splitter.keyboard_step = desc.data.splitter.keyboard_step;
        },
        .slider => |*slider| {
            if (desc.kind != .slider) return false;
            slider.value = desc.data.slider.value;
            slider.min = desc.data.slider.min;
            slider.max = desc.data.slider.max;
        },
        .scroll_area => |*scroll_area| {
            if (desc.kind != .scroll_area) return false;
            scroll_area.scroll_x = desc.data.scroll_area.scroll_x;
            scroll_area.scroll_y = desc.data.scroll_area.scroll_y;
            scroll_area.disable_horizontal_scroll = desc.data.scroll_area.disable_horizontal_scroll;
            scroll_area.disable_vertical_scroll = desc.data.scroll_area.disable_vertical_scroll;
        },
        .text_input => |*text_input| {
            if (desc.kind != .text_input) return false;
            setTextInputValue(text_input, fromCStr(desc.data.text_input.placeholder), fromCStr(desc.data.text_input.value));
        },
        .spacer => |*spacer| {
            if (desc.kind != .spacer) return false;
            spacer.width = desc.data.spacer.width;
            spacer.height = desc.data.spacer.height;
        },
    }
    return true;
}

fn convertEvent(ev: CEvent) event.Event {
    return switch (ev.kind) {
        .mouse_move => .{ .mouse_move = .{
            .x = ev.data.mouse_move.x,
            .y = ev.data.mouse_move.y,
        } },
        .mouse_button => .{ .mouse_button = .{
            .button = switch (ev.data.mouse_button.button) {
                .left => .left,
                .right => .right,
                .middle => .middle,
            },
            .state = switch (ev.data.mouse_button.state) {
                .pressed => .pressed,
                .released => .released,
            },
            .x = ev.data.mouse_button.x,
            .y = ev.data.mouse_button.y,
            .timestamp_ms = ev.data.mouse_button.timestamp_ms,
            .mods = modifiersFromC(ev.data.mouse_button.mods),
        } },
        .mouse_scroll => .{ .mouse_scroll = .{
            .dx = ev.data.mouse_scroll.dx,
            .dy = ev.data.mouse_scroll.dy,
            .mods = modifiersFromC(ev.data.mouse_scroll.mods),
        } },
        .key => .{ .key = .{
            .scancode = ev.data.key.scancode,
            .keycode = keycodeFromC(ev.data.key.keycode),
            .mods = modifiersFromC(ev.data.key.mods),
            .state = switch (ev.data.key.state) {
                .pressed => .pressed,
                .released => .released,
                .repeat => .repeat,
            },
        } },
        .text => .{ .text = .{
            .codepoint = @intCast(ev.data.text.codepoint),
        } },
        .focus => .{ .focus = .{
            .focused = ev.data.focus.focused,
        } },
        .resize => .{ .resize = .{
            .width = ev.data.resize.width,
            .height = ev.data.resize.height,
        } },
    };
}

fn markDirty(ctx: *CContext) void {
    ctx.ctx.runtime.invalidate();
}

fn validHandle(ctx: *const CContext, handle: CHandle) bool {
    return ctx.ctx.tree.isAlive(handleFromC(handle));
}

fn convertDrawCommand(cmd: draw.DrawCommand) CDrawCommand {
    return switch (cmd) {
        .rect => |rect_cmd| .{
            .kind = .rect,
            .data = .{ .rect = .{
                .bounds = rectToC(rect_cmd.bounds),
                .color = colorToC(rect_cmd.color),
                .border_color = colorToC(rect_cmd.border_color),
                .border_width = rect_cmd.border_width,
                .corner_radius = rect_cmd.corner_radius,
            } },
        },
        .text => |text_cmd| .{
            .kind = .text,
            .data = .{ .text = .{
                .bounds = rectToC(text_cmd.bounds),
                .baseline_y = text_cmd.baseline_y,
                .text = toCStr(text_cmd.text),
                .color = colorToC(text_cmd.color),
                .font_size = text_cmd.font_size,
                .text_align = switch (text_cmd.text_align) {
                    .start => .start,
                    .center => .center,
                    .end => .end,
                },
                .overflow = switch (text_cmd.overflow) {
                    .visible => .visible,
                    .wrap => .wrap,
                    .clip => .clip,
                    .ellipsis => .ellipsis,
                },
            } },
        },
        .clip => |clip_cmd| .{
            .kind = .clip,
            .data = .{ .clip = .{
                .has_bounds = clip_cmd.bounds != null,
                .bounds = if (clip_cmd.bounds) |bounds| rectToC(bounds) else .{},
            } },
        },
        .icon => |icon_cmd| .{
            .kind = .icon,
            .data = .{ .icon = .{
                .bounds = rectToC(icon_cmd.bounds),
                .kind = icon_cmd.kind,
                .color = colorToC(icon_cmd.color),
            } },
        },
        .custom => |custom_cmd| .{
            .kind = .custom,
            .data = .{ .custom = .{
                .handle = handleToC(custom_cmd.handle),
                .bounds = rectToC(custom_cmd.bounds),
            } },
        },
    };
}

fn cClipboardGet(ptr: *anyopaque) ?[]const u8 {
    const ctx: *CContext = @ptrCast(@alignCast(ptr));
    if (!ctx.clipboard_enabled or ctx.clipboard_provider.get_text_fn == null) return null;
    const text = ctx.clipboard_provider.get_text_fn.?(ctx.clipboard_provider.ptr);
    if (text.ptr == null or text.len == 0) return null;
    return fromCStr(text);
}

fn cClipboardSet(ptr: *anyopaque, text: []const u8) void {
    const ctx: *CContext = @ptrCast(@alignCast(ptr));
    if (!ctx.clipboard_enabled or ctx.clipboard_provider.set_text_fn == null) return;
    ctx.clipboard_provider.set_text_fn.?(ctx.clipboard_provider.ptr, toCStr(text));
}

fn measureTextBridge(text: []const u8, font_size: f32, user_data: ?*anyopaque) layout.TextDimensions {
    const raw: *const CTextMeasureCtx = @ptrCast(@alignCast(user_data));
    if (raw.measure_fn == null) return .{ .width = 0, .height = font_size };
    const dims = raw.measure_fn.?(toCStr(text), font_size, raw.user_data);
    return .{
        .width = dims.width,
        .height = dims.height,
        .ascent = dims.ascent,
        .descent = dims.descent,
    };
}

fn textMeasurePtr(ctx: *CContext, measure: ?*const CTextMeasureCtx) ?*const layout.TextMeasureCtx {
    if (measure == null) {
        ctx.measure_enabled = false;
        ctx.measure_bridge.user_data = null;
        return null;
    }
    ctx.measure_provider = measure.?.*;
    ctx.measure_enabled = true;
    ctx.measure_bridge.user_data = @ptrCast(&ctx.measure_provider);
    return &ctx.measure_bridge;
}

export fn goop_default_theme() CTheme {
    return themeToC(style.Theme.default);
}

export fn goop_context_create(opts: ?*const CContextOptions) ?*CContext {
    const options = opts orelse &CContextOptions{};
    const theme = if (options.has_theme) themeFromC(options.theme) else style.Theme.default;

    const ctx = allocator.create(CContext) catch return null;
    errdefer allocator.destroy(ctx);

    ctx.* = .{
        .ctx = api.Context.init(allocator, .{
            .width = options.width,
            .height = options.height,
            .theme = theme,
        }) catch return null,
    };
    return ctx;
}

export fn goop_context_destroy(ctx: ?*CContext) void {
    const context = ctx orelse return;
    context.draw_commands.deinit(allocator);
    context.ctx.deinit();
    allocator.destroy(context);
}

export fn goop_context_set_theme(ctx: ?*CContext, theme: ?*const CTheme) bool {
    const context = ctx orelse return false;
    const next_theme = theme orelse return false;
    context.ctx.theme = themeFromC(next_theme.*);
    markDirty(context);
    return true;
}

export fn goop_context_set_clipboard(ctx: ?*CContext, clipboard: ?*const CClipboard) bool {
    const context = ctx orelse return false;
    if (clipboard) |provider| {
        context.clipboard_provider = provider.*;
        context.clipboard_enabled = provider.get_text_fn != null and provider.set_text_fn != null;
        if (context.clipboard_enabled) {
            context.ctx.clipboard = .{
                .ptr = @ptrCast(context),
                .getTextFn = &cClipboardGet,
                .setTextFn = &cClipboardSet,
            };
        } else {
            context.ctx.clipboard = null;
        }
    } else {
        context.clipboard_provider = .{};
        context.clipboard_enabled = false;
        context.ctx.clipboard = null;
    }
    return true;
}

export fn goop_context_clear_clicked_flags(ctx: ?*CContext) bool {
    const context = ctx orelse return false;
    context.ctx.clearClickedFlags();
    return true;
}

export fn goop_context_push_event(ctx: ?*CContext, ev: ?*const CEvent) bool {
    const context = ctx orelse return false;
    const input = ev orelse return false;
    context.ctx.pushEvent(convertEvent(input.*)) catch return false;
    return true;
}

export fn goop_context_process_events(ctx: ?*CContext) bool {
    const context = ctx orelse return false;
    context.ctx.processEvents();
    return true;
}

export fn goop_context_do_layout(ctx: ?*CContext, measure: ?*const CTextMeasureCtx) bool {
    const context = ctx orelse return false;
    context.ctx.doLayout(textMeasurePtr(context, measure));
    return true;
}

export fn goop_context_generate_draw_list(ctx: ?*CContext, out_draw_list: ?*CDrawList) bool {
    const context = ctx orelse return false;
    const out = out_draw_list orelse return false;

    const draw_list = context.ctx.generateDrawList() catch {
        out.* = .{};
        return false;
    };

    context.draw_commands.clearRetainingCapacity();
    context.draw_commands.ensureTotalCapacity(allocator, draw_list.commands.len) catch {
        out.* = .{};
        return false;
    };
    for (draw_list.commands) |command| {
        context.draw_commands.appendAssumeCapacity(convertDrawCommand(command));
    }

    out.* = .{
        .commands = if (context.draw_commands.items.len == 0) null else context.draw_commands.items.ptr,
        .len = context.draw_commands.items.len,
    };
    return true;
}

export fn goop_context_set_dimensions(ctx: ?*CContext, width: u32, height: u32) bool {
    const context = ctx orelse return false;
    context.ctx.setDimensions(width, height);
    return true;
}

export fn goop_context_add_root(ctx: ?*CContext, desc: ?*const CWidget, out_handle: ?*CHandle) bool {
    const context = ctx orelse return false;
    const widget_desc = desc orelse return false;
    const handle_ptr = out_handle orelse return false;
    const handle = context.ctx.tree.addRoot(buildWidgetDesc(widget_desc.*)) catch return false;
    applyTextInputSeedValue(&context.ctx.tree.get(handle).kind, widget_desc.*);
    markDirty(context);
    handle_ptr.* = handleToC(handle);
    return true;
}

export fn goop_context_add_child(ctx: ?*CContext, parent: CHandle, desc: ?*const CWidget, out_handle: ?*CHandle) bool {
    const context = ctx orelse return false;
    const widget_desc = desc orelse return false;
    const handle_ptr = out_handle orelse return false;
    if (!validHandle(context, parent)) return false;
    const handle = context.ctx.tree.addChild(handleFromC(parent), buildWidgetDesc(widget_desc.*)) catch return false;
    applyTextInputSeedValue(&context.ctx.tree.get(handle).kind, widget_desc.*);
    markDirty(context);
    handle_ptr.* = handleToC(handle);
    return true;
}

export fn goop_context_update_widget(ctx: ?*CContext, handle: CHandle, desc: ?*const CWidget) bool {
    const context = ctx orelse return false;
    const widget_desc = desc orelse return false;
    if (!validHandle(context, handle)) return false;
    const node = context.ctx.tree.get(handleFromC(handle));
    if (!updateWidgetKind(&node.kind, widget_desc.*)) return false;
    markDirty(context);
    return true;
}

export fn goop_context_set_style(ctx: ?*CContext, handle: CHandle, override_style: ?*const CStyle) bool {
    const context = ctx orelse return false;
    const style_desc = override_style orelse return false;
    if (!validHandle(context, handle)) return false;
    context.ctx.tree.get(handleFromC(handle)).style_override = styleFromC(style_desc.*);
    markDirty(context);
    return true;
}

export fn goop_context_remove_widget(ctx: ?*CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    context.ctx.tree.remove(handleFromC(handle)) catch return false;
    // tree.remove changes the live-node count; the runtime detects the
    // change on the next doLayout call.
    return true;
}

export fn goop_context_is_alive(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    return context.ctx.tree.isAlive(handleFromC(handle));
}

/// Snapshot per-handle read-only state (rect, interaction flags, kind
/// view) into one struct. Returns false for dead handles.
export fn goop_context_node(ctx: ?*const CContext, handle: CHandle, out_node: ?*CNodeView) bool {
    const context = ctx orelse return false;
    const out = out_node orelse return false;
    const node = context.ctx.tree.node(handleFromC(handle)) orelse return false;
    out.* = nodeViewToC(node);
    return true;
}

/// Snapshot per-frame interaction state (pointer position, button
/// state, focus, drag source, last drop, last secondary click, last
/// primary press timestamp). Always succeeds; out_snapshot must be
/// non-null.
export fn goop_context_frame(ctx: ?*const CContext, out_snapshot: ?*CFrameSnapshot) bool {
    const context = ctx orelse return false;
    const out = out_snapshot orelse return false;
    out.* = frameSnapshotToC(context.ctx.runtime.frame(&context.ctx.tree));
    return true;
}

export fn goop_context_table_column_fraction(ctx: ?*const CContext, handle: CHandle, index: u8, out_fraction: ?*f32) bool {
    const context = ctx orelse return false;
    const fraction_ptr = out_fraction orelse return false;
    const fraction = context.ctx.tree.tableColumnFraction(handleFromC(handle), index) orelse return false;
    fraction_ptr.* = fraction;
    return true;
}

// Mark layout and draw caches stale after caller-owned state changes.
export fn goop_context_invalidate(ctx: ?*CContext) bool {
    const context = ctx orelse return false;
    context.ctx.runtime.invalidate();
    return true;
}

export fn goop_context_set_user_id(ctx: ?*CContext, handle: CHandle, user_id: u64) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    context.ctx.tree.setUserId(handleFromC(handle), user_id);
    return true;
}

export fn goop_context_user_id(ctx: ?*const CContext, handle: CHandle) u64 {
    const context = ctx orelse return 0;
    return context.ctx.tree.userId(handleFromC(handle));
}

export fn goop_context_set_custom_draw(ctx: ?*CContext, handle: CHandle, custom: bool) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.runtime.setCustomDraw(&context.ctx.tree, handleFromC(handle), custom);
}

export fn goop_context_set_drop_target(ctx: ?*CContext, handle: CHandle, accepts_drop: bool) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    context.ctx.tree.setDropTarget(handleFromC(handle), accepts_drop);
    return true;
}

export fn goop_context_focus_widget(ctx: ?*CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    return context.ctx.runtime.focusWidget(&context.ctx.tree, handleFromC(handle));
}

export fn goop_context_clear_focus(ctx: ?*CContext) bool {
    const context = ctx orelse return false;
    context.ctx.runtime.clearFocus(&context.ctx.tree);
    return true;
}

export fn goop_context_cancel_pointer_gesture(ctx: ?*CContext) bool {
    const context = ctx orelse return false;
    context.ctx.runtime.cancelPointerGesture(&context.ctx.tree);
    return true;
}

test "c api smoke" {
    const opts = CContextOptions{ .width = 320, .height = 200 };
    const ctx = goop_context_create(&opts) orelse return error.OutOfMemory;
    defer goop_context_destroy(ctx);

    var root: CHandle = .{};
    try std.testing.expect(goop_context_add_root(ctx, &CWidget{
        .kind = .container,
        .data = .{ .container = .{ .direction = .column } },
    }, &root));

    var button: CHandle = .{};
    try std.testing.expect(goop_context_add_child(ctx, root, &CWidget{
        .kind = .button,
        .data = .{ .button = .{ .label = toCStr("OK") } },
    }, &button));

    try std.testing.expect(goop_context_do_layout(ctx, null));

    var node: CNodeView = .{};
    try std.testing.expect(goop_context_node(ctx, button, &node));

    const press = CEvent{
        .kind = .mouse_button,
        .data = .{ .mouse_button = .{
            .button = .left,
            .state = .pressed,
            .x = node.rect.x + node.rect.w * 0.5,
            .y = node.rect.y + node.rect.h * 0.5,
        } },
    };
    const release = CEvent{
        .kind = .mouse_button,
        .data = .{ .mouse_button = .{
            .button = .left,
            .state = .released,
            .x = node.rect.x + node.rect.w * 0.5,
            .y = node.rect.y + node.rect.h * 0.5,
        } },
    };

    try std.testing.expect(goop_context_push_event(ctx, &press));
    try std.testing.expect(goop_context_push_event(ctx, &release));
    try std.testing.expect(goop_context_process_events(ctx));
    try std.testing.expect(goop_context_node(ctx, button, &node));
    try std.testing.expect(node.clicked);

    var draw_list: CDrawList = .{};
    try std.testing.expect(goop_context_generate_draw_list(ctx, &draw_list));
    try std.testing.expect(draw_list.len > 0);
}

test "c api menu item exposes checked state and defaults to enabled" {
    const opts = CContextOptions{ .width = 320, .height = 200 };
    const ctx = goop_context_create(&opts) orelse return error.OutOfMemory;
    defer goop_context_destroy(ctx);

    var popup: CHandle = .{};
    try std.testing.expect(goop_context_add_root(ctx, &CWidget{
        .kind = .popup,
        .data = .{ .popup = .{} },
    }, &popup));

    var item: CHandle = .{};
    try std.testing.expect(goop_context_add_child(ctx, popup, &CWidget{
        .kind = .menu_item,
        .data = .{ .menu_item = .{
            .label = toCStr("Sidebar"),
            .shortcut = toCStr("Ctrl+B"),
            .checked = true,
        } },
    }, &item));

    var node: CNodeView = .{};
    try std.testing.expect(goop_context_node(ctx, item, &node));
    try std.testing.expectEqual(CWidgetKind.menu_item, node.kind.kind);
    const v = node.kind.data.menu_item;
    try std.testing.expect(v.checked);
    try std.testing.expect(!v.disabled);
    try std.testing.expectEqual(@as(usize, 6), v.shortcut.len);
}

test "c header parses" {
    const c = @cImport({
        @cInclude("goop.h");
    });

    const Pair = struct { Z: type, C: type };
    const pairs = [_]Pair{
        .{ .Z = CStr, .C = c.goop_string_t },
        .{ .Z = CHandle, .C = c.goop_node_handle_t },
        .{ .Z = CRect, .C = c.goop_rect_t },
        .{ .Z = CColor, .C = c.goop_color_t },
        .{ .Z = CEdges, .C = c.goop_edges_t },
        .{ .Z = CTheme, .C = c.goop_theme_t },
        .{ .Z = CStyle, .C = c.goop_style_t },
        .{ .Z = COptionalU16, .C = c.goop_optional_u16_t },
        .{ .Z = COptionalU8, .C = c.goop_optional_u8_t },

        .{ .Z = CContainerWidget, .C = c.goop_container_widget_t },
        .{ .Z = CTextWidget, .C = c.goop_text_widget_t },
        .{ .Z = CButtonWidget, .C = c.goop_button_widget_t },
        .{ .Z = CCheckboxWidget, .C = c.goop_checkbox_widget_t },
        .{ .Z = CRadioButtonWidget, .C = c.goop_radio_button_widget_t },
        .{ .Z = CTreeItemWidget, .C = c.goop_tree_item_widget_t },
        .{ .Z = CDropdownWidget, .C = c.goop_dropdown_widget_t },
        .{ .Z = CListBoxWidget, .C = c.goop_list_box_widget_t },
        .{ .Z = CSelectableWidget, .C = c.goop_selectable_widget_t },
        .{ .Z = CGridSelectorWidget, .C = c.goop_grid_selector_widget_t },
        .{ .Z = CGridItemWidget, .C = c.goop_grid_item_widget_t },
        .{ .Z = CTableWidget, .C = c.goop_table_widget_t },
        .{ .Z = CTableRowWidget, .C = c.goop_table_row_widget_t },
        .{ .Z = CPopupWidget, .C = c.goop_popup_widget_t },
        .{ .Z = CTooltipWidget, .C = c.goop_tooltip_widget_t },
        .{ .Z = CMenuWidget, .C = c.goop_menu_widget_t },
        .{ .Z = CMenuItemWidget, .C = c.goop_menu_item_widget_t },
        .{ .Z = CDragValueWidget, .C = c.goop_drag_value_widget_t },
        .{ .Z = CSpinboxWidget, .C = c.goop_spinbox_widget_t },
        .{ .Z = CTabItemWidget, .C = c.goop_tab_item_widget_t },
        .{ .Z = CSplitterWidget, .C = c.goop_splitter_widget_t },
        .{ .Z = CSliderWidget, .C = c.goop_slider_widget_t },
        .{ .Z = CScrollAreaWidget, .C = c.goop_scroll_area_widget_t },
        .{ .Z = CTextInputWidget, .C = c.goop_text_input_widget_t },
        .{ .Z = CSpacerWidget, .C = c.goop_spacer_widget_t },
        .{ .Z = CUnitWidget, .C = c.goop_unit_widget_t },
        .{ .Z = CWidget, .C = c.goop_widget_t },

        .{ .Z = CContainerView, .C = c.goop_container_view_t },
        .{ .Z = CTextView, .C = c.goop_text_view_t },
        .{ .Z = CButtonView, .C = c.goop_button_view_t },
        .{ .Z = CCheckboxView, .C = c.goop_checkbox_view_t },
        .{ .Z = CRadioButtonView, .C = c.goop_radio_button_view_t },
        .{ .Z = CTreeItemView, .C = c.goop_tree_item_view_t },
        .{ .Z = CDropdownView, .C = c.goop_dropdown_view_t },
        .{ .Z = CListBoxView, .C = c.goop_list_box_view_t },
        .{ .Z = CSelectableView, .C = c.goop_selectable_view_t },
        .{ .Z = CGridSelectorView, .C = c.goop_grid_selector_view_t },
        .{ .Z = CGridItemView, .C = c.goop_grid_item_view_t },
        .{ .Z = CTableView, .C = c.goop_table_view_t },
        .{ .Z = CTableRowView, .C = c.goop_table_row_view_t },
        .{ .Z = CMenuView, .C = c.goop_menu_view_t },
        .{ .Z = CPopupView, .C = c.goop_popup_view_t },
        .{ .Z = CTooltipView, .C = c.goop_tooltip_view_t },
        .{ .Z = CMenuItemView, .C = c.goop_menu_item_view_t },
        .{ .Z = CDragValueView, .C = c.goop_drag_value_view_t },
        .{ .Z = CSpinboxView, .C = c.goop_spinbox_view_t },
        .{ .Z = CTabItemView, .C = c.goop_tab_item_view_t },
        .{ .Z = CSplitterView, .C = c.goop_splitter_view_t },
        .{ .Z = CSliderView, .C = c.goop_slider_view_t },
        .{ .Z = CScrollAreaView, .C = c.goop_scroll_area_view_t },
        .{ .Z = CTextInputView, .C = c.goop_text_input_view_t },
        .{ .Z = CWidgetView, .C = c.goop_widget_view_t },

        .{ .Z = CMouseMoveEvent, .C = c.goop_mouse_move_event_t },
        .{ .Z = CMouseButtonEvent, .C = c.goop_mouse_button_event_t },
        .{ .Z = CMouseScrollEvent, .C = c.goop_mouse_scroll_event_t },
        .{ .Z = CKeyEvent, .C = c.goop_key_event_t },
        .{ .Z = CTextEvent, .C = c.goop_text_event_t },
        .{ .Z = CFocusEvent, .C = c.goop_focus_event_t },
        .{ .Z = CResizeEvent, .C = c.goop_resize_event_t },
        .{ .Z = CEvent, .C = c.goop_event_t },

        .{ .Z = CDrawRect, .C = c.goop_draw_rect_t },
        .{ .Z = CDrawText, .C = c.goop_draw_text_t },
        .{ .Z = CClipRect, .C = c.goop_clip_rect_t },
        .{ .Z = CDrawIcon, .C = c.goop_draw_icon_t },
        .{ .Z = CDrawCustom, .C = c.goop_draw_custom_t },
        .{ .Z = CDrawCommand, .C = c.goop_draw_command_t },
        .{ .Z = CDrawList, .C = c.goop_draw_list_t },

        .{ .Z = CTextDimensions, .C = c.goop_text_dimensions_t },
        .{ .Z = CTextMeasureCtx, .C = c.goop_text_measure_ctx_t },
        .{ .Z = CClipboard, .C = c.goop_clipboard_t },
        .{ .Z = CContextOptions, .C = c.goop_context_options_t },
        .{ .Z = CSecondaryClick, .C = c.goop_secondary_click_t },
        .{ .Z = CTreeDrop, .C = c.goop_tree_drop_t },
        .{ .Z = CGridDrop, .C = c.goop_grid_drop_t },
        .{ .Z = CListDrop, .C = c.goop_list_drop_t },
        .{ .Z = CTableDrop, .C = c.goop_table_drop_t },
        .{ .Z = CWidgetDrop, .C = c.goop_widget_drop_t },
        .{ .Z = CDrop, .C = c.goop_drop_t },

        .{ .Z = CNodeView, .C = c.goop_node_view_t },
        .{ .Z = CFrameButtons, .C = c.goop_frame_buttons_t },
        .{ .Z = CFrameSnapshot, .C = c.goop_frame_snapshot_t },
    };

    inline for (pairs) |pair| {
        std.testing.expectEqual(@sizeOf(pair.Z), @sizeOf(pair.C)) catch |err| {
            std.debug.print("size mismatch: zig={s} c={s} zig_size={} c_size={}\n", .{
                @typeName(pair.Z),
                @typeName(pair.C),
                @sizeOf(pair.Z),
                @sizeOf(pair.C),
            });
            return err;
        };
        inline for (@typeInfo(pair.Z).@"struct".fields) |field| {
            const z_off = @offsetOf(pair.Z, field.name);
            const c_off = @offsetOf(pair.C, field.name);
            std.testing.expectEqual(z_off, c_off) catch |err| {
                std.debug.print("offset mismatch: {s}.{s}: zig={} c={}\n", .{
                    @typeName(pair.Z),
                    field.name,
                    z_off,
                    c_off,
                });
                return err;
            };
        }
    }
}

test "c header draw command kinds match" {
    const c = @cImport({
        @cInclude("goop.h");
    });
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CDrawCommandKind.rect)), c.GOOP_DRAW_RECT);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CDrawCommandKind.text)), c.GOOP_DRAW_TEXT);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CDrawCommandKind.clip)), c.GOOP_DRAW_CLIP);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CDrawCommandKind.icon)), c.GOOP_DRAW_ICON);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CDrawCommandKind.custom)), c.GOOP_DRAW_CUSTOM);
}

test "c header widget kinds match" {
    const c = @cImport({
        @cInclude("goop.h");
    });
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CWidgetKind.container)), c.GOOP_WIDGET_CONTAINER);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CWidgetKind.text)), c.GOOP_WIDGET_TEXT);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CWidgetKind.button)), c.GOOP_WIDGET_BUTTON);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CWidgetKind.scroll_area)), c.GOOP_WIDGET_SCROLL_AREA);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CWidgetKind.text_input)), c.GOOP_WIDGET_TEXT_INPUT);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CWidgetKind.spacer)), c.GOOP_WIDGET_SPACER);
}
