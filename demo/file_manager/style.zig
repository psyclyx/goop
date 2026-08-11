const std = @import("std");
const goop = @import("goop");

pub fn uiScaleValue(scale: f32, value: f32) f32 {
    return value * scale;
}

pub fn uiPx(ui_scale: f32, value: f32) f32 {
    return uiScaleValue(ui_scale, value);
}

pub fn uiEdgesAll(ui_scale: f32, value: f32) goop.style.Edges {
    return goop.style.Edges.all(uiPx(ui_scale, value));
}

pub fn uiEdgesSymmetric(ui_scale: f32, h: f32, v: f32) goop.style.Edges {
    return goop.style.Edges.symmetric(uiPx(ui_scale, h), uiPx(ui_scale, v));
}

pub fn detailTitleFontSizePx(ui_scale: f32) f32 {
    return uiPx(ui_scale, 16);
}

pub fn detailCaptionFontSizePx(ui_scale: f32) f32 {
    return uiPx(ui_scale, 13);
}

pub fn previewBodyFontSizePx(ui_scale: f32) f32 {
    return uiPx(ui_scale, 13);
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
        // Translucent accent tint over the white row: a ~33% wash that reads
        // clearly as selected while staying lighter than opaque chrome. Renders
        // correctly now that surface fills honor their instance color (see
        // recordUnitRect in snail_adapter).
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

pub fn fileManagerTheme(ui_scale: f32) goop.Theme {
    return fileManagerThemeForScale(ui_scale);
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

pub fn fileManagerToolbarButtonStyle(ui_scale: f32, active: bool, enabled: bool) goop.Style {
    return .{
        .bg = if (active)
            .rgb(222, 233, 249)
        else if (enabled)
            .rgb(247, 249, 252)
        else
            .rgb(240, 243, 247),
        .fg = if (enabled) fileManagerThemeForScale(ui_scale).fg else fileManagerMutedTextColor(),
        .border = if (active)
            fileManagerThemeForScale(ui_scale).accent
        else
            .rgb(209, 216, 226),
        .border_width = uiPx(ui_scale, 1),
        .padding = uiEdgesSymmetric(ui_scale, 10, 6),
        .border_radius = uiPx(ui_scale, 5),
    };
}

pub fn fileManagerTextInputStyle(ui_scale: f32) goop.Style {
    return .{
        .bg = .rgb(255, 255, 255),
        .border = .rgb(203, 210, 223),
        .border_width = uiPx(ui_scale, 1),
        .padding = uiEdgesSymmetric(ui_scale, 10, 6),
        .border_radius = uiPx(ui_scale, 5),
    };
}

pub fn fileManagerRenameInputStyle(ui_scale: f32) goop.Style {
    return .{
        .bg = .rgb(255, 255, 255),
        .fg = fileManagerThemeForScale(ui_scale).fg,
        .border = fileManagerThemeForScale(ui_scale).accent,
        .border_width = uiPx(ui_scale, 1),
        .padding = uiEdgesSymmetric(ui_scale, 4, 1),
        .border_radius = uiPx(ui_scale, 3),
    };
}

pub fn fileManagerMenuBarStyle(ui_scale: f32) goop.Style {
    return .{
        .bg = fileManagerChromeColor(),
        .border_width = 0,
        .padding = uiEdgesSymmetric(ui_scale, 6, 2),
        .spacing = uiPx(ui_scale, 0),
        .border_radius = 0,
    };
}

pub fn fileManagerMenuStyle(ui_scale: f32) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .padding = uiEdgesSymmetric(ui_scale, 6, 2),
        .border_radius = uiPx(ui_scale, 2),
    };
}

pub fn fileManagerMenuRootButtonStyle(ui_scale: f32) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .padding = uiEdgesSymmetric(ui_scale, 6, 2),
        .border_radius = uiPx(ui_scale, 2),
    };
}

pub fn fileManagerMenuPopupStyle(ui_scale: f32) goop.Style {
    return .{
        .bg = .rgb(255, 255, 255),
        .border = .rgb(203, 210, 223),
        .border_width = uiPx(ui_scale, 1),
        .padding = uiEdgesSymmetric(ui_scale, 6, 6),
        .spacing = 0,
        .border_radius = uiPx(ui_scale, 8),
    };
}

pub fn fileManagerMenuItemStyle(ui_scale: f32) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .padding = uiEdgesSymmetric(ui_scale, 10, 6),
        .border_radius = uiPx(ui_scale, 4),
    };
}

pub fn fileManagerSectionLabelStyle(ui_scale: f32) goop.Style {
    return .{
        .fg = fileManagerMutedTextColor(),
        .font_size = uiPx(ui_scale, 13),
    };
}

pub fn fileManagerFolderTreeStyle(ui_scale: f32) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .padding = uiEdgesAll(ui_scale, 0),
        .spacing = 0,
        .border_radius = 0,
    };
}

pub fn fileManagerFolderTreeItemStyle(ui_scale: f32) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .font_size = uiPx(ui_scale, 14.5),
        .padding = .{
            .top = uiPx(ui_scale, 3),
            .right = uiPx(ui_scale, 6),
            .bottom = uiPx(ui_scale, 3),
            .left = 0,
        },
        .border_radius = uiPx(ui_scale, 3),
    };
}

pub fn fileManagerPlaceItemStyle(ui_scale: f32) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .font_size = uiPx(ui_scale, 14.5),
        .padding = uiEdgesSymmetric(ui_scale, 6, 4),
        .border_radius = uiPx(ui_scale, 3),
    };
}

pub fn fileManagerStatusTextStyle(ui_scale: f32) goop.Style {
    return .{
        .fg = fileManagerMutedTextColor(),
        .font_size = uiPx(ui_scale, 12.5),
    };
}

pub fn fileManagerShellStyle(ui_scale: f32) goop.Style {
    return .{
        .bg = fileManagerShellColor(),
        .border_width = 0,
        .padding = uiEdgesAll(ui_scale, 0),
        .spacing = 0,
        .border_radius = 0,
    };
}

pub fn fileManagerToolbarStyle(ui_scale: f32) goop.Style {
    return .{
        .bg = fileManagerChromeColor(),
        .border_width = 0,
        .padding = uiEdgesSymmetric(ui_scale, 10, 9),
        .spacing = uiPx(ui_scale, 8),
        .border_radius = 0,
    };
}

pub fn fileManagerPaneStyle(ui_scale: f32, bg: goop.Color) goop.Style {
    return .{
        .bg = bg,
        .border_width = 0,
        .padding = uiEdgesAll(ui_scale, 0),
        .spacing = 0,
        .border_radius = 0,
    };
}

pub fn fileManagerPaneHeaderStyle(ui_scale: f32) goop.Style {
    return .{
        .bg = fileManagerPanelHeaderColor(),
        .border_width = 0,
        .padding = uiEdgesSymmetric(ui_scale, 12, 8),
        .spacing = uiPx(ui_scale, 6),
        .border_radius = 0,
    };
}

pub fn fileManagerDetailContentStyle(ui_scale: f32) goop.Style {
    return .{
        .bg = .rgba(0, 0, 0, 0),
        .border_width = 0,
        .padding = uiEdgesAll(ui_scale, 0),
        .spacing = uiPx(ui_scale, 8),
        .border_radius = 0,
    };
}

pub fn fileManagerPreviewFrameStyle(ui_scale: f32) goop.Style {
    return .{
        .bg = .rgb(255, 255, 255),
        .border = .rgb(214, 220, 228),
        .border_width = 1,
        .padding = uiEdgesSymmetric(ui_scale, 12, 10),
        .spacing = 0,
        .border_radius = uiPx(ui_scale, 6),
    };
}

pub fn fileManagerDetailTitleStyle(ui_scale: f32) goop.Style {
    return .{
        .fg = .rgb(20, 25, 33),
        .font_size = detailTitleFontSizePx(ui_scale),
    };
}

pub fn fileManagerDetailMetaStyle(ui_scale: f32) goop.Style {
    return .{
        .fg = fileManagerMutedTextColor(),
        .font_size = detailCaptionFontSizePx(ui_scale),
    };
}

pub fn fileManagerDetailHintStyle(ui_scale: f32) goop.Style {
    return .{
        .fg = fileManagerMutedTextColor(),
        .font_size = detailCaptionFontSizePx(ui_scale),
    };
}

pub fn fileManagerPreviewBodyStyle(ui_scale: f32) goop.Style {
    return .{
        .fg = .rgb(34, 40, 48),
        .font_size = previewBodyFontSizePx(ui_scale),
    };
}

pub fn fileManagerGutterStyle(ui_scale: f32) goop.Style {
    return .{
        .bg = fileManagerShellColor(),
        .border_width = 0,
        .padding = uiEdgesAll(ui_scale, 0),
        .spacing = 0,
        .border_radius = 0,
    };
}
