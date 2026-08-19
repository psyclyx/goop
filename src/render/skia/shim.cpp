// C ABI shim over Skia's C++ API.
//
// Everything that crosses this boundary is POD (ints, pointers, byte buffers)
// so the Zig side never touches a C++ type. The shim is compiled by the system
// g++ so it shares libskia's libstdc++ ABI (Ganesh's VulkanBackendContext holds
// a std::function that Skia invokes).
//
// The renderer is GPU: a GrDirectContext is built on a caller-supplied Vulkan
// device (goop_graphics_vulkan), surfaces are Ganesh render targets, and the
// visual vocabulary is replayed onto their SkCanvas.

#include <cstddef>
#include <cstdint>
#include <memory>

#include "core/SkCanvas.h"
#include "core/SkColor.h"
#include "core/SkColorSpace.h"
#include "core/SkFont.h"
#include "core/SkFontMgr.h"
#include "core/SkFontStyle.h"
#include "core/SkFontTypes.h"
#include "core/SkImageInfo.h"
#include "core/SkPaint.h"
#include "core/SkRRect.h"
#include "core/SkRect.h"
#include "core/SkRefCnt.h"
#include "core/SkSurface.h"
#include "core/SkTypeface.h"

#include "gpu/GpuTypes.h"
#include "gpu/ganesh/GrBackendSurface.h"
#include "gpu/ganesh/GrDirectContext.h"
#include "gpu/ganesh/GrTypes.h"
#include "gpu/ganesh/SkSurfaceGanesh.h"
#include "gpu/ganesh/vk/GrVkBackendSurface.h"
#include "gpu/ganesh/vk/GrVkDirectContext.h"
#include "gpu/ganesh/vk/GrVkTypes.h"
#include "gpu/vk/VulkanBackendContext.h"
#include "gpu/vk/VulkanExtensions.h"
#include "gpu/vk/VulkanTypes.h"

#include "ports/SkFontMgr_fontconfig.h"
#include "ports/SkFontScanner_FreeType.h"

#include <vulkan/vulkan.h>

namespace {

// goop packs colors as 0xRRGGBBAA; Skia wants ARGB.
SkColor toSkColor(uint32_t rgba) {
    return SkColorSetARGB(rgba & 0xff, (rgba >> 24) & 0xff, (rgba >> 16) & 0xff,
                          (rgba >> 8) & 0xff);
}

struct Context {
    sk_sp<GrDirectContext> gr;
    std::unique_ptr<skgpu::VulkanExtensions> extensions;
    sk_sp<SkFontMgr> font_mgr;
    sk_sp<SkTypeface> typeface;
};

}  // namespace

extern "C" {

// ── Raster self-test (no GPU) ──────────────────────────────────────────────
// Proves the toolchain independently of Vulkan.
int goop_skia_raster_selftest(int width, int height, unsigned char *out_rgba) {
    if (width <= 0 || height <= 0 || out_rgba == nullptr) return 1;
    const SkImageInfo info = SkImageInfo::Make(
        width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    sk_sp<SkSurface> surface = SkSurfaces::Raster(info);
    if (!surface) return 2;
    SkCanvas *canvas = surface->getCanvas();
    canvas->clear(SkColorSetARGB(255, 20, 22, 28));
    SkPaint fill;
    fill.setAntiAlias(true);
    fill.setColor(SkColorSetARGB(255, 60, 130, 220));
    SkRRect rrect;
    rrect.setRectXY(SkRect::MakeXYWH(20.0f, 20.0f, width - 40.0f, height - 40.0f),
                    12.0f, 12.0f);
    canvas->drawRRect(rrect, fill);
    if (!canvas->readPixels(info, out_rgba, static_cast<size_t>(width) * 4, 0, 0))
        return 3;
    return 0;
}

// ── GPU (Ganesh-on-Vulkan) context ─────────────────────────────────────────
void *goop_skia_context_create(void *instance, void *physical_device,
                               void *device, void *queue,
                               uint32_t graphics_queue_index,
                               void *get_instance_proc_addr) {
    auto gip = reinterpret_cast<PFN_vkGetInstanceProcAddr>(get_instance_proc_addr);
    if (gip == nullptr) return nullptr;

    auto vk_instance = static_cast<VkInstance>(instance);
    auto gdp = reinterpret_cast<PFN_vkGetDeviceProcAddr>(
        gip(vk_instance, "vkGetDeviceProcAddr"));
    if (gdp == nullptr) return nullptr;

    skgpu::VulkanGetProc get_proc =
        [gip, gdp](const char *name, VkInstance inst,
                   VkDevice dev) -> PFN_vkVoidFunction {
        if (dev != VK_NULL_HANDLE) return gdp(dev, name);
        return gip(inst, name);
    };

    // Headless device: no instance/device extensions enabled.
    auto extensions = std::make_unique<skgpu::VulkanExtensions>();

    skgpu::VulkanBackendContext backend;
    backend.fInstance = vk_instance;
    backend.fPhysicalDevice = static_cast<VkPhysicalDevice>(physical_device);
    backend.fDevice = static_cast<VkDevice>(device);
    backend.fQueue = static_cast<VkQueue>(queue);
    backend.fGraphicsQueueIndex = graphics_queue_index;
    backend.fMaxAPIVersion = VK_API_VERSION_1_2;
    backend.fVkExtensions = extensions.get();
    backend.fGetProc = get_proc;

    sk_sp<GrDirectContext> gr = GrDirectContexts::MakeVulkan(backend);
    if (!gr) return nullptr;

    auto ctx = new Context();
    ctx->gr = std::move(gr);
    ctx->extensions = std::move(extensions);
    ctx->font_mgr = SkFontMgr_New_FontConfig(nullptr, SkFontScanner_Make_FreeType());
    if (ctx->font_mgr)
        ctx->typeface = ctx->font_mgr->legacyMakeTypeface(nullptr, SkFontStyle::Normal());
    return ctx;
}

// CPU raster context: no GrDirectContext. Surfaces are Skia raster surfaces.
// Used when there is no real GPU (e.g. only a software Vulkan device), or when
// GOOP_SKIA_BACKEND=cpu is set.
void *goop_skia_context_create_cpu() {
    auto ctx = new Context();
    ctx->font_mgr = SkFontMgr_New_FontConfig(nullptr, SkFontScanner_Make_FreeType());
    if (ctx->font_mgr)
        ctx->typeface = ctx->font_mgr->legacyMakeTypeface(nullptr, SkFontStyle::Normal());
    return ctx;
}

void goop_skia_context_destroy(void *handle) {
    delete static_cast<Context *>(handle);
}

void goop_skia_flush(void *handle) {
    auto ctx = static_cast<Context *>(handle);
    if (ctx->gr) ctx->gr->flushAndSubmit(GrSyncCpu::kYes);  // raster is immediate
}

// ── Surfaces ────────────────────────────────────────────────────────────────
void *goop_skia_surface_create(void *ctx_handle, int width, int height) {
    auto ctx = static_cast<Context *>(ctx_handle);
    const SkImageInfo info = SkImageInfo::Make(
        width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    sk_sp<SkSurface> surface =
        ctx->gr ? SkSurfaces::RenderTarget(ctx->gr.get(), skgpu::Budgeted::kYes, info)
                : SkSurfaces::Raster(info);
    if (!surface) return nullptr;
    return surface.release();  // owned by the caller until surface_destroy
}

// Wrap a caller-owned VkImage (e.g. a swapchain image) as a Ganesh render
// target. This is the primitive on-screen presentation builds on: a compositor
// hands us the acquired image, Skia renders into it, and the caller presents.
void *goop_skia_surface_wrap_vk_image(void *ctx_handle, void *vk_image,
                                      uint32_t vk_format, int width, int height,
                                      uint32_t usage_flags) {
    auto ctx = static_cast<Context *>(ctx_handle);
    if (!ctx->gr) return nullptr;  // wrapping is meaningful only on the GPU path

    GrVkImageInfo info;
    info.fImage = static_cast<VkImage>(vk_image);
    info.fImageTiling = VK_IMAGE_TILING_OPTIMAL;
    info.fImageLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    info.fFormat = static_cast<VkFormat>(vk_format);
    info.fImageUsageFlags = usage_flags;
    info.fSampleCount = 1;
    info.fLevelCount = 1;
    info.fCurrentQueueFamily = VK_QUEUE_FAMILY_IGNORED;

    GrBackendRenderTarget target =
        GrBackendRenderTargets::MakeVk(width, height, info);
    sk_sp<SkSurface> surface = SkSurfaces::WrapBackendRenderTarget(
        ctx->gr.get(), target, kTopLeft_GrSurfaceOrigin, kRGBA_8888_SkColorType,
        nullptr, nullptr);
    if (!surface) return nullptr;
    return surface.release();
}

void goop_skia_surface_destroy(void *surface) {
    SkSafeUnref(static_cast<SkSurface *>(surface));
}

void *goop_skia_surface_canvas(void *surface) {
    return static_cast<SkSurface *>(surface)->getCanvas();
}

int goop_skia_surface_read_pixels(void *surface, int width, int height,
                                  unsigned char *out_rgba) {
    const SkImageInfo info = SkImageInfo::Make(
        width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    return static_cast<SkSurface *>(surface)->readPixels(
               info, out_rgba, static_cast<size_t>(width) * 4, 0, 0)
               ? 0
               : 1;
}

// ── Visual-op primitives ────────────────────────────────────────────────────
void goop_skia_clear(void *canvas, uint32_t rgba) {
    static_cast<SkCanvas *>(canvas)->clear(toSkColor(rgba));
}

void goop_skia_clip_push(void *canvas, float x, float y, float w, float h) {
    auto c = static_cast<SkCanvas *>(canvas);
    c->save();
    c->clipRect(SkRect::MakeXYWH(x, y, w, h), true);
}

void goop_skia_clip_pop(void *canvas) {
    static_cast<SkCanvas *>(canvas)->restore();
}

void goop_skia_draw_surface(void *canvas, float x, float y, float w, float h,
                            uint32_t fill_rgba, uint32_t border_rgba,
                            float border_width, float corner_radius) {
    auto c = static_cast<SkCanvas *>(canvas);
    SkRRect rrect;
    rrect.setRectXY(SkRect::MakeXYWH(x, y, w, h), corner_radius, corner_radius);
    if ((fill_rgba & 0xff) != 0) {
        SkPaint fill;
        fill.setAntiAlias(true);
        fill.setStyle(SkPaint::kFill_Style);
        fill.setColor(toSkColor(fill_rgba));
        c->drawRRect(rrect, fill);
    }
    if (border_width > 0.0f && (border_rgba & 0xff) != 0) {
        SkPaint stroke;
        stroke.setAntiAlias(true);
        stroke.setStyle(SkPaint::kStroke_Style);
        stroke.setStrokeWidth(border_width);
        stroke.setColor(toSkColor(border_rgba));
        SkRRect inset = rrect;
        inset.inset(border_width * 0.5f, border_width * 0.5f);
        c->drawRRect(inset, stroke);
    }
}

void goop_skia_draw_text(void *ctx_handle, void *canvas, const char *utf8,
                         size_t len, float x, float baseline, float size,
                         uint32_t rgba) {
    auto ctx = static_cast<Context *>(ctx_handle);
    if (!ctx->typeface || len == 0) return;
    SkFont font(ctx->typeface, size);
    font.setEdging(SkFont::Edging::kAntiAlias);
    SkPaint paint;
    paint.setAntiAlias(true);
    paint.setColor(toSkColor(rgba));
    static_cast<SkCanvas *>(canvas)->drawSimpleText(
        utf8, len, SkTextEncoding::kUTF8, x, baseline, font, paint);
}

}  // extern "C"
