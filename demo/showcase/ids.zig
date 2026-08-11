//! Stable semantic vocabulary shared by showcase construction and behavior.

const goop = @import("goop_ui");

pub const element = struct {
    pub const menu_file = goop.ElementId.init(0x0101);
    pub const menu_open_recent = goop.ElementId.init(0x0102);
    pub const menu_recent_a = goop.ElementId.init(0x0103);
    pub const menu_recent_b = goop.ElementId.init(0x0104);
    pub const menu_quit = goop.ElementId.init(0x0105);
    pub const menu_edit = goop.ElementId.init(0x0106);
    pub const menu_copy = goop.ElementId.init(0x0107);
    pub const menu_paste = goop.ElementId.init(0x0108);

    pub const toolbar_translate = goop.ElementId.init(0x0201);
    pub const toolbar_rotate = goop.ElementId.init(0x0202);
    pub const toolbar_scale = goop.ElementId.init(0x0203);

    pub const outline_scene = goop.ElementId.init(0x0301);
    pub const outline_camera = goop.ElementId.init(0x0302);
    pub const outline_light = goop.ElementId.init(0x0303);

    pub const list = goop.ElementId.init(0x0401);
    pub const list_scene = goop.ElementId.init(0x0402);
    pub const list_camera = goop.ElementId.init(0x0403);
    pub const list_light = goop.ElementId.init(0x0404);
    pub const grid = goop.ElementId.init(0x0410);
    pub const grid_brick = goop.ElementId.init(0x0411);
    pub const grid_metal = goop.ElementId.init(0x0412);
    pub const grid_leaves = goop.ElementId.init(0x0413);
    pub const grid_icons = goop.ElementId.init(0x0414);

    pub const asset_table = goop.ElementId.init(0x0501);
    pub const asset_scene = goop.ElementId.init(0x0502);
    pub const asset_camera = goop.ElementId.init(0x0503);
    pub const asset_light = goop.ElementId.init(0x0504);

    pub const viewport_mode = goop.ElementId.init(0x0601);
    pub const viewport_solid = goop.ElementId.init(0x0602);
    pub const viewport_wireframe = goop.ElementId.init(0x0603);
    pub const viewport_material = goop.ElementId.init(0x0604);
    pub const exposure = goop.ElementId.init(0x0610);
    pub const samples = goop.ElementId.init(0x0611);
    pub const option_enabled = goop.ElementId.init(0x0620);
    pub const option_a = goop.ElementId.init(0x0621);
    pub const option_b = goop.ElementId.init(0x0622);
    pub const option_c = goop.ElementId.init(0x0623);
    pub const text_input = goop.ElementId.init(0x0624);
    pub const slider = goop.ElementId.init(0x0625);
    pub const tab_scene = goop.ElementId.init(0x0630);
    pub const tab_render = goop.ElementId.init(0x0631);

    pub const splitter = goop.ElementId.init(0x0701);
    pub const viewport_scroll = goop.ElementId.init(0x0702);

    pub const context_popup = goop.ElementId.init(0x0801);
    pub const context_rename = goop.ElementId.init(0x0802);
    pub const context_delete = goop.ElementId.init(0x0803);
};

pub const action = struct {
    pub const menu_file = goop.ActionId.init(0x1001);
    pub const menu_open_recent = goop.ActionId.init(0x1002);
    pub const menu_recent_a = goop.ActionId.init(0x1003);
    pub const menu_recent_b = goop.ActionId.init(0x1004);
    pub const menu_quit = goop.ActionId.init(0x1005);
    pub const menu_edit = goop.ActionId.init(0x1006);
    pub const menu_copy = goop.ActionId.init(0x1007);
    pub const menu_paste = goop.ActionId.init(0x1008);

    pub const toolbar_translate = goop.ActionId.init(0x1101);
    pub const toolbar_rotate = goop.ActionId.init(0x1102);
    pub const toolbar_scale = goop.ActionId.init(0x1103);

    pub const select_outline_scene = goop.ActionId.init(0x1201);
    pub const select_outline_camera = goop.ActionId.init(0x1202);
    pub const select_outline_light = goop.ActionId.init(0x1203);
    pub const select_list_scene = goop.ActionId.init(0x1210);
    pub const select_list_camera = goop.ActionId.init(0x1211);
    pub const select_list_light = goop.ActionId.init(0x1212);
    pub const select_grid_brick = goop.ActionId.init(0x1220);
    pub const select_grid_metal = goop.ActionId.init(0x1221);
    pub const select_grid_leaves = goop.ActionId.init(0x1222);
    pub const select_grid_icons = goop.ActionId.init(0x1223);
    pub const select_asset_scene = goop.ActionId.init(0x1230);
    pub const select_asset_camera = goop.ActionId.init(0x1231);
    pub const select_asset_light = goop.ActionId.init(0x1232);

    pub const viewport_solid = goop.ActionId.init(0x1301);
    pub const viewport_wireframe = goop.ActionId.init(0x1302);
    pub const viewport_material = goop.ActionId.init(0x1303);
    pub const option_a = goop.ActionId.init(0x1310);
    pub const option_b = goop.ActionId.init(0x1311);
    pub const option_c = goop.ActionId.init(0x1312);
    pub const tab_scene = goop.ActionId.init(0x1320);
    pub const tab_render = goop.ActionId.init(0x1321);

    pub const context_rename = goop.ActionId.init(0x1401);
    pub const context_delete = goop.ActionId.init(0x1402);
};
