/*
 * ddns-test-server: loopback HTTP test double for the strim-ddns smoke test.
 *
 * Binds 127.0.0.1 on an ephemeral port, prints the chosen port to stdout on
 * a single line (flushed), then serves argv[1] as the fixed response body to
 * every request until killed. Each request's first line is appended to the
 * log file given in argv[2], so the smoke test can assert the query params
 * (host/domain/password/ip) the client actually sent. Mirrors the repo's
 * notify_stub pattern (core/notify_stub.c): a tiny static C double built by
 * the same musl transition, runnable under qemu on any host.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define REQUEST_MAX 8192

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <response-body> <request-log>\n", argv[0]);
        return 2;
    }
    const char *body = argv[1];
    const char *log_path = argv[2];

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) {
        fprintf(stderr, "ddns-test-server: socket: %s\n", strerror(errno));
        return 1;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0; /* ephemeral */
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        fprintf(stderr, "ddns-test-server: bind: %s\n", strerror(errno));
        return 1;
    }
    socklen_t alen = sizeof(addr);
    if (getsockname(srv, (struct sockaddr *)&addr, &alen) != 0) {
        fprintf(stderr, "ddns-test-server: getsockname: %s\n", strerror(errno));
        return 1;
    }
    if (listen(srv, 4) != 0) {
        fprintf(stderr, "ddns-test-server: listen: %s\n", strerror(errno));
        return 1;
    }

    printf("%d\n", ntohs(addr.sin_port));
    fflush(stdout);

    FILE *logf = fopen(log_path, "a");
    if (!logf) {
        fprintf(stderr, "ddns-test-server: cannot open %s: %s\n",
                log_path, strerror(errno));
        return 1;
    }

    char response[8192];
    int n = snprintf(response, sizeof(response),
                     "HTTP/1.1 200 OK\r\n"
                     "Content-Length: %zu\r\n"
                     "Content-Type: text/plain\r\n"
                     "Connection: close\r\n"
                     "\r\n"
                     "%s",
                     strlen(body), body);
    if (n < 0 || (size_t)n >= sizeof(response)) {
        fprintf(stderr, "ddns-test-server: response too large\n");
        return 1;
    }

    for (;;) {
        int cli = accept(srv, NULL, NULL);
        if (cli < 0) {
            fprintf(stderr, "ddns-test-server: accept: %s\n", strerror(errno));
            continue;
        }
        char req[REQUEST_MAX + 1];
        size_t got = 0;
        while (got < REQUEST_MAX) {
            ssize_t r = read(cli, req + got, REQUEST_MAX - got);
            if (r <= 0) {
                break;
            }
            got += (size_t)r;
            if (got >= 4 && memcmp(req + got - 4, "\r\n\r\n", 4) == 0) {
                break;
            }
        }
        req[got] = '\0';
        /* The request log captures the first line (method + target). */
        char *nl = strchr(req, '\n');
        if (nl) {
            *nl = '\0';
        }
        fprintf(logf, "%s\n", req);
        fflush(logf);
        (void)!write(cli, response, (size_t)n);
        close(cli);
    }
}