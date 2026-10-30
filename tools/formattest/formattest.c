// Format test: opens each file with the same libmpv build JellyReco ships (MPVUI's Libmpv),
// decodes video, then switches through every audio and subtitle track and checks each one
// gets a working decoder. Exit code = number of failed files.
#include <mpv/client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int errors_seen = 0;
static char last_error[512];

static void drain(mpv_handle *h, double seconds, int *loaded, int *ended_error) {
    double until = now() + seconds;
    while (now() < until) {
        mpv_event *e = mpv_wait_event(h, 0.05);
        if (e->event_id == MPV_EVENT_NONE) continue;
        if (e->event_id == MPV_EVENT_FILE_LOADED && loaded) *loaded = 1;
        if (e->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *ef = e->data;
            if (ef->reason == MPV_END_FILE_REASON_ERROR && ended_error) {
                *ended_error = 1;
                snprintf(last_error, sizeof last_error, "end-file error: %s", mpv_error_string(ef->error));
            }
        }
        if (e->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *m = e->data;
            if (strstr(m->text, "Failed to initialize") || strstr(m->text, "Could not open codec") ||
                strstr(m->text, "No decoder") || strstr(m->text, "could not be decoded") ||
                strstr(m->text, "Unsupported codec") || strstr(m->text, "not found")) {
                errors_seen++;
                snprintf(last_error, sizeof last_error, "[%s] %s", m->prefix, m->text);
                size_t n = strlen(last_error);
                if (n && last_error[n - 1] == '\n') last_error[n - 1] = 0;
            }
        }
    }
}

static int has_decoder(mpv_handle *h, const char *type) {
    char prop[64];
    snprintf(prop, sizeof prop, "current-tracks/%s/decoder-desc", type);
    char *v = mpv_get_property_string(h, prop);
    int ok = v && *v;
    if (v) mpv_free(v);
    return ok;
}

static int test_file(const char *path) {
    mpv_handle *h = mpv_create();
    if (!h) { printf("FAIL %s: mpv_create\n", path); return 1; }
    mpv_set_option_string(h, "vo", "null");
    mpv_set_option_string(h, "ao", "null");
    mpv_set_option_string(h, "hwdec", "no");
    mpv_set_option_string(h, "untimed", "yes");
    mpv_set_option_string(h, "sub-auto", "no");
    mpv_set_option_string(h, "keep-open", "yes");
    mpv_set_option_string(h, "terminal", "no");
    mpv_request_log_messages(h, "v");
    if (mpv_initialize(h) < 0) { printf("FAIL %s: initialize\n", path); return 1; }

    errors_seen = 0;
    last_error[0] = 0;
    const char *cmd[] = {"loadfile", path, NULL};
    mpv_command(h, cmd);
    int loaded = 0, ended_error = 0;
    double deadline = now() + 20;
    while (!loaded && !ended_error && now() < deadline) drain(h, 0.2, &loaded, &ended_error);
    if (!loaded) {
        printf("FAIL %s: did not load (%s)\n", path, last_error);
        mpv_terminate_destroy(h);
        return 1;
    }
    drain(h, 1.0, NULL, &ended_error);

    int failures = 0;
    int64_t count = 0;
    mpv_get_property(h, "track-list/count", MPV_FORMAT_INT64, &count);
    int video = 0, audio = 0, subs = 0;
    for (int64_t i = 0; i < count; i++) {
        char prop[64];
        snprintf(prop, sizeof prop, "track-list/%lld/type", (long long)i);
        char *type = mpv_get_property_string(h, prop);
        snprintf(prop, sizeof prop, "track-list/%lld/id", (long long)i);
        int64_t id = 0;
        mpv_get_property(h, prop, MPV_FORMAT_INT64, &id);
        snprintf(prop, sizeof prop, "track-list/%lld/codec", (long long)i);
        char *codec = mpv_get_property_string(h, prop);
        if (!type) continue;
        const char *opt = strcmp(type, "audio") == 0 ? "aid" : strcmp(type, "sub") == 0 ? "sid" : "vid";
        char idstr[32];
        snprintf(idstr, sizeof idstr, "%lld", (long long)id);
        errors_seen = 0;
        mpv_set_property_string(h, opt, idstr);
        drain(h, 1.2, NULL, &ended_error);
        int ok;
        if (strcmp(type, "sub") == 0) {
            // Subtitles: jump to where the test line is shown and read the text mpv produced.
            // (ASS goes straight to libass with no separate decoder, so the text is the real proof.)
            const char *seek[] = {"seek", "2", "absolute+exact", NULL};
            mpv_command(h, seek);
            mpv_set_property_string(h, "pause", "yes");
            drain(h, 1.0, NULL, &ended_error);
            char *text = mpv_get_property_string(h, "sub-text");
            ok = text && strstr(text, "JellyReco") && errors_seen == 0 && !ended_error;
            if (!ok && !last_error[0]) snprintf(last_error, sizeof last_error, "no subtitle text (got \"%s\")", text ? text : "null");
            if (text) mpv_free(text);
            mpv_set_property_string(h, "pause", "no");
        } else {
            ok = has_decoder(h, type) && errors_seen == 0 && !ended_error;
        }
        if (strcmp(type, "video") == 0) video++;
        else if (strcmp(type, "audio") == 0) audio++;
        else subs++;
        printf("  %-5s #%lld %-14s %s%s%s\n", type, (long long)id, codec ? codec : "?", ok ? "ok" : "FAILED",
               ok ? "" : " - ", ok ? "" : last_error);
        if (!ok) failures++;
        if (codec) mpv_free(codec);
        mpv_free(type);
    }
    // Video must actually advance.
    double pos = 0;
    mpv_get_property(h, "time-pos", MPV_FORMAT_DOUBLE, &pos);
    if (video > 0 && pos <= 0) { printf("  video did not advance\n"); failures++; }
    printf("%s %s (%d video, %d audio, %d subtitle tracks)\n\n", failures ? "FAIL" : "PASS", path, video, audio, subs);
    mpv_terminate_destroy(h);
    return failures ? 1 : 0;
}

int main(int argc, char **argv) {
    int failed = 0;
    for (int i = 1; i < argc; i++) failed += test_file(argv[i]);
    printf("%d of %d files failed\n", failed, argc - 1);
    return failed;
}
