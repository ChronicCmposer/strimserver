/*
 * doh_extract_test: focused unit test for doh_extract_ipv4().
 *
 * Feeds the five DoH reply shapes the loopback smoke test drives through
 * ddns-test-server and asserts the extracted A record (or the NULL
 * not-resolved outcome). Links the real vendored yyjson so the extractor is
 * exercised against the actual JSON parser the binary uses.
 *
 *   (a) single A record                    -> 1.2.3.4
 *   (b) empty reply (no Answer)            -> not resolved
 *   (c) non-zero Status                    -> not resolved
 *   (d) leading CNAME then an A record     -> 5.6.7.8 (CNAME skipped)
 *   (e) A record with non-IPv4 data        -> not resolved
 */
#include "doh.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

/* expect_ip: run the extractor over json and require either the exact
 * dotted-quad want, or (want == NULL) a NULL not-resolved outcome. An
 * unexpected out-of-memory signal is a failure. */
static void expect_ip(const char *name, const char *json, const char *want) {
    bool oom = false;
    char *ip = doh_extract_ipv4(json, strlen(json), &oom);
    if (oom) {
        fprintf(stderr, "FAIL %s: unexpected out-of-memory\n", name);
        failures++;
        free(ip);
        return;
    }
    if (want == NULL) {
        if (ip != NULL) {
            fprintf(stderr, "FAIL %s: expected not-resolved, got %s\n",
                    name, ip);
            failures++;
        }
    } else if (ip == NULL || strcmp(ip, want) != 0) {
        fprintf(stderr, "FAIL %s: expected %s, got %s\n",
                name, want, ip ? ip : "(null)");
        failures++;
    }
    free(ip);
}

int main(void) {
    expect_ip("single A",
              "{\"Status\":0,\"Answer\":[{\"type\":1,\"data\":\"1.2.3.4\"}]}",
              "1.2.3.4");
    expect_ip("empty reply", "{\"Status\":0}", NULL);
    expect_ip("non-zero status", "{\"Status\":3}", NULL);
    expect_ip("CNAME then A",
              "{\"Status\":0,\"Answer\":[{\"type\":5,\"data\":\"cname.\"},"
              "{\"type\":1,\"data\":\"5.6.7.8\"}]}",
              "5.6.7.8");
    expect_ip("non-IPv4 data",
              "{\"Status\":0,\"Answer\":[{\"type\":1,\"data\":\"not-an-ip\"}]}",
              NULL);

    if (failures != 0) {
        fprintf(stderr, "FAIL: %d extractor assertion(s)\n", failures);
        return 1;
    }
    printf("doh extractor unit test PASSED (5 reply shapes)\n");
    return 0;
}