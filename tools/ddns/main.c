/*
 * strim-ddns: Namecheap dynamic-DNS update client.
 *
 * Performs the Namecheap Dynamic DNS HTTPS GET and reports success from the
 * response BODY (the endpoint answers HTTP 200 for both outcomes, so the
 * body is authoritative):
 *   - classic plain-text reply: "Good <ip>" (record updated) or
 *     "No change" (IP unchanged);
 *   - since ~2021 an <interface-response> XML blob (declared UTF-16 but
 *     actually UTF-8; NUL-stripped and text-matched rather than XML-decoded
 *     to sidestep the misdeclared charset) whose success signal is
 *     <ErrCount>0</ErrCount>.
 *
 * Mirrors the gitd reference implementation's ddnsSuccess().
 *
 * Config comes from argv (host domain password_file [ip]) or, when the args
 * are absent, from the DDNS_HOST / DDNS_DOMAIN / DDNS_PASSWORD_FILE /
 * DDNS_IP environment variables. DDNS_ENDPOINT overrides the update URL
 * (testability); DDNS_CA_BUNDLE overrides the CA bundle path
 * (CURLOPT_CAINFO); when unset, libcurl's compiled-in CURL_CA_BUNDLE
 * (/etc/ssl/certs/ca-certificates.crt in the image) is used.
 *
 * Exit: 0 on success, 1 on update/transfer failure, 2 on usage/config errors.
 */

#include <curl/curl.h>

#include <ctype.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DDNS_DEFAULT_ENDPOINT "https://dynamicdns.park-your-domain.com/update"

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

/* build_update_url: assembles
 *   <endpoint>?host=<h>&domain=<d>&password=<p>[&ip=<i>]
 * with every value URL-escaped. Returns a malloc'd string, or NULL on OOM.
 * When ip is omitted the endpoint uses the requester IP (Namecheap
 * behavior; gitd relies on it). */
static char *build_update_url(const char *endpoint, const char *host,
                              const char *domain, const char *password,
                              const char *ip) {
    char *host_e = curl_easy_escape(NULL, host, 0);
    char *domain_e = curl_easy_escape(NULL, domain, 0);
    char *pw_e = curl_easy_escape(NULL, password, 0);
    char *ip_e = (ip && *ip) ? curl_easy_escape(NULL, ip, 0) : NULL;
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

/* perform_update: runs the HTTPS GET, capturing the body into *reply.
 * TLS verification is ON (CURLOPT_SSL_VERIFYPEER=1 + VERIFYHOST=2); the CA
 * bundle comes from ca_bundle when set, else libcurl's compiled-in default.
 * Returns 0 on transfer success (the body decides the outcome), -1 on any
 * transport/TLS error (already printed). */
static int perform_update(const char *url, const char *ca_bundle,
                          struct reply_buffer *reply) {
    CURL *curl = curl_easy_init();
    if (!curl) {
        fprintf(stderr, "strim-ddns: curl_easy_init failed\n");
        return -1;
    }
    char errbuf[CURL_ERROR_SIZE] = {0};
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 15L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "strim-ddns/1.0");
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, reply_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, reply);
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, errbuf);
    if (ca_bundle && *ca_bundle) {
        curl_easy_setopt(curl, CURLOPT_CAINFO, ca_bundle);
    }
    CURLcode rc = curl_easy_perform(curl);
    curl_easy_cleanup(curl);
    if (rc != CURLE_OK) {
        fprintf(stderr, "strim-ddns: transfer failed: %s%s%s\n",
                curl_easy_strerror(rc), errbuf[0] ? ": " : "", errbuf);
        return -1;
    }
    return 0;
}

static void print_usage(const char *prog) {
    fprintf(stderr,
            "usage: %s [host domain password_file [ip]]\n"
            "  config may instead come from DDNS_HOST, DDNS_DOMAIN,\n"
            "  DDNS_PASSWORD_FILE, DDNS_IP; DDNS_ENDPOINT overrides the\n"
            "  update URL; DDNS_CA_BUNDLE overrides the CA bundle path.\n",
            prog);
}

int main(int argc, char **argv) {
    const char *host = argc > 1 ? argv[1] : getenv("DDNS_HOST");
    const char *domain = argc > 2 ? argv[2] : getenv("DDNS_DOMAIN");
    const char *password_file = argc > 3 ? argv[3] : getenv("DDNS_PASSWORD_FILE");
    const char *ip = argc > 4 ? argv[4] : getenv("DDNS_IP");
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
    int rc = perform_update(url, ca_bundle, &reply);
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