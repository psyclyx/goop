#include "goop_chrome.h"

#include <stdio.h>

int main(void) {
    goop_context_t *ctx = goop_context_create(&(goop_context_options_t){
        .width = 320,
        .height = 160,
    });
    goop_chrome_t *chrome = goop_chrome_create();
    if (!ctx || !chrome) {
        goop_chrome_destroy(chrome);
        goop_context_destroy(ctx);
        return 1;
    }

    goop_node_handle_t button = {0};
    if (!goop_context_add_root(ctx, &(goop_control_desc_t){
            .identity = { .element_id = 1 },
            .widget = {
                .kind = GOOP_WIDGET_BUTTON,
                .data.button = { .label = goop_string_from_cstr("Render me") },
            },
        }, &button) ||
        !goop_context_do_layout(ctx, NULL)) {
        goop_chrome_destroy(chrome);
        goop_context_destroy(ctx);
        return 1;
    }

    const goop_chrome_options_t options = {
        .kind = GOOP_CHROME_SCOPE_FULL,
        .include_floating = true,
    };
    goop_visual_list_t visuals = {0};
    if (goop_chrome_prepare(chrome, ctx, &options, &visuals) != GOOP_CHROME_OK ||
        visuals.len == 0) {
        goop_chrome_destroy(chrome);
        goop_context_destroy(ctx);
        return 1;
    }

    size_t text_operations = 0;
    for (size_t i = 0; i < visuals.len; ++i) {
        if (visuals.operations[i].kind == GOOP_VISUAL_TEXT) ++text_operations;
    }
    if (text_operations != 1) {
        fprintf(stderr, "expected one stock Chrome text operation\n");
        goop_chrome_destroy(chrome);
        goop_context_destroy(ctx);
        return 1;
    }

    printf("goop Chrome C example: visual_operations=%zu\n", visuals.len);
    goop_chrome_destroy(chrome);
    goop_context_destroy(ctx);
    return 0;
}
