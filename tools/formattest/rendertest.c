// Draws frames with the app's libmpv through mpv's software renderer (the same subtitle
// renderer the app uses) and counts subtitle pixels on a black picture. Proves subtitles are
// really drawn, not just decoded: PGS, DVB, SRT, coloured ASS.
//   rendertest [--fonts DIR FAMILY] file...
#include <mpv/client.h>
#include <mpv/render.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int wait_for(mpv_handle *h, mpv_event_id id, double seconds) {
    for (double t = 0; t < seconds; t += 0.05) {
        mpv_event *e = mpv_wait_event(h, 0.05);
        if (e->event_id == id) return 1;
        if (e->event_id == MPV_EVENT_END_FILE) return 0;
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *fontsDir = NULL, *family = NULL;
    int first = 1, failures = 0;
    if (argc > 3 && strcmp(argv[1], "--fonts") == 0) { fontsDir = argv[2]; family = argv[3]; first = 4; }
    printf("Subtitle render test (%s)\n", fontsDir ? "with the app's fonts" : "no fonts given");
    for (int i = first; i < argc; i++) {
        const char *file = argv[i];
        mpv_handle *h = mpv_create();
        mpv_set_option_string(h, "vo", "libmpv");
        mpv_set_option_string(h, "ao", "null");
        mpv_set_option_string(h, "hwdec", "no");
        mpv_set_option_string(h, "keep-open", "yes");
        mpv_set_option_string(h, "terminal", "no");
        // The app's subtitle options.
        mpv_set_option_string(h, "sub-auto", "no");
        mpv_set_option_string(h, "embeddedfonts", "yes");
        mpv_set_option_string(h, "sub-ass-override", "scale");
        mpv_set_option_string(h, "sub-font-size", "52");
        mpv_set_option_string(h, "sub-border-style", "outline-and-shadow");
        mpv_set_option_string(h, "sub-border-size", "3");
        if (fontsDir) {
            mpv_set_option_string(h, "sub-fonts-dir", fontsDir);
            mpv_set_option_string(h, "sub-font", family);
            mpv_set_option_string(h, "osd-font", family);
        }
        if (mpv_initialize(h) < 0) { printf("FAIL %s: mpv_initialize\n", file); failures++; continue; }
        mpv_render_param cp[] = {{MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_SW}, {0}};
        mpv_render_context *ctx = NULL;
        int rc = mpv_render_context_create(&ctx, h, cp);
        if (rc < 0) { printf("FAIL %s: software renderer unavailable (%s)\n", file, mpv_error_string(rc)); failures++; mpv_terminate_destroy(h); continue; }

        const char *cmd[] = {"loadfile", file, NULL};
        mpv_command(h, cmd);
        if (!wait_for(h, MPV_EVENT_FILE_LOADED, 20)) { printf("FAIL %s: not loaded\n", file); failures++; goto done; }
        mpv_set_property_string(h, "sid", "1");
        // Play from the start like a viewer would (a TS seek can skip a subtitle's only packet),
        // then pause inside the subtitle's display time.
        for (int n = 0; n < 200; n++) {
            mpv_wait_event(h, 0.05);
            mpv_render_context_update(ctx);
            double pos = 0;
            if (mpv_get_property(h, "time-pos", MPV_FORMAT_DOUBLE, &pos) >= 0 && pos >= 1.5) break;
            int size0[2] = {64, 36}; size_t stride0 = 64 * 4; unsigned char tmp[64 * 36 * 4];
            mpv_render_param rp0[] = {{MPV_RENDER_PARAM_SW_SIZE, size0}, {MPV_RENDER_PARAM_SW_FORMAT, "rgb0"},
                                      {MPV_RENDER_PARAM_SW_STRIDE, &stride0}, {MPV_RENDER_PARAM_SW_POINTER, tmp}, {0}};
            mpv_render_context_render(ctx, rp0);   // keep frames flowing
        }
        mpv_set_property_string(h, "pause", "yes");

        int size[2] = {1280, 720};
        size_t stride = 1280 * 4;
        unsigned char *buf = calloc(stride * 720, 1);
        long best = 0;
        for (int n = 0; n < 60; n++) {
            mpv_wait_event(h, 0.05);
            mpv_render_context_update(ctx);
            mpv_render_param rp[] = {
                {MPV_RENDER_PARAM_SW_SIZE, size}, {MPV_RENDER_PARAM_SW_FORMAT, "rgb0"},
                {MPV_RENDER_PARAM_SW_STRIDE, &stride}, {MPV_RENDER_PARAM_SW_POINTER, buf}, {0}};
            if (mpv_render_context_render(ctx, rp) < 0) continue;
            long bright = 0;
            for (size_t p = 0; p < stride * 720; p += 4)
                if (buf[p] > 150 || buf[p + 1] > 150 || buf[p + 2] > 150) bright++;
            if (bright > best) best = bright;
        }
        free(buf);
        char *sid = mpv_get_property_string(h, "current-tracks/sub/codec");
        printf("%s %s: %ld subtitle pixels (codec %s)\n", best >= 300 ? "PASS" : "FAIL", file, best, sid ? sid : "none");
        if (sid) mpv_free(sid);
        if (best < 300) failures++;
    done:
        mpv_render_context_free(ctx);
        mpv_terminate_destroy(h);
    }
    printf("%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
