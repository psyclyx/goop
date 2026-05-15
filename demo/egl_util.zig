const std = @import("std");

pub const egl = @cImport({
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
});

pub fn windowSurfaceAttribs(display: egl.EGLDisplay) [3]egl.EGLint {
    if (!supportsSrgbSurface(display)) return .{ egl.EGL_NONE, 0, 0 };
    return .{
        egl.EGL_GL_COLORSPACE,
        egl.EGL_GL_COLORSPACE_SRGB,
        egl.EGL_NONE,
    };
}

pub fn linearWindowSurfaceAttribs() [1]egl.EGLint {
    return .{egl.EGL_NONE};
}

pub fn pbufferSurfaceAttribs(display: egl.EGLDisplay, width: u32, height: u32) [7]egl.EGLint {
    if (!supportsSrgbSurface(display)) {
        return .{
            egl.EGL_WIDTH,
            @intCast(width),
            egl.EGL_HEIGHT,
            @intCast(height),
            egl.EGL_NONE,
            0,
            0,
        };
    }
    return .{
        egl.EGL_WIDTH,
        @intCast(width),
        egl.EGL_HEIGHT,
        @intCast(height),
        egl.EGL_GL_COLORSPACE,
        egl.EGL_GL_COLORSPACE_SRGB,
        egl.EGL_NONE,
    };
}

pub fn linearPbufferSurfaceAttribs(width: u32, height: u32) [5]egl.EGLint {
    return .{
        egl.EGL_WIDTH,
        @intCast(width),
        egl.EGL_HEIGHT,
        @intCast(height),
        egl.EGL_NONE,
    };
}

pub fn surfaceIsSrgb(display: egl.EGLDisplay, surface: egl.EGLSurface) bool {
    var colorspace: egl.EGLint = 0;
    if (egl.eglQuerySurface(display, surface, egl.EGL_GL_COLORSPACE, &colorspace) == 0) return false;
    return colorspace == egl.EGL_GL_COLORSPACE_SRGB;
}

fn supportsSrgbSurface(display: egl.EGLDisplay) bool {
    if (versionAtLeast(display, 1, 5)) return true;
    const exts_ptr = egl.eglQueryString(display, egl.EGL_EXTENSIONS) orelse return false;
    return hasExtension(std.mem.span(exts_ptr), "EGL_KHR_gl_colorspace");
}

fn versionAtLeast(display: egl.EGLDisplay, min_major: u32, min_minor: u32) bool {
    const version_ptr = egl.eglQueryString(display, egl.EGL_VERSION) orelse return false;
    const version = std.mem.span(version_ptr);
    var fields = std.mem.tokenizeAny(u8, version, ". ");
    const major_text = fields.next() orelse return false;
    const minor_text = fields.next() orelse return false;
    const major = std.fmt.parseInt(u32, major_text, 10) catch return false;
    const minor = std.fmt.parseInt(u32, minor_text, 10) catch return false;
    return major > min_major or (major == min_major and minor >= min_minor);
}

pub fn hasExtension(exts: []const u8, needle: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, exts, ' ');
    while (it.next()) |ext| {
        if (std.mem.eql(u8, ext, needle)) return true;
    }
    return false;
}
