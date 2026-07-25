//! Pure construction of the widget showcase.
//!
//! This module owns no window, event loop, renderer, text engine, or GPU
//! object. It only builds the established component tree and returns the
//! handles the controller needs.

const goop = @import("goop");

pub const ToolbarHandles = struct {
    translate: ?goop.NodeHandle = null,
    rotate: ?goop.NodeHandle = null,
    scale: ?goop.NodeHandle = null,
};

pub const OutlineHandles = struct {
    parent: ?goop.NodeHandle = null,
    child_a: ?goop.NodeHandle = null,
    child_b: ?goop.NodeHandle = null,
};

pub const ChoiceHandles = struct {
    checkbox: ?goop.NodeHandle = null,
    radio_a: ?goop.NodeHandle = null,
    radio_b: ?goop.NodeHandle = null,
    radio_c: ?goop.NodeHandle = null,
    dropdown: ?goop.NodeHandle = null,
};

pub const SelectionHandles = struct {
    list_box: ?goop.NodeHandle = null,
    scene: ?goop.NodeHandle = null,
    camera: ?goop.NodeHandle = null,
    light: ?goop.NodeHandle = null,
    grid_selector: ?goop.NodeHandle = null,
    grid_a: ?goop.NodeHandle = null,
    grid_b: ?goop.NodeHandle = null,
    grid_c: ?goop.NodeHandle = null,
    grid_d: ?goop.NodeHandle = null,
};

pub const TableHandles = struct {
    root: ?goop.NodeHandle = null,
    row_a: ?goop.NodeHandle = null,
    row_b: ?goop.NodeHandle = null,
    row_c: ?goop.NodeHandle = null,
};

pub const MenuHandles = struct {
    file: ?goop.NodeHandle = null,
    edit: ?goop.NodeHandle = null,
    open_recent: ?goop.NodeHandle = null,
    recent_a: ?goop.NodeHandle = null,
    recent_b: ?goop.NodeHandle = null,
    quit: ?goop.NodeHandle = null,
    copy: ?goop.NodeHandle = null,
    paste: ?goop.NodeHandle = null,
};

pub const ValueHandles = struct {
    drag_value: ?goop.NodeHandle = null,
    spinbox: ?goop.NodeHandle = null,
    splitter: ?goop.NodeHandle = null,
};

pub const TabHandles = struct {
    scene: ?goop.NodeHandle = null,
    render: ?goop.NodeHandle = null,
};

pub const ContextHandles = struct {
    context_popup: ?goop.NodeHandle = null,
    context_action_a: ?goop.NodeHandle = null,
    context_action_b: ?goop.NodeHandle = null,
};

pub const Handles = struct {
    toolbar: ToolbarHandles = .{},
    outline: OutlineHandles = .{},
    choices: ChoiceHandles = .{},
    selection: SelectionHandles = .{},
    table: TableHandles = .{},
    menus: MenuHandles = .{},
    values: ValueHandles = .{},
    tabs: TabHandles = .{},
    context: ContextHandles = .{},
};

pub fn build(ctx: *goop.Context) !Handles {
    var handles = Handles{};
    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });

    const menu_bar = try ctx.tree.addChild(root, .{ .menu_bar = .{} });
    handles.menus.file = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "File" } });
    const file_popup = try ctx.tree.addChild(handles.menus.file.?, .{ .popup = .{
        .placement = .below_start,
        .visible = false,
    } });
    handles.menus.open_recent = try ctx.tree.addChild(file_popup, .{ .menu_item = .{ .label = "Open Recent" } });
    const recent_popup = try ctx.tree.addChild(handles.menus.open_recent.?, .{ .popup = .{
        .placement = .right_start,
        .visible = false,
    } });
    handles.menus.recent_a = try ctx.tree.addChild(recent_popup, .{ .menu_item = .{ .label = "shot_v014.blend" } });
    handles.menus.recent_b = try ctx.tree.addChild(recent_popup, .{ .menu_item = .{ .label = "layout_blockout.blend" } });
    handles.menus.quit = try ctx.tree.addChild(file_popup, .{ .menu_item = .{ .label = "Quit" } });

    handles.menus.edit = try ctx.tree.addChild(menu_bar, .{ .menu = .{ .label = "Edit" } });
    const edit_popup = try ctx.tree.addChild(handles.menus.edit.?, .{ .popup = .{
        .placement = .below_start,
        .visible = false,
    } });
    handles.menus.copy = try ctx.tree.addChild(edit_popup, .{ .menu_item = .{ .label = "Copy" } });
    handles.menus.paste = try ctx.tree.addChild(edit_popup, .{ .menu_item = .{ .label = "Paste" } });

    const toolbar = try ctx.tree.addChild(root, .{ .toolbar = .{} });
    _ = ctx.setStyle(toolbar, .{
        .bg = .rgb(36, 36, 36),
        .border = .rgb(68, 68, 68),
        .padding = goop.style.Edges.symmetric(8, 6),
        .border_radius = 0,
    });
    handles.toolbar.translate = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "Translate" } });
    handles.toolbar.rotate = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "Rotate" } });
    handles.toolbar.scale = try ctx.tree.addChild(toolbar, .{ .button = .{ .label = "Scale" } });

    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "goop demo - click the buttons" } });
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Outline" } });
    handles.outline.parent = try ctx.tree.addChild(root, .{ .tree_item = .{
        .label = "Scene",
        .group = 10,
        .selected = true,
        .editable = true,
        .rename_trigger = .selected_click,
    } });
    handles.outline.child_a = try ctx.tree.addChild(handles.outline.parent.?, .{ .tree_item = .{
        .label = "Camera",
        .group = 10,
        .editable = true,
        .rename_trigger = .selected_click,
    } });
    handles.outline.child_b = try ctx.tree.addChild(handles.outline.parent.?, .{ .tree_item = .{
        .label = "Directional Light",
        .group = 10,
        .editable = true,
        .rename_trigger = .selected_click,
    } });
    const outline_tooltip = try ctx.tree.addChild(handles.outline.parent.?, .{ .tooltip = .{
        .placement = .below_start,
        .y = 4,
    } });
    _ = try ctx.tree.addChild(outline_tooltip, .{ .text = .{ .content = "Click again while selected to rename." } });

    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "List Box" } });
    handles.selection.list_box = try ctx.tree.addChild(root, .{ .list_box = .{ .selection_mode = .multiple } });
    handles.selection.scene = try ctx.tree.addChild(handles.selection.list_box.?, .{ .selectable = .{
        .label = "Scene Collection",
        .selected = true,
    } });
    handles.selection.camera = try ctx.tree.addChild(handles.selection.list_box.?, .{ .selectable = .{ .label = "Camera Rig" } });
    handles.selection.light = try ctx.tree.addChild(handles.selection.list_box.?, .{ .selectable = .{ .label = "Lighting Set" } });

    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Grid Selector" } });
    handles.selection.grid_selector = try ctx.tree.addChild(root, .{ .grid_selector = .{
        .selection_mode = .multiple,
        .item_width = 104,
        .item_height = 96,
        .column_gap = 8,
        .row_gap = 8,
    } });
    handles.selection.grid_a = try ctx.tree.addChild(handles.selection.grid_selector.?, .{ .grid_item = .{ .label = "Brick", .selected = true } });
    handles.selection.grid_b = try ctx.tree.addChild(handles.selection.grid_selector.?, .{ .grid_item = .{ .label = "Metal" } });
    handles.selection.grid_c = try ctx.tree.addChild(handles.selection.grid_selector.?, .{ .grid_item = .{ .label = "Leaves" } });
    handles.selection.grid_d = try ctx.tree.addChild(handles.selection.grid_selector.?, .{ .grid_item = .{ .label = "UI Icons" } });

    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Asset Table" } });
    handles.table.root = try ctx.tree.addChild(root, .{ .table = .{
        .columns = 3,
        .resizable = true,
        .sortable = true,
        .selection_mode = .multiple,
        .min_column_width = 96,
    } });
    {
        const table = &ctx.mutateKind(handles.table.root.?).?.table;
        table.internal.column_weights[0] = 0.56;
        table.internal.column_weights[1] = 0.24;
        table.internal.column_weights[2] = 0.20;
    }
    const header = try ctx.tree.addChild(handles.table.root.?, .{ .table_row = .{ .header = true } });
    try addTableRow(ctx, header, "Name", "Type", "Visible");
    handles.table.row_a = try ctx.tree.addChild(handles.table.root.?, .{ .table_row = .{ .selected = true } });
    try addTableRow(ctx, handles.table.row_a.?, "SceneRoot", "Collection", "Yes");
    handles.table.row_b = try ctx.tree.addChild(handles.table.root.?, .{ .table_row = .{} });
    try addTableRow(ctx, handles.table.row_b.?, "CameraRig", "Object", "Yes");
    handles.table.row_c = try ctx.tree.addChild(handles.table.root.?, .{ .table_row = .{} });
    try addTableRow(ctx, handles.table.row_c.?, "KeyLight", "Light", "No");

    handles.choices.dropdown = try ctx.tree.addChild(root, .{ .dropdown = .{ .placeholder = "Viewport mode" } });
    const dropdown_popup = try ctx.tree.addChild(handles.choices.dropdown.?, .{ .popup = .{ .placement = .below_start } });
    _ = try ctx.tree.addChild(dropdown_popup, .{ .menu_item = .{ .label = "Solid" } });
    _ = try ctx.tree.addChild(dropdown_popup, .{ .menu_item = .{ .label = "Wireframe" } });
    _ = try ctx.tree.addChild(dropdown_popup, .{ .menu_item = .{ .label = "Material Preview" } });

    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Numbers" } });
    const exposure_row = try ctx.tree.addChild(root, .{ .container = .{ .direction = .row } });
    _ = try ctx.tree.addChild(exposure_row, .{ .text = .{ .content = "Exposure" } });
    handles.values.drag_value = try ctx.tree.addChild(exposure_row, .{ .drag_value = .{
        .value = 1.25,
        .min = -4,
        .max = 8,
        .speed = 0.02,
        .precision = 2,
    } });
    const samples_row = try ctx.tree.addChild(root, .{ .container = .{ .direction = .row } });
    _ = try ctx.tree.addChild(samples_row, .{ .text = .{ .content = "Samples" } });
    handles.values.spinbox = try ctx.tree.addChild(samples_row, .{ .spinbox = .{
        .value = 64,
        .min = 1,
        .max = 512,
        .step = 1,
        .precision = 0,
    } });

    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Editor Tabs" } });
    const tab_bar = try ctx.tree.addChild(root, .{ .tab_bar = .{} });
    handles.tabs.scene = try ctx.tree.addChild(tab_bar, .{ .tab_item = .{ .label = "Scene", .selected = true } });
    _ = try ctx.tree.addChild(handles.tabs.scene.?, .{ .text = .{ .content = "Scene tools: hierarchy, transforms, visibility." } });
    handles.tabs.render = try ctx.tree.addChild(tab_bar, .{ .tab_item = .{ .label = "Render" } });
    _ = try ctx.tree.addChild(handles.tabs.render.?, .{ .text = .{ .content = "Render settings: samples, output, color management." } });

    handles.choices.checkbox = try ctx.tree.addChild(root, .{ .checkbox = .{ .label = "Enable option" } });
    handles.choices.radio_a = try ctx.tree.addChild(root, .{ .radio_button = .{ .label = "Option A", .group = 1, .selected = true } });
    handles.choices.radio_b = try ctx.tree.addChild(root, .{ .radio_button = .{ .label = "Option B", .group = 1 } });
    handles.choices.radio_c = try ctx.tree.addChild(root, .{ .radio_button = .{ .label = "Option C", .group = 1 } });
    _ = try ctx.tree.addChild(root, .{ .text_input = .{ .placeholder = "Type here..." } });
    _ = try ctx.tree.addChild(root, .{ .slider = .{ .value = 0.5, .min = 0, .max = 1 } });

    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Split View" } });
    handles.values.splitter = try ctx.tree.addChild(root, .{ .splitter = .{
        .direction = .row,
        .ratio = 0.56,
        .min_first = 150,
        .min_second = 140,
        .thickness = 8,
    } });
    const inspector = try ctx.tree.addChild(handles.values.splitter.?, .{ .container = .{ .direction = .column } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Inspector" } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Transform" } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Location  0.00  1.50  6.20" } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Rotation  0.00  0.00  0.00" } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Scale     1.00  1.00  1.00" } });
    const viewport = try ctx.tree.addChild(handles.values.splitter.?, .{ .container = .{ .direction = .column } });
    _ = try ctx.tree.addChild(viewport, .{ .text = .{ .content = "Viewport Notes" } });
    const scroll = try ctx.tree.addChild(viewport, .{ .scroll_area = .{} });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 1" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 2" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 3" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 4" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 5" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 6" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 7" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 8" } });

    const status_bar = try ctx.tree.addChild(root, .{ .status_bar = .{} });
    _ = ctx.setStyle(status_bar, .{
        .bg = .rgb(34, 34, 34),
        .border = .rgb(68, 68, 68),
        .padding = goop.style.Edges.symmetric(8, 5),
        .border_radius = 0,
    });
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = "Scene: 3 items" } });
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = "Render: Preview" } });
    _ = try ctx.tree.addChild(status_bar, .{ .text = .{ .content = "Status: Ready" } });

    handles.context.context_popup = try ctx.tree.addRoot(.{ .popup = .{ .placement = .absolute, .visible = false } });
    handles.context.context_action_a = try ctx.tree.addChild(handles.context.context_popup.?, .{ .menu_item = .{ .label = "Rename" } });
    handles.context.context_action_b = try ctx.tree.addChild(handles.context.context_popup.?, .{ .menu_item = .{ .label = "Delete" } });
    return handles;
}

fn addTableRow(
    ctx: *goop.Context,
    row: goop.NodeHandle,
    first: []const u8,
    second: []const u8,
    third: []const u8,
) !void {
    const a = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    const b = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    const c = try ctx.tree.addChild(row, .{ .table_cell = .{} });
    _ = try ctx.tree.addChild(a, .{ .text = .{ .content = first } });
    _ = try ctx.tree.addChild(b, .{ .text = .{ .content = second } });
    _ = try ctx.tree.addChild(c, .{ .text = .{ .content = third } });
}
