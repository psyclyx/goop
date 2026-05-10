#include "goop.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static bool push_mouse_click(goop_context_t *ctx, goop_rect_t rect) {
    const float x = rect.x + (rect.w * 0.5f);
    const float y = rect.y + (rect.h * 0.5f);

    const goop_event_t press = {
        .kind = GOOP_EVENT_MOUSE_BUTTON,
        .data.mouse_button = {
            .button = GOOP_MOUSE_LEFT,
            .state = GOOP_BUTTON_PRESSED,
            .x = x,
            .y = y,
            .timestamp_ms = 1,
        },
    };
    const goop_event_t release = {
        .kind = GOOP_EVENT_MOUSE_BUTTON,
        .data.mouse_button = {
            .button = GOOP_MOUSE_LEFT,
            .state = GOOP_BUTTON_RELEASED,
            .x = x,
            .y = y,
            .timestamp_ms = 2,
        },
    };

    return goop_context_push_event(ctx, &press) && goop_context_push_event(ctx, &release);
}

static bool push_text(goop_context_t *ctx, uint32_t codepoint) {
    const goop_event_t text = {
        .kind = GOOP_EVENT_TEXT,
        .data.text = {
            .codepoint = codepoint,
        },
    };
    return goop_context_push_event(ctx, &text);
}

typedef struct {
    size_t rect;
    size_t text;
    size_t clip;
    size_t icon;
    size_t custom;
    size_t unknown;
} draw_summary_t;

static draw_summary_t summarize_draw_list(const goop_draw_list_t *draw_list) {
    draw_summary_t summary = {0};

    for (size_t i = 0; i < draw_list->len; ++i) {
        switch (draw_list->commands[i].kind) {
            case GOOP_DRAW_RECT:
                ++summary.rect;
                break;
            case GOOP_DRAW_TEXT:
                ++summary.text;
                break;
            case GOOP_DRAW_CLIP:
                ++summary.clip;
                break;
            case GOOP_DRAW_ICON:
                ++summary.icon;
                break;
            case GOOP_DRAW_CUSTOM:
                ++summary.custom;
                break;
            default:
                ++summary.unknown;
                break;
        }
    }

    return summary;
}

int main(void) {
    goop_context_t *ctx = goop_context_create(&(goop_context_options_t){
        .width = 480,
        .height = 240,
    });
    if (!ctx) {
        fprintf(stderr, "failed to create goop context\n");
        return 1;
    }

    goop_node_handle_t root = {0};
    if (!goop_context_add_root(ctx, &(goop_widget_t){
            .kind = GOOP_WIDGET_CONTAINER,
            .data.container = { .direction = GOOP_DIRECTION_COLUMN },
        }, &root)) {
        fprintf(stderr, "failed to add root container\n");
        goop_context_destroy(ctx);
        return 1;
    }

    goop_node_handle_t input = {0};
    if (!goop_context_add_child(ctx, root, &(goop_widget_t){
            .kind = GOOP_WIDGET_TEXT_INPUT,
            .data.text_input = {
                .placeholder = goop_string_from_cstr("Name"),
                .value = goop_string_from_cstr(""),
            },
        }, &input)) {
        fprintf(stderr, "failed to add text input\n");
        goop_context_destroy(ctx);
        return 1;
    }

    goop_node_handle_t button = {0};
    if (!goop_context_add_child(ctx, root, &(goop_widget_t){
            .kind = GOOP_WIDGET_BUTTON,
            .data.button = { .label = goop_string_from_cstr("Apply") },
        }, &button)) {
        fprintf(stderr, "failed to add button\n");
        goop_context_destroy(ctx);
        return 1;
    }

    if (!goop_context_do_layout(ctx, NULL)) {
        fprintf(stderr, "layout failed\n");
        goop_context_destroy(ctx);
        return 1;
    }

    goop_rect_t input_rect = {0};
    goop_rect_t button_rect = {0};
    if (!goop_context_layout_rect(ctx, input, &input_rect) ||
        !goop_context_layout_rect(ctx, button, &button_rect)) {
        fprintf(stderr, "failed to query layout rects\n");
        goop_context_destroy(ctx);
        return 1;
    }

    if (!goop_context_clear_clicked_flags(ctx) ||
        !push_mouse_click(ctx, input_rect) ||
        !push_text(ctx, 'R') ||
        !push_text(ctx, 'e') ||
        !push_text(ctx, 'n') ||
        !push_text(ctx, 0x00E9) ||
        !push_mouse_click(ctx, button_rect) ||
        !goop_context_process_events(ctx)) {
        fprintf(stderr, "failed to drive input events\n");
        goop_context_destroy(ctx);
        return 1;
    }

    const goop_string_t value = goop_context_text_input_value(ctx, input);
    const bool clicked = goop_context_was_clicked(ctx, button);

    if (!clicked || value.len != 5 || !value.ptr ||
        value.ptr[0] != 'R' || value.ptr[1] != 'e' || value.ptr[2] != 'n' ||
        (unsigned char)value.ptr[3] != 0xC3 || (unsigned char)value.ptr[4] != 0xA9) {
        fprintf(stderr, "unexpected widget state after event processing\n");
        goop_context_destroy(ctx);
        return 1;
    }

    goop_draw_list_t draw_list = {0};
    if (!goop_context_generate_draw_list(ctx, &draw_list) || draw_list.len == 0) {
        fprintf(stderr, "failed to generate draw list\n");
        goop_context_destroy(ctx);
        return 1;
    }

    printf("goop c example: text=%.*s clicked=%d draw_commands=%zu\n",
           (int)value.len, value.ptr, clicked ? 1 : 0, draw_list.len);

    const draw_summary_t summary = summarize_draw_list(&draw_list);
    printf("draw summary: rect=%zu text=%zu clip=%zu icon=%zu custom=%zu\n",
           summary.rect, summary.text, summary.clip, summary.icon, summary.custom);

    if (summary.unknown != 0) {
        fprintf(stderr,
                "draw list contains %zu commands with unknown kind — "
                "C header is likely out of sync with c_api.zig\n",
                summary.unknown);
        goop_context_free_draw_list(ctx, &draw_list);
        goop_context_destroy(ctx);
        return 1;
    }

    if (summary.rect + summary.text + summary.clip + summary.icon + summary.custom != draw_list.len) {
        fprintf(stderr, "draw summary did not classify every command\n");
        goop_context_free_draw_list(ctx, &draw_list);
        goop_context_destroy(ctx);
        return 1;
    }

    if (summary.text < 1) {
        fprintf(stderr,
                "expected at least one text command (button label), got %zu — "
                "draw command layout may be misaligned\n",
                summary.text);
        goop_context_free_draw_list(ctx, &draw_list);
        goop_context_destroy(ctx);
        return 1;
    }

    bool found_button_label = false;
    for (size_t i = 0; i < draw_list.len; ++i) {
        if (draw_list.commands[i].kind != GOOP_DRAW_TEXT) continue;
        const goop_draw_text_t *t = &draw_list.commands[i].data.text;
        if (t->text.len == 5 && t->text.ptr != NULL &&
            memcmp(t->text.ptr, "Apply", 5) == 0) {
            found_button_label = true;
            break;
        }
    }
    if (!found_button_label) {
        fprintf(stderr,
                "expected a text command with content \"Apply\" — "
                "goop_draw_text_t field layout likely diverged from c_api.zig\n");
        goop_context_free_draw_list(ctx, &draw_list);
        goop_context_destroy(ctx);
        return 1;
    }

    goop_context_free_draw_list(ctx, &draw_list);
    goop_context_destroy(ctx);
    return 0;
}
