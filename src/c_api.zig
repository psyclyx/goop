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
    has_border: bool = false,
    border: CColor = .{},
    has_font_size: bool = false,
    font_size: f32 = 0,
    has_padding: bool = false,
    padding: CEdges = .{},
    has_border_radius: bool = false,
    border_radius: f32 = 0,
    has_border_width: bool = false,
    border_width: f32 = 0,
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
};

const CTextInputWidget = extern struct {
    placeholder: CStr = .{},
    value: CStr = .{},
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
    } = .{ .container = .{} },
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
    tab = 0,
    enter = 1,
    space = 2,
    escape = 3,
    backspace = 4,
    delete = 5,
    left = 6,
    right = 7,
    up = 8,
    down = 9,
    home = 10,
    end = 11,
    left_shift = 12,
    right_shift = 13,
    left_ctrl = 14,
    right_ctrl = 15,
    a = 16,
    c = 17,
    v = 18,
    x = 19,
    unknown = 20,
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
};

const CMouseScrollEvent = extern struct {
    dx: f32 = 0,
    dy: f32 = 0,
};

const CKeyEvent = extern struct {
    scancode: u32 = 0,
    keycode: CKeycode = .unknown,
    state: CKeyState = .pressed,
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
};

const CIconKind = enum(c_int) {
    folder = 0,
    file = 1,
    symlink = 2,
    home = 3,
    back = 4,
    up = 5,
    refresh = 6,
    list = 7,
    grid = 8,
    info = 9,
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
    kind: CIconKind = .file,
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
        .border = if (c_style.has_border) colorFromC(c_style.border) else null,
        .font_size = if (c_style.has_font_size) c_style.font_size else null,
        .padding = if (c_style.has_padding) edgesFromC(c_style.padding) else null,
        .border_radius = if (c_style.has_border_radius) c_style.border_radius else null,
        .border_width = if (c_style.has_border_width) c_style.border_width else null,
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

fn keycodeFromC(keycode: CKeycode) event.Event.Keycode {
    return switch (keycode) {
        .tab => .tab,
        .enter => .enter,
        .space => .space,
        .escape => .escape,
        .backspace => .backspace,
        .delete => .delete,
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
        .home => .home,
        .end => .end,
        .left_shift => .left_shift,
        .right_shift => .right_shift,
        .left_ctrl => .left_ctrl,
        .right_ctrl => .right_ctrl,
        .a => .a,
        .c => .c,
        .v => .v,
        .x => .x,
        .unknown => .unknown,
    };
}

fn buildTextInput(desc: CTextInputWidget) widget.WidgetKind.TextInput {
    var ti = widget.WidgetKind.TextInput{
        .placeholder = fromCStr(desc.placeholder),
    };
    const value = fromCStr(desc.value);
    if (value.len > 0) ti.insertSlice(value);
    return ti;
}

fn setTextInputValue(ti: *widget.WidgetKind.TextInput, placeholder: []const u8, value: []const u8) void {
    ti.* = .{ .placeholder = placeholder };
    if (value.len > 0) ti.insertSlice(value);
}

fn buildWidgetKind(desc: CWidget) widget.WidgetKind {
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
        .menu_item => .{ .menu_item = .{ .label = fromCStr(desc.data.menu_item.label) } },
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
        } },
        .text_input => .{ .text_input = buildTextInput(desc.data.text_input) },
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
        },
        .text_input => |*text_input| {
            if (desc.kind != .text_input) return false;
            setTextInputValue(text_input, fromCStr(desc.data.text_input.placeholder), fromCStr(desc.data.text_input.value));
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
        } },
        .mouse_scroll => .{ .mouse_scroll = .{
            .dx = ev.data.mouse_scroll.dx,
            .dy = ev.data.mouse_scroll.dy,
        } },
        .key => .{ .key = .{
            .scancode = ev.data.key.scancode,
            .keycode = keycodeFromC(ev.data.key.keycode),
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
    ctx.ctx.invalidate();
}

fn validHandle(ctx: *const CContext, handle: CHandle) bool {
    return ctx.ctx.isAlive(handleFromC(handle));
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
                .kind = switch (icon_cmd.kind) {
                    .folder => .folder,
                    .file => .file,
                    .symlink => .symlink,
                    .home => .home,
                    .back => .back,
                    .up => .up,
                    .refresh => .refresh,
                    .list => .list,
                    .grid => .grid,
                    .info => .info,
                },
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

export fn goop_context_free_draw_list(_: ?*CContext, _: ?*CDrawList) void {}

export fn goop_context_set_dimensions(ctx: ?*CContext, width: u32, height: u32) bool {
    const context = ctx orelse return false;
    context.ctx.setDimensions(width, height);
    return true;
}

export fn goop_context_add_root(ctx: ?*CContext, desc: ?*const CWidget, out_handle: ?*CHandle) bool {
    const context = ctx orelse return false;
    const widget_desc = desc orelse return false;
    const handle_ptr = out_handle orelse return false;
    const handle = context.ctx.tree.addRoot(buildWidgetKind(widget_desc.*)) catch return false;
    markDirty(context);
    handle_ptr.* = handleToC(handle);
    return true;
}

export fn goop_context_add_child(ctx: ?*CContext, parent: CHandle, desc: ?*const CWidget, out_handle: ?*CHandle) bool {
    const context = ctx orelse return false;
    const widget_desc = desc orelse return false;
    const handle_ptr = out_handle orelse return false;
    if (!validHandle(context, parent)) return false;
    const handle = context.ctx.tree.addChild(handleFromC(parent), buildWidgetKind(widget_desc.*)) catch return false;
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
    context.ctx.removeWidget(handleFromC(handle)) catch return false;
    return true;
}

export fn goop_context_is_alive(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    return context.ctx.isAlive(handleFromC(handle));
}

export fn goop_context_layout_rect(ctx: ?*const CContext, handle: CHandle, out_rect: ?*CRect) bool {
    const context = ctx orelse return false;
    const rect = out_rect orelse return false;
    if (!validHandle(context, handle)) return false;
    rect.* = rectToC(context.ctx.tree.getConst(handleFromC(handle)).layout_rect);
    return true;
}

export fn goop_context_was_clicked(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.wasClicked(handleFromC(handle));
}

export fn goop_context_was_secondary_clicked(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.wasSecondaryClicked(handleFromC(handle));
}

export fn goop_context_is_checked(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.isChecked(handleFromC(handle));
}

export fn goop_context_is_selected(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.isSelected(handleFromC(handle));
}

export fn goop_context_is_expanded(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.isExpanded(handleFromC(handle));
}

export fn goop_context_tree_item_toggled(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.treeItemToggled(handleFromC(handle));
}

export fn goop_context_tree_item_label(ctx: ?*const CContext, handle: CHandle) CStr {
    const context = ctx orelse return .{};
    if (!validHandle(context, handle)) return .{};
    return toCStr(context.ctx.treeItemLabel(handleFromC(handle)));
}

export fn goop_context_tree_item_editing(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.treeItemEditing(handleFromC(handle));
}

export fn goop_context_tree_item_rename_committed(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.treeItemRenameCommitted(handleFromC(handle));
}

export fn goop_context_slider_value(ctx: ?*const CContext, handle: CHandle) f32 {
    const context = ctx orelse return 0;
    if (!validHandle(context, handle)) return 0;
    return context.ctx.sliderValue(handleFromC(handle));
}

export fn goop_context_drag_value(ctx: ?*const CContext, handle: CHandle) f32 {
    const context = ctx orelse return 0;
    if (!validHandle(context, handle)) return 0;
    return context.ctx.dragValue(handleFromC(handle));
}

export fn goop_context_drag_value_changed(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.dragValueChanged(handleFromC(handle));
}

export fn goop_context_spinbox_value(ctx: ?*const CContext, handle: CHandle) f32 {
    const context = ctx orelse return 0;
    if (!validHandle(context, handle)) return 0;
    return context.ctx.spinboxValue(handleFromC(handle));
}

export fn goop_context_spinbox_changed(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.spinboxChanged(handleFromC(handle));
}

export fn goop_context_splitter_ratio(ctx: ?*const CContext, handle: CHandle) f32 {
    const context = ctx orelse return 0;
    if (!validHandle(context, handle)) return 0;
    return context.ctx.splitterRatio(handleFromC(handle));
}

export fn goop_context_splitter_changed(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.splitterChanged(handleFromC(handle));
}

export fn goop_context_text_input_value(ctx: ?*const CContext, handle: CHandle) CStr {
    const context = ctx orelse return .{};
    if (!validHandle(context, handle)) return .{};
    return toCStr(context.ctx.textInputValue(handleFromC(handle)));
}

export fn goop_context_dropdown_value(ctx: ?*const CContext, handle: CHandle) CStr {
    const context = ctx orelse return .{};
    if (!validHandle(context, handle)) return .{};
    return toCStr(context.ctx.dropdownValue(handleFromC(handle)));
}

export fn goop_context_dropdown_selected_index(ctx: ?*const CContext, handle: CHandle, out_index: ?*u16) bool {
    const context = ctx orelse return false;
    const index_ptr = out_index orelse return false;
    if (!validHandle(context, handle)) return false;
    const index = context.ctx.dropdownSelectedIndex(handleFromC(handle)) orelse return false;
    index_ptr.* = index;
    return true;
}

export fn goop_context_dropdown_changed(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.dropdownChanged(handleFromC(handle));
}

export fn goop_context_list_box_selected_index(ctx: ?*const CContext, handle: CHandle, out_index: ?*u16) bool {
    const context = ctx orelse return false;
    const index_ptr = out_index orelse return false;
    if (!validHandle(context, handle)) return false;
    const index = context.ctx.listBoxSelectedIndex(handleFromC(handle)) orelse return false;
    index_ptr.* = index;
    return true;
}

export fn goop_context_list_box_changed(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.listBoxChanged(handleFromC(handle));
}

export fn goop_context_list_box_selection_count(ctx: ?*const CContext, handle: CHandle) u16 {
    const context = ctx orelse return 0;
    if (!validHandle(context, handle)) return 0;
    return context.ctx.listBoxSelectionCount(handleFromC(handle));
}

export fn goop_context_grid_selector_selected_index(ctx: ?*const CContext, handle: CHandle, out_index: ?*u16) bool {
    const context = ctx orelse return false;
    const index_ptr = out_index orelse return false;
    if (!validHandle(context, handle)) return false;
    const index = context.ctx.gridSelectorSelectedIndex(handleFromC(handle)) orelse return false;
    index_ptr.* = index;
    return true;
}

export fn goop_context_grid_selector_changed(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.gridSelectorChanged(handleFromC(handle));
}

export fn goop_context_grid_selector_selection_count(ctx: ?*const CContext, handle: CHandle) u16 {
    const context = ctx orelse return 0;
    if (!validHandle(context, handle)) return 0;
    return context.ctx.gridSelectorSelectionCount(handleFromC(handle));
}

export fn goop_context_table_column_fraction(ctx: ?*const CContext, handle: CHandle, index: u8, out_fraction: ?*f32) bool {
    const context = ctx orelse return false;
    const fraction_ptr = out_fraction orelse return false;
    if (!validHandle(context, handle)) return false;
    const fraction = context.ctx.tableColumnFraction(handleFromC(handle), index) orelse return false;
    fraction_ptr.* = fraction;
    return true;
}

export fn goop_context_table_changed(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.tableChanged(handleFromC(handle));
}

export fn goop_context_table_resized_column(ctx: ?*const CContext, handle: CHandle, out_index: ?*u8) bool {
    const context = ctx orelse return false;
    const index_ptr = out_index orelse return false;
    if (!validHandle(context, handle)) return false;
    const index = context.ctx.tableResizedColumn(handleFromC(handle)) orelse return false;
    index_ptr.* = index;
    return true;
}

export fn goop_context_table_sorted_column(ctx: ?*const CContext, handle: CHandle, out_index: ?*u8) bool {
    const context = ctx orelse return false;
    const index_ptr = out_index orelse return false;
    if (!validHandle(context, handle)) return false;
    const index = context.ctx.tableSortedColumn(handleFromC(handle)) orelse return false;
    index_ptr.* = index;
    return true;
}

export fn goop_context_table_sort_direction(ctx: ?*const CContext, handle: CHandle, out_direction: ?*CSortDirection) bool {
    const context = ctx orelse return false;
    const direction_ptr = out_direction orelse return false;
    if (!validHandle(context, handle)) return false;
    const direction = context.ctx.tableSortDirection(handleFromC(handle)) orelse return false;
    direction_ptr.* = sortDirectionToC(direction);
    return true;
}

export fn goop_context_table_sort_changed(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.tableSortChanged(handleFromC(handle));
}

export fn goop_context_table_selection_changed(ctx: ?*const CContext, handle: CHandle) bool {
    const context = ctx orelse return false;
    if (!validHandle(context, handle)) return false;
    return context.ctx.tableSelectionChanged(handleFromC(handle));
}

export fn goop_context_table_selection_count(ctx: ?*const CContext, handle: CHandle) u16 {
    const context = ctx orelse return 0;
    if (!validHandle(context, handle)) return 0;
    return context.ctx.tableSelectionCount(handleFromC(handle));
}

export fn goop_context_table_selected_row_index(ctx: ?*const CContext, handle: CHandle, out_index: ?*u16) bool {
    const context = ctx orelse return false;
    const index_ptr = out_index orelse return false;
    if (!validHandle(context, handle)) return false;
    const index = context.ctx.tableSelectedRowIndex(handleFromC(handle)) orelse return false;
    index_ptr.* = index;
    return true;
}

export fn goop_context_last_secondary_click(ctx: ?*const CContext, out_click: ?*CSecondaryClick) bool {
    const context = ctx orelse return false;
    const click_ptr = out_click orelse return false;
    const click = context.ctx.lastSecondaryClick() orelse return false;
    click_ptr.* = .{
        .target = handleToC(click.target),
        .x = click.x,
        .y = click.y,
    };
    return true;
}

export fn goop_context_last_tree_drop(ctx: ?*const CContext, out_drop: ?*CTreeDrop) bool {
    const context = ctx orelse return false;
    const drop_ptr = out_drop orelse return false;
    const drop = context.ctx.lastTreeDrop() orelse return false;
    drop_ptr.* = .{
        .source = handleToC(drop.source),
        .target = handleToC(drop.target),
        .position = treeDropPositionToC(drop.position),
    };
    return true;
}

export fn goop_context_last_grid_drop(ctx: ?*const CContext, out_drop: ?*CGridDrop) bool {
    const context = ctx orelse return false;
    const drop_ptr = out_drop orelse return false;
    const drop = context.ctx.lastGridDrop() orelse return false;
    drop_ptr.* = .{
        .source = handleToC(drop.source),
        .target = handleToC(drop.target),
        .position = gridDropPositionToC(drop.position),
    };
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

    var rect: CRect = .{};
    try std.testing.expect(goop_context_layout_rect(ctx, button, &rect));

    const press = CEvent{
        .kind = .mouse_button,
        .data = .{ .mouse_button = .{
            .button = .left,
            .state = .pressed,
            .x = rect.x + rect.w * 0.5,
            .y = rect.y + rect.h * 0.5,
        } },
    };
    const release = CEvent{
        .kind = .mouse_button,
        .data = .{ .mouse_button = .{
            .button = .left,
            .state = .released,
            .x = rect.x + rect.w * 0.5,
            .y = rect.y + rect.h * 0.5,
        } },
    };

    try std.testing.expect(goop_context_push_event(ctx, &press));
    try std.testing.expect(goop_context_push_event(ctx, &release));
    try std.testing.expect(goop_context_process_events(ctx));
    try std.testing.expect(goop_context_was_clicked(ctx, button));

    var draw_list: CDrawList = .{};
    try std.testing.expect(goop_context_generate_draw_list(ctx, &draw_list));
    try std.testing.expect(draw_list.len > 0);
}

test "c header parses" {
    const c = @cImport({
        @cInclude("goop.h");
    });
    try std.testing.expect(@sizeOf(c.goop_node_handle_t) == @sizeOf(CHandle));
    try std.testing.expect(@sizeOf(c.goop_widget_t) > 0);
}
