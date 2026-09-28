/*
 * notify.c — static musl C replacement for core/notify.sh.
 *
 * POSTs a controller-compatible PathEvent to the local controller /event
 * endpoint. Intended to be called from mediamtx runOnAvailable/
 * runOnUnavailable hooks inside the FROM scratch image, where /bin/sh and
 * wget are busybox applets (now removed).
 *
 *   path   -- ingress0 | normalized
 *   status -- ready | not-ready | unknown
 *
 * The controller validates these server-side; an invalid path/status or a
 * bad body comes back as a non-2xx, which becomes a non-zero exit here
 * (mirroring wget -q semantics: any connection/HTTP error -> non-zero).
 *
 * License: project code (see LICENSE). No GPL.
 */

#include "envfile.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define CONTROLLER_HOST      "127.0.0.1"
#define ENV_FILE_PATH        "/strimserver.env"
#define RESPONSE_TIMEOUT_SEC 5

/* JSON string values cannot contain raw '"' or control characters; the
 * enum-constrained path/status never contain them, so reject anything that
 * does rather than attempt escaping. */
static int is_json_safe(const char *value) {
    return strchr(value, '"') == NULL && strchr(value, '\n') == NULL &&
           strchr(value, '\r') == NULL;
}

int main(int argc, char **argv) {
    const char *path;
    const char *status;
    const char *port_str;
    char err[256];
    char body[256];
    char request[512];
    char response[4096];
    char *port_end;
    long port;
    int body_len;
    int request_len;
    int fd;
    size_t sent;
    size_t response_len;
    int status_code;
    struct sockaddr_in addr;
    struct timeval timeout;

    if (argc < 3) {
        fprintf(stderr, "usage: notify <path> <status>\n");
        return 2;
    }
    path = argv[1];
    status = argv[2];
    if (!is_json_safe(path) || !is_json_safe(status)) {
        fprintf(stderr,
                "notify: path/status must not contain quotes or newlines\n");
        return 1;
    }

    port_str = getenv("CONTROLLER_HTTP_PORT");
    if (port_str == NULL || port_str[0] == '\0') {
        /* Defensive fallback mirroring notify.sh's own sourcing. */
        if (source_env_file(ENV_FILE_PATH, err, sizeof err) != 0) {
            fprintf(stderr, "notify: could not source %s: %s\n",
                    ENV_FILE_PATH, err);
            return 1;
        }
        port_str = getenv("CONTROLLER_HTTP_PORT");
        if (port_str == NULL || port_str[0] == '\0') {
            fprintf(stderr,
                    "notify: CONTROLLER_HTTP_PORT is not set "
                    "(set it in %s)\n",
                    ENV_FILE_PATH);
            return 1;
        }
    }

    port = strtol(port_str, &port_end, 10);
    if (*port_end != '\0' || port < 1 || port > 65535) {
        fprintf(stderr, "notify: invalid CONTROLLER_HTTP_PORT: %s\n",
                port_str);
        return 1;
    }

    body_len = snprintf(body, sizeof body, "{\"path\":\"%s\",\"status\":\"%s\"}",
                        path, status);
    if (body_len < 0 || (size_t)body_len >= sizeof body) {
        fprintf(stderr, "notify: body too long\n");
        return 1;
    }

    request_len = snprintf(
        request, sizeof request,
        "POST /event HTTP/1.1\r\n"
        "Host: %s:%s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n"
        "\r\n"
        "%s",
        CONTROLLER_HOST, port_str, body_len, body);
    if (request_len < 0 || (size_t)request_len >= sizeof request) {
        fprintf(stderr, "notify: request too long\n");
        return 1;
    }

    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        fprintf(stderr, "notify: socket: %s\n", strerror(errno));
        return 1;
    }
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, CONTROLLER_HOST, &addr.sin_addr) != 1) {
        fprintf(stderr, "notify: bad address %s\n", CONTROLLER_HOST);
        close(fd);
        return 1;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        fprintf(stderr, "notify: connect %s:%s: %s\n", CONTROLLER_HOST,
                port_str, strerror(errno));
        close(fd);
        return 1;
    }

    /* Never hang forever waiting on a stalled controller. */
    timeout.tv_sec = RESPONSE_TIMEOUT_SEC;
    timeout.tv_usec = 0;
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);

    sent = 0;
    while (sent < (size_t)request_len) {
        ssize_t n = write(fd, request + sent, (size_t)request_len - sent);

        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "notify: write: %s\n", strerror(errno));
            close(fd);
            return 1;
        }
        sent += (size_t)n;
    }

    response_len = 0;
    for (;;) {
        ssize_t n = read(fd, response + response_len,
                         sizeof response - response_len);

        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (response_len == 0) {
                fprintf(stderr, "notify: read: %s\n", strerror(errno));
                close(fd);
                return 1;
            }
            break; /* partial response then error: judge what we got */
        }
        if (n == 0) {
            break; /* connection closed by the server */
        }
        response_len += (size_t)n;
        if (response_len == sizeof response) {
            break;
        }
    }
    close(fd);

    if (response_len < sizeof response) {
        response[response_len] = '\0';
    }
    if (sscanf(response, "HTTP/%*d.%*d %d", &status_code) != 1) {
        fprintf(stderr, "notify: malformed HTTP response\n");
        return 1;
    }
    return (status_code >= 200 && status_code < 300) ? 0 : 1;
}