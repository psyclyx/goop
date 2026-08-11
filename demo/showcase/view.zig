//! Pure construction and focused visual projection for the widget showcase.
//!
//! Node handles are construction-local. Application behavior observes stable
//! element/action IDs through `goop.ControlEvents` and never retains tree
//! identity.

const goop = @import("goop");
const ids = @import("showcase_ids");
const element = ids.element;
const action = ids.action;

pub fn build(ctx: *goop.Context) !void {
    const root = try ctx.tree.addRoot(.{ .container = .{ .direction = .column } });
    try buildMenus(ctx, root);
    try buildToolbar(ctx, root);
    try buildOutline(ctx, root);
    try buildSelections(ctx, root);
    try buildTable(ctx, root);
    try buildEditors(ctx, root);
    try buildSplitView(ctx, root);
    try buildFooter(ctx, root);
}

/// Apply one model-owned popup projection by stable identity.
///
/// This is the only post-construction tree lookup the showcase needs. The
/// application retains plain popup state, not a tree handle.
pub fn applyPopupProjection(
    ctx: *goop.Context,
    popup_id: goop.ElementId,
    visible: bool,
    x: f32,
    y: f32,
) void {
    const handle = ctx.tree.findByElementId(popup_id) orelse return;
    const popup = &ctx.mutateKind(handle).?.popup;
    popup.visible = visible;
    popup.x = x;
    popup.y = y;
}

fn buildMenus(ctx: *goop.Context, root: goop.NodeHandle) !void {
    const menu_bar = try ctx.tree.addChild(root, .{ .menu_bar = .{} });
    const file = try ctx.tree.addChildControl(menu_bar, .{
        .identity = .{ .element_id = element.menu_file, .action_id = action.menu_file },
        .widget = .{ .menu = .{ .label = "File" } },
    });
    const file_popup = try ctx.tree.addChild(file, .{ .popup = .{
        .placement = .below_start,
        .visible = false,
    } });
    const open_recent = try ctx.tree.addChildControl(file_popup, .{
        .identity = .{ .element_id = element.menu_open_recent, .action_id = action.menu_open_recent },
        .widget = .{ .menu_item = .{ .label = "Open Recent" } },
    });
    const recent_popup = try ctx.tree.addChild(open_recent, .{ .popup = .{
        .placement = .right_start,
        .visible = false,
    } });
    _ = try ctx.tree.addChildControl(recent_popup, .{
        .identity = .{ .element_id = element.menu_recent_a, .action_id = action.menu_recent_a },
        .widget = .{ .menu_item = .{ .label = "shot_v014.blend" } },
    });
    _ = try ctx.tree.addChildControl(recent_popup, .{
        .identity = .{ .element_id = element.menu_recent_b, .action_id = action.menu_recent_b },
        .widget = .{ .menu_item = .{ .label = "layout_blockout.blend" } },
    });
    _ = try ctx.tree.addChildControl(file_popup, .{
        .identity = .{ .element_id = element.menu_quit, .action_id = action.menu_quit },
        .widget = .{ .menu_item = .{ .label = "Quit" } },
    });

    const edit = try ctx.tree.addChildControl(menu_bar, .{
        .identity = .{ .element_id = element.menu_edit, .action_id = action.menu_edit },
        .widget = .{ .menu = .{ .label = "Edit" } },
    });
    const edit_popup = try ctx.tree.addChild(edit, .{ .popup = .{
        .placement = .below_start,
        .visible = false,
    } });
    _ = try ctx.tree.addChildControl(edit_popup, .{
        .identity = .{ .element_id = element.menu_copy, .action_id = action.menu_copy },
        .widget = .{ .menu_item = .{ .label = "Copy" } },
    });
    _ = try ctx.tree.addChildControl(edit_popup, .{
        .identity = .{ .element_id = element.menu_paste, .action_id = action.menu_paste },
        .widget = .{ .menu_item = .{ .label = "Paste" } },
    });
}

fn buildToolbar(ctx: *goop.Context, root: goop.NodeHandle) !void {
    const toolbar = try ctx.tree.addChild(root, .{ .toolbar = .{} });
    _ = ctx.setStyle(toolbar, .{
        .bg = .rgb(36, 36, 36),
        .border = .rgb(68, 68, 68),
        .padding = goop.style.Edges.symmetric(8, 6),
        .border_radius = 0,
    });
    _ = try ctx.tree.addChildControl(toolbar, .{
        .identity = .{ .element_id = element.toolbar_translate, .action_id = action.toolbar_translate },
        .widget = .{ .button = .{ .label = "Translate" } },
    });
    _ = try ctx.tree.addChildControl(toolbar, .{
        .identity = .{ .element_id = element.toolbar_rotate, .action_id = action.toolbar_rotate },
        .widget = .{ .button = .{ .label = "Rotate" } },
    });
    _ = try ctx.tree.addChildControl(toolbar, .{
        .identity = .{ .element_id = element.toolbar_scale, .action_id = action.toolbar_scale },
        .widget = .{ .button = .{ .label = "Scale" } },
    });
}

fn buildOutline(ctx: *goop.Context, root: goop.NodeHandle) !void {
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "goop demo - click the buttons" } });
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Outline" } });
    const parent = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = element.outline_scene, .action_id = action.select_outline_scene },
        .widget = .{ .tree_item = .{
            .label = "Scene",
            .group = 10,
            .selected = true,
            .editable = true,
            .rename_trigger = .selected_click,
        } },
    });
    _ = try ctx.tree.addChildControl(parent, .{
        .identity = .{ .element_id = element.outline_camera, .action_id = action.select_outline_camera },
        .widget = .{ .tree_item = .{
            .label = "Camera",
            .group = 10,
            .editable = true,
            .rename_trigger = .selected_click,
        } },
    });
    _ = try ctx.tree.addChildControl(parent, .{
        .identity = .{ .element_id = element.outline_light, .action_id = action.select_outline_light },
        .widget = .{ .tree_item = .{
            .label = "Directional Light",
            .group = 10,
            .editable = true,
            .rename_trigger = .selected_click,
        } },
    });
    const tooltip = try ctx.tree.addChild(parent, .{ .tooltip = .{
        .placement = .below_start,
        .y = 4,
    } });
    _ = try ctx.tree.addChild(tooltip, .{ .text = .{ .content = "Click again while selected to rename." } });
}

fn buildSelections(ctx: *goop.Context, root: goop.NodeHandle) !void {
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "List Box" } });
    const list = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = element.list },
        .widget = .{ .list_box = .{ .selection_mode = .multiple } },
    });
    _ = try ctx.tree.addChildControl(list, .{
        .identity = .{ .element_id = element.list_scene, .action_id = action.select_list_scene },
        .widget = .{ .selectable = .{ .label = "Scene Collection", .selected = true } },
    });
    _ = try ctx.tree.addChildControl(list, .{
        .identity = .{ .element_id = element.list_camera, .action_id = action.select_list_camera },
        .widget = .{ .selectable = .{ .label = "Camera Rig" } },
    });
    _ = try ctx.tree.addChildControl(list, .{
        .identity = .{ .element_id = element.list_light, .action_id = action.select_list_light },
        .widget = .{ .selectable = .{ .label = "Lighting Set" } },
    });

    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Grid Selector" } });
    const grid = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = element.grid },
        .widget = .{ .grid_selector = .{
            .selection_mode = .multiple,
            .item_width = 104,
            .item_height = 96,
            .column_gap = 8,
            .row_gap = 8,
        } },
    });
    _ = try ctx.tree.addChildControl(grid, .{
        .identity = .{ .element_id = element.grid_brick, .action_id = action.select_grid_brick },
        .widget = .{ .grid_item = .{ .label = "Brick", .selected = true } },
    });
    _ = try ctx.tree.addChildControl(grid, .{
        .identity = .{ .element_id = element.grid_metal, .action_id = action.select_grid_metal },
        .widget = .{ .grid_item = .{ .label = "Metal" } },
    });
    _ = try ctx.tree.addChildControl(grid, .{
        .identity = .{ .element_id = element.grid_leaves, .action_id = action.select_grid_leaves },
        .widget = .{ .grid_item = .{ .label = "Leaves" } },
    });
    _ = try ctx.tree.addChildControl(grid, .{
        .identity = .{ .element_id = element.grid_icons, .action_id = action.select_grid_icons },
        .widget = .{ .grid_item = .{ .label = "UI Icons" } },
    });
}

fn buildTable(ctx: *goop.Context, root: goop.NodeHandle) !void {
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Asset Table" } });
    const table = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = element.asset_table },
        .widget = .{ .table = .{
            .columns = 3,
            .resizable = true,
            .sortable = true,
            .selection_mode = .multiple,
            .min_column_width = 96,
        } },
    });
    {
        const state = &ctx.mutateKind(table).?.table;
        state.internal.column_weights[0] = 0.56;
        state.internal.column_weights[1] = 0.24;
        state.internal.column_weights[2] = 0.20;
    }
    const header = try ctx.tree.addChild(table, .{ .table_row = .{ .header = true } });
    try addTableRow(ctx, header, "Name", "Type", "Visible");
    const scene = try ctx.tree.addChildControl(table, .{
        .identity = .{ .element_id = element.asset_scene, .action_id = action.select_asset_scene },
        .widget = .{ .table_row = .{ .selected = true } },
    });
    try addTableRow(ctx, scene, "SceneRoot", "Collection", "Yes");
    const camera = try ctx.tree.addChildControl(table, .{
        .identity = .{ .element_id = element.asset_camera, .action_id = action.select_asset_camera },
        .widget = .{ .table_row = .{} },
    });
    try addTableRow(ctx, camera, "CameraRig", "Object", "Yes");
    const light = try ctx.tree.addChildControl(table, .{
        .identity = .{ .element_id = element.asset_light, .action_id = action.select_asset_light },
        .widget = .{ .table_row = .{} },
    });
    try addTableRow(ctx, light, "KeyLight", "Light", "No");
}

fn buildEditors(ctx: *goop.Context, root: goop.NodeHandle) !void {
    const dropdown = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = element.viewport_mode },
        .widget = .{ .dropdown = .{ .placeholder = "Viewport mode" } },
    });
    const dropdown_popup = try ctx.tree.addChild(dropdown, .{ .popup = .{ .placement = .below_start } });
    _ = try ctx.tree.addChildControl(dropdown_popup, .{
        .identity = .{ .element_id = element.viewport_solid, .action_id = action.viewport_solid },
        .widget = .{ .menu_item = .{ .label = "Solid" } },
    });
    _ = try ctx.tree.addChildControl(dropdown_popup, .{
        .identity = .{ .element_id = element.viewport_wireframe, .action_id = action.viewport_wireframe },
        .widget = .{ .menu_item = .{ .label = "Wireframe" } },
    });
    _ = try ctx.tree.addChildControl(dropdown_popup, .{
        .identity = .{ .element_id = element.viewport_material, .action_id = action.viewport_material },
        .widget = .{ .menu_item = .{ .label = "Material Preview" } },
    });

    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Numbers" } });
    const exposure_row = try ctx.tree.addChild(root, .{ .container = .{ .direction = .row } });
    _ = try ctx.tree.addChild(exposure_row, .{ .text = .{ .content = "Exposure" } });
    _ = try ctx.tree.addChildControl(exposure_row, .{
        .identity = .{ .element_id = element.exposure },
        .widget = .{ .drag_value = .{
            .value = 1.25,
            .min = -4,
            .max = 8,
            .speed = 0.02,
            .precision = 2,
        } },
    });
    const samples_row = try ctx.tree.addChild(root, .{ .container = .{ .direction = .row } });
    _ = try ctx.tree.addChild(samples_row, .{ .text = .{ .content = "Samples" } });
    _ = try ctx.tree.addChildControl(samples_row, .{
        .identity = .{ .element_id = element.samples },
        .widget = .{ .spinbox = .{
            .value = 64,
            .min = 1,
            .max = 512,
            .step = 1,
            .precision = 0,
        } },
    });

    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Editor Tabs" } });
    const tab_bar = try ctx.tree.addChild(root, .{ .tab_bar = .{} });
    const scene = try ctx.tree.addChildControl(tab_bar, .{
        .identity = .{ .element_id = element.tab_scene, .action_id = action.tab_scene },
        .widget = .{ .tab_item = .{ .label = "Scene", .selected = true } },
    });
    _ = try ctx.tree.addChild(scene, .{ .text = .{ .content = "Scene tools: hierarchy, transforms, visibility." } });
    const render = try ctx.tree.addChildControl(tab_bar, .{
        .identity = .{ .element_id = element.tab_render, .action_id = action.tab_render },
        .widget = .{ .tab_item = .{ .label = "Render" } },
    });
    _ = try ctx.tree.addChild(render, .{ .text = .{ .content = "Render settings: samples, output, color management." } });

    _ = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = element.option_enabled },
        .widget = .{ .checkbox = .{ .label = "Enable option" } },
    });
    _ = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = element.option_a, .action_id = action.option_a },
        .widget = .{ .radio_button = .{ .label = "Option A", .group = 1, .selected = true } },
    });
    _ = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = element.option_b, .action_id = action.option_b },
        .widget = .{ .radio_button = .{ .label = "Option B", .group = 1 } },
    });
    _ = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = element.option_c, .action_id = action.option_c },
        .widget = .{ .radio_button = .{ .label = "Option C", .group = 1 } },
    });
    _ = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = element.text_input },
        .widget = .{ .text_input = .{ .placeholder = "Type here..." } },
    });
    _ = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = element.slider },
        .widget = .{ .slider = .{ .value = 0.5, .min = 0, .max = 1 } },
    });
}

fn buildSplitView(ctx: *goop.Context, root: goop.NodeHandle) !void {
    _ = try ctx.tree.addChild(root, .{ .text = .{ .content = "Split View" } });
    const splitter = try ctx.tree.addChildControl(root, .{
        .identity = .{ .element_id = element.splitter },
        .widget = .{ .splitter = .{
            .direction = .row,
            .ratio = 0.56,
            .min_first = 150,
            .min_second = 140,
            .thickness = 8,
        } },
    });
    const inspector = try ctx.tree.addChild(splitter, .{ .container = .{ .direction = .column } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Inspector" } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Transform" } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Location  0.00  1.50  6.20" } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Rotation  0.00  0.00  0.00" } });
    _ = try ctx.tree.addChild(inspector, .{ .text = .{ .content = "Scale     1.00  1.00  1.00" } });
    const viewport = try ctx.tree.addChild(splitter, .{ .container = .{ .direction = .column } });
    _ = try ctx.tree.addChild(viewport, .{ .text = .{ .content = "Viewport Notes" } });
    const scroll = try ctx.tree.addChildControl(viewport, .{
        .identity = .{ .element_id = element.viewport_scroll },
        .widget = .{ .scroll_area = .{} },
    });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 1" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 2" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 3" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 4" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 5" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 6" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 7" } });
    _ = try ctx.tree.addChild(scroll, .{ .text = .{ .content = "Scroll area line 8" } });
}

fn buildFooter(ctx: *goop.Context, root: goop.NodeHandle) !void {
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

    const popup = try ctx.tree.addRootControl(.{
        .identity = .{ .element_id = element.context_popup },
        .widget = .{ .popup = .{ .placement = .absolute, .visible = false } },
    });
    _ = try ctx.tree.addChildControl(popup, .{
        .identity = .{ .element_id = element.context_rename, .action_id = action.context_rename },
        .widget = .{ .menu_item = .{ .label = "Rename" } },
    });
    _ = try ctx.tree.addChildControl(popup, .{
        .identity = .{ .element_id = element.context_delete, .action_id = action.context_delete },
        .widget = .{ .menu_item = .{ .label = "Delete" } },
    });
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
