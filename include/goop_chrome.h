#ifndef GOOP_CHROME_H
#define GOOP_CHROME_H

#include "goop.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct goop_chrome goop_chrome_t;

typedef enum {
    GOOP_VISUAL_SURFACE = 0,
    GOOP_VISUAL_TEXT = 1,
    GOOP_VISUAL_PUSH_CLIP = 2,
    GOOP_VISUAL_POP_CLIP = 3,
    GOOP_VISUAL_ICON = 4,
    GOOP_VISUAL_CUSTOM = 5,
    GOOP_VISUAL_IMAGE = 6,
} goop_visual_operation_kind_t;

typedef enum {
    GOOP_TEXT_ALIGN_START = 0,
    GOOP_TEXT_ALIGN_CENTER = 1,
    GOOP_TEXT_ALIGN_END = 2,
} goop_text_align_t;

typedef enum {
    GOOP_TEXT_OVERFLOW_VISIBLE = 0,
    GOOP_TEXT_OVERFLOW_CLIP = 1,
    GOOP_TEXT_OVERFLOW_ELLIPSIS = 2,
    GOOP_TEXT_OVERFLOW_WRAP = 3,
} goop_text_overflow_t;

typedef struct {
    goop_rect_t bounds;
    goop_color_t color;
    goop_color_t border_color;
    float border_width;
    float corner_radius;
} goop_visual_surface_t;

typedef struct {
    goop_rect_t bounds;
    goop_string_t text;
    goop_color_t color;
    float font_size;
    goop_text_align_t text_align;
    goop_text_overflow_t overflow;
} goop_visual_text_t;

typedef struct {
    goop_rect_t bounds;
    uint32_t kind;
    goop_color_t color;
} goop_visual_icon_t;

typedef enum {
    GOOP_IMAGE_FIT_CONTAIN = 0,
    GOOP_IMAGE_FIT_COVER = 1,
    GOOP_IMAGE_FIT_STRETCH = 2,
} goop_image_fit_t;

typedef struct {
    goop_rect_t bounds;
    uint64_t resource_id;
    uint32_t revision;
    uint32_t width;
    uint32_t height;
    const uint8_t *rgba;
    size_t rgba_len;
    goop_image_fit_t fit;
} goop_visual_image_t;

typedef enum {
    GOOP_CUSTOM_VISUAL_ELEMENT = 0,
    GOOP_CUSTOM_VISUAL_EXPLICIT = 1,
} goop_custom_visual_namespace_t;

typedef struct {
    goop_custom_visual_namespace_t id_namespace;
    uint64_t value;
    goop_rect_t bounds;
} goop_visual_custom_t;

typedef struct {
    goop_visual_operation_kind_t kind;
    union {
        goop_visual_surface_t surface;
        goop_visual_text_t text;
        goop_rect_t push_clip;
        goop_visual_icon_t icon;
        goop_visual_image_t image;
        goop_visual_custom_t custom;
    } data;
} goop_visual_operation_t;

typedef struct {
    const goop_visual_operation_t *operations;
    size_t len;
} goop_visual_list_t;

typedef enum {
    GOOP_CHROME_SCOPE_FULL = 0,
    GOOP_CHROME_SCOPE_POPUP = 1,
} goop_chrome_scope_kind_t;

typedef struct {
    goop_chrome_scope_kind_t kind;
    bool include_floating;
    goop_element_id_t popup_element;
} goop_chrome_options_t;

typedef enum {
    GOOP_CHROME_OK = 0,
    GOOP_CHROME_INVALID_ARGUMENT = 1,
    GOOP_CHROME_OUT_OF_MEMORY = 2,
    GOOP_CHROME_UNKNOWN_POPUP_ELEMENT = 3,
    GOOP_CHROME_MISSING_CUSTOM_VISUAL_ID = 4,
} goop_chrome_result_t;

goop_chrome_t *goop_chrome_create(void);
void goop_chrome_destroy(goop_chrome_t *chrome);
void goop_chrome_invalidate(goop_chrome_t *chrome);

/* Preparing a dirty revision may allocate. Returned operations borrow Chrome
 * storage and context-owned text. They remain valid only until a context
 * mutation, dirty preparation, explicit invalidation, or destruction of
 * either owner. */
goop_chrome_result_t goop_chrome_prepare(
    goop_chrome_t *chrome,
    const goop_context_t *ctx,
    const goop_chrome_options_t *options,
    goop_visual_list_t *out_visuals);

#ifdef __cplusplus
}
#endif

#endif
