const std = @import("std");
const goop = @import("goop");

const fm = @import("controller.zig");
const State = fm.State;

// Local aliases for callbacks back into the main module:
const detailTitleFontSizePx = fm.detailTitleFontSizePx;
const detailCaptionFontSizePx = fm.detailCaptionFontSizePx;
const previewBodyFontSizePx = fm.previewBodyFontSizePx;

pub fn uiScaleValue(scale: f32, value: f32) f32 {
    return value * scale;
}

pub fn uiPx(state: *const State, value: f32) f32 {
    return uiScaleValue(state.runtime.ui_scale, value);
}

pub fn uiEdgesAll(state: *const State, value: f32) goop.style.Edges {
    return goop.style.Edges.all(uiPx(state, value));
}

pub fn uiEdgesSymmetric(state: *const State, h: f32, v: f32) goop.style.Edges {
    return goop.style.Edges.symmetric(uiPx(state, h), uiPx(state, v));
}

pub fn fileManagerThemeForScale(ui_scale: f32) goop.Theme {
    return .{
        .bg = .rgb(243, 246, 251),
        .fg = .rgb(24, 29, 38),
        .accent = .rgb(58, 126, 219),
        .border = .rgb(203, 210, 223),
        .bg_hover = .rgb(231, 238, 248),
        .bg_active = .rgb(220, 229, 243),
        .focus_ring = .rgba(58, 126, 219, 210),
        .placeholder_fg = .rgb(123, 133, 148),
        .selection_bg = .rgba(58, 126, 219, 84),
        .tree_guide = .rgba(112, 122, 138, 210),
        .font_size = uiScaleValue(ui_scale, 14),
        .padding = goop.style.Edges.symmetric(uiScaleValue(ui_scale, 8), uiScaleValue(ui_scale, 6)),
        .border_radius = uiScaleValue(ui_scale, 6),
        .border_width = 1,
        .spacing = uiScaleValue(ui_scale, 6),
        .thumb_width = uiScaleValue(ui_scale, 14),
    };
}

pub fn fileManagerTheme(state: *const State) goop.Theme {
    return fileManagerThemeForScale(state.runtime.ui_scale);
}

pub fn fileManagerShellColor() goop.Color {
    return .rgb(240, 243, 247);
}

pub fn fileManagerChromeColor() goop.Color {
    return .rgb(232, 236, 241);
}

pub fn fileManagerSurfaceColor() goop.Color {
    return .rgb(255, 255, 255);
}

pub fn fileManagerPanelHeaderColor() goop.Color {
    return .rgb(246, 248, 251);
}

pub fn fileManagerSidebarColor() goop.Color {
    return .rgb(245, 247, 250);
}

pub fn fileManagerMutedTextColor() goop.Color {
    return .rgb(100, 109, 123);
}

pub fn fileManagerToolbarButtonStyle(state: *const State, active: bool, enabled: bool) goop.Style {
    return .{
        .bg = if (active)
            .rgb(222, 233, 249)
        else if (enabled)
            .rgb(247, 249, 252)
        else
            .rgb(240, 243, 247),
        .fg = if (enabled) fileManagerTheme(state).fg else fileManagerMutedTextColor(),
        .border = if (active)
            fileManagerTheme(state).accent
        else
            .rgb(209, 216, 226),
        .border_width = uiPx(state, 1),
        .padding = uiEdgesSymmetric(state, 10, 6),
        .border_radius = uiPx(state, 5),
    };
}

pub fn fileManagerTextInputStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgb(255, 255, 255),
        .border = .rgb(203, 210, 223),
        .border_width = uiPx(state, 1),
        .padding = uiEdgesSymmetric(state, 10, 6),
        .border_radius = uiPx(state, 5),
    };
}

pub fn fileManagerRenameInputStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgb(255, 255, 255),
        .fg = fileManagerTheme(state).fg,
        .border = fileManagerTheme(state).accent,
        .border_width = uiPx(state, 1),
        .padding = uiEdgesSymmetric(state, 4, 1),
        .border_radius = uiPx(state, 3),
    };
}

pub fn fileManagerMenuBarStyle(state: *const State) goop.Style {
    return .{
        .bg = fileManagerChromeColor(),
        .border_width = 0,
        .padding = uiEdgesSymmetric(state, 6, 2),
        .spacing = uiPx(state, 0),
        .border_radius = 0,
    };
}

pub fn fileManagerMenuStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .padding = uiEdgesSymmetric(state, 6, 2),
        .border_radius = uiPx(state, 2),
    };
}

pub fn fileManagerMenuRootButtonStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .padding = uiEdgesSymmetric(state, 6, 2),
        .border_radius = uiPx(state, 2),
    };
}

pub fn fileManagerMenuPopupStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgb(255, 255, 255),
        .border = .rgb(203, 210, 223),
        .border_width = uiPx(state, 1),
        .padding = uiEdgesSymmetric(state, 6, 6),
        .spacing = 0,
        .border_radius = uiPx(state, 8),
    };
}

pub fn fileManagerMenuItemStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .padding = uiEdgesSymmetric(state, 10, 6),
        .border_radius = uiPx(state, 4),
    };
}

pub fn fileManagerSectionLabelStyle(state: *const State) goop.Style {
    return .{
        .fg = fileManagerMutedTextColor(),
        .font_size = uiPx(state, 13),
    };
}

pub fn fileManagerFolderTreeStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .padding = uiEdgesAll(state, 0),
        .spacing = 0,
        .border_radius = 0,
    };
}

pub fn fileManagerFolderTreeItemStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .font_size = uiPx(state, 14.5),
        .padding = .{
            .top = uiPx(state, 3),
            .right = uiPx(state, 6),
            .bottom = uiPx(state, 3),
            .left = 0,
        },
        .border_radius = uiPx(state, 3),
    };
}

pub fn fileManagerPlaceItemStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .font_size = uiPx(state, 14.5),
        .padding = uiEdgesSymmetric(state, 6, 4),
        .border_radius = uiPx(state, 3),
    };
}

pub fn fileManagerStatusTextStyle(state: *const State) goop.Style {
    return .{
        .fg = fileManagerMutedTextColor(),
        .font_size = uiPx(state, 12.5),
    };
}

pub fn fileManagerShellStyle(state: *const State) goop.Style {
    return .{
        .bg = fileManagerShellColor(),
        .border_width = 0,
        .padding = uiEdgesAll(state, 0),
        .spacing = 0,
        .border_radius = 0,
    };
}

pub fn fileManagerToolbarStyle(state: *const State) goop.Style {
    return .{
        .bg = fileManagerChromeColor(),
        .border_width = 0,
        .padding = uiEdgesSymmetric(state, 10, 9),
        .spacing = uiPx(state, 8),
        .border_radius = 0,
    };
}

pub fn fileManagerPaneStyle(state: *const State, bg: goop.Color) goop.Style {
    return .{
        .bg = bg,
        .border_width = 0,
        .padding = uiEdgesAll(state, 0),
        .spacing = 0,
        .border_radius = 0,
    };
}

pub fn fileManagerPaneHeaderStyle(state: *const State) goop.Style {
    return .{
        .bg = fileManagerPanelHeaderColor(),
        .border_width = 0,
        .padding = uiEdgesSymmetric(state, 12, 8),
        .spacing = uiPx(state, 6),
        .border_radius = 0,
    };
}

pub fn fileManagerDetailContentStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .padding = uiEdgesAll(state, 0),
        .spacing = uiPx(state, 8),
        .border_radius = 0,
    };
}

pub fn fileManagerPreviewFrameStyle(state: *const State) goop.Style {
    return .{
        .bg = .rgb(255, 255, 255),
        .border = .rgb(214, 220, 228),
        .border_width = 1,
        .padding = uiEdgesSymmetric(state, 12, 10),
        .spacing = 0,
        .border_radius = uiPx(state, 6),
    };
}

pub fn fileManagerDetailTitleStyle(state: *const State) goop.Style {
    return .{
        .fg = .rgb(20, 25, 33),
        .font_size = detailTitleFontSizePx(state),
    };
}

pub fn fileManagerDetailMetaStyle(state: *const State) goop.Style {
    return .{
        .fg = fileManagerMutedTextColor(),
        .font_size = detailCaptionFontSizePx(state),
    };
}

pub fn fileManagerDetailHintStyle(state: *const State) goop.Style {
    return .{
        .fg = fileManagerMutedTextColor(),
        .font_size = detailCaptionFontSizePx(state),
    };
}

pub fn fileManagerPreviewBodyStyle(state: *const State) goop.Style {
    return .{
        .fg = .rgb(34, 40, 48),
        .font_size = previewBodyFontSizePx(state),
    };
}

pub fn fileManagerGutterStyle(state: *const State) goop.Style {
    return .{
        .bg = fileManagerShellColor(),
        .border_width = 0,
        .padding = uiEdgesAll(state, 0),
        .spacing = 0,
        .border_radius = 0,
    };
}
