/*
 * strim-ddns: Namecheap dynamic-DNS update client + DNS-over-HTTPS probe.
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
 *   check <host> <domain>
 *     Resolves $host.$domain's A records over DNS-over-HTTPS (DoH): first
 *     Google's dns.google/resolve, and on a transport or parse failure
 *     Cloudflare's dns-query (with an Accept: application/dns-json header).
 *     Prints the first IPv4 address to stdout, or exits 1 having printed
 *     nothing when the name does not resolve.
 *
 * Config comes from argv (host domain password_file [ip]) or, when the args
 * are absent, from the DDNS_HOST / DDNS_DOMAIN / DDNS_PASSWORD_FILE /
 * DDNS_IP environment variables. DDNS_ENDPOINT overrides the update URL
 * (testability); DDNS_DOH_ENDPOINT overrides the DoH endpoint (testability;
 * when set, check uses ONLY it, with no fallback); DDNS_DOH_PRIMARY_ENDPOINT
 * and DDNS_DOH_FALLBACK_ENDPOINT override the first (Google) and fallback
 * (Cloudflare) DoH endpoints of the fallback path (testability);
 * DDNS_CHECK_TIMEOUT caps each check DoH query in seconds (default 6; the
 * update query stays at 15); DDNS_CA_BUNDLE overrides the CA bundle path
 * (CURLOPT_CAINFO); when unset, libcurl's compiled-in CURL_CA_BUNDLE
 * (/etc/ssl/certs/ca-certificates.crt in the image) is used.
 *
 * Exit: 0 on success, 1 on update/transfer failure or a not-resolved check,
 * 2 on usage/config errors.
 */

#include <curl/curl.h>

#include "doh.h"

#include <ctype.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DDNS_DEFAULT_ENDPOINT "https://dynamicdns.park-your-domain.com/update"

/* HTTPS timeouts: the update path is a single Namecheap GET that may take up
 * to 15s on a slow box; the check probe runs twice per attempt (Google +
 * Cloudflare fallback) inside deploy.sh's retry loop, so each check query is
 * capped much lower (DDNS_CHECK_TIMEOUT, default 6s) to keep the loop's
 * wall-clock budget real. */
#define DDNS_UPDATE_TIMEOUT_SECS 15L
#define DDNS_CHECK_TIMEOUT_DEFAULT_SECS 6L

/* DoH endpoints: Google first, Cloudflare as the fallback. dns.google's
 * /resolve returns JSON by default; Cloudflare's RFC 8484-style /dns-query
 * needs the JSON Accept header. */
#define DOH_GOOGLE_ENDPOINT "https://dns.google/resolve"
#define DOH_CLOUDFLARE_ENDPOINT "https://cloudflare-dns.com/dns-query"
#define DOH_CLOUDFLARE_ACCEPT "Accept: application/dns-json"

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

/* build_doh_url: assembles <endpoint>?name=<fqdn>&type=A with the fqdn
 * URL-escaped. Returns a malloc'd string, or NULL on failure. */
static char *build_doh_url(const char *endpoint, const char *fqdn) {
    char *fqdn_e = url_escape(fqdn);
    if (!fqdn_e) {
        return NULL;
    }
    size_t need = strlen(endpoint) + strlen(fqdn_e) + 32;
    char *url = malloc(need);
    if (!url) {
        curl_free(fqdn_e);
        return NULL;
    }
    snprintf(url, need, "%s?name=%s&type=A", endpoint, fqdn_e);
    curl_free(fqdn_e);
    return url;
}

/* perform_https_get: runs the HTTPS GET, capturing the body into *reply.
 * TLS verification is ON (CURLOPT_SSL_VERIFYPEER=1 + VERIFYHOST=2); the CA
 * bundle comes from ca_bundle when set, else libcurl's compiled-in default.
 * When accept_header is set it is sent verbatim (e.g. the DoH JSON Accept
 * header); when quiet is true, transport errors are not printed (the check
 * probe's contract is silence on stdout and stderr -- the exit code is the
 * answer). timeout_secs bounds the whole transfer (CURLOPT_TIMEOUT).
 * Returns 0 on transfer success (the body decides the outcome), -1 on any
 * transport/TLS error (already printed unless quiet). */
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

/* doh_resolve: one DoH query for fqdn's A records against endpoint, bounded
 * by timeout_secs. Returns a malloc'd IPv4 string on success; on a transport
 * failure or a reply that does not resolve, prints nothing and returns NULL
 * (the caller decides fallback or the not-resolved exit). Sets *oom when an
 * out-of-memory condition aborted the lookup, so the caller can distinguish
 * a hard program error from a genuine not-resolved answer. */
static char *doh_resolve(const char *endpoint, const char *accept_header,
                         const char *fqdn, const char *ca_bundle,
                         long timeout_secs, bool *oom) {
    *oom = false;
    char *url = build_doh_url(endpoint, fqdn);
    if (!url) {
        *oom = true;
        return NULL;
    }
    struct reply_buffer reply = {0};
    int rc = perform_https_get(url, ca_bundle, accept_header, /*quiet=*/true,
                               timeout_secs, &reply);
    free(url);
    if (rc != 0) {
        free(reply.data);
        return NULL;
    }
    char *ip = doh_extract_ipv4(reply.data, reply.len, oom);
    free(reply.data);
    return ip;
}

static void print_usage(const char *prog) {
    fprintf(stderr,
            "usage: %s update <host> <domain> [password_file] [ip]\n"
            "       %s check <host> <domain>\n"
            "  the bare invocation %s <host> <domain> [password_file] [ip]\n"
            "  is treated as \"update\" (legacy).\n"
            "  config may instead come from DDNS_HOST, DDNS_DOMAIN,\n"
            "  DDNS_PASSWORD_FILE, DDNS_IP; DDNS_ENDPOINT overrides the\n"
            "  update URL; DDNS_DOH_ENDPOINT overrides the DoH endpoint\n"
            "  (single, no fallback); DDNS_DOH_PRIMARY_ENDPOINT and\n"
            "  DDNS_DOH_FALLBACK_ENDPOINT override the fallback-path\n"
            "  endpoints; DDNS_CHECK_TIMEOUT caps each check query in\n"
            "  seconds (default 6); DDNS_CA_BUNDLE overrides the CA bundle.\n",
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

/* run_check: the DoH resolution probe. Resolves $host.$domain's A records
 * over the primary DoH endpoint, and on a transport/parse failure the
 * fallback endpoint (Google -> Cloudflare; both overridable for tests), and
 * prints the first IPv4 address, or exits 1 having printed nothing when the
 * name does not resolve. Usage/config errors exit 2. */
static int run_check(int argc, char **argv, int first) {
    const char *host = argc > first ? argv[first] : getenv("DDNS_HOST");
    const char *domain = argc > first + 1 ? argv[first + 1] : getenv("DDNS_DOMAIN");
    const char *endpoint = getenv("DDNS_DOH_ENDPOINT");
    const char *primary_env = getenv("DDNS_DOH_PRIMARY_ENDPOINT");
    const char *fallback_env = getenv("DDNS_DOH_FALLBACK_ENDPOINT");
    const char *ca_bundle = getenv("DDNS_CA_BUNDLE");

    if (!host || !*host || !domain || !*domain) {
        print_usage(argv[0]);
        return 2;
    }

    /* Parse the per-check query timeout at the boundary: DDNS_CHECK_TIMEOUT
     * (seconds), defaulting to the short check budget. */
    long timeout_secs = DDNS_CHECK_TIMEOUT_DEFAULT_SECS;
    const char *timeout_env = getenv("DDNS_CHECK_TIMEOUT");
    if (timeout_env && *timeout_env) {
        char *end = NULL;
        long parsed = strtol(timeout_env, &end, 10);
        if (end == timeout_env || *end != '\0' || parsed <= 0) {
            fprintf(stderr,
                    "strim-ddns: invalid DDNS_CHECK_TIMEOUT '%s' "
                    "(expected a positive integer of seconds)\n",
                    timeout_env);
            return 2;
        }
        timeout_secs = parsed;
    }

    size_t fqdn_len = strlen(host) + 1 + strlen(domain) + 1;
    char *fqdn = malloc(fqdn_len);
    if (!fqdn) {
        return 2;
    }
    snprintf(fqdn, fqdn_len, "%s.%s", host, domain);

    char *ip = NULL;
    bool oom = false;
    if (endpoint && *endpoint) {
        ip = doh_resolve(endpoint, NULL, fqdn, ca_bundle, timeout_secs, &oom);
    } else {
        const char *primary = (primary_env && *primary_env)
                                  ? primary_env
                                  : DOH_GOOGLE_ENDPOINT;
        const char *fallback = (fallback_env && *fallback_env)
                                   ? fallback_env
                                   : DOH_CLOUDFLARE_ENDPOINT;
        ip = doh_resolve(primary, NULL, fqdn, ca_bundle, timeout_secs, &oom);
        if (!ip && !oom) {
            ip = doh_resolve(fallback, DOH_CLOUDFLARE_ACCEPT, fqdn, ca_bundle,
                             timeout_secs, &oom);
        }
    }
    free(fqdn);

    if (!ip) {
        if (oom) {
            fprintf(stderr, "strim-ddns: out of memory during DoH lookup\n");
            return 2;
        }
        return 1; /* not resolved: nothing printed */
    }
    printf("%s\n", ip);
    free(ip);
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