//! Showcase behavior over semantic control output.
//!
//! Platform events and tree interaction have already been translated to an
//! ordered, borrowed `goop.ControlEvents` batch before this module runs. The
//! controller owns application state and never inspects the component tree.

const std = @import("std");
const goop = @import("goop");
const ids = @import("showcase_ids");
const element = ids.element;
const action = ids.action;

pub const PopupState = struct {
    visible: bool = false,
    x: f32 = 0,
    y: f32 = 0,
};

pub const ToolbarState = struct {
    click_count: u32 = 0,
};

pub const ChoiceState = struct {
    option_enabled: bool = false,
    selected_option: goop.ElementId = element.option_a,
    active_tab: goop.ElementId = element.tab_scene,
    outline_expanded: bool = false,
};

pub const ValueState = struct {
    exposure: f32 = 1.25,
    samples: f32 = 64,
    splitter_ratio: f32 = 0.56,
    slider_value: f32 = 0.5,
    viewport_mode: ?u16 = null,
};

pub const TableState = struct {
    table_column: u8 = 0,
    table_column_fraction: f32 = 0,
    sort_column: u8 = 0,
    sort_direction: goop.SortChanged.Direction = .ascending,
};

pub const ScrollState = struct {
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
};

pub const SelectionState = struct {
    selection_source: ?goop.ElementId = null,
    selected: std.ArrayListUnmanaged(goop.ElementId) = .empty,
};

pub const DropState = struct {
    last_drop_source: ?goop.ElementId = null,
    last_drop_target: ?goop.ElementId = null,
};

pub const EventTrace = struct {
    last_element: ?goop.ElementId = null,
    last_action: ?goop.ActionId = null,
    last_event: ?EventKind = null,
    processed_event_count: usize = 0,
};

pub const Model = struct {
    toolbar: ToolbarState = .{},
    choices: ChoiceState = .{},
    values: ValueState = .{},
    table: TableState = .{},
    scroll: ScrollState = .{},
    text: std.ArrayListUnmanaged(u8) = .empty,
    selection: SelectionState = .{},
    drop: DropState = .{},
    trace: EventTrace = .{},
    context_popup: PopupState = .{},

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        self.selection.selected.deinit(allocator);
        self.text.deinit(allocator);
    }
};

pub const EventKind = enum {
    activated,
    secondary_activated,
    value_changed,
    toggle_changed,
    text_changed,
    sort_changed,
    selection_changed,
    scroll_changed,
    popup_visibility_changed,
    drop,
};

/// Apply a borrowed semantic event batch in occurrence order.
///
/// Payload copies are explicit and fallible because the model owns text and
/// selection data after the borrowed batch expires.
pub fn update(
    model: *Model,
    allocator: std.mem.Allocator,
    events: goop.ControlEvents,
) std.mem.Allocator.Error!void {
    var required_text_capacity: usize = 0;
    var required_selection_capacity: usize = 0;
    for (events.items) |control_event| switch (control_event) {
        .text_changed => |changed| {
            required_text_capacity = @max(required_text_capacity, events.text(changed).len);
        },
        .selection_changed => |changed| {
            required_selection_capacity = @max(required_selection_capacity, events.selection(changed).len);
        },
        else => {},
    };
    try model.text.ensureTotalCapacity(allocator, required_text_capacity);
    try model.selection.selected.ensureTotalCapacity(allocator, required_selection_capacity);

    for (events.items) |control_event| {
        model.trace.processed_event_count += 1;
        switch (control_event) {
            .activated => |activation| {
                model.trace.last_event = .activated;
                model.trace.last_element = activation.element;
                model.trace.last_action = activation.action;
                handleActivation(model, activation);
            },
            .secondary_activated => |activation| {
                model.trace.last_event = .secondary_activated;
                model.trace.last_element = activation.element;
                model.trace.last_action = activation.action;
                model.context_popup = .{
                    .visible = true,
                    .x = activation.x,
                    .y = activation.y,
                };
            },
            .popup_visibility_changed => |changed| {
                model.trace.last_event = .popup_visibility_changed;
                model.trace.last_element = changed.element;
                if (changed.element == ids.element.context_popup) {
                    model.context_popup.visible = changed.visible;
                }
            },
            .value_changed => |changed| {
                model.trace.last_event = .value_changed;
                model.trace.last_element = changed.element;
                handleValue(model, changed);
            },
            .toggle_changed => |changed| {
                model.trace.last_event = .toggle_changed;
                model.trace.last_element = changed.element;
                handleToggle(model, changed);
            },
            .text_changed => |changed| {
                model.trace.last_event = .text_changed;
                model.trace.last_element = changed.element;
                const text = events.text(changed);
                model.text.clearRetainingCapacity();
                model.text.appendSliceAssumeCapacity(text);
                std.debug.print("Text changed: {s}\n", .{model.text.items});
            },
            .sort_changed => |changed| {
                model.trace.last_event = .sort_changed;
                model.trace.last_element = changed.element;
                model.table.sort_column = changed.column;
                model.table.sort_direction = changed.direction;
                std.debug.print("Asset sort: column {} {s}\n", .{
                    model.table.sort_column,
                    @tagName(model.table.sort_direction),
                });
            },
            .selection_changed => |changed| {
                model.trace.last_event = .selection_changed;
                model.trace.last_element = changed.element;
                model.selection.selection_source = changed.element;
                const selected = events.selection(changed);
                model.selection.selected.clearRetainingCapacity();
                model.selection.selected.appendSliceAssumeCapacity(selected);
                std.debug.print("Selection changed: {} item(s)\n", .{model.selection.selected.items.len});
            },
            .scroll_changed => |changed| {
                model.trace.last_event = .scroll_changed;
                model.trace.last_element = changed.element;
                model.scroll.scroll_x = changed.x;
                model.scroll.scroll_y = changed.y;
                std.debug.print("Scroll position: {d:.1}, {d:.1}\n", .{
                    model.scroll.scroll_x,
                    model.scroll.scroll_y,
                });
            },
            .drop => |drop| {
                model.trace.last_event = .drop;
                model.trace.last_element = drop.target;
                model.drop.last_drop_source = drop.source;
                model.drop.last_drop_target = drop.target;
                std.debug.print("Drop: {} -> {}\n", .{ drop.source.value(), drop.target.value() });
            },
        }
    }
}

fn handleActivation(model: *Model, activation: goop.Activation) void {
    const command = activation.action orelse return;

    if (isToolbarAction(command)) {
        model.toolbar.click_count += 1;
        std.debug.print("Toolbar action: {s} (total: {})\n", .{
            actionLabel(command),
            model.toolbar.click_count,
        });
        return;
    }

    if (command == action.option_a) model.choices.selected_option = element.option_a;
    if (command == action.option_b) model.choices.selected_option = element.option_b;
    if (command == action.option_c) model.choices.selected_option = element.option_c;
    if (command == action.tab_scene) model.choices.active_tab = element.tab_scene;
    if (command == action.tab_render) model.choices.active_tab = element.tab_render;
    if (command == action.context_rename or command == action.context_delete) {
        model.context_popup.visible = false;
    }

    std.debug.print("{s}\n", .{actionLabel(command)});
}

fn handleValue(model: *Model, changed: goop.ValueChanged) void {
    switch (changed.value) {
        .scalar => |value| {
            if (changed.element == element.exposure) {
                model.values.exposure = value;
                std.debug.print("Exposure changed: {d:.2}\n", .{model.values.exposure});
            } else if (changed.element == element.samples) {
                model.values.samples = value;
                std.debug.print("Samples changed: {d:.0}\n", .{model.values.samples});
            } else if (changed.element == element.splitter) {
                model.values.splitter_ratio = value;
                std.debug.print("Splitter ratio: {d:.2}\n", .{model.values.splitter_ratio});
            } else if (changed.element == element.slider) {
                model.values.slider_value = value;
            }
        },
        .index => |index| {
            if (changed.element != element.viewport_mode) return;
            model.values.viewport_mode = index;
            std.debug.print("Viewport mode index: {?}\n", .{model.values.viewport_mode});
        },
        .column_fraction => |column| {
            if (changed.element != element.asset_table) return;
            model.table.table_column = column.column;
            model.table.table_column_fraction = column.fraction;
        },
    }
}

fn handleToggle(model: *Model, changed: goop.ToggleChanged) void {
    if (changed.element == element.option_enabled) {
        model.choices.option_enabled = changed.value;
        std.debug.print("Checkbox toggled: {}\n", .{model.choices.option_enabled});
    } else if (changed.element == element.outline_scene) {
        model.choices.outline_expanded = changed.value;
    } else if (changed.value and isOptionElement(changed.element)) {
        model.choices.selected_option = changed.element;
    }
}

fn isToolbarAction(command: goop.ActionId) bool {
    return command == action.toolbar_translate or
        command == action.toolbar_rotate or
        command == action.toolbar_scale;
}

fn isOptionElement(element_id: goop.ElementId) bool {
    return element_id == element.option_a or
        element_id == element.option_b or
        element_id == element.option_c;
}

fn actionLabel(command: goop.ActionId) []const u8 {
    if (command == action.toolbar_translate) return "Translate";
    if (command == action.toolbar_rotate) return "Rotate";
    if (command == action.toolbar_scale) return "Scale";
    if (command == action.menu_file) return "Menu toggled: File";
    if (command == action.menu_edit) return "Menu toggled: Edit";
    if (command == action.menu_open_recent) return "Menu toggled: Open Recent";
    if (command == action.menu_recent_a) return "Recent file: shot_v014.blend";
    if (command == action.menu_recent_b) return "Recent file: layout_blockout.blend";
    if (command == action.menu_quit) return "Menu action: Quit";
    if (command == action.menu_copy) return "Menu action: Copy";
    if (command == action.menu_paste) return "Menu action: Paste";
    if (command == action.select_outline_scene) return "Outline row selected: Scene";
    if (command == action.select_outline_camera) return "Outline row selected: Camera";
    if (command == action.select_outline_light) return "Outline row selected: Directional Light";
    if (command == action.select_list_scene) return "List row selected: Scene Collection";
    if (command == action.select_list_camera) return "List row selected: Camera Rig";
    if (command == action.select_list_light) return "List row selected: Lighting Set";
    if (command == action.select_grid_brick) return "Grid tile selected: Brick";
    if (command == action.select_grid_metal) return "Grid tile selected: Metal";
    if (command == action.select_grid_leaves) return "Grid tile selected: Leaves";
    if (command == action.select_grid_icons) return "Grid tile selected: UI Icons";
    if (command == action.select_asset_scene) return "Asset row clicked: SceneRoot";
    if (command == action.select_asset_camera) return "Asset row clicked: CameraRig";
    if (command == action.select_asset_light) return "Asset row clicked: KeyLight";
    if (command == action.viewport_solid) return "Viewport mode: Solid";
    if (command == action.viewport_wireframe) return "Viewport mode: Wireframe";
    if (command == action.viewport_material) return "Viewport mode: Material Preview";
    if (command == action.option_a) return "Radio: Option A selected";
    if (command == action.option_b) return "Radio: Option B selected";
    if (command == action.option_c) return "Radio: Option C selected";
    if (command == action.tab_scene) return "Tab selected: Scene";
    if (command == action.tab_render) return "Tab selected: Render";
    if (command == action.context_rename) return "Context action: Rename";
    if (command == action.context_delete) return "Context action: Delete";
    return "Unknown showcase action";
}

test "event routing preserves occurrence order" {
    var model = Model{};
    defer model.deinit(std.testing.allocator);
    const items = [_]goop.ControlEvent{
        .{ .activated = .{
            .element = element.toolbar_translate,
            .action = action.toolbar_translate,
        } },
        .{ .secondary_activated = .{
            .element = element.asset_scene,
            .action = action.select_asset_scene,
            .x = 42,
            .y = 84,
        } },
        .{ .activated = .{
            .element = element.context_delete,
            .action = action.context_delete,
        } },
        .{ .activated = .{
            .element = element.toolbar_rotate,
            .action = action.toolbar_rotate,
        } },
    };

    try update(&model, std.testing.allocator, .{
        .items = &items,
        .text_bytes = &.{},
        .selection_ids = &.{},
    });

    try std.testing.expectEqual(@as(usize, 4), model.trace.processed_event_count);
    try std.testing.expectEqual(@as(u32, 2), model.toolbar.click_count);
    try std.testing.expectEqual(action.toolbar_rotate, model.trace.last_action.?);
    try std.testing.expectEqual(EventKind.activated, model.trace.last_event.?);
    try std.testing.expect(!model.context_popup.visible);
}

test "borrowed payloads are copied into model state" {
    var model = Model{};
    defer model.deinit(std.testing.allocator);
    const selected = [_]goop.ElementId{ element.grid_brick, element.grid_metal };
    const items = [_]goop.ControlEvent{
        .{ .selection_changed = .{
            .element = element.grid,
            .selected = .{ .start = 0, .len = selected.len },
        } },
        .{ .text_changed = .{
            .element = element.text_input,
            .text = .{ .start = 0, .len = 5 },
        } },
        .{ .value_changed = .{
            .element = element.exposure,
            .value = .{ .scalar = 2.5 },
        } },
    };

    try update(&model, std.testing.allocator, .{
        .items = &items,
        .text_bytes = "hello",
        .selection_ids = &selected,
    });

    try std.testing.expectEqual(element.grid, model.selection.selection_source.?);
    try std.testing.expectEqualSlices(goop.ElementId, &selected, model.selection.selected.items);
    try std.testing.expectEqualStrings("hello", model.text.items);
    try std.testing.expectEqual(@as(f32, 2.5), model.values.exposure);
    try std.testing.expectEqual(EventKind.value_changed, model.trace.last_event.?);
}
