/*
 * notify_stub.c — test-only static HTTP listener for the notify smoke test.
 *
 * Listens on 127.0.0.1:<port>, reads each request (headers + body), prints
 * the raw request to stdout, and answers 200 OK by default, or 500 when the
 * request line or body mentions `bandwidthtest` or `fail`. Serves a fixed
 * number of connections then exits 0.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define MAX_REQUESTS 4
#define REQUEST_CAP  8192

/* Case-insensitive search for needle within hay[0, len). */
static const char *ci_search(const char *hay, size_t len, const char *needle) {
    size_t nlen = strlen(needle);

    if (nlen == 0) {
        return hay;
    }
    if (len < nlen) {
        return NULL;
    }
    for (size_t i = 0; i + nlen <= len; i++) {
        size_t k;

        for (k = 0; k < nlen; k++) {
            char a = hay[i + k];
            char b = needle[k];

            if (a >= 'A' && a <= 'Z') {
                a += 'a' - 'A';
            }
            if (b >= 'A' && b <= 'Z') {
                b += 'a' - 'A';
            }
            if (a != b) {
                break;
            }
        }
        if (k == nlen) {
            return hay + i;
        }
    }
    return NULL;
}

/* Request body length announced by the Content-Length header, or 0 when
 * absent. Only the header section is scanned. */
static long parse_content_length(const char *buf, size_t headers_len) {
    const char *found = ci_search(buf, headers_len, "Content-Length:");
    char *end;
    long value;

    if (found == NULL) {
        return 0;
    }
    found += strlen("Content-Length:");
    value = strtol(found, &end, 10);
    if (end == found || value < 0) {
        return 0;
    }
    return value;
}

/* Pointer to the start of "\r\n\r\n" within buf[0, len), or NULL. */
static char *find_headers_end(const char *buf, size_t len) {
    if (len < 4) {
        return NULL;
    }
    for (size_t i = 0; i + 4 <= len; i++) {
        if (buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' &&
            buf[i + 3] == '\n') {
            return (char *)buf + i;
        }
    }
    return NULL;
}

int main(int argc, char **argv) {
    long port;
    char *port_end;
    int listener;
    struct sockaddr_in addr;
    int reuse = 1;

    if (argc < 2) {
        fprintf(stderr, "usage: notify_stub <port>\n");
        return 2;
    }
    port = strtol(argv[1], &port_end, 10);
    if (*port_end != '\0' || port < 1 || port > 65535) {
        fprintf(stderr, "usage: notify_stub <port>\n");
        return 2;
    }

    signal(SIGPIPE, SIG_IGN); /* never die because a client went away */

    listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) {
        fprintf(stderr, "notify_stub: socket: %s\n", strerror(errno));
        return 1;
    }
    (void)setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof reuse);
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) != 1 ||
        bind(listener, (struct sockaddr *)&addr, sizeof addr) != 0) {
        fprintf(stderr, "notify_stub: bind 127.0.0.1:%ld: %s\n", port,
                strerror(errno));
        close(listener);
        return 1;
    }
    if (listen(listener, 4) != 0) {
        fprintf(stderr, "notify_stub: listen: %s\n", strerror(errno));
        close(listener);
        return 1;
    }

    for (int served = 0; served < MAX_REQUESTS; served++) {
        int conn = accept(listener, NULL, NULL);
        char request[REQUEST_CAP];
        size_t request_len = 0;
        long body_left = -1;
        const char *response;

        if (conn < 0) {
            if (errno == EINTR) {
                served--;
                continue;
            }
            break;
        }
        for (;;) {
            ssize_t n;
            char *headers_end;

            if (request_len == sizeof request - 1) {
                break; /* cap reached; good enough for a test stub */
            }
            n = read(conn, request + request_len,
                     sizeof request - 1 - request_len);
            if (n < 0) {
                if (errno == EINTR) {
                    continue;
                }
                break;
            }
            if (n == 0) {
                break; /* client closed */
            }
            request_len += (size_t)n;
            headers_end = find_headers_end(request, request_len);
            if (headers_end != NULL) {
                size_t headers_len = (size_t)(headers_end - request);
                size_t body_needed;

                if (body_left < 0) {
                    body_left = parse_content_length(request, headers_len);
                }
                body_needed = headers_len + 4 + (size_t)body_left;
                if (request_len >= body_needed) {
                    break; /* full request: headers + body */
                }
            }
        }
        request[request_len] = '\0';

        fwrite(request, 1, request_len, stdout);
        fflush(stdout);

        if (strstr(request, "bandwidthtest") != NULL ||
            strstr(request, "fail") != NULL) {
            response = "HTTP/1.1 500 Internal Server Error\r\n"
                       "Content-Length: 0\r\n"
                       "Connection: close\r\n"
                       "\r\n";
        } else {
            response = "HTTP/1.1 200 OK\r\n"
                       "Content-Length: 0\r\n"
                       "Connection: close\r\n"
                       "\r\n";
        }
        if (write(conn, response, strlen(response)) < 0) {
            /* client may have vanished; nothing to do */
        }
        close(conn);
    }
    close(listener);
    return 0;
}