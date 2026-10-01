/*
 * ddns-test-server: loopback test double for the strim-ddns smoke test.
 *
 * Two modes:
 *
 *   HTTP mode: ddns-test-server <response-body> <request-log>
 *     Binds 127.0.0.1:0 (TCP), prints the chosen port to stdout on a single
 *     line (flushed), then serves argv[1] as the fixed response body to every
 *     request until killed. The same body serves both the update endpoint
 *     (/update, plain-text/XML replies). Each request's full text (request
 *     line + headers) is appended to the log file given in argv[2]. Mirrors
 *     the repo's notify_stub pattern (core/notify_stub.c).
 *
 *   DNS mode: ddns-test-server dns <role> <config> <request-log>
 *     Binds 127.0.0.1:0 (UDP), prints the chosen port to stdout on a single
 *     line (flushed), then answers DNS queries until killed. Two roles drive
 *     the check subcommand's direct-authoritative flow:
 *       - resolver (config "fixed"): a stand-in recursive resolver. Answers
 *         the NS query for example.com. with ns1.example.com., the A query
 *         for ns1.example.com. with 127.0.0.1 (so the direct A query lands
 *         back on the loopback), the AAAA query for ns1.example.com. with an
 *         empty NOERROR, and everything else with NXDOMAIN.
 *       - authoritative (per-case config): a stand-in authoritative server
 *         for testhost.example.com. Configs:
 *           single:<ip>               one A record
 *           cname:<target>,<ip>       CNAME then A (multi-record answer)
 *           only-cname:<target>       CNAME only, no A
 *           empty                     NOERROR with no answers
 *           nxdomain                  NXDOMAIN rcode
 *           servfail                  SERVFAIL rcode
 *           refused                   REFUSED rcode
 *     Every received query is appended to the request log as
 *     "DNS <name> <TYPE> rcode=<n>" so the smoke test can assert the flow
 *     (NS discovery, NS-hostname resolution, and the direct A query each hit
 *     the right role).
 */
#include "dns_wire.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define REQUEST_MAX 8192
#define DNS_BUF_MAX 512
#define DNS_TTL 300

/* -------------------------------------------------------------------------
 * HTTP mode (the original test double; update cases)
 * ------------------------------------------------------------------------- */

static int run_http_mode(int argc, char **argv) {
    (void)argc;
    const char *body = argv[0];
    const char *log_path = argv[1];

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
        /* The request log captures the whole request (request line +
         * headers) so tests can assert the query params. */
        fprintf(logf, "%s\n", req);
        fflush(logf);
        (void)!write(cli, response, (size_t)n);
        close(cli);
    }
}

/* -------------------------------------------------------------------------
 * DNS mode (UDP test double for the check subcommand)
 * ------------------------------------------------------------------------- */

/* name_eq: case-insensitive comparison of a decoded wire name (no trailing
 * root dot) against an expected dotted name. */
static bool name_eq(const char *wire_name, const char *expected) {
    return strcasecmp(wire_name, expected) == 0;
}

/* log_query: append one received-query line to the request log. */
static void log_query(FILE *logf, const struct dns_wire_query *q, int rcode) {
    const char *type = "?";
    switch (q->qtype) {
    case DNS_WIRE_TYPE_A:
        type = "A";
        break;
    case DNS_WIRE_TYPE_NS:
        type = "NS";
        break;
    case DNS_WIRE_TYPE_CNAME:
        type = "CNAME";
        break;
    case DNS_WIRE_TYPE_AAAA:
        type = "AAAA";
        break;
    }
    fprintf(logf, "DNS %s %s rcode=%d\n", q->name, type, rcode);
    fflush(logf);
}

/* send_reply: build the response for q with the given answers and rcode and
 * send it back to the client. recursive sets RA in the reply header (set for
 * the resolver role, clear for the authoritative role). */
static void send_reply(int srv, const struct sockaddr_in *client,
                       socklen_t client_len, FILE *logf,
                       const struct dns_wire_query *q, int rcode,
                       const struct dns_wire_answer *answers, size_t nanswers,
                       bool recursive) {
    uint8_t resp[DNS_BUF_MAX];
    int n = dns_wire_build_response(q, rcode, answers, nanswers, resp,
                                    sizeof(resp), recursive);
    log_query(logf, q, rcode);
    if (n < 0) {
        return; /* cannot build: drop the packet (client times out) */
    }
    (void)!sendto(srv, resp, (size_t)n, 0, (const struct sockaddr *)client,
                  client_len);
}

/* answer_a_record: a single A answer whose owner is the queried name. */
static struct dns_wire_answer a_answer(const struct dns_wire_query *q,
                                       const char *ip) {
    struct dns_wire_answer a;
    memset(&a, 0, sizeof(a));
    a.owner = q->name;
    a.type = DNS_WIRE_TYPE_A;
    a.data = ip;
    a.ttl = DNS_TTL;
    return a;
}

/* run_resolver_dns: the stand-in recursive resolver (fixed behavior). */
static void run_resolver_dns(int srv, const struct sockaddr_in *client,
                             socklen_t client_len, FILE *logf,
                             const struct dns_wire_query *q) {
    if (q->qclass != DNS_WIRE_CLASS_IN) {
        return; /* non-IN queries are dropped */
    }
    if (q->qtype == DNS_WIRE_TYPE_NS && name_eq(q->name, "example.com")) {
        struct dns_wire_answer ans;
        memset(&ans, 0, sizeof(ans));
        ans.owner = q->name;
        ans.type = DNS_WIRE_TYPE_NS;
        ans.data = "ns1.example.com";
        ans.ttl = DNS_TTL;
        send_reply(srv, client, client_len, logf, q, DNS_WIRE_RCODE_NOERROR,
                   &ans, 1, true);
        return;
    }
    if (q->qtype == DNS_WIRE_TYPE_A && name_eq(q->name, "ns1.example.com")) {
        struct dns_wire_answer ans = a_answer(q, "127.0.0.1");
        send_reply(srv, client, client_len, logf, q, DNS_WIRE_RCODE_NOERROR,
                   &ans, 1, true);
        return;
    }
    if (q->qtype == DNS_WIRE_TYPE_AAAA && name_eq(q->name, "ns1.example.com")) {
        /* No AAAA for the NS: the client keeps the IPv4 address. */
        send_reply(srv, client, client_len, logf, q, DNS_WIRE_RCODE_NOERROR,
                   NULL, 0, true);
        return;
    }
    send_reply(srv, client, client_len, logf, q, DNS_WIRE_RCODE_NXDOMAIN,
               NULL, 0, true);
}

/* run_authoritative_dns: the stand-in authoritative server, configured per
 * smoke-test case (see the top-of-file comment for the config grammar). */
static void run_authoritative_dns(int srv, const struct sockaddr_in *client,
                                  socklen_t client_len, FILE *logf,
                                  const struct dns_wire_query *q,
                                  const char *config) {
    if (q->qclass != DNS_WIRE_CLASS_IN) {
        return;
    }
    if (q->qtype != DNS_WIRE_TYPE_A) {
        send_reply(srv, client, client_len, logf, q, DNS_WIRE_RCODE_NXDOMAIN,
                   NULL, 0, false);
        return;
    }

    if (strcmp(config, "empty") == 0) {
        send_reply(srv, client, client_len, logf, q, DNS_WIRE_RCODE_NOERROR,
                   NULL, 0, false);
        return;
    }
    if (strcmp(config, "nxdomain") == 0) {
        send_reply(srv, client, client_len, logf, q, DNS_WIRE_RCODE_NXDOMAIN,
                   NULL, 0, false);
        return;
    }
    if (strcmp(config, "servfail") == 0) {
        send_reply(srv, client, client_len, logf, q, DNS_WIRE_RCODE_SERVFAIL,
                   NULL, 0, false);
        return;
    }
    if (strcmp(config, "refused") == 0) {
        send_reply(srv, client, client_len, logf, q, DNS_WIRE_RCODE_REFUSED,
                   NULL, 0, false);
        return;
    }
    if (strncmp(config, "single:", 7) == 0) {
        struct dns_wire_answer ans = a_answer(q, config + 7);
        send_reply(srv, client, client_len, logf, q, DNS_WIRE_RCODE_NOERROR,
                   &ans, 1, false);
        return;
    }
    if (strncmp(config, "only-cname:", 11) == 0) {
        struct dns_wire_answer ans;
        memset(&ans, 0, sizeof(ans));
        ans.owner = q->name;
        ans.type = DNS_WIRE_TYPE_CNAME;
        ans.data = config + 11;
        ans.ttl = DNS_TTL;
        send_reply(srv, client, client_len, logf, q, DNS_WIRE_RCODE_NOERROR,
                   &ans, 1, false);
        return;
    }
    if (strncmp(config, "cname:", 6) == 0) {
        /* config = "cname:<target>,<ip>" */
        const char *comma = strchr(config + 6, ',');
        if (comma == NULL) {
            fprintf(stderr, "ddns-test-server: bad cname config '%s'\n",
                    config);
            return;
        }
        size_t target_len = (size_t)(comma - (config + 6));
        char target[256];
        if (target_len == 0 || target_len >= sizeof(target)) {
            fprintf(stderr, "ddns-test-server: bad cname config '%s'\n",
                    config);
            return;
        }
        memcpy(target, config + 6, target_len);
        target[target_len] = '\0';
        const char *ip = comma + 1;

        struct dns_wire_answer answers[2];
        memset(answers, 0, sizeof(answers));
        answers[0].owner = q->name;
        answers[0].type = DNS_WIRE_TYPE_CNAME;
        answers[0].data = target;
        answers[0].ttl = DNS_TTL;
        answers[1].owner = target;
        answers[1].type = DNS_WIRE_TYPE_A;
        answers[1].data = ip;
        answers[1].ttl = DNS_TTL;
        send_reply(srv, client, client_len, logf, q, DNS_WIRE_RCODE_NOERROR,
                   answers, 2, false);
        return;
    }
    fprintf(stderr, "ddns-test-server: unknown authoritative config '%s'\n",
            config);
}

static int run_dns_mode(int argc, char **argv) {
    (void)argc;
    const char *role = argv[0];
    const char *config = argv[1];
    const char *log_path = argv[2];

    int srv = socket(AF_INET, SOCK_DGRAM, 0);
    if (srv < 0) {
        fprintf(stderr, "ddns-test-server: dns socket: %s\n", strerror(errno));
        return 1;
    }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0; /* ephemeral */
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        fprintf(stderr, "ddns-test-server: dns bind: %s\n", strerror(errno));
        return 1;
    }
    socklen_t alen = sizeof(addr);
    if (getsockname(srv, (struct sockaddr *)&addr, &alen) != 0) {
        fprintf(stderr, "ddns-test-server: dns getsockname: %s\n",
                strerror(errno));
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

    for (;;) {
        uint8_t buf[DNS_BUF_MAX];
        struct sockaddr_in client;
        socklen_t client_len = sizeof(client);
        ssize_t r = recvfrom(srv, buf, sizeof(buf), 0,
                             (struct sockaddr *)&client, &client_len);
        if (r < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "ddns-test-server: dns recvfrom: %s\n",
                    strerror(errno));
            continue;
        }
        struct dns_wire_query q;
        if (dns_wire_parse_query(buf, (size_t)r, &q) != 0) {
            continue; /* malformed query: drop it */
        }
        if (strcmp(role, "resolver") == 0) {
            run_resolver_dns(srv, &client, client_len, logf, &q);
        } else if (strcmp(role, "authoritative") == 0) {
            run_authoritative_dns(srv, &client, client_len, logf, &q, config);
        } else {
            fprintf(stderr, "ddns-test-server: unknown dns role '%s'\n", role);
            return 1;
        }
    }
}

int main(int argc, char **argv) {
    if (argc == 3) {
        return run_http_mode(argc - 1, argv + 1);
    }
    if (argc == 5 && strcmp(argv[1], "dns") == 0) {
        return run_dns_mode(argc - 2, argv + 2);
    }
    fprintf(stderr,
            "usage: %s <response-body> <request-log>\n"
            "       %s dns <resolver|authoritative> <config> <request-log>\n",
            argv[0], argv[0]);
    return 2;
}