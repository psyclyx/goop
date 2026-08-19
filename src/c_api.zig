const std = @import("std");
const api = @import("goop");
const visual = @import("goop_visual");
const shared = @import("c_api/context.zig");
const widget = api.widget;
const input_types = api.input;
const style = api.style;

const allocator = std.heap.c_allocator;

const CStr = shared.String;

const CHandle = extern struct {
    index: u32 = 0,
    generation: u32 = 0,
};

const COptionalActionId = extern struct {
    value: u64 = 0,
    has_value: bool = false,
};

const COptionalElementId = extern struct {
    value: u64 = 0,
    has_value: bool = false,
};

const CControlIdentity = extern struct {
    element_id: u64 = 0,
    action_id: COptionalActionId = .{},
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

const CWidgetKind = enum(c_int) {
    container = 0,
    text = 1,
    icon = 2,
    button = 3,
    checkbox = 4,
    radio_button = 5,
    tree_item = 6,
    dropdown = 7,
    list_box = 8,
    selectable = 9,
    grid_selector = 10,
    grid_item = 11,
    table = 12,
    table_row = 13,
    table_cell = 14,
    toolbar = 15,
    status_bar = 16,
    menu_bar = 17,
    menu = 18,
    popup = 19,
    tooltip = 20,
    menu_item = 21,
    drag_value = 22,
    spinbox = 23,
    tab_bar = 24,
    tab_item = 25,
    splitter = 26,
    slider = 27,
    scroll_area = 28,
    text_input = 29,
    spacer = 30,
    custom = 31,
};

const COptionalU32 = extern struct {
    has_value: bool = false,
    value: u32 = 0,
};

const COptionalU16 = extern struct {
    has_value: bool = false,
    value: u16 = 0,
};

const COptionalU8 = extern struct {
    has_value: bool = false,
    value: u8 = 0,
};

const COptionalColor = extern struct {
    has_value: bool = false,
    value: CColor = .{},
};

const CContainerWidget = extern struct {
    direction: CDirection = .column,
};

const CTextWidget = extern struct {
    content: CStr = .{},
};

const CIconWidget = extern struct {
    kind: u32 = 0,
    color: COptionalColor = .{},
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
    icon: COptionalU32 = .{},
    icon_color: COptionalColor = .{},
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
    icon: COptionalU32 = .{},
    icon_color: COptionalColor = .{},
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
    delay_ms: u32 = 500,
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
    thickness: f32 = 8,
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

const CCustomWidget = extern struct {
    type_id: u64 = 0,
    width: f32 = 0,
    height: f32 = 0,
    min_width: f32 = 0,
    min_height: f32 = 0,
    grow_width: bool = true,
    grow_height: bool = false,
    focusable: bool = false,
};

const CUnitWidget = extern struct {
    _reserved: u8 = 0,
};

const CWidget = extern struct {
    kind: CWidgetKind = .container,
    data: extern union {
        container: CContainerWidget,
        text: CTextWidget,
        icon: CIconWidget,
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
        custom: CCustomWidget,
    } = .{ .container = .{} },
};

const CControlDesc = extern struct {
    identity: CControlIdentity = .{},
    widget: CWidget = .{},
};

// Read-only views into widget state. Mirrors api.WidgetView one-for-one.

const CContainerView = extern struct { direction: CDirection = .row };

const CTextView = extern struct { content: CStr = .{} };

const CIconView = extern struct {
    kind: u32 = 0,
    color: COptionalColor = .{},
};

const CButtonView = extern struct {
    label: CStr = .{},
};

const CCheckboxView = extern struct {
    label: CStr = .{},
    checked: bool = false,
};

const CRadioButtonView = extern struct {
    label: CStr = .{},
    group: u32 = 0,
    selected: bool = false,
};

const CTreeItemView = extern struct {
    label: CStr = .{},
    group: u32 = 0,
    icon: COptionalU32 = .{},
    icon_color: COptionalColor = .{},
    has_children: bool = false,
    expanded: bool = false,
    selected: bool = false,
    editing: bool = false,
    dragging: bool = false,
};

const CDropdownView = extern struct {
    placeholder: CStr = .{},
    selected_text: CStr = .{},
    selected_index: COptionalU16 = .{},
    open: bool = false,
};

const CListBoxView = extern struct { _reserved: u8 = 0 };

const CSelectableView = extern struct {
    label: CStr = .{},
    group: u32 = 0,
    selected: bool = false,
    dragging: bool = false,
};

const CGridSelectorView = extern struct {
    computed_columns: u16 = 0,
};

const CGridItemView = extern struct {
    label: CStr = .{},
    icon: COptionalU32 = .{},
    icon_color: COptionalColor = .{},
    selected: bool = false,
    dragging: bool = false,
};

const CTableView = extern struct {
    active_columns: u8 = 0,
    sorted_column: COptionalU8 = .{},
    sort_direction: CSortDirection = .ascending,
};

const CTableRowView = extern struct {
    header: bool = false,
    selected: bool = false,
    dragging: bool = false,
};

const CMenuView = extern struct {
    label: CStr = .{},
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
    visible: bool = false,
};

const CUpdateResult = extern struct {
    changed: bool = false,
    has_next_deadline: bool = false,
    next_deadline_ms: u64 = 0,
};

const CMenuItemView = extern struct {
    label: CStr = .{},
    shortcut: CStr = .{},
    checked: bool = false,
    disabled: bool = false,
};

const CDragValueView = extern struct {
    value: f32 = 0,
    editing: bool = false,
    display_text: CStr = .{},
};

const CSpinboxView = extern struct {
    value: f32 = 0,
    editing: bool = false,
    display_text: CStr = .{},
};

const CTabItemView = extern struct {
    label: CStr = .{},
    selected: bool = false,
};

const CSplitterView = extern struct {
    ratio: f32 = 0,
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

const CCustomView = extern struct {
    type_id: u64 = 0,
    width: f32 = 0,
    height: f32 = 0,
    min_width: f32 = 0,
    min_height: f32 = 0,
    grow_width: bool = false,
    grow_height: bool = false,
    focusable: bool = false,
};

const CWidgetView = extern struct {
    kind: CWidgetKind = .container,
    data: extern union {
        container: CContainerView,
        text: CTextView,
        icon: CIconView,
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
        custom: CCustomView,
    } = .{ .container = .{} },
};

const CResolvedElement = extern struct {
    id: COptionalElementId = .{},
    parent_id: COptionalElementId = .{},
    action_id: COptionalActionId = .{},
    bounds: CRect = .{},
    style: CTheme = .{},
    widget: CWidgetView = .{},
    focused: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    drop_hovered: bool = false,
};

const CResolvedElementFn = *const fn (user_data: ?*anyopaque, element: *const CResolvedElement) callconv(.c) void;

const CResolvedVisitor = extern struct {
    enter: ?CResolvedElementFn = null,
    leave: ?CResolvedElementFn = null,
    user_data: ?*anyopaque = null,
};

const CNodeView = extern struct {
    rect: CRect = .{},
    identity: CControlIdentity = .{},
    focused: bool = false,
    accepts_drop: bool = false,
    drop_hovered: bool = false,
    kind: CWidgetView = .{},
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
    a = 0,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    digit_0,
    digit_1,
    digit_2,
    digit_3,
    digit_4,
    digit_5,
    digit_6,
    digit_7,
    digit_8,
    digit_9,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    space,
    tab,
    enter,
    backspace,
    delete,
    insert,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    escape,
    minus,
    equal,
    left_bracket,
    right_bracket,
    backslash,
    semicolon,
    apostrophe,
    comma,
    period,
    slash,
    grave,
    left_shift,
    right_shift,
    left_ctrl,
    right_ctrl,
    left_alt,
    right_alt,
    left_super,
    right_super,
    caps_lock,
    num_lock,
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

const CTextDimensions = shared.TextDimensions;
const CTextMeasureCtx = shared.TextMeasureContext;
const CClipboard = shared.Clipboard;

const CContextOptions = extern struct {
    width: u32 = 800,
    height: u32 = 600,
    has_theme: bool = false,
    theme: CTheme = .{},
};

const CPayloadSpan = extern struct {
    start: usize = 0,
    len: usize = 0,
};

const CControlEventKind = enum(c_int) {
    activated = 0,
    secondary_activated = 1,
    value_changed = 2,
    toggle_changed = 3,
    text_changed = 4,
    sort_changed = 5,
    selection_changed = 6,
    scroll_changed = 7,
    drop = 8,
    popup_visibility_changed = 9,
};

const CActivation = extern struct {
    element: u64 = 0,
    action: COptionalActionId = .{},
};

const CSecondaryActivation = extern struct {
    element: u64 = 0,
    action: COptionalActionId = .{},
    x: f32 = 0,
    y: f32 = 0,
};

const CControlValueKind = enum(c_int) {
    scalar = 0,
    index = 1,
    column_fraction = 2,
};

const CColumnFraction = extern struct {
    column: u8 = 0,
    fraction: f32 = 0,
};

const CControlValue = extern struct {
    kind: CControlValueKind = .scalar,
    data: extern union {
        scalar: f32,
        index: COptionalU16,
        column_fraction: CColumnFraction,
    } = .{ .scalar = 0 },
};

const CValueChanged = extern struct {
    element: u64 = 0,
    value: CControlValue = .{},
};

const CToggleChanged = extern struct {
    element: u64 = 0,
    value: bool = false,
};

const CTextChanged = extern struct {
    element: u64 = 0,
    text: CPayloadSpan = .{},
    committed: bool = false,
};

const CSortChanged = extern struct {
    element: u64 = 0,
    column: u8 = 0,
    direction: CSortDirection = .ascending,
};

const CSelectionChanged = extern struct {
    element: u64 = 0,
    selected: CPayloadSpan = .{},
};

const CScrollChanged = extern struct {
    element: u64 = 0,
    x: f32 = 0,
    y: f32 = 0,
};

const CPopupVisibilityChanged = extern struct {
    element: u64 = 0,
    visible: bool = false,
};

const CDropPositionKind = enum(c_int) {
    before = 0,
    inside = 1,
    after = 2,
    item = 3,
    background = 4,
    point = 5,
};

const CDropPosition = extern struct {
    kind: CDropPositionKind = .inside,
    x: f32 = 0,
    y: f32 = 0,
};

const CControlDrop = extern struct {
    source: u64 = 0,
    target: u64 = 0,
    position: CDropPosition = .{},
    modifiers: u32 = 0,
};

const CControlEvent = extern struct {
    kind: CControlEventKind = .activated,
    data: extern union {
        activated: CActivation,
        secondary_activated: CSecondaryActivation,
        value_changed: CValueChanged,
        toggle_changed: CToggleChanged,
        text_changed: CTextChanged,
        sort_changed: CSortChanged,
        selection_changed: CSelectionChanged,
        scroll_changed: CScrollChanged,
        popup_visibility_changed: CPopupVisibilityChanged,
        drop: CControlDrop,
    } = .{ .activated = .{} },
};

const CControlEvents = extern struct {
    items: [*c]const CControlEvent = null,
    len: usize = 0,
    text_bytes: [*c]const u8 = null,
    text_bytes_len: usize = 0,
    selection_ids: [*c]const u64 = null,
    selection_ids_len: usize = 0,
};

const CContext = shared.Context;

fn fromCStr(str: CStr) []const u8 {
    if (str.ptr == null or str.len == 0) return "";
    const ptr = str.ptr orelse return "";
    return @as([*]const u8, @ptrCast(ptr))[0..str.len];
}

fn toCStr(str: []const u8) CStr {
    if (str.len == 0) return .{};
    return .{ .ptr = @ptrCast(str.ptr), .len = str.len };
}

// Generic C ↔ Zig value conversion. Walks struct fields by name and
// dispatches per-pair through a small table of known type pairs.
// Replaces ~600 lines of mechanical hand-written converters.

fn cToZ(comptime DstT: type, src: anytype) DstT {
    const SrcT = @TypeOf(src);
    if (DstT == SrcT) return src;

    if (DstT == []const u8 and SrcT == CStr) return fromCStr(src);
    if (DstT == widget.NodeHandle and SrcT == CHandle)
        return .{ .index = src.index, .generation = src.generation };
    if (DstT == style.Color and SrcT == CColor)
        return .{ .r = src.r, .g = src.g, .b = src.b, .a = src.a };
    if (DstT == style.Edges and SrcT == CEdges)
        return .{ .top = src.top, .right = src.right, .bottom = src.bottom, .left = src.left };
    if (DstT == visual.Rect and SrcT == CRect)
        return .{ .x = src.x, .y = src.y, .w = src.w, .h = src.h };

    // C-side optional pattern (struct { has_value, value }) → ?T
    if (@typeInfo(DstT) == .optional and
        (SrcT == COptionalU8 or SrcT == COptionalU16 or
            SrcT == COptionalU32 or SrcT == COptionalColor))
    {
        const Child = @typeInfo(DstT).optional.child;
        return if (src.has_value) cToZ(Child, src.value) else null;
    }

    // Same-tag-name enums
    if (@typeInfo(DstT) == .@"enum" and @typeInfo(SrcT) == .@"enum") {
        return std.meta.stringToEnum(DstT, @tagName(src)) orelse @panic("unknown enum tag");
    }

    // Integer width adjustment (e.g. u32 codepoint → u21).
    if (@typeInfo(DstT) == .int and @typeInfo(SrcT) == .int) {
        return @intCast(src);
    }

    // Struct-to-struct: walk DstT fields by name
    if (@typeInfo(DstT) == .@"struct" and @typeInfo(SrcT) == .@"struct") {
        var result: DstT = undefined;
        inline for (std.meta.fields(DstT)) |f| {
            @field(result, f.name) = cToZ(f.type, @field(src, f.name));
        }
        return result;
    }

    @compileError("no cToZ from " ++ @typeName(SrcT) ++ " to " ++ @typeName(DstT));
}

fn zToC(comptime DstT: type, src: anytype) DstT {
    const SrcT = @TypeOf(src);
    if (DstT == SrcT) return src;

    if (DstT == CStr and SrcT == []const u8) return toCStr(src);
    if (DstT == CHandle and SrcT == widget.NodeHandle)
        return .{ .index = src.index, .generation = src.generation };
    if (DstT == CColor and SrcT == style.Color)
        return .{ .r = src.r, .g = src.g, .b = src.b, .a = src.a };
    if (DstT == CEdges and SrcT == style.Edges)
        return .{ .top = src.top, .right = src.right, .bottom = src.bottom, .left = src.left };
    if (DstT == CRect and SrcT == visual.Rect)
        return .{ .x = src.x, .y = src.y, .w = src.w, .h = src.h };

    // ?T → C-side optional pattern
    if ((DstT == COptionalU8 or DstT == COptionalU16 or
        DstT == COptionalU32 or DstT == COptionalColor) and
        @typeInfo(SrcT) == .optional)
    {
        const CChild = @FieldType(DstT, "value");
        return if (src) |v| .{
            .has_value = true,
            .value = zToC(CChild, v),
        } else .{};
    }

    // Same-tag-name enums
    if (@typeInfo(DstT) == .@"enum" and @typeInfo(SrcT) == .@"enum") {
        return std.meta.stringToEnum(DstT, @tagName(src)) orelse @panic("unknown enum tag");
    }

    // Integer width adjustment.
    if (@typeInfo(DstT) == .int and @typeInfo(SrcT) == .int) {
        return @intCast(src);
    }

    // Struct-to-struct: walk DstT fields by name
    if (@typeInfo(DstT) == .@"struct" and @typeInfo(SrcT) == .@"struct") {
        var result: DstT = undefined;
        inline for (std.meta.fields(DstT)) |f| {
            @field(result, f.name) = zToC(f.type, @field(src, f.name));
        }
        return result;
    }

    @compileError("no zToC from " ++ @typeName(SrcT) ++ " to " ++ @typeName(DstT));
}

fn handleFromC(handle: CHandle) widget.NodeHandle {
    return cToZ(widget.NodeHandle, handle);
}

fn handleToC(handle: widget.NodeHandle) CHandle {
    return zToC(CHandle, handle);
}

fn rectToC(rect: visual.Rect) CRect {
    return zToC(CRect, rect);
}

fn themeFromC(c_theme: CTheme) style.Theme {
    return cToZ(style.Theme, c_theme);
}

fn themeToC(theme: style.Theme) CTheme {
    return zToC(CTheme, theme);
}

/// CStyle uses a flat `has_X: bool, X: T` pair per Style field rather
/// than a nested optional struct, so it doesn't fit the generic walker.
fn styleFromC(c_style: CStyle) style.Style {
    var result: style.Style = .{};
    inline for (std.meta.fields(style.Style)) |f| {
        if (@field(c_style, "has_" ++ f.name)) {
            const Inner = @typeInfo(f.type).optional.child;
            @field(result, f.name) = cToZ(Inner, @field(c_style, f.name));
        }
    }
    return result;
}

/// Build a per-kind C view by walking the persistent/current fields on the
/// matching WidgetView arm. Occurrence output never enters this snapshot.
fn viewArmToC(comptime DstT: type, payload: anytype) DstT {
    if (DstT == CUnitWidget) return .{};
    if (DstT == CListBoxView) return .{};
    const PayloadT = @TypeOf(payload);
    var result: DstT = undefined;
    inline for (std.meta.fields(DstT)) |f| {
        if (PayloadT == void or !@hasField(PayloadT, f.name)) {
            @compileError("CView field '" ++ f.name ++ "' has no source on " ++ @typeName(PayloadT));
        }
        @field(result, f.name) = zToC(f.type, @field(payload, f.name));
    }
    return result;
}

fn widgetViewToC(view: api.WidgetView) CWidgetView {
    const Data = @FieldType(CWidgetView, "data");
    return switch (view) {
        inline else => |payload, tag| .{
            .kind = @field(CWidgetKind, @tagName(tag)),
            .data = @unionInit(
                Data,
                @tagName(tag),
                viewArmToC(@FieldType(Data, @tagName(tag)), payload),
            ),
        },
    };
}

fn nodeViewToC(node: api.NodeView) CNodeView {
    return .{
        .rect = rectToC(node.rect),
        .identity = .{
            .element_id = if (node.element_id) |id| id.value() else 0,
            .action_id = if (node.action_id) |id| .{
                .value = id.value(),
                .has_value = true,
            } else .{},
        },
        .focused = node.focused,
        .accepts_drop = node.accepts_drop,
        .drop_hovered = node.drop_hovered,
        .kind = widgetViewToC(node.kind),
    };
}

fn optionalElementToC(id: ?api.ElementId) COptionalElementId {
    return if (id) |value| .{ .value = value.value(), .has_value = true } else .{};
}

fn resolvedElementToC(element: api.ResolvedElement) CResolvedElement {
    return .{
        .id = optionalElementToC(element.id),
        .parent_id = optionalElementToC(element.parent_id),
        .action_id = optionalActionToC(element.action_id),
        .bounds = rectToC(element.bounds),
        .style = themeToC(element.style),
        .widget = widgetViewToC(element.widget),
        .focused = element.focused,
        .hovered = element.hovered,
        .pressed = element.pressed,
        .drop_hovered = element.drop_hovered,
    };
}

const ResolvedVisitorAdapter = struct {
    callbacks: *const CResolvedVisitor,

    pub fn enter(self: *ResolvedVisitorAdapter, element: api.ResolvedElement) void {
        const resolved = resolvedElementToC(element);
        self.callbacks.enter.?(self.callbacks.user_data, &resolved);
    }

    pub fn leave(self: *ResolvedVisitorAdapter, element: api.ResolvedElement) void {
        const resolved = resolvedElementToC(element);
        self.callbacks.leave.?(self.callbacks.user_data, &resolved);
    }
};

fn payloadSpanToC(span: anytype) CPayloadSpan {
    return .{ .start = span.start, .len = span.len };
}

fn optionalActionToC(action: ?api.ActionId) COptionalActionId {
    return if (action) |id| .{ .value = id.value(), .has_value = true } else .{};
}

fn controlValueToC(value: api.ValueChanged.Value) CControlValue {
    return switch (value) {
        .scalar => |scalar| .{ .kind = .scalar, .data = .{ .scalar = scalar } },
        .index => |index| .{ .kind = .index, .data = .{ .index = if (index) |value_index| .{
            .has_value = true,
            .value = value_index,
        } else .{} } },
        .column_fraction => |fraction| .{
            .kind = .column_fraction,
            .data = .{ .column_fraction = .{
                .column = fraction.column,
                .fraction = fraction.fraction,
            } },
        },
    };
}

fn dropPositionToC(position: api.ControlDrop.Position) CDropPosition {
    return switch (position) {
        .before => .{ .kind = .before },
        .inside => .{ .kind = .inside },
        .after => .{ .kind = .after },
        .item => .{ .kind = .item },
        .background => .{ .kind = .background },
        .point => |point| .{ .kind = .point, .x = point.x, .y = point.y },
    };
}

fn controlEventToC(output: api.ControlEvent) CControlEvent {
    return switch (output) {
        .activated => |activation| .{
            .kind = .activated,
            .data = .{ .activated = .{
                .element = activation.element.value(),
                .action = optionalActionToC(activation.action),
            } },
        },
        .secondary_activated => |activation| .{
            .kind = .secondary_activated,
            .data = .{ .secondary_activated = .{
                .element = activation.element.value(),
                .action = optionalActionToC(activation.action),
                .x = activation.x,
                .y = activation.y,
            } },
        },
        .value_changed => |changed| .{
            .kind = .value_changed,
            .data = .{ .value_changed = .{
                .element = changed.element.value(),
                .value = controlValueToC(changed.value),
            } },
        },
        .toggle_changed => |changed| .{
            .kind = .toggle_changed,
            .data = .{ .toggle_changed = .{
                .element = changed.element.value(),
                .value = changed.value,
            } },
        },
        .text_changed => |changed| .{
            .kind = .text_changed,
            .data = .{ .text_changed = .{
                .element = changed.element.value(),
                .text = payloadSpanToC(changed.text),
                .committed = changed.committed,
            } },
        },
        .sort_changed => |changed| .{
            .kind = .sort_changed,
            .data = .{ .sort_changed = .{
                .element = changed.element.value(),
                .column = changed.column,
                .direction = zToC(CSortDirection, changed.direction),
            } },
        },
        .selection_changed => |changed| .{
            .kind = .selection_changed,
            .data = .{ .selection_changed = .{
                .element = changed.element.value(),
                .selected = payloadSpanToC(changed.selected),
            } },
        },
        .scroll_changed => |changed| .{
            .kind = .scroll_changed,
            .data = .{ .scroll_changed = .{
                .element = changed.element.value(),
                .x = changed.x,
                .y = changed.y,
            } },
        },
        .popup_visibility_changed => |changed| .{
            .kind = .popup_visibility_changed,
            .data = .{ .popup_visibility_changed = .{
                .element = changed.element.value(),
                .visible = changed.visible,
            } },
        },
        .drop => |drop| .{
            .kind = .drop,
            .data = .{ .drop = .{
                .source = drop.source.value(),
                .target = drop.target.value(),
                .position = dropPositionToC(drop.position),
                .modifiers = (@as(u32, @intFromBool(drop.modifiers.shift)) << 0) |
                    (@as(u32, @intFromBool(drop.modifiers.ctrl)) << 1),
            } },
        },
    };
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

/// Build a WidgetDesc arm from the matching CWidget arm. Walks each
/// Zig field; if C side has the same name, copy it through `cToZ`,
/// otherwise fall back to the field's compile-time default. This
/// lets fields like `WidgetDesc.Text.overflow` (Zig-only with a
/// default) coexist with `text_input.value` (C-only, ignored here —
/// applied separately via `applyTextInputSeedValue`).
fn descArmFromC(comptime DstT: type, c_payload: anytype) DstT {
    const PT = @TypeOf(c_payload);
    var result: DstT = undefined;
    inline for (std.meta.fields(DstT)) |f| {
        if (@hasField(PT, f.name)) {
            @field(result, f.name) = cToZ(f.type, @field(c_payload, f.name));
        } else {
            const default_ptr = f.default_value_ptr orelse @compileError(
                "WidgetDesc field " ++ @typeName(DstT) ++ "." ++ f.name ++
                    " has no C counterpart and no Zig default",
            );
            const typed: *const f.type = @ptrCast(@alignCast(default_ptr));
            @field(result, f.name) = typed.*;
        }
    }
    return result;
}

fn buildWidgetDesc(desc: CWidget) widget.WidgetDesc {
    return switch (desc.kind) {
        inline else => |tag| @unionInit(
            widget.WidgetDesc,
            @tagName(tag),
            descArmFromC(@FieldType(widget.WidgetDesc, @tagName(tag)), @field(desc.data, @tagName(tag))),
        ),
    };
}

/// Replace a widget's kind payload with the matching C desc. Walks
/// the Zig kind's fields and assigns each one whose name appears on
/// the C payload through `cToZ`. text_input gets special-cased — its
/// `buffer` doesn't exist on C side, and the C `value` field seeds
/// the buffer separately.
fn updateWidgetKind(kind: *widget.WidgetKind, desc: CWidget) bool {
    return switch (kind.*) {
        inline else => |*payload, tag| blk: {
            const tag_name = @tagName(tag);
            if (desc.kind != @field(CWidgetKind, tag_name)) break :blk false;
            const c_payload = @field(desc.data, tag_name);
            const PayloadT = @TypeOf(payload.*);
            const CPayloadT = @TypeOf(c_payload);
            if (tag == .text_input) {
                payload.* = .{ .placeholder = fromCStr(c_payload.placeholder) };
                if (c_payload.value.len > 0) payload.insertSlice(fromCStr(c_payload.value));
            } else {
                inline for (std.meta.fields(PayloadT)) |f| {
                    if (@hasField(CPayloadT, f.name)) {
                        @field(payload, f.name) = cToZ(f.type, @field(c_payload, f.name));
                    }
                }
            }
            widget.syncDerivedState(kind);
            break :blk true;
        },
    };
}

fn convertEvent(ev: CEvent) input_types.Event {
    return switch (ev.kind) {
        inline else => |tag| @unionInit(
            input_types.Event,
            @tagName(tag),
            cToZ(@FieldType(input_types.Event, @tagName(tag)), @field(ev.data, @tagName(tag))),
        ),
    };
}

fn markDirty(ctx: *CContext) void {
    ctx.ctx.runtime.invalidate();
}

fn validHandle(ctx: *const CContext, handle: CHandle) bool {
    return ctx.ctx.tree.isAlive(handleFromC(handle));
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
    context.deinitAdapters(allocator);
    context.ctx.deinit();
    allocator.destroy(context);
}

export fn goop_context_set_theme(ctx: ?*CContext, theme: ?*const CTheme) bool {
    const context = ctx orelse return false;
    const next_theme = theme orelse return false;
    context.ctx.setTheme(themeFromC(next_theme.*));
    return true;
}

export fn goop_context_set_clipboard(ctx: ?*CContext, clipboard: ?*const CClipboard) bool {
    const context = ctx orelse return false;
    context.setClipboard(clipboard);
    return true;
}

export fn goop_context_push_event(ctx: ?*CContext, ev: ?*const CEvent) bool {
    const context = ctx orelse return false;
    const input = ev orelse return false;
    context.ctx.pushEvent(convertEvent(input.*)) catch return false;
    return true;
}

export fn goop_context_process_events(ctx: ?*CContext, out_events: ?*CControlEvents) bool {
    const context = ctx orelse return false;
    const out = out_events orelse return false;
    out.* = .{};

    const batch = context.ctx.processEvents() catch return false;
    const words_per_event = std.math.divCeil(usize, @sizeOf(CControlEvent), @sizeOf(u64)) catch unreachable;
    context.control_event_words.resize(allocator, batch.items.len * words_per_event) catch return false;
    context.selection_ids.resize(allocator, batch.selection_ids.len) catch return false;

    const converted: [*]CControlEvent = if (context.control_event_words.items.len == 0)
        undefined
    else
        @ptrCast(@alignCast(context.control_event_words.items.ptr));
    for (batch.items, 0..) |output, index| converted[index] = controlEventToC(output);
    for (batch.selection_ids, 0..) |id, index| context.selection_ids.items[index] = id.value();

    out.* = .{
        .items = if (batch.items.len == 0) null else converted,
        .len = batch.items.len,
        .text_bytes = if (batch.text_bytes.len == 0) null else batch.text_bytes.ptr,
        .text_bytes_len = batch.text_bytes.len,
        .selection_ids = if (context.selection_ids.items.len == 0) null else context.selection_ids.items.ptr,
        .selection_ids_len = context.selection_ids.items.len,
    };
    return true;
}

export fn goop_context_update(ctx: ?*CContext, now_ms: u64, out_result: ?*CUpdateResult) bool {
    const context = ctx orelse return false;
    const out = out_result orelse return false;
    const result = context.ctx.update(now_ms);
    out.* = .{
        .changed = result.changed,
        .has_next_deadline = result.next_deadline_ms != null,
        .next_deadline_ms = result.next_deadline_ms orelse 0,
    };
    return true;
}

export fn goop_context_do_layout(ctx: ?*CContext, measure: ?*const CTextMeasureCtx) bool {
    const context = ctx orelse return false;
    context.ctx.doLayout(context.textMeasure(measure));
    return true;
}

export fn goop_context_set_dimensions(ctx: ?*CContext, width: u32, height: u32) bool {
    const context = ctx orelse return false;
    context.ctx.setDimensions(width, height);
    return true;
}

export fn goop_context_add_root(ctx: ?*CContext, desc: ?*const CControlDesc, out_handle: ?*CHandle) bool {
    const context = ctx orelse return false;
    const control_desc = desc orelse return false;
    const handle_ptr = out_handle orelse return false;
    const element_id = api.ElementId.init(control_desc.identity.element_id);
    if (context.ctx.tree.findByElementId(element_id) != null) return false;
    const handle = context.ctx.tree.addRootControl(.{
        .identity = .{
            .element_id = element_id,
            .action_id = if (control_desc.identity.action_id.has_value)
                api.ActionId.init(control_desc.identity.action_id.value)
            else
                null,
        },
        .widget = buildWidgetDesc(control_desc.widget),
    }) catch return false;
    applyTextInputSeedValue(&context.ctx.tree.get(handle).kind, control_desc.widget);
    markDirty(context);
    handle_ptr.* = handleToC(handle);
    return true;
}

export fn goop_context_add_child(ctx: ?*CContext, parent: CHandle, desc: ?*const CControlDesc, out_handle: ?*CHandle) bool {
    const context = ctx orelse return false;
    const control_desc = desc orelse return false;
    const handle_ptr = out_handle orelse return false;
    if (!validHandle(context, parent)) return false;
    const element_id = api.ElementId.init(control_desc.identity.element_id);
    if (context.ctx.tree.findByElementId(element_id) != null) return false;
    const handle = context.ctx.tree.addChildControl(handleFromC(parent), .{
        .identity = .{
            .element_id = element_id,
            .action_id = if (control_desc.identity.action_id.has_value)
                api.ActionId.init(control_desc.identity.action_id.value)
            else
                null,
        },
        .widget = buildWidgetDesc(control_desc.widget),
    }) catch return false;
    applyTextInputSeedValue(&context.ctx.tree.get(handle).kind, control_desc.widget);
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
    // tree.remove bumps the tree revision; the runtime detects the
    // topology change on the next doLayout call.
    return true;
}

export fn goop_context_is_alive(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    return context.ctx.tree.isAlive(handleFromC(handle));
}

export fn goop_context_find_element(ctx: ?*const CContext, element: u64, out_handle: ?*CHandle) bool {
    const context = ctx orelse return false;
    const out = out_handle orelse return false;
    const handle = context.ctx.tree.findByElementId(api.ElementId.init(element)) orelse return false;
    out.* = handleToC(handle);
    return true;
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

export fn goop_context_table_column_fraction(ctx: ?*const CContext, handle: CHandle, index: u8, out_fraction: ?*f32) bool {
    const context = ctx orelse return false;
    const fraction_ptr = out_fraction orelse return false;
    const fraction = context.ctx.tree.tableColumnFraction(handleFromC(handle), index) orelse return false;
    fraction_ptr.* = fraction;
    return true;
}

// Mark layout and resolved visual state stale after caller-owned changes.
export fn goop_context_invalidate(ctx: ?*CContext) bool {
    const context = ctx orelse return false;
    context.ctx.invalidate();
    return true;
}

export fn goop_context_visit_resolved(ctx: ?*const CContext, visitor: ?*const CResolvedVisitor) bool {
    const context = ctx orelse return false;
    const callbacks = visitor orelse return false;
    if (callbacks.enter == null or callbacks.leave == null) return false;
    var adapter = ResolvedVisitorAdapter{ .callbacks = callbacks };
    context.ctx.visitResolved(&adapter) catch return false;
    return true;
}

export fn goop_context_set_accepts_drop(ctx: ?*CContext, element: u64, accepts_drop: bool) bool {
    const context = ctx orelse return false;
    const handle = context.ctx.tree.findByElementId(api.ElementId.init(element)) orelse return false;
    context.ctx.tree.setDropTarget(handle, accepts_drop);
    return true;
}

export fn goop_context_focus_element(ctx: ?*CContext, element: u64) bool {
    const context = ctx orelse return false;
    const handle = context.ctx.tree.findByElementId(api.ElementId.init(element)) orelse return false;
    return context.ctx.focusWidget(handle);
}

export fn goop_context_clear_focus(ctx: ?*CContext) bool {
    const context = ctx orelse return false;
    context.ctx.clearFocus();
    return true;
}

export fn goop_context_cancel_pointer_gesture(ctx: ?*CContext) bool {
    const context = ctx orelse return false;
    context.ctx.cancelPointerGesture();
    return true;
}

fn containsType(comptime T: type, comptime Needle: type) bool {
    if (T == Needle) return true;
    return switch (@typeInfo(T)) {
        .pointer => |pointer| containsType(pointer.child, Needle),
        .optional => |optional| containsType(optional.child, Needle),
        .array => |array| containsType(array.child, Needle),
        .vector => |vector| containsType(vector.child, Needle),
        .@"struct" => |structure| contains: {
            inline for (structure.fields) |field| {
                if (containsType(field.type, Needle)) break :contains true;
            }
            break :contains false;
        },
        .@"union" => |union_info| contains: {
            inline for (union_info.fields) |field| {
                if (containsType(field.type, Needle)) break :contains true;
            }
            break :contains false;
        },
        else => false,
    };
}

test "c api smoke" {
    const opts = CContextOptions{ .width = 320, .height = 200 };
    const ctx = goop_context_create(&opts) orelse return error.OutOfMemory;
    defer goop_context_destroy(ctx);

    var root: CHandle = .{};
    try std.testing.expect(goop_context_add_root(ctx, &CControlDesc{
        .identity = .{ .element_id = 1 },
        .widget = .{
            .kind = .container,
            .data = .{ .container = .{ .direction = .column } },
        },
    }, &root));

    var button: CHandle = .{};
    try std.testing.expect(goop_context_add_child(ctx, root, &CControlDesc{
        .identity = .{
            .element_id = 2,
            .action_id = .{ .value = 20, .has_value = true },
        },
        .widget = .{
            .kind = .button,
            .data = .{ .button = .{ .label = toCStr("OK") } },
        },
    }, &button));

    var duplicate: CHandle = .{};
    try std.testing.expect(!goop_context_add_child(ctx, root, &CControlDesc{
        .identity = .{ .element_id = 2 },
        .widget = .{ .kind = .button, .data = .{ .button = .{ .label = toCStr("duplicate") } } },
    }, &duplicate));

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
    var outputs: CControlEvents = .{};
    try std.testing.expect(goop_context_process_events(ctx, &outputs));
    try std.testing.expectEqual(@as(usize, 1), outputs.len);
    try std.testing.expectEqual(CControlEventKind.activated, outputs.items[0].kind);
    try std.testing.expectEqual(@as(u64, 2), outputs.items[0].data.activated.element);
    try std.testing.expect(outputs.items[0].data.activated.action.has_value);
    try std.testing.expectEqual(@as(u64, 20), outputs.items[0].data.activated.action.value);

    var found: CHandle = .{};
    try std.testing.expect(goop_context_find_element(ctx, 2, &found));
    try std.testing.expectEqual(button.index, found.index);
    try std.testing.expectEqual(button.generation, found.generation);
}

test "c icon data is passive and reaches the resolved visitor without handles" {
    const ctx = goop_context_create(&CContextOptions{ .width = 320, .height = 200 }) orelse return error.OutOfMemory;
    defer goop_context_destroy(ctx);

    const expected_color = CColor{ .r = 12, .g = 34, .b = 56, .a = 78 };
    var icon: CHandle = .{};
    try std.testing.expect(goop_context_add_root(ctx, &CControlDesc{
        .identity = .{
            .element_id = 7,
            .action_id = .{ .value = 70, .has_value = true },
        },
        .widget = .{ .kind = .icon, .data = .{ .icon = .{
            .kind = 0x10203040,
            .color = .{ .has_value = true, .value = expected_color },
        } } },
    }, &icon));
    try std.testing.expect(goop_context_do_layout(ctx, null));

    var node: CNodeView = .{};
    try std.testing.expect(goop_context_node(ctx, icon, &node));
    try std.testing.expectEqual(CWidgetKind.icon, node.kind.kind);
    try std.testing.expectEqual(@as(u32, 0x10203040), node.kind.data.icon.kind);
    try std.testing.expect(node.kind.data.icon.color.has_value);
    try std.testing.expect(std.meta.eql(expected_color, node.kind.data.icon.color.value));

    const x = node.rect.x + node.rect.w * 0.5;
    const y = node.rect.y + node.rect.h * 0.5;
    const press = CEvent{ .kind = .mouse_button, .data = .{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = x,
        .y = y,
    } } };
    const release = CEvent{ .kind = .mouse_button, .data = .{ .mouse_button = .{
        .button = .left,
        .state = .released,
        .x = x,
        .y = y,
    } } };
    try std.testing.expect(goop_context_push_event(ctx, &press));
    try std.testing.expect(goop_context_push_event(ctx, &release));
    var events: CControlEvents = .{};
    try std.testing.expect(goop_context_process_events(ctx, &events));
    try std.testing.expectEqual(@as(usize, 0), events.len);

    const Capture = struct {
        saw_icon: bool = false,
        leaves: usize = 0,
    };
    const Callbacks = struct {
        fn enter(user_data: ?*anyopaque, element: *const CResolvedElement) callconv(.c) void {
            const capture: *Capture = @ptrCast(@alignCast(user_data.?));
            if (element.id.has_value and element.id.value == 7 and element.widget.kind == .icon) {
                const resolved_icon = element.widget.data.icon;
                capture.saw_icon = resolved_icon.kind == 0x10203040 and
                    resolved_icon.color.has_value and
                    std.meta.eql(expected_color, resolved_icon.color.value);
            }
        }

        fn leave(user_data: ?*anyopaque, _: *const CResolvedElement) callconv(.c) void {
            const capture: *Capture = @ptrCast(@alignCast(user_data.?));
            capture.leaves += 1;
        }
    };
    var capture = Capture{};
    try std.testing.expect(goop_context_visit_resolved(ctx, &CResolvedVisitor{
        .enter = &Callbacks.enter,
        .leave = &Callbacks.leave,
        .user_data = &capture,
    }));
    try std.testing.expect(capture.saw_icon);
    try std.testing.expectEqual(@as(usize, 1), capture.leaves);
    try std.testing.expect(!containsType(CResolvedElement, CHandle));
}

test "c tree and grid item views preserve passive icon hints" {
    const ctx = goop_context_create(&CContextOptions{ .width = 320, .height = 200 }) orelse return error.OutOfMemory;
    defer goop_context_destroy(ctx);

    const tree_color = CColor{ .r = 1, .g = 2, .b = 3, .a = 4 };
    var tree_item: CHandle = .{};
    try std.testing.expect(goop_context_add_root(ctx, &CControlDesc{
        .identity = .{ .element_id = 11 },
        .widget = .{ .kind = .tree_item, .data = .{ .tree_item = .{
            .label = toCStr("Tree"),
            .group = 9,
            .icon = .{ .has_value = true, .value = 101 },
            .icon_color = .{ .has_value = true, .value = tree_color },
        } } },
    }, &tree_item));

    const grid_color = CColor{ .r = 5, .g = 6, .b = 7, .a = 8 };
    var grid_item: CHandle = .{};
    try std.testing.expect(goop_context_add_root(ctx, &CControlDesc{
        .identity = .{ .element_id = 12 },
        .widget = .{ .kind = .grid_item, .data = .{ .grid_item = .{
            .label = toCStr("Grid"),
            .icon = .{ .has_value = true, .value = 202 },
            .icon_color = .{ .has_value = true, .value = grid_color },
        } } },
    }, &grid_item));

    var tree_view: CNodeView = .{};
    try std.testing.expect(goop_context_node(ctx, tree_item, &tree_view));
    try std.testing.expectEqual(CWidgetKind.tree_item, tree_view.kind.kind);
    try std.testing.expect(tree_view.kind.data.tree_item.icon.has_value);
    try std.testing.expectEqual(@as(u32, 101), tree_view.kind.data.tree_item.icon.value);
    try std.testing.expect(tree_view.kind.data.tree_item.icon_color.has_value);
    try std.testing.expect(std.meta.eql(tree_color, tree_view.kind.data.tree_item.icon_color.value));

    var grid_view: CNodeView = .{};
    try std.testing.expect(goop_context_node(ctx, grid_item, &grid_view));
    try std.testing.expectEqual(CWidgetKind.grid_item, grid_view.kind.kind);
    try std.testing.expect(grid_view.kind.data.grid_item.icon.has_value);
    try std.testing.expectEqual(@as(u32, 202), grid_view.kind.data.grid_item.icon.value);
    try std.testing.expect(grid_view.kind.data.grid_item.icon_color.has_value);
    try std.testing.expect(std.meta.eql(grid_color, grid_view.kind.data.grid_item.icon_color.value));
}

test "c api preserves text event order and borrowed spans" {
    const ctx = goop_context_create(&CContextOptions{ .width = 320, .height = 200 }) orelse return error.OutOfMemory;
    defer goop_context_destroy(ctx);

    var input: CHandle = .{};
    try std.testing.expect(goop_context_add_root(ctx, &CControlDesc{
        .identity = .{ .element_id = 42 },
        .widget = .{
            .kind = .text_input,
            .data = .{ .text_input = .{ .placeholder = toCStr("Name") } },
        },
    }, &input));
    try std.testing.expect(goop_context_do_layout(ctx, null));
    try std.testing.expect(goop_context_focus_element(ctx, 42));

    const first = CEvent{ .kind = .text, .data = .{ .text = .{ .codepoint = 'h' } } };
    const second = CEvent{ .kind = .text, .data = .{ .text = .{ .codepoint = 'i' } } };
    try std.testing.expect(goop_context_push_event(ctx, &first));
    try std.testing.expect(goop_context_push_event(ctx, &second));

    var outputs: CControlEvents = .{};
    try std.testing.expect(goop_context_process_events(ctx, &outputs));
    try std.testing.expectEqual(@as(usize, 2), outputs.len);
    try std.testing.expectEqual(CControlEventKind.text_changed, outputs.items[0].kind);
    try std.testing.expectEqual(CControlEventKind.text_changed, outputs.items[1].kind);

    const first_span = outputs.items[0].data.text_changed.text;
    const second_span = outputs.items[1].data.text_changed.text;
    try std.testing.expectEqualStrings("h", outputs.text_bytes[first_span.start..][0..first_span.len]);
    try std.testing.expectEqualStrings("hi", outputs.text_bytes[second_span.start..][0..second_span.len]);

    var empty: CControlEvents = .{};
    try std.testing.expect(goop_context_process_events(ctx, &empty));
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expect(empty.items == null);
}

test "c api resolves borrowed selection IDs" {
    const ctx = goop_context_create(&CContextOptions{ .width = 320, .height = 200 }) orelse return error.OutOfMemory;
    defer goop_context_destroy(ctx);

    var list: CHandle = .{};
    try std.testing.expect(goop_context_add_root(ctx, &CControlDesc{
        .identity = .{ .element_id = 60 },
        .widget = .{ .kind = .list_box, .data = .{ .list_box = .{} } },
    }, &list));
    var first: CHandle = .{};
    try std.testing.expect(goop_context_add_child(ctx, list, &CControlDesc{
        .identity = .{ .element_id = 61 },
        .widget = .{ .kind = .selectable, .data = .{ .selectable = .{
            .label = toCStr("First"),
            .selected = true,
        } } },
    }, &first));
    var second: CHandle = .{};
    try std.testing.expect(goop_context_add_child(ctx, list, &CControlDesc{
        .identity = .{ .element_id = 62 },
        .widget = .{ .kind = .selectable, .data = .{ .selectable = .{
            .label = toCStr("Second"),
        } } },
    }, &second));
    try std.testing.expect(goop_context_do_layout(ctx, null));
    try std.testing.expect(goop_context_focus_element(ctx, 61));

    const down = CEvent{ .kind = .key, .data = .{ .key = .{
        .keycode = .down,
        .state = .pressed,
    } } };
    try std.testing.expect(goop_context_push_event(ctx, &down));
    var outputs: CControlEvents = .{};
    try std.testing.expect(goop_context_process_events(ctx, &outputs));
    try std.testing.expectEqual(@as(usize, 1), outputs.len);
    try std.testing.expectEqual(CControlEventKind.selection_changed, outputs.items[0].kind);
    const span = outputs.items[0].data.selection_changed.selected;
    try std.testing.expectEqual(@as(usize, 1), span.len);
    try std.testing.expectEqual(@as(u64, 62), outputs.selection_ids[span.start]);
}

test "c resolved visitor is balanced, ordered, and handle-free" {
    const Phase = enum { enter, leave };
    const Visit = struct { phase: Phase, id: u64 };
    const Capture = struct {
        visits: [8]Visit = undefined,
        visit_count: usize = 0,
        stack: [4]CResolvedElement = undefined,
        depth: usize = 0,
        max_depth: usize = 0,
        balanced: bool = true,
        saw_borrowed_text: bool = false,
        saw_focused_style: bool = false,
        saw_layout: bool = false,
    };
    const Callbacks = struct {
        fn enter(user_data: ?*anyopaque, element: *const CResolvedElement) callconv(.c) void {
            const capture: *Capture = @ptrCast(@alignCast(user_data.?));
            const id = if (element.id.has_value) element.id.value else 0;
            capture.visits[capture.visit_count] = .{ .phase = .enter, .id = id };
            capture.visit_count += 1;
            capture.stack[capture.depth] = element.*;
            capture.depth += 1;
            capture.max_depth = @max(capture.max_depth, capture.depth);

            if (id == 1) capture.saw_layout = element.bounds.w > 0 and element.bounds.h > 0;
            if (id == 3 and element.widget.kind == .text) {
                capture.saw_borrowed_text = std.mem.eql(
                    u8,
                    fromCStr(element.widget.data.text.content),
                    "Nested",
                );
            }
            if (id == 4) {
                capture.saw_focused_style = element.focused and
                    element.hovered and element.pressed and
                    element.style.bg.r == 9 and element.style.bg.g == 8 and element.style.bg.b == 7;
            }
        }

        fn leave(user_data: ?*anyopaque, element: *const CResolvedElement) callconv(.c) void {
            const capture: *Capture = @ptrCast(@alignCast(user_data.?));
            if (capture.depth == 0) {
                capture.balanced = false;
                return;
            }
            capture.depth -= 1;
            const entered = capture.stack[capture.depth];
            capture.balanced = capture.balanced and
                entered.id.has_value == element.id.has_value and
                entered.id.value == element.id.value and
                entered.parent_id.has_value == element.parent_id.has_value and
                entered.parent_id.value == element.parent_id.value and
                std.meta.eql(entered.bounds, element.bounds) and
                entered.widget.kind == element.widget.kind;
            capture.visits[capture.visit_count] = .{
                .phase = .leave,
                .id = if (element.id.has_value) element.id.value else 0,
            };
            capture.visit_count += 1;
        }
    };

    const ctx = goop_context_create(&CContextOptions{ .width = 320, .height = 200 }) orelse return error.OutOfMemory;
    defer goop_context_destroy(ctx);
    var root: CHandle = .{};
    try std.testing.expect(goop_context_add_root(ctx, &CControlDesc{
        .identity = .{ .element_id = 1 },
        .widget = .{ .kind = .container, .data = .{ .container = .{ .direction = .column } } },
    }, &root));
    var nested: CHandle = .{};
    try std.testing.expect(goop_context_add_child(ctx, root, &CControlDesc{
        .identity = .{ .element_id = 2 },
        .widget = .{ .kind = .container, .data = .{ .container = .{ .direction = .column } } },
    }, &nested));
    var text_node: CHandle = .{};
    try std.testing.expect(goop_context_add_child(ctx, nested, &CControlDesc{
        .identity = .{ .element_id = 3 },
        .widget = .{ .kind = .text, .data = .{ .text = .{ .content = toCStr("Nested") } } },
    }, &text_node));
    var button: CHandle = .{};
    try std.testing.expect(goop_context_add_child(ctx, root, &CControlDesc{
        .identity = .{ .element_id = 4, .action_id = .{ .value = 40, .has_value = true } },
        .widget = .{ .kind = .button, .data = .{ .button = .{ .label = toCStr("Focus") } } },
    }, &button));
    try std.testing.expect(goop_context_set_style(ctx, button, &CStyle{
        .has_bg = true,
        .bg = .{ .r = 9, .g = 8, .b = 7, .a = 255 },
    }));
    try std.testing.expect(goop_context_focus_element(ctx, 4));
    try std.testing.expect(goop_context_do_layout(ctx, null));
    var button_view: CNodeView = .{};
    try std.testing.expect(goop_context_node(ctx, button, &button_view));
    const pointer_x = button_view.rect.x + button_view.rect.w * 0.5;
    const pointer_y = button_view.rect.y + button_view.rect.h * 0.5;
    const move = CEvent{ .kind = .mouse_move, .data = .{ .mouse_move = .{ .x = pointer_x, .y = pointer_y } } };
    const press = CEvent{ .kind = .mouse_button, .data = .{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = pointer_x,
        .y = pointer_y,
    } } };
    try std.testing.expect(goop_context_push_event(ctx, &move));
    try std.testing.expect(goop_context_push_event(ctx, &press));
    var ignored_outputs: CControlEvents = .{};
    try std.testing.expect(goop_context_process_events(ctx, &ignored_outputs));

    var capture = Capture{};
    const visitor = CResolvedVisitor{
        .enter = &Callbacks.enter,
        .leave = &Callbacks.leave,
        .user_data = &capture,
    };
    try std.testing.expect(goop_context_visit_resolved(ctx, &visitor));
    try std.testing.expect(capture.balanced);
    try std.testing.expectEqual(@as(usize, 0), capture.depth);
    try std.testing.expectEqual(@as(usize, 3), capture.max_depth);
    try std.testing.expect(capture.saw_layout);
    try std.testing.expect(capture.saw_borrowed_text);
    try std.testing.expect(capture.saw_focused_style);
    try std.testing.expectEqualSlices(Visit, &.{
        .{ .phase = .enter, .id = 1 },
        .{ .phase = .enter, .id = 2 },
        .{ .phase = .enter, .id = 3 },
        .{ .phase = .leave, .id = 3 },
        .{ .phase = .leave, .id = 2 },
        .{ .phase = .enter, .id = 4 },
        .{ .phase = .leave, .id = 4 },
        .{ .phase = .leave, .id = 1 },
    }, capture.visits[0..capture.visit_count]);

    try std.testing.expect(!goop_context_visit_resolved(ctx, &CResolvedVisitor{
        .enter = &Callbacks.enter,
        .user_data = &capture,
    }));
}

test "c api menu item exposes checked state and defaults to enabled" {
    const opts = CContextOptions{ .width = 320, .height = 200 };
    const ctx = goop_context_create(&opts) orelse return error.OutOfMemory;
    defer goop_context_destroy(ctx);

    var popup: CHandle = .{};
    try std.testing.expect(goop_context_add_root(ctx, &CControlDesc{
        .identity = .{ .element_id = 1 },
        .widget = .{ .kind = .popup, .data = .{ .popup = .{} } },
    }, &popup));

    var item: CHandle = .{};
    try std.testing.expect(goop_context_add_child(ctx, popup, &CControlDesc{
        .identity = .{ .element_id = 2 },
        .widget = .{
            .kind = .menu_item,
            .data = .{ .menu_item = .{
                .label = toCStr("Sidebar"),
                .shortcut = toCStr("Ctrl+B"),
                .checked = true,
            } },
        },
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
    @setEvalBranchQuota(2000);
    const c = @cImport({
        @cInclude("goop.h");
    });

    const Pair = struct { Z: type, C: type };
    const pairs = [_]Pair{
        .{ .Z = CStr, .C = c.goop_string_t },
        .{ .Z = CHandle, .C = c.goop_node_handle_t },
        .{ .Z = COptionalActionId, .C = c.goop_optional_action_id_t },
        .{ .Z = COptionalElementId, .C = c.goop_optional_element_id_t },
        .{ .Z = CControlIdentity, .C = c.goop_control_identity_t },
        .{ .Z = CRect, .C = c.goop_rect_t },
        .{ .Z = CColor, .C = c.goop_color_t },
        .{ .Z = CEdges, .C = c.goop_edges_t },
        .{ .Z = CTheme, .C = c.goop_theme_t },
        .{ .Z = CStyle, .C = c.goop_style_t },
        .{ .Z = COptionalU32, .C = c.goop_optional_u32_t },
        .{ .Z = COptionalU16, .C = c.goop_optional_u16_t },
        .{ .Z = COptionalU8, .C = c.goop_optional_u8_t },
        .{ .Z = COptionalColor, .C = c.goop_optional_color_t },

        .{ .Z = CContainerWidget, .C = c.goop_container_widget_t },
        .{ .Z = CTextWidget, .C = c.goop_text_widget_t },
        .{ .Z = CIconWidget, .C = c.goop_icon_widget_t },
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
        .{ .Z = CCustomWidget, .C = c.goop_custom_widget_t },
        .{ .Z = CUnitWidget, .C = c.goop_unit_widget_t },
        .{ .Z = CWidget, .C = c.goop_widget_t },
        .{ .Z = CControlDesc, .C = c.goop_control_desc_t },

        .{ .Z = CContainerView, .C = c.goop_container_view_t },
        .{ .Z = CTextView, .C = c.goop_text_view_t },
        .{ .Z = CIconView, .C = c.goop_icon_view_t },
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
        .{ .Z = CUpdateResult, .C = c.goop_update_result_t },
        .{ .Z = CMenuItemView, .C = c.goop_menu_item_view_t },
        .{ .Z = CDragValueView, .C = c.goop_drag_value_view_t },
        .{ .Z = CSpinboxView, .C = c.goop_spinbox_view_t },
        .{ .Z = CTabItemView, .C = c.goop_tab_item_view_t },
        .{ .Z = CSplitterView, .C = c.goop_splitter_view_t },
        .{ .Z = CSliderView, .C = c.goop_slider_view_t },
        .{ .Z = CScrollAreaView, .C = c.goop_scroll_area_view_t },
        .{ .Z = CTextInputView, .C = c.goop_text_input_view_t },
        .{ .Z = CCustomView, .C = c.goop_custom_view_t },
        .{ .Z = CWidgetView, .C = c.goop_widget_view_t },
        .{ .Z = CResolvedElement, .C = c.goop_resolved_element_t },
        .{ .Z = CResolvedVisitor, .C = c.goop_resolved_visitor_t },

        .{ .Z = CMouseMoveEvent, .C = c.goop_mouse_move_event_t },
        .{ .Z = CMouseButtonEvent, .C = c.goop_mouse_button_event_t },
        .{ .Z = CMouseScrollEvent, .C = c.goop_mouse_scroll_event_t },
        .{ .Z = CKeyEvent, .C = c.goop_key_event_t },
        .{ .Z = CTextEvent, .C = c.goop_text_event_t },
        .{ .Z = CFocusEvent, .C = c.goop_focus_event_t },
        .{ .Z = CResizeEvent, .C = c.goop_resize_event_t },
        .{ .Z = CEvent, .C = c.goop_event_t },

        .{ .Z = CTextDimensions, .C = c.goop_text_dimensions_t },
        .{ .Z = CTextMeasureCtx, .C = c.goop_text_measure_ctx_t },
        .{ .Z = CClipboard, .C = c.goop_clipboard_t },
        .{ .Z = CContextOptions, .C = c.goop_context_options_t },
        .{ .Z = CPayloadSpan, .C = c.goop_payload_span_t },
        .{ .Z = CActivation, .C = c.goop_activation_t },
        .{ .Z = CSecondaryActivation, .C = c.goop_secondary_activation_t },
        .{ .Z = CColumnFraction, .C = c.goop_column_fraction_t },
        .{ .Z = CControlValue, .C = c.goop_control_value_t },
        .{ .Z = CValueChanged, .C = c.goop_value_changed_t },
        .{ .Z = CToggleChanged, .C = c.goop_toggle_changed_t },
        .{ .Z = CTextChanged, .C = c.goop_text_changed_t },
        .{ .Z = CSortChanged, .C = c.goop_sort_changed_t },
        .{ .Z = CSelectionChanged, .C = c.goop_selection_changed_t },
        .{ .Z = CScrollChanged, .C = c.goop_scroll_changed_t },
        .{ .Z = CPopupVisibilityChanged, .C = c.goop_popup_visibility_changed_t },
        .{ .Z = CDropPosition, .C = c.goop_drop_position_t },
        .{ .Z = CControlDrop, .C = c.goop_control_drop_t },
        .{ .Z = CControlEvent, .C = c.goop_control_event_t },
        .{ .Z = CControlEvents, .C = c.goop_control_events_t },
        .{ .Z = CNodeView, .C = c.goop_node_view_t },
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
        try std.testing.expectEqual(@alignOf(pair.Z), @alignOf(pair.C));
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

test "core C header contains no transient polling or Chrome ownership" {
    const c = @cImport({
        @cInclude("goop.h");
    });
    const banned_declarations = [_][]const u8{
        "goop_context_clear_clicked_flags",
        "goop_context_frame",
        "goop_context_set_user_id",
        "goop_context_user_id",
        "goop_context_set_custom_paint",
        "goop_context_generate_paint_list",
        "goop_frame_snapshot_t",
        "goop_paint_list_t",
        "goop_chrome_t",
    };
    inline for (banned_declarations) |name| try std.testing.expect(!@hasDecl(c, name));
    inline for (.{ "clicked", "changed", "toggled", "drop_received", "user_id", "custom_paint" }) |field| {
        try std.testing.expect(!@hasField(c.goop_node_view_t, field));
    }
    inline for (.{ "handle", "node_handle", "tree" }) |field| {
        try std.testing.expect(!@hasField(c.goop_resolved_element_t, field));
    }
    try std.testing.expect(!containsType(c.goop_resolved_element_t, c.goop_node_handle_t));
}

test "c header control event kinds match" {
    const c = @cImport({
        @cInclude("goop.h");
    });
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CControlEventKind.activated)), c.GOOP_CONTROL_EVENT_ACTIVATED);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CControlEventKind.secondary_activated)), c.GOOP_CONTROL_EVENT_SECONDARY_ACTIVATED);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CControlEventKind.value_changed)), c.GOOP_CONTROL_EVENT_VALUE_CHANGED);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CControlEventKind.toggle_changed)), c.GOOP_CONTROL_EVENT_TOGGLE_CHANGED);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CControlEventKind.text_changed)), c.GOOP_CONTROL_EVENT_TEXT_CHANGED);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CControlEventKind.sort_changed)), c.GOOP_CONTROL_EVENT_SORT_CHANGED);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CControlEventKind.selection_changed)), c.GOOP_CONTROL_EVENT_SELECTION_CHANGED);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CControlEventKind.scroll_changed)), c.GOOP_CONTROL_EVENT_SCROLL_CHANGED);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CControlEventKind.drop)), c.GOOP_CONTROL_EVENT_DROP);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CControlEventKind.popup_visibility_changed)), c.GOOP_CONTROL_EVENT_POPUP_VISIBILITY_CHANGED);
}

test "c header widget kinds match" {
    const c = @cImport({
        @cInclude("goop.h");
    });
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CWidgetKind.container)), c.GOOP_WIDGET_CONTAINER);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CWidgetKind.text)), c.GOOP_WIDGET_TEXT);
    try std.testing.expectEqual(@as(c_int, 2), c.GOOP_WIDGET_ICON);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CWidgetKind.icon)), c.GOOP_WIDGET_ICON);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CWidgetKind.button)), c.GOOP_WIDGET_BUTTON);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CWidgetKind.scroll_area)), c.GOOP_WIDGET_SCROLL_AREA);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CWidgetKind.text_input)), c.GOOP_WIDGET_TEXT_INPUT);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CWidgetKind.spacer)), c.GOOP_WIDGET_SPACER);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CWidgetKind.custom)), c.GOOP_WIDGET_CUSTOM);
    try std.testing.expectEqual(@as(c_int, 31), c.GOOP_WIDGET_CUSTOM);
}
