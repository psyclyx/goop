//! Showcase behavior over the retained component handles.
//!
//! Platform events have already been translated to goop events before this
//! module runs. It has no Wayland, Vulkan, or text-engine dependency.

const std = @import("std");
const goop = @import("goop");
const view = @import("showcase_view");

pub const Model = struct {
    toolbar_click_count: u32 = 0,
};

pub fn update(model: *Model, ctx: *goop.Context, handles: view.Handles) void {
    if (ctx.frame().last_secondary_click) |click| {
        if (handles.context.context_popup) |popup| {
            const popup_node = ctx.tree.get(popup);
            popup_node.kind.popup.x = click.x;
            popup_node.kind.popup.y = click.y;
            popup_node.kind.popup.visible = true;
        }
    }

    toolbarAction(model, ctx, handles.toolbar.translate, "Translate");
    toolbarAction(model, ctx, handles.toolbar.rotate, "Rotate");
    toolbarAction(model, ctx, handles.toolbar.scale, "Scale");

    if (clicked(ctx, handles.choices.checkbox)) {
        const node = ctx.tree.node(handles.choices.checkbox.?).?;
        std.debug.print("Checkbox toggled: {}\n", .{node.kind.checkbox.checked});
    }
    logClick(ctx, handles.choices.radio_a, "Radio: Option A selected");
    logClick(ctx, handles.choices.radio_b, "Radio: Option B selected");
    logClick(ctx, handles.choices.radio_c, "Radio: Option C selected");
    logClick(ctx, handles.selection.scene, "List row selected: Scene Collection");
    logClick(ctx, handles.selection.camera, "List row selected: Camera Rig");
    logClick(ctx, handles.selection.light, "List row selected: Lighting Set");
    logClick(ctx, handles.selection.grid_a, "Grid tile selected: Brick");
    logClick(ctx, handles.selection.grid_b, "Grid tile selected: Metal");
    logClick(ctx, handles.selection.grid_c, "Grid tile selected: Leaves");
    logClick(ctx, handles.selection.grid_d, "Grid tile selected: UI Icons");
    logClick(ctx, handles.table.row_a, "Asset row clicked: SceneRoot");
    logClick(ctx, handles.table.row_b, "Asset row clicked: CameraRig");
    logClick(ctx, handles.table.row_c, "Asset row clicked: KeyLight");
    logClick(ctx, handles.menus.file, "Menu toggled: File");
    logClick(ctx, handles.menus.edit, "Menu toggled: Edit");
    logClick(ctx, handles.menus.recent_a, "Recent file: shot_v014.blend");
    logClick(ctx, handles.menus.recent_b, "Recent file: layout_blockout.blend");
    logClick(ctx, handles.menus.quit, "Menu action: Quit");
    logClick(ctx, handles.menus.copy, "Menu action: Copy");
    logClick(ctx, handles.menus.paste, "Menu action: Paste");
    logClick(ctx, handles.tabs.scene, "Tab selected: Scene");
    logClick(ctx, handles.tabs.render, "Tab selected: Render");
    logClick(ctx, handles.context.context_action_a, "Context action: Rename");
    logClick(ctx, handles.context.context_action_b, "Context action: Delete");

    if (handles.values.drag_value) |handle| if (ctx.tree.node(handle).?.changed) {
        std.debug.print("Exposure changed: {d:.2}\n", .{
            ctx.tree.node(handle).?.kind.drag_value.value,
        });
    };
    if (handles.values.spinbox) |handle| if (ctx.tree.node(handle).?.changed) {
        std.debug.print("Samples changed: {d:.0}\n", .{
            ctx.tree.node(handle).?.kind.spinbox.value,
        });
    };
    if (handles.values.splitter) |handle| if (ctx.tree.node(handle).?.changed) {
        std.debug.print("Splitter ratio: {d:.2}\n", .{
            ctx.tree.node(handle).?.kind.splitter.ratio,
        });
    };
    if (handles.choices.dropdown) |handle| if (ctx.tree.node(handle).?.changed) {
        std.debug.print("Dropdown selected: {s}\n", .{
            ctx.tree.node(handle).?.kind.dropdown.selected_text,
        });
    };
}

fn toolbarAction(
    model: *Model,
    ctx: *const goop.Context,
    handle: ?goop.NodeHandle,
    label: []const u8,
) void {
    if (!clicked(ctx, handle)) return;
    model.toolbar_click_count += 1;
    std.debug.print("Toolbar action: {s} (total: {})\n", .{
        label,
        model.toolbar_click_count,
    });
}

fn logClick(ctx: *const goop.Context, handle: ?goop.NodeHandle, message: []const u8) void {
    if (clicked(ctx, handle)) std.debug.print("{s}\n", .{message});
}

fn clicked(ctx: *const goop.Context, handle: ?goop.NodeHandle) bool {
    const resolved = handle orelse return false;
    return ctx.tree.node(resolved).?.clicked;
}
