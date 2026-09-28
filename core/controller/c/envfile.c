/*
 * envfile.c — shared env-file parsing + template expansion for the
 * strimserver OCI image's static C binaries.
 *
 * source_env_file(): the old entrypoint.sh's `set -a; . /strimserver.env;
 * set +a`. The file is a KEY="value" listing generated from envspec.go's
 * %q; this parser handles comments, blanks, optional `export` prefixes, and
 * double-quoted values (no shell interpolation — values are plain).
 *
 * expand_template_file(): clean-room replacement for gettext's envsubst
 * (`envsubst < template > output`): substitutes ${VAR}, $VAR (undefined
 * variables become the empty string) and $$ (a literal `$`).
 *
 * License: project code (see LICENSE). No GPL.
 */

#include "envfile.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define STRIM_ENV_LINE_MAX 4096

int source_env_file(const char *path, char *err, size_t err_cap) {
    FILE *f;
    char line[STRIM_ENV_LINE_MAX];

    f = fopen(path, "r");
    if (f == NULL) {
        return 0; /* absent: process env only (Go run() has no env file) */
    }
    while (fgets(line, sizeof line, f) != NULL) {
        char *p = line;
        char *eq;
        char *name;
        char *value;

        /* Trim leading whitespace. */
        while (*p == ' ' || *p == '\t') {
            p++;
        }
        if (*p == '\0' || *p == '\n' || *p == '\r' || *p == '#') {
            continue; /* blank or comment */
        }
        if (strncmp(p, "export ", 7) == 0) {
            p += 7;
            while (*p == ' ' || *p == '\t') {
                p++;
            }
        }
        name = p;
        eq = strchr(p, '=');
        if (eq == NULL) {
            snprintf(err, err_cap, "malformed line in %s: %s", path, line);
            fclose(f);
            return -1;
        }
        *eq = '\0';
        value = eq + 1;

        /* Trim trailing whitespace / newline from the name. */
        {
            char *q = name + strlen(name);
            while (q > name && (q[-1] == ' ' || q[-1] == '\t')) {
                *--q = '\0';
            }
        }
        /* Strip surrounding double quotes from the value. */
        {
            size_t vlen = strlen(value);
            while (vlen > 0 && (value[vlen - 1] == '\n' ||
                                value[vlen - 1] == '\r')) {
                value[--vlen] = '\0';
            }
            if (vlen >= 2 && value[0] == '"' && value[vlen - 1] == '"') {
                value[vlen - 1] = '\0';
                value++;
            }
        }
        if (name[0] == '\0') {
            snprintf(err, err_cap, "malformed line in %s: %s", path, line);
            fclose(f);
            return -1;
        }
        if (setenv(name, value, 1) != 0) {
            snprintf(err, err_cap, "setenv(%s) failed in %s", name, path);
            fclose(f);
            return -1;
        }
    }
    fclose(f);
    return 0;
}

/* -------------------------------------------------------------------------
 * Template expansion (envsubst replacement)
 * ------------------------------------------------------------------------- */

static int is_env_name_start(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

static int is_env_name_char(char c) {
    return is_env_name_start(c) || (c >= '0' && c <= '9');
}

/* A ${...} reference is substituted only when its content is a valid
 * environment variable name ([A-Za-z_][A-Za-z0-9_]*); anything else (e.g.
 * ${VAR:-default}) is left untouched, matching envsubst. */
static int is_env_name_valid(const char *name, size_t len) {
    if (len == 0 || !is_env_name_start(name[0])) {
        return 0;
    }
    for (size_t i = 1; i < len; i++) {
        if (!is_env_name_char(name[i])) {
            return 0;
        }
    }
    return 1;
}

static int write_env_value(const char *name, FILE *out) {
    const char *value = getenv(name);

    if (value != NULL && fputs(value, out) == EOF) {
        return -1;
    }
    return 0;
}

int expand_template_file(const char *template_path, const char *output_path,
                         char *err, size_t err_cap) {
    FILE *in;
    FILE *out;
    char *buf;
    size_t cap;
    size_t len;
    size_t i;

    if (template_path == NULL || output_path == NULL || err == NULL) {
        return -1;
    }
    err[0] = '\0';

    in = fopen(template_path, "r");
    if (in == NULL) {
        snprintf(err, err_cap, "could not open template %s: %s",
                 template_path, strerror(errno));
        return -1;
    }

    /* Read the whole template up front so expansion can look ahead freely
     * ($$, ${VAR} and $VAR all need a lookahead of one or more bytes). */
    cap = 8192;
    len = 0;
    buf = malloc(cap);
    if (buf == NULL) {
        snprintf(err, err_cap, "out of memory reading %s", template_path);
        fclose(in);
        return -1;
    }
    for (;;) {
        size_t n;

        if (len == cap) {
            char *grown;

            cap *= 2;
            grown = realloc(buf, cap);
            if (grown == NULL) {
                snprintf(err, err_cap, "out of memory reading %s",
                         template_path);
                free(buf);
                fclose(in);
                return -1;
            }
            buf = grown;
        }
        n = fread(buf + len, 1, cap - len, in);
        len += n;
        if (n == 0) {
            if (ferror(in)) {
                snprintf(err, err_cap, "could not read %s: %s",
                         template_path, strerror(errno));
                free(buf);
                fclose(in);
                return -1;
            }
            break; /* EOF */
        }
    }
    fclose(in);

    out = fopen(output_path, "w");
    if (out == NULL) {
        snprintf(err, err_cap, "could not open output %s: %s",
                 output_path, strerror(errno));
        free(buf);
        return -1;
    }

    i = 0;
    while (i < len) {
        char c = buf[i];

        if (c != '$') {
            if (fputc(c, out) == EOF) {
                goto write_failed;
            }
            i++;
            continue;
        }
        if (i + 1 >= len) {
            /* A lone trailing '$' is literal. */
            if (fputc('$', out) == EOF) {
                goto write_failed;
            }
            i++;
            continue;
        }
        if (buf[i + 1] == '$') {
            /* $$ -> literal $ */
            if (fputc('$', out) == EOF) {
                goto write_failed;
            }
            i += 2;
            continue;
        }
        if (buf[i + 1] == '{') {
            /* ${VAR} */
            size_t end = i + 2;
            size_t nlen;

            while (end < len && buf[end] != '}') {
                end++;
            }
            nlen = end - (i + 2);
            if (end < len && nlen < 256 &&
                is_env_name_valid(buf + i + 2, nlen)) {
                char name[256];

                memcpy(name, buf + i + 2, nlen);
                name[nlen] = '\0';
                if (write_env_value(name, out) != 0) {
                    goto write_failed;
                }
                i = end + 1;
                continue;
            }
            /* Not a valid ${VAR}: emit '$' and reprocess the rest. */
            if (fputc('$', out) == EOF) {
                goto write_failed;
            }
            i++;
            continue;
        }
        if (is_env_name_start(buf[i + 1])) {
            /* $VAR — the name is the longest run of name characters. */
            size_t end = i + 1;
            size_t nlen;

            while (end < len && is_env_name_char(buf[end])) {
                end++;
            }
            nlen = end - (i + 1);
            if (nlen < 256) {
                char name[256];

                memcpy(name, buf + i + 1, nlen);
                name[nlen] = '\0';
                if (write_env_value(name, out) != 0) {
                    goto write_failed;
                }
                i = end;
                continue;
            }
        }
        /* '$' followed by anything else: literal. */
        if (fputc('$', out) == EOF) {
            goto write_failed;
        }
        i++;
    }

    if (fclose(out) != 0) {
        snprintf(err, err_cap, "could not finish writing %s: %s",
                 output_path, strerror(errno));
        free(buf);
        unlink(output_path);
        return -1;
    }
    free(buf);
    return 0;

write_failed:
    snprintf(err, err_cap, "could not write %s: %s",
             output_path, strerror(errno));
    fclose(out);
    free(buf);
    unlink(output_path); /* never leave a half-rendered output behind */
    return -1;
}