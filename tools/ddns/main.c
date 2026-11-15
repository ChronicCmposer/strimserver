/*
 * strim-ddns: Namecheap dynamic-DNS update client + direct-authoritative
 * DNS probe.
 *
 * Two subcommands:
 *
 *   update <host> <domain> [password_file] [ip]
 *     Performs the Namecheap Dynamic DNS HTTPS GET and reports success from
 *     the response BODY (the endpoint answers HTTP 200 for both outcomes, so
 *     the body is authoritative):
 *       - classic plain-text reply: "Good <ip>" (record updated) or
 *         "No change" (IP unchanged);
 *       - since ~2021 an <interface-response> XML blob (declared UTF-16 but
 *         actually UTF-8; NUL-stripped and text-matched rather than
 *         XML-decoded to sidestep the misdeclared charset) whose success
 *         signal is <ErrCount>0</ErrCount>.
 *     Mirrors the gitd reference implementation's ddnsSuccess().
 *
 *   check <host> <domain> <expected_ip>
 *     Resolves $host.$domain's A record by querying EVERY discovered
 *     authoritative nameserver directly, bypassing every resolver for the
 *     dynamic record:
 *       1. NS discovery: ask the box's resolver (c-ares, system resolver
 *          server list) for the DOMAIN's NS records (type NS).
 *       2. NS hostname -> IPv4: resolve each NS hostname's A records via the
 *          same resolver. All per-NS lookups run concurrently in one c-ares
 *          event loop. Only IPv4 A records are used (never AAAA).
 *       3. Direct A query: for EACH NS, send the A query for $host.$domain
 *          STRAIGHT to that NS's own IPv4 addresses over UDP/53 with c-ares
 *          (ARES_OPT_SERVERS + ARES_FLAG_NORECURSE, so the RD bit is 0 and
 *          the authoritative server answers from its own zone data). All
 *          per-NS queries run concurrently in one c-ares event loop.
 *     Every channel -- NS discovery, NS-hostname resolution, and each direct
 *     query -- uses the same configured DNS budget (4000 ms x 2 tries). The
 *     expected IPv4 is REQUIRED (third argument or DDNS_EXPECTED_IP): the
 *     check passes ONLY when every discovered NS returns it via at least one
 *     of its own addresses. A missing expected IP is a usage error, never an
 *     agreement-only success. One unreachable or disagreeing NS means "not
 *     yet": exit 1 with nothing on stdout. The check prints one line per NS
 *     to stderr (hostname plus the observed IPv4, or "none") and, on success,
 *     the expected IPv4 to stdout. It never counts or prints attempts -- that
 *     belongs to the verify unit.
 *
 * Config comes from argv (host domain password_file [ip]) or, when the args
 * are absent, from the DDNS_HOST / DDNS_DOMAIN / DDNS_PASSWORD_FILE /
 * DDNS_IP environment variables. DDNS_ENDPOINT overrides the update URL
 * (testability). DDNS_EXPECTED_IP supplies the check's expected IPv4 when it
 * is not given as the optional third check argument. DDNS_RESOLVER (test-only)
 * overrides the resolver c-ares uses for NS discovery / NS-hostname resolution
 * as "ip" or "ip:port" (loopback DNS test double); DDNS_AUTHORITATIVE_PORT
 * (test-only) overrides the UDP/TCP port of the direct authoritative A query
 * (default 53). When unset, c-ares uses the system resolver config and port
 * 53, so production behavior is unchanged. DDNS_CA_BUNDLE overrides the CA
 * bundle path (CURLOPT_CAINFO); when unset, libcurl's compiled-in
 * CURL_CA_BUNDLE (/etc/ssl/certs/ca-certificates.crt in the image) is used.
 *
 * Exit: 0 on success, 1 on update/transfer failure or a not-resolved check,
 * 2 on usage/config errors.
 */

#include <curl/curl.h>

#include <ares.h>

#include "agreement.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>

#define DDNS_DEFAULT_ENDPOINT "https://dynamicdns.park-your-domain.com/update"

/* HTTPS timeouts: the update path is a single Namecheap GET that may take up
 * to 15s on a slow box. */
#define DDNS_UPDATE_TIMEOUT_SECS 15L

/* Per-query DNS budget for the check probe: EVERY c-ares channel the check
 * creates (the resolver channel for NS discovery and NS-hostname resolution,
 * and each authoritative channel for the direct A query) is initialized with
 * DDNS_DNS_TIMEOUT_MS between tries and DDNS_DNS_TRIES tries, bounding a
 * single phase to ~8s. The verify unit retries the whole check until its
 * deadline, so a failure here is "not yet", never a hard stop. With the
 * three phases (NS discovery, per-NS A resolution, per-NS direct query) the
 * worst case is ~24s < the verify unit's per-attempt `timeout 30`. */
#define DDNS_DNS_TIMEOUT_MS 4000L
#define DDNS_DNS_TRIES 2

#define DDNS_MAX_NS 16
#define DDNS_MAX_NS_IPS 32
#define DDNS_MAX_A_RECORDS 8

/* Bounded response capture (the endpoint replies are a few hundred bytes;
 * the Go client caps reads at 1 MiB). */
struct reply_buffer {
    char *data;
    size_t len;
    size_t cap;
};

static size_t reply_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    struct reply_buffer *buf = userdata;
    size_t incoming = size * nmemb;

    if (buf->len + incoming + 1 > buf->cap) {
        size_t newcap = buf->cap ? buf->cap * 2 : 4096;
        while (newcap < buf->len + incoming + 1) {
            newcap *= 2;
        }
        char *grown = realloc(buf->data, newcap);
        if (!grown) {
            return 0; /* curl turns a short write into a transfer error */
        }
        buf->data = grown;
        buf->cap = newcap;
    }
    memcpy(buf->data + buf->len, ptr, incoming);
    buf->len += incoming;
    buf->data[buf->len] = '\0';
    return incoming;
}

/* ddns_reply_is_success: body-based success detection, mirroring gitd's
 * ddnsSuccess(). Returns true for the plain-text prefixes, or for an
 * <interface-response> whose <ErrCount> is exactly 0. */
static bool ddns_reply_is_success(const char *reply) {
    if (strncmp(reply, "Good", 4) == 0) {
        return true;
    }
    if (strncmp(reply, "OK", 2) == 0) {
        return true;
    }
    if (strncmp(reply, "No change", 9) == 0) {
        return true;
    }
    if (strstr(reply, "<interface-response>") == NULL) {
        return false;
    }
    const char *err = strstr(reply, "<ErrCount>");
    if (err == NULL) {
        return false;
    }
    const char *p = err + strlen("<ErrCount>");
    while (isspace((unsigned char)*p)) {
        p++;
    }
    if (*p != '0') {
        return false;
    }
    p++;
    while (isspace((unsigned char)*p)) {
        p++;
    }
    return strncmp(p, "</ErrCount>", strlen("</ErrCount>")) == 0;
}

/* sanitize_reply: NUL-stripped, whitespace-trimmed copy of the raw body.
 * The XML replies are declared UTF-16 but arrive as UTF-8 with embedded NUL
 * bytes; stripping them (as the Go client does) makes the text matches
 * above work. Returns a malloc'd NUL-terminated string, or NULL on OOM. */
static char *sanitize_reply(const char *raw, size_t len) {
    char *clean = malloc(len + 1);
    if (!clean) {
        return NULL;
    }
    size_t j = 0;
    for (size_t i = 0; i < len; i++) {
        if (raw[i] != '\0') {
            clean[j++] = raw[i];
        }
    }
    clean[j] = '\0';

    char *start = clean;
    while (*start && isspace((unsigned char)*start)) {
        start++;
    }
    char *end = clean + j;
    while (end > start && isspace((unsigned char)end[-1])) {
        end--;
    }
    *end = '\0';
    if (start != clean) {
        memmove(clean, start, (size_t)(end - start) + 1);
    }
    return clean;
}

/* read_password_file: returns the whitespace-trimmed file contents, or NULL
 * with a descriptive error already printed. Empty files are rejected. */
static char *read_password_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "strim-ddns: cannot open password_file %s: %s\n",
                path, strerror(errno));
        return NULL;
    }
    char buf[65536];
    size_t n = fread(buf, 1, sizeof(buf), f);
    fclose(f);
    if (n == sizeof(buf)) {
        fprintf(stderr, "strim-ddns: password_file %s is too large\n", path);
        return NULL;
    }
    buf[n] = '\0';

    char *start = buf;
    while (*start && isspace((unsigned char)*start)) {
        start++;
    }
    char *end = buf + n;
    while (end > start && isspace((unsigned char)end[-1])) {
        end--;
    }
    if (start == end) {
        fprintf(stderr, "strim-ddns: password_file %s is empty\n", path);
        return NULL;
    }
    char *password = malloc((size_t)(end - start) + 1);
    if (!password) {
        return NULL;
    }
    memcpy(password, start, (size_t)(end - start));
    password[end - start] = '\0';
    return password;
}

/* url_escape: percent-encode s for use in a query string. curl_easy_escape
 * allocates with malloc; free the result with curl_free. Returns NULL on
 * failure. */
static char *url_escape(const char *s) {
    return curl_easy_escape(NULL, s, 0);
}

/* build_update_url: assembles
 *   <endpoint>?host=<h>&domain=<d>&password=<p>[&ip=<i>]
 * with every value URL-escaped. Returns a malloc'd string, or NULL on OOM.
 * When ip is omitted the endpoint uses the requester IP (Namecheap
 * behavior; gitd relies on it). */
static char *build_update_url(const char *endpoint, const char *host,
                              const char *domain, const char *password,
                              const char *ip) {
    char *host_e = url_escape(host);
    char *domain_e = url_escape(domain);
    char *pw_e = url_escape(password);
    char *ip_e = (ip && *ip) ? url_escape(ip) : NULL;
    if (!host_e || !domain_e || !pw_e || (ip && *ip && !ip_e)) {
        curl_free(host_e);
        curl_free(domain_e);
        curl_free(pw_e);
        curl_free(ip_e);
        return NULL;
    }

    size_t need = strlen(endpoint) + strlen(host_e) + strlen(domain_e) +
                  strlen(pw_e) + (ip_e ? strlen(ip_e) : 0) + 64;
    char *url = malloc(need);
    if (!url) {
        curl_free(host_e);
        curl_free(domain_e);
        curl_free(pw_e);
        curl_free(ip_e);
        return NULL;
    }
    if (ip_e) {
        snprintf(url, need, "%s?host=%s&domain=%s&password=%s&ip=%s",
                 endpoint, host_e, domain_e, pw_e, ip_e);
    } else {
        snprintf(url, need, "%s?host=%s&domain=%s&password=%s",
                 endpoint, host_e, domain_e, pw_e);
    }
    curl_free(host_e);
    curl_free(domain_e);
    curl_free(pw_e);
    curl_free(ip_e);
    return url;
}

/* perform_https_get: runs the HTTPS GET, capturing the body into *reply.
 * TLS verification is ON (CURLOPT_SSL_VERIFYPEER=1 + VERIFYHOST=2); the CA
 * bundle comes from ca_bundle when set, else libcurl's compiled-in default.
 * When accept_header is set it is sent verbatim. When quiet is true,
 * transport errors are not printed (the check probe's contract is silence on
 * stdout and stderr -- the exit code is the answer). timeout_secs bounds the
 * whole transfer (CURLOPT_TIMEOUT). Returns 0 on transfer success (the body
 * decides the outcome), -1 on any transport/TLS error (already printed
 * unless quiet). */
static int perform_https_get(const char *url, const char *ca_bundle,
                             const char *accept_header, bool quiet,
                             long timeout_secs, struct reply_buffer *reply) {
    CURL *curl = curl_easy_init();
    if (!curl) {
        if (!quiet) {
            fprintf(stderr, "strim-ddns: curl_easy_init failed\n");
        }
        return -1;
    }
    struct curl_slist *headers = NULL;
    if (accept_header && *accept_header) {
        headers = curl_slist_append(NULL, accept_header);
        if (!headers) {
            if (!quiet) {
                fprintf(stderr,
                        "strim-ddns: out of memory building request headers\n");
            }
            curl_easy_cleanup(curl);
            return -1;
        }
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    }
    char errbuf[CURL_ERROR_SIZE] = {0};
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    /* Pin IPv4 egress: no IPv6 path is attempted. Combined with the absent
     * ip= parameter (DDNS_IP empty), Namecheap records the requester's IPv4. */
    curl_easy_setopt(curl, CURLOPT_IPRESOLVE, (long)CURL_IPRESOLVE_V4);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout_secs);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "strim-ddns/1.0");
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, reply_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, reply);
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, errbuf);
    if (ca_bundle && *ca_bundle) {
        curl_easy_setopt(curl, CURLOPT_CAINFO, ca_bundle);
    }
    CURLcode rc = curl_easy_perform(curl);
    curl_easy_cleanup(curl);
    if (headers) {
        curl_slist_free_all(headers);
    }
    if (rc != CURLE_OK) {
        if (!quiet) {
            fprintf(stderr, "strim-ddns: transfer failed: %s%s%s\n",
                    curl_easy_strerror(rc), errbuf[0] ? ": " : "", errbuf);
        }
        return -1;
    }
    return 0;
}

static void print_usage(const char *prog) {
    fprintf(stderr,
            "usage: %s update <host> <domain> [password_file] [ip]\n"
            "       %s check <host> <domain> <expected_ip>\n"
            "  the bare invocation %s <host> <domain> [password_file] [ip]\n"
            "  is treated as \"update\" (legacy).\n"
            "  config may instead come from DDNS_HOST, DDNS_DOMAIN,\n"
            "  DDNS_PASSWORD_FILE, DDNS_IP; DDNS_ENDPOINT overrides the\n"
            "  update URL; DDNS_CA_BUNDLE overrides the CA bundle.\n"
            "  check discovers the domain's authoritative nameservers via\n"
            "  the system resolver, resolves each NS's own IPv4, and queries\n"
            "  every NS directly (no resolver is trusted for the dynamic A\n"
            "  record). The expected IPv4 is REQUIRED; it passes only when\n"
            "  every NS returns it. One line per NS is printed to stderr.\n"
            "  DDNS_RESOLVER (test-only) points NS discovery at an ip[:port]\n"
            "  resolver; DDNS_AUTHORITATIVE_PORT (test-only) overrides the\n"
            "  direct query port (default 53); DDNS_EXPECTED_IP supplies the\n"
            "  required expected IPv4 when not given positionally.\n",
            prog, prog, prog);
}

/* run_update: the Namecheap update path. argv[first] is the first config
 * argument (host); positional args or the DDNS_* env vars fill the rest. */
static int run_update(int argc, char **argv, int first) {
    const char *host = argc > first ? argv[first] : getenv("DDNS_HOST");
    const char *domain = argc > first + 1 ? argv[first + 1] : getenv("DDNS_DOMAIN");
    const char *password_file = argc > first + 2 ? argv[first + 2] : getenv("DDNS_PASSWORD_FILE");
    const char *ip = argc > first + 3 ? argv[first + 3] : getenv("DDNS_IP");
    const char *endpoint = getenv("DDNS_ENDPOINT");
    const char *ca_bundle = getenv("DDNS_CA_BUNDLE");

    if (!host || !*host || !domain || !*domain ||
        !password_file || !*password_file) {
        print_usage(argv[0]);
        return 2;
    }
    if (!endpoint || !*endpoint) {
        endpoint = DDNS_DEFAULT_ENDPOINT;
    }

    char *password = read_password_file(password_file);
    if (!password) {
        return 2;
    }
    char *url = build_update_url(endpoint, host, domain, password, ip);
    free(password);
    if (!url) {
        fprintf(stderr, "strim-ddns: out of memory building update URL\n");
        return 2;
    }

    struct reply_buffer reply = {0};
    int rc = perform_https_get(url, ca_bundle, NULL, /*quiet=*/false,
                               DDNS_UPDATE_TIMEOUT_SECS, &reply);
    free(url);
    if (rc != 0) {
        free(reply.data);
        return 1;
    }

    char *clean = sanitize_reply(reply.data, reply.len);
    free(reply.data);
    if (!clean) {
        fprintf(stderr, "strim-ddns: out of memory reading response\n");
        return 1;
    }

    bool ok = ddns_reply_is_success(clean);
    fprintf(ok ? stdout : stderr, "%s\n", clean);
    free(clean);
    return ok ? 0 : 1;
}

/* =========================================================================
 * check subcommand: direct authoritative A-record resolution (c-ares)
 * =========================================================================
 *
 * Parse-don't-validate at the boundary: the raw DNS replies are parsed by
 * c-ares (ares_parse_ns_reply / ares_parse_a_reply) and only typed
 * hostnames/IPs flow through the rest of the function. Guard clauses handle
 * every failure path with an early return; nothing is printed to stdout on
 * any failure, preserving the one-IPv4-or-nothing contract.
 */

/* dns_status_str: short human reason for an ares_query callback status. */
static const char *dns_status_str(int status) {
    switch (status) {
    case ARES_SUCCESS:
        return "ok";
    case ARES_ENODATA:
        return "no answer records";
    case ARES_EFORMERR:
        return "malformed response";
    case ARES_ESERVFAIL:
        return "server failure";
    case ARES_ENOTFOUND:
        return "name not found";
    case ARES_ENOTIMP:
        return "not implemented";
    case ARES_EREFUSED:
        return "query refused";
    case ARES_EBADRESP:
        return "bad response";
    case ARES_ECONNREFUSED:
        return "connection refused";
    case ARES_ETIMEOUT:
        return "timeout";
    case ARES_ECANCELLED:
        return "cancelled";
    case ARES_ENOMEM:
        return "out of memory";
    default:
        return "DNS error";
    }
}

/* dns_query_state: one synchronous ares_query; the callback stashes a
 * malloc'd copy of the reply so parsing can happen after the event loop. */
struct dns_query_state {
    bool done;
    bool oom;
    int status;
    unsigned char *reply;
    size_t reply_len;
};

static void dns_query_cb(void *arg, int status, int timeouts,
                         unsigned char *abuf, int alen) {
    (void)timeouts;
    struct dns_query_state *st = arg;
    st->status = status;
    if (abuf != NULL && alen > 0) {
        unsigned char *copy = malloc((size_t)alen);
        if (copy == NULL) {
            st->oom = true;
        } else {
            memcpy(copy, abuf, (size_t)alen);
            st->reply = copy;
            st->reply_len = (size_t)alen;
        }
    }
    st->done = true;
}

/* run_dns_query: one synchronous ares_query on channel. The channel's own
 * ARES_OPT_TIMEOUTMS / ARES_OPT_TRIES bound the wait; the 1s select cap just
 * paces the event loop (ares_timeout returns whichever is sooner). On
 * completion st->status holds the callback status and st->reply a malloc'd
 * reply copy (free with free()). */
static void run_dns_query(ares_channel_t *channel, const char *name,
                          int dnsclass, int type, struct dns_query_state *st) {
    /* Defensive: the callback normally overwrites this, but if the event
     * loop drains before it fires (nfds == 0 break below), the query must
     * read as a failure, never as ARES_SUCCESS. */
    st->status = ARES_ETIMEOUT;
    ares_query(channel, name, dnsclass, type, dns_query_cb, st);
    while (!st->done) {
        fd_set read_fds, write_fds;
        FD_ZERO(&read_fds);
        FD_ZERO(&write_fds);
        int nfds = ares_fds(channel, &read_fds, &write_fds);
        if (nfds == 0) {
            break; /* query drained; nothing left to wait on */
        }
        struct timeval maxtv, tv;
        maxtv.tv_sec = 1;
        maxtv.tv_usec = 0;
        struct timeval *tvp = ares_timeout(channel, &maxtv, &tv);
        int rc = select(nfds, &read_fds, &write_fds, NULL, tvp);
        if (rc < 0 && errno != EINTR) {
            st->status = ARES_ETIMEOUT;
            ares_cancel(channel);
            st->done = true;
            break;
        }
        ares_process(channel, &read_fds, &write_fds);
    }
}

/* merge_fds: union src read/write sets into dst and track the highest fd. */
static void merge_fds(const fd_set *src_read, const fd_set *src_write,
                      fd_set *dst_read, fd_set *dst_write, int *highest_fd) {
    for (int fd = 0; fd < FD_SETSIZE; fd++) {
        if (FD_ISSET(fd, src_read)) {
            FD_SET(fd, dst_read);
            if (fd > *highest_fd) {
                *highest_fd = fd;
            }
        }
        if (FD_ISSET(fd, src_write)) {
            FD_SET(fd, dst_write);
            if (fd > *highest_fd) {
                *highest_fd = fd;
            }
        }
    }
}

/* timeval_before: true when a is strictly earlier than b. */
static bool timeval_before(const struct timeval *a, const struct timeval *b) {
    return a->tv_sec < b->tv_sec ||
           (a->tv_sec == b->tv_sec && a->tv_usec < b->tv_usec);
}

/* pump_channels: drive several c-ares channels in ONE select() event loop
 * until every channel is idle. This is what makes the per-NS lookups (phase 2)
 * and per-NS direct queries (phase 3) concurrent rather than serial: one
 * select waits on all channels' sockets at once and each ready channel is
 * processed in the same iteration. Each channel's own ARES_OPT_TIMEOUTMS /
 * ARES_OPT_TRIES still bound its queries; the 1s cap only paces the loop. */
static void pump_channels(ares_channel_t **channels, size_t nchannels) {
    for (;;) {
        fd_set all_read, all_write;
        FD_ZERO(&all_read);
        FD_ZERO(&all_write);
        int highest_fd = -1;
        bool any_socket = false;
        struct timeval soonest;
        bool have_soonest = false;

        for (size_t i = 0; i < nchannels; i++) {
            fd_set read_fds, write_fds;
            FD_ZERO(&read_fds);
            FD_ZERO(&write_fds);
            int nfds = ares_fds(channels[i], &read_fds, &write_fds);
            if (nfds > 0) {
                any_socket = true;
                merge_fds(&read_fds, &write_fds, &all_read, &all_write,
                          &highest_fd);
            }
            struct timeval cap = {1, 0};
            struct timeval tv;
            struct timeval *tvp = ares_timeout(channels[i], &cap, &tv);
            if (tvp != NULL &&
                (!have_soonest || timeval_before(tvp, &soonest))) {
                soonest = *tvp;
                have_soonest = true;
            }
        }
        if (!any_socket) {
            return;
        }
        int rc = select(highest_fd + 1, &all_read, &all_write, NULL,
                        have_soonest ? &soonest : NULL);
        if (rc < 0 && errno != EINTR) {
            for (size_t i = 0; i < nchannels; i++) {
                ares_cancel(channels[i]);
            }
            return;
        }
        for (size_t i = 0; i < nchannels; i++) {
            ares_process(channels[i], &all_read, &all_write);
        }
    }
}


/* init_channel_options: the single place the check's DNS budget is applied.
 * Every ares_init_options() call site starts from this configured struct, so
 * no channel (including the production NS-discovery/resolution channel) is
 * ever left on c-ares defaults. Callers add their own servers/flags. */
static void init_channel_options(struct ares_options *options, int *optmask) {
    memset(options, 0, sizeof(*options));
    *optmask = ARES_OPT_TIMEOUTMS | ARES_OPT_TRIES;
    options->timeout = DDNS_DNS_TIMEOUT_MS;
    options->tries = DDNS_DNS_TRIES;
}

static int init_resolver_channel(ares_channel_t **channel_out,
                                 const struct in_addr *override_ip,
                                 unsigned short override_port) {
    struct ares_options options;
    int optmask = 0;
    init_channel_options(&options, &optmask);
    if (override_ip != NULL) {
        options.servers = (struct in_addr *)override_ip;
        options.nservers = 1;
        optmask |= ARES_OPT_SERVERS;
        if (override_port != 0) {
            options.udp_port = override_port;
            options.tcp_port = override_port;
            optmask |= ARES_OPT_UDP_PORT | ARES_OPT_TCP_PORT;
        }
    }
    return ares_init_options(channel_out, &options, optmask);
}

/* init_authoritative_channel: a c-ares channel whose ONLY servers are the
 * discovered authoritative NS IPs, with the RD bit cleared (ARES_FLAG_NORECURSE)
 * so the NS answers from its own zone data. port_override (test-only
 * DDNS_AUTHORITATIVE_PORT) replaces the default 53. */
static int init_authoritative_channel(ares_channel_t **channel_out,
                                      const struct in_addr *ns_ips,
                                      size_t nns,
                                      unsigned short port_override) {
    struct ares_options options;
    int optmask = 0;
    init_channel_options(&options, &optmask);
    optmask |= ARES_OPT_FLAGS | ARES_OPT_SERVERS;
    options.flags = ARES_FLAG_NORECURSE;
    options.servers = (struct in_addr *)ns_ips;
    options.nservers = (int)nns;
    if (port_override != 0) {
        options.udp_port = port_override;
        options.tcp_port = port_override;
        optmask |= ARES_OPT_UDP_PORT | ARES_OPT_TCP_PORT;
    }
    return ares_init_options(channel_out, &options, optmask);
}

/* parse_resolver_override: parse DDNS_RESOLVER ("ip" or "ip:port", test-only)
 * at the boundary. Returns 0 with *ip_out unset when the env is empty/absent;
 * returns 1 with ip/port filled on success; returns -1 on malformed input
 * (with a descriptive error printed). */
static int parse_resolver_override(const char *env, struct in_addr *ip_out,
                                   unsigned short *port_out) {
    if (env == NULL || *env == '\0') {
        return 0;
    }
    const char *colon = strrchr(env, ':');
    if (colon == NULL) {
        if (inet_pton(AF_INET, env, ip_out) != 1) {
            fprintf(stderr,
                    "strim-ddns: invalid DDNS_RESOLVER '%s' "
                    "(expected an IPv4 address or ip:port)\n",
                    env);
            return -1;
        }
        *port_out = 0;
        return 1;
    }
    char ipbuf[64];
    size_t iplen = (size_t)(colon - env);
    if (iplen == 0 || iplen >= sizeof(ipbuf)) {
        fprintf(stderr,
                "strim-ddns: invalid DDNS_RESOLVER '%s' "
                "(expected an IPv4 address or ip:port)\n",
                env);
        return -1;
    }
    memcpy(ipbuf, env, iplen);
    ipbuf[iplen] = '\0';
    if (inet_pton(AF_INET, ipbuf, ip_out) != 1) {
        fprintf(stderr,
                "strim-ddns: invalid DDNS_RESOLVER '%s' "
                "(expected an IPv4 address or ip:port)\n",
                env);
        return -1;
    }
    char *end = NULL;
    long parsed = strtol(colon + 1, &end, 10);
    if (end == colon + 1 || *end != '\0' || parsed <= 0 || parsed > 65535) {
        fprintf(stderr,
                "strim-ddns: invalid DDNS_RESOLVER '%s' "
                "(expected an IPv4 address or ip:port)\n",
                env);
        return -1;
    }
    *port_out = (unsigned short)parsed;
    return 1;
}

/* parse_authoritative_port: parse DDNS_AUTHORITATIVE_PORT (test-only) at the
 * boundary. Returns the port (0 when unset) or -1 on malformed input (with a
 * descriptive error printed). */
static long parse_authoritative_port(const char *env) {
    if (env == NULL || *env == '\0') {
        return 0;
    }
    char *end = NULL;
    long parsed = strtol(env, &end, 10);
    if (end == env || *end != '\0' || parsed <= 0 || parsed > 65535) {
        fprintf(stderr,
                "strim-ddns: invalid DDNS_AUTHORITATIVE_PORT '%s' "
                "(expected a port number 1-65535)\n",
                env);
        return -1;
    }
    return parsed;
}

/* ns_probe: one discovered nameserver and everything learned about it. */
struct ns_probe {
    char *hostname;                            /* strdup'd NS hostname */
    struct in_addr addresses[DDNS_MAX_NS_IPS]; /* its own A-record IPv4s */
    size_t n_addresses;
    struct in_addr observed[DDNS_MAX_A_RECORDS]; /* A records it returned */
    size_t n_observed;
    struct dns_query_state address_query; /* phase 2 reply/status */
    struct dns_query_state direct_query;  /* phase 3 reply/status */
};

/* free_probes: release the NS hostnames (reply buffers are freed per phase). */
static void free_probes(struct ns_probe *probes, size_t n) {
    for (size_t i = 0; i < n; i++) {
        free(probes[i].hostname);
    }
}

/* parse_a_records: extract up to cap IPv4 A records from a completed query
 * into out. Returns true when at least one address was extracted; a failed,
 * empty, or AAAA-only reply yields false with *count == 0 (only A records are
 * ever considered). */
static bool parse_a_records(const struct dns_query_state *state,
                            struct in_addr *out, size_t cap, size_t *count) {
    *count = 0;
    if (state->status != ARES_SUCCESS || state->reply == NULL) {
        return false;
    }
    struct ares_addrttl addrs[DDNS_MAX_NS_IPS];
    int n_addrs = DDNS_MAX_NS_IPS;
    if (ares_parse_a_reply(state->reply, (int)state->reply_len, NULL, addrs,
                           &n_addrs) != ARES_SUCCESS ||
        n_addrs <= 0) {
        return false;
    }
    size_t copied = (size_t)n_addrs < cap ? (size_t)n_addrs : cap;
    for (size_t i = 0; i < copied; i++) {
        out[i] = addrs[i].ipaddr;
    }
    *count = copied;
    return copied > 0;
}

/* reset_query_state: mark a query as failed-until-proven-successful so a
 * drained event loop can never read as ARES_SUCCESS. */
static void reset_query_state(struct dns_query_state *state) {
    state->done = false;
    state->oom = false;
    state->status = ARES_ETIMEOUT;
    state->reply = NULL;
    state->reply_len = 0;
}

/* resolve_ns_addresses: phase 2 -- resolve every NS hostname's A records
 * concurrently in one c-ares event loop (a single A query per NS on the shared
 * resolver channel). Returns 0 on success, -1 on out-of-memory. */
static int resolve_ns_addresses(ares_channel_t *resolver,
                                struct ns_probe *probes, size_t n) {
    for (size_t i = 0; i < n; i++) {
        reset_query_state(&probes[i].address_query);
        ares_query(resolver, probes[i].hostname, ARES_CLASS_IN,
                   ARES_REC_TYPE_A, dns_query_cb, &probes[i].address_query);
    }
    ares_channel_t *channels[1] = {resolver};
    pump_channels(channels, 1);

    for (size_t i = 0; i < n; i++) {
        if (probes[i].address_query.oom) {
            free(probes[i].address_query.reply);
            probes[i].address_query.reply = NULL;
            return -1;
        }
        parse_a_records(&probes[i].address_query, probes[i].addresses,
                        DDNS_MAX_NS_IPS, &probes[i].n_addresses);
        free(probes[i].address_query.reply);
        probes[i].address_query.reply = NULL;
    }
    return 0;
}

/* query_nameservers: phase 3 -- query the FQDN directly against EACH
 * nameserver through that NS's own IPv4 addresses (one authoritative channel
 * per NS, RD bit clear), with every per-NS query driven concurrently by one
 * select() loop. Returns 0 on success, -1 on out-of-memory/channel failure. */
static int query_nameservers(struct ns_probe *probes, size_t n,
                             const char *fqdn, unsigned short port) {
    ares_channel_t *channels[DDNS_MAX_NS];
    memset(channels, 0, sizeof(channels));

    for (size_t i = 0; i < n; i++) {
        reset_query_state(&probes[i].direct_query);
        if (probes[i].n_addresses == 0) {
            continue; /* no IPv4 for this NS: it cannot answer, stays "none" */
        }
        if (init_authoritative_channel(&channels[i], probes[i].addresses,
                                       probes[i].n_addresses,
                                       port) != ARES_SUCCESS) {
            for (size_t k = 0; k < n; k++) {
                if (channels[k] != NULL) {
                    ares_destroy(channels[k]);
                }
            }
            return -1;
        }
        ares_query(channels[i], fqdn, ARES_CLASS_IN, ARES_REC_TYPE_A,
                   dns_query_cb, &probes[i].direct_query);
    }

    ares_channel_t *active[DDNS_MAX_NS];
    size_t n_active = 0;
    for (size_t i = 0; i < n; i++) {
        if (channels[i] != NULL) {
            active[n_active++] = channels[i];
        }
    }
    if (n_active > 0) {
        pump_channels(active, n_active);
    }
    for (size_t i = 0; i < n; i++) {
        if (channels[i] != NULL) {
            ares_destroy(channels[i]);
        }
    }

    for (size_t i = 0; i < n; i++) {
        if (probes[i].direct_query.oom) {
            free(probes[i].direct_query.reply);
            probes[i].direct_query.reply = NULL;
            return -1;
        }
        parse_a_records(&probes[i].direct_query, probes[i].observed,
                        DDNS_MAX_A_RECORDS, &probes[i].n_observed);
        free(probes[i].direct_query.reply);
        probes[i].direct_query.reply = NULL;
    }
    return 0;
}

/* run_check: the direct-authoritative resolution probe (see the top-of-file
 * comment). Prints one IPv4 to stdout on success; prints nothing and exits 1
 * when the name does not resolve consistently; exits 2 on usage/config
 * errors. Always prints one line per discovered nameserver on stderr. */
static int run_check(int argc, char **argv, int first) {
    const char *host = argc > first ? argv[first] : getenv("DDNS_HOST");
    const char *domain = argc > first + 1 ? argv[first + 1] : getenv("DDNS_DOMAIN");

    if (!host || !*host || !domain || !*domain) {
        print_usage(argv[0]);
        return 2;
    }

    /* Parse the test-only overrides at the boundary: bad input is a usage
     * error (exit 2), never a silent misconfiguration. */
    struct in_addr resolver_override;
    unsigned short resolver_override_port = 0;
    int ov = parse_resolver_override(getenv("DDNS_RESOLVER"), &resolver_override,
                                     &resolver_override_port);
    if (ov < 0) {
        return 2;
    }
    long auth_port = parse_authoritative_port(getenv("DDNS_AUTHORITATIVE_PORT"));
    if (auth_port < 0) {
        return 2;
    }

    /* Required expected IP (3rd positional arg or DDNS_EXPECTED_IP): the
     * check's contract is "every NS returns THIS address", so a missing
     * expected IP is a usage error -- never an agreement-only success. */
    const char *expected_arg =
        argc > first + 2 ? argv[first + 2] : getenv("DDNS_EXPECTED_IP");
    if (expected_arg == NULL || *expected_arg == '\0') {
        fprintf(stderr,
                "strim-ddns: check requires an expected IPv4 "
                "(third argument or DDNS_EXPECTED_IP)\n");
        print_usage(argv[0]);
        return 2;
    }
    struct in_addr expected;
    if (inet_pton(AF_INET, expected_arg, &expected) != 1) {
        fprintf(stderr, "strim-ddns: invalid expected IP '%s'\n",
                expected_arg);
        return 2;
    }

    size_t fqdn_len = strlen(host) + 1 + strlen(domain) + 1;
    char *fqdn = malloc(fqdn_len);
    if (!fqdn) {
        fprintf(stderr, "strim-ddns: out of memory during DNS check\n");
        return 2;
    }
    snprintf(fqdn, fqdn_len, "%s.%s", host, domain);

    /* 1. NS discovery: ask the resolver for the DOMAIN's NS records. Both the
     * production path (system resolver server list) and the test-only
     * DDNS_RESOLVER override go through init_resolver_channel, so the
     * configured 4000 ms x 2 budget always applies. */
    ares_channel_t *resolver_chan = NULL;
    int init_rc = init_resolver_channel(&resolver_chan,
                                        ov > 0 ? &resolver_override : NULL,
                                        resolver_override_port);
    if (init_rc != ARES_SUCCESS) {
        fprintf(stderr, "strim-ddns: failed to initialize the DNS resolver\n");
        free(fqdn);
        return 2;
    }

    struct dns_query_state nsq = {0};
    run_dns_query(resolver_chan, domain, ARES_CLASS_IN, ARES_REC_TYPE_NS, &nsq);
    if (nsq.oom) {
        fprintf(stderr, "strim-ddns: out of memory during DNS check\n");
        ares_destroy(resolver_chan);
        free(fqdn);
        return 2;
    }
    if (nsq.status != ARES_SUCCESS) {
        fprintf(stderr, "check %s not resolved (NS lookup failed: %s)\n",
                fqdn, dns_status_str(nsq.status));
        free(nsq.reply);
        ares_destroy(resolver_chan);
        free(fqdn);
        return 1;
    }
    struct hostent *ns_hosts = NULL;
    int ns_rc = ares_parse_ns_reply(nsq.reply, (int)nsq.reply_len, &ns_hosts);
    free(nsq.reply);
    if (ns_rc != ARES_SUCCESS || ns_hosts == NULL || ns_hosts->h_aliases == NULL) {
        fprintf(stderr, "check %s not resolved (NS lookup failed: %s)\n",
                fqdn, dns_status_str(ns_rc));
        ares_free_hostent(ns_hosts);
        ares_destroy(resolver_chan);
        free(fqdn);
        return 1;
    }

    /* 2. Copy the discovered NS hostnames into probes (the hostent is freed
     * immediately after; the strdup'd names outlive it). */
    struct ns_probe probes[DDNS_MAX_NS];
    memset(probes, 0, sizeof(probes));
    size_t ns_count = 0;
    for (int i = 0; ns_hosts->h_aliases[i] != NULL; i++) {
        if (ns_count >= DDNS_MAX_NS) {
            fprintf(stderr,
                    "check %s not resolved (too many nameservers to verify)\n",
                    fqdn);
            free_probes(probes, ns_count);
            ares_free_hostent(ns_hosts);
            ares_destroy(resolver_chan);
            free(fqdn);
            return 1;
        }
        probes[ns_count].hostname = strdup(ns_hosts->h_aliases[i]);
        if (probes[ns_count].hostname == NULL) {
            fprintf(stderr, "strim-ddns: out of memory during DNS check\n");
            free_probes(probes, ns_count);
            ares_free_hostent(ns_hosts);
            ares_destroy(resolver_chan);
            free(fqdn);
            return 2;
        }
        ns_count++;
    }
    ares_free_hostent(ns_hosts);
    if (ns_count == 0) {
        fprintf(stderr, "check %s not resolved (no NS records)\n", fqdn);
        ares_destroy(resolver_chan);
        free(fqdn);
        return 1;
    }

    /* 3. Resolve every NS hostname's own IPv4 (A) addresses concurrently in
     * one c-ares event loop. AAAA is never queried: only A-record addresses
     * are used for the direct queries. */
    if (resolve_ns_addresses(resolver_chan, probes, ns_count) != 0) {
        fprintf(stderr, "strim-ddns: out of memory during DNS check\n");
        ares_destroy(resolver_chan);
        free_probes(probes, ns_count);
        free(fqdn);
        return 2;
    }
    ares_destroy(resolver_chan);

    size_t ns_with_address = 0;
    for (size_t i = 0; i < ns_count; i++) {
        if (probes[i].n_addresses > 0) {
            ns_with_address++;
        }
    }
    if (ns_with_address == 0) {
        /* Still report one line per NS: every discovered nameserver lacks an
         * IPv4 A record, and the operator must see which ones. */
        for (size_t i = 0; i < ns_count; i++) {
            fprintf(stderr, "check %s ns %s -> none\n", fqdn,
                    probes[i].hostname);
        }
        fprintf(stderr,
                "check %s not resolved (no IPv4 address for the domain's NS)\n",
                fqdn);
        free_probes(probes, ns_count);
        free(fqdn);
        return 1;
    }

    /* 4. Query the FQDN directly against EACH nameserver through that NS's own
     * addresses, all NS queries concurrent in one event loop. */
    if (query_nameservers(probes, ns_count, fqdn,
                          (unsigned short)auth_port) != 0) {
        fprintf(stderr, "strim-ddns: out of memory during DNS check\n");
        free_probes(probes, ns_count);
        free(fqdn);
        return 2;
    }

    struct ns_observation observations[DDNS_MAX_NS];
    for (size_t i = 0; i < ns_count; i++) {
        observations[i].addrs = probes[i].observed;
        observations[i].count = probes[i].n_observed;
    }

    /* Pass only when EVERY nameserver returns the required expected IP. An
     * unreachable or disagreeing NS is "not yet". */
    bool resolved = agreement_all_match(observations, ns_count, expected);
    struct in_addr agreed = expected;

    /* One line per NS: hostname plus the IP it returned (or none), so a
     * lagging nameserver is visible instead of hidden by a faster sibling. */
    for (size_t i = 0; i < ns_count; i++) {
        const char *shown = "none";
        char ipbuf[INET_ADDRSTRLEN];
        if (probes[i].n_observed > 0) {
            struct in_addr pick = resolved ? agreed : probes[i].observed[0];
            if (inet_ntop(AF_INET, &pick, ipbuf, sizeof(ipbuf)) != NULL) {
                shown = ipbuf;
            }
        }
        fprintf(stderr, "check %s ns %s -> %s\n", fqdn, probes[i].hostname,
                shown);
    }

    if (!resolved) {
        char want[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &expected, want, sizeof(want)) == NULL) {
            snprintf(want, sizeof(want), "?");
        }
        fprintf(stderr,
                "check %s not resolved "
                "(expected %s not returned by every nameserver)\n",
                fqdn, want);
        free_probes(probes, ns_count);
        free(fqdn);
        return 1;
    }

    char ip[INET_ADDRSTRLEN];
    if (inet_ntop(AF_INET, &agreed, ip, sizeof(ip)) == NULL) {
        fprintf(stderr, "check %s not resolved (bad A record)\n", fqdn);
        free_probes(probes, ns_count);
        free(fqdn);
        return 1;
    }
    printf("%s\n", ip);
    fprintf(stderr, "check %s -> %s (all %zu nameservers returned it)\n", fqdn,
            ip, ns_count);
    free_probes(probes, ns_count);
    free(fqdn);
    return 0;
}

int main(int argc, char **argv) {
    /* Subcommand dispatch: "update" / "check" select the mode; a bare
     * invocation (no subcommand) is preserved as "update" for the legacy
     * systemd unit. argv[first] is the first config argument in both cases. */
    const char *subcmd = "update";
    int first = 1;
    if (argc > 1 && (strcmp(argv[1], "update") == 0 ||
                     strcmp(argv[1], "check") == 0)) {
        subcmd = argv[1];
        first = 2;
    }
    if (strcmp(subcmd, "check") == 0) {
        return run_check(argc, argv, first);
    }
    return run_update(argc, argv, first);
}