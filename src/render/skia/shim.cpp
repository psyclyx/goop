// C ABI shim over Skia's C++ API.
//
// Everything that crosses this boundary is POD (ints, pointers, byte buffers)
// so the Zig side never touches a C++ type and no std:: object crosses the
// linker seam. This first entry point only proves the toolchain: create a
// raster surface, draw, and read the pixels back. GPU (Ganesh) surface
// creation and the visual-op replay land on top of the same SkCanvas calls.

#include "core/SkCanvas.h"
#include "core/SkColor.h"
#include "core/SkImageInfo.h"
#include "core/SkPaint.h"
#include "core/SkRRect.h"
#include "core/SkRect.h"
#include "core/SkSurface.h"

extern "C" {

// Render a fixed scene into a caller-owned RGBA8 buffer (width*height*4 bytes,
// premultiplied). Returns 0 on success, non-zero on failure.
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
    rrect.setRectXY(
        SkRect::MakeXYWH(20.0f, 20.0f,
                         static_cast<SkScalar>(width) - 40.0f,
                         static_cast<SkScalar>(height) - 40.0f),
        12.0f, 12.0f);
    canvas->drawRRect(rrect, fill);

    if (!canvas->readPixels(info, out_rgba, static_cast<size_t>(width) * 4, 0, 0))
        return 3;

    return 0;
}

}  // extern "C"
