/*
 * entrypoint.c — static musl C replacement for core/entrypoint.mediamtx.sh.
 *
 * Sources the strimserver env file, applies the SRT passphrase secret
 * fallback, drops the stale normalized-mpegts socket, renders the mediamtx
 * config from the template, and execs /mediamtx at the requested nice
 * level. `--render-only` stops after the render step (used by tests).
 *
 * License: project code (see LICENSE). No GPL.
 */

#include "envfile.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

extern char **environ;

#define DEFAULT_ENV_FILE   "/strimserver.env"
#define DEFAULT_TEMPLATE   "/mediamtx.yaml.template"
#define DEFAULT_OUTPUT     "/mediamtx.yaml"
#define DEFAULT_NICE       "-10"
#define SRT_SECRET_PATH    "/run/secrets/srt-passphrase"
#define MEDIAMTX_BIN       "/mediamtx"

static const char *env_or_default(const char *name, const char *fallback) {
    const char *value = getenv(name);

    if (value == NULL || value[0] == '\0') {
        return fallback;
    }
    return value;
}

/* Mirrors the shell's `SRT_PUBLISH_PASSPHRASE="$(cat /run/secrets/srt-passphrase)"`
 * fallback: only when the variable is unset/empty and the secret exists.
 * Command substitution strips all trailing newlines, so do the same here. */
static int load_srt_secret(char *err, size_t err_cap) {
    const char *pass = getenv("SRT_PUBLISH_PASSPHRASE");
    FILE *f;
    char value[4096];
    size_t len;

    if (pass != NULL && pass[0] != '\0') {
        return 0;
    }
    f = fopen(SRT_SECRET_PATH, "r");
    if (f == NULL) {
        return 0; /* no secret mounted */
    }
    len = fread(value, 1, sizeof value - 1, f);
    if (len == sizeof value - 1 && fgetc(f) != EOF) {
        snprintf(err, err_cap, "secret %s is too large", SRT_SECRET_PATH);
        fclose(f);
        return -1;
    }
    if (ferror(f)) {
        snprintf(err, err_cap, "could not read %s: %s",
                 SRT_SECRET_PATH, strerror(errno));
        fclose(f);
        return -1;
    }
    fclose(f);
    while (len > 0 && (value[len - 1] == '\n' || value[len - 1] == '\r')) {
        len--;
    }
    value[len] = '\0';
    if (setenv("SRT_PUBLISH_PASSPHRASE", value, 1) != 0) {
        snprintf(err, err_cap, "setenv(SRT_PUBLISH_PASSPHRASE) failed: %s",
                 strerror(errno));
        return -1;
    }
    return 0;
}

int main(int argc, char **argv) {
    char err[1024];
    const char *env_file;
    const char *template_path;
    const char *output_path;
    const char *socket_path;
    const char *nice_str;
    int nice_value;
    int render_only = 0;
    char *exec_argv[3];

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--render-only") == 0) {
            render_only = 1;
        }
    }

    /* (a) Source the env file; an absent file is fine (returns 0), a
     * malformed one is a hard error. */
    env_file = env_or_default("STRIMSERVER_ENV_FILE", DEFAULT_ENV_FILE);
    if (source_env_file(env_file, err, sizeof err) != 0) {
        fprintf(stderr, "entrypoint: could not source %s: %s\n",
                env_file, err);
        return 1;
    }

    /* (b) SRT secret fallback. */
    if (load_srt_secret(err, sizeof err) != 0) {
        fprintf(stderr, "entrypoint: %s\n", err);
        return 1;
    }

    /* (c) Drop the stale normalized-mpegts socket; it may not exist. */
    socket_path = getenv("NORMALIZED_MPEGTS_SOCKET");
    if (socket_path != NULL) {
        unlink(socket_path);
    }

    /* (d) Render the mediamtx config. Template/output paths are resolved
     * after sourcing so overrides inside the env file are honored too. */
    template_path = env_or_default("STRIMSERVER_TEMPLATE", DEFAULT_TEMPLATE);
    output_path = env_or_default("STRIMSERVER_OUTPUT", DEFAULT_OUTPUT);
    if (expand_template_file(template_path, output_path, err, sizeof err) !=
        0) {
        fprintf(stderr, "entrypoint: %s\n", err);
        return 1;
    }

    if (render_only) {
        return 0;
    }

    /* (e) Adopt the requested nice level (the old /usr/bin/nice -n). */
    nice_str = getenv("MEDIAMTX_NICE");
    nice_value = (nice_str != NULL) ? atoi(nice_str) : atoi(DEFAULT_NICE);
    if (setpriority(PRIO_PROCESS, 0, nice_value) != 0) {
        fprintf(stderr, "entrypoint: warning: setpriority(%d) failed: %s\n",
                nice_value, strerror(errno));
    }

    /* (f) Replace this process with mediamtx. */
    exec_argv[0] = "mediamtx";
    exec_argv[1] = (char *)output_path;
    exec_argv[2] = NULL;
    execve(MEDIAMTX_BIN, exec_argv, environ);
    fprintf(stderr, "entrypoint: exec %s failed: %s\n",
            MEDIAMTX_BIN, strerror(errno));
    return 1;
}