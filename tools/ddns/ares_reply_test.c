/*
 * ares_reply_test: focused unit test for ares_parse_a_reply() over wire
 * shapes.
 *
 * Feeds the DNS wire-format responses the loopback authoritative test double
 * serves (built with the same dns_wire.c codec, linked against the real
 * vendored c-ares) into ares_parse_a_reply and asserts the extracted A
 * record (or the not-resolved outcome). No networking: the reply bytes are
 * handed straight to the parser, so the extractor is exercised against the
 * actual c-ares the binary links.
 *
 *   (a) single A                        -> 1.2.3.4
 *   (b) CNAME then A (multi-record)     -> 5.6.7.8 (CNAME chased, A wins)
 *   (c) empty NOERROR (no answers)      -> not resolved (ARES_ENODATA)
 *   (d) CNAME only (no A)               -> not resolved (ARES_ENODATA)
 */
#include "dns_wire.h"

#include <ares.h>

#include <arpa/inet.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

/* build_response: wrap dns_wire_build_response with a fixed synthetic query
 * for testhost.example.com so the caller only picks the answers. Returns the
 * response length, or -1. */
static int build_response(int rcode, const struct dns_wire_answer *answers,
                          size_t nanswers, uint8_t *out, size_t out_cap) {
    /* A minimal DNS query for testhost.example.com A IN. */
    static const uint8_t query[] = {
        0x12, 0x34,             /* id */
        0x01, 0x00,             /* RD */
        0x00, 0x01,             /* QDCOUNT */
        0x00, 0x00,             /* ANCOUNT */
        0x00, 0x00,             /* NSCOUNT */
        0x00, 0x00,             /* ARCOUNT */
        8, 't', 'e', 's', 't', 'h', 'o', 's', 't', /* label "testhost" */
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e',      /* label "example" */
        3, 'c', 'o', 'm',                          /* label "com" */
        0,                                          /* root */
        0x00, 0x01,             /* QTYPE A */
        0x00, 0x01,             /* QCLASS IN */
    };
    struct dns_wire_query q;
    if (dns_wire_parse_query(query, sizeof(query), &q) != 0) {
        fprintf(stderr, "FAIL: internal query parse failed\n");
        exit(2);
    }
    /* Authoritative-style reply: RA=0 (an authoritative server never claims
     * recursion available); c-ares ignores RA, so this is purely semantic. */
    return dns_wire_build_response(&q, rcode, answers, nanswers, out, out_cap,
                                   false);
}

/* expect_ip: parse the response and require either the exact dotted-quad
 * want, or (want == NULL) a not-resolved outcome. */
static void expect_ip(const char *name, int rcode,
                      const struct dns_wire_answer *answers, size_t nanswers,
                      const char *want) {
    uint8_t wire[512];
    int len = build_response(rcode, answers, nanswers, wire, sizeof(wire));
    if (len < 0) {
        fprintf(stderr, "FAIL %s: could not build response\n", name);
        failures++;
        return;
    }
    struct ares_addrttl addrs[8];
    int n_addrs = 8;
    int rc = ares_parse_a_reply(wire, len, NULL, addrs, &n_addrs);
    if (want == NULL) {
        if (rc == ARES_SUCCESS && n_addrs > 0) {
            char got[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &addrs[0].ipaddr, got, sizeof(got));
            fprintf(stderr, "FAIL %s: expected not-resolved, got %s\n",
                    name, got);
            failures++;
        }
        return;
    }
    if (rc != ARES_SUCCESS || n_addrs <= 0) {
        fprintf(stderr, "FAIL %s: expected %s, got rc=%d n_addrs=%d\n",
                name, want, rc, n_addrs);
        failures++;
        return;
    }
    char got[INET_ADDRSTRLEN];
    if (inet_ntop(AF_INET, &addrs[0].ipaddr, got, sizeof(got)) == NULL ||
        strcmp(got, want) != 0) {
        fprintf(stderr, "FAIL %s: expected %s, got %s\n", name, want, got);
        failures++;
    }
}

int main(void) {
    struct dns_wire_answer a;
    memset(&a, 0, sizeof(a));

    /* (a) single A */
    a.owner = "testhost.example.com";
    a.type = DNS_WIRE_TYPE_A;
    a.data = "1.2.3.4";
    a.ttl = 300;
    expect_ip("single A", DNS_WIRE_RCODE_NOERROR, &a, 1, "1.2.3.4");

    /* (b) CNAME then A: the parser must chase the CNAME and surface the A */
    struct dns_wire_answer chain[2];
    memset(chain, 0, sizeof(chain));
    chain[0].owner = "testhost.example.com";
    chain[0].type = DNS_WIRE_TYPE_CNAME;
    chain[0].data = "alias.example.com";
    chain[0].ttl = 300;
    chain[1].owner = "alias.example.com";
    chain[1].type = DNS_WIRE_TYPE_A;
    chain[1].data = "5.6.7.8";
    chain[1].ttl = 300;
    expect_ip("CNAME then A", DNS_WIRE_RCODE_NOERROR, chain, 2, "5.6.7.8");

    /* (c) empty NOERROR: not resolved */
    expect_ip("empty", DNS_WIRE_RCODE_NOERROR, NULL, 0, NULL);

    /* (d) CNAME only, no A: not resolved */
    struct dns_wire_answer cname_only;
    memset(&cname_only, 0, sizeof(cname_only));
    cname_only.owner = "testhost.example.com";
    cname_only.type = DNS_WIRE_TYPE_CNAME;
    cname_only.data = "alias.example.com";
    cname_only.ttl = 300;
    expect_ip("CNAME only", DNS_WIRE_RCODE_NOERROR, &cname_only, 1, NULL);

    if (failures != 0) {
        fprintf(stderr, "FAIL: %d ares_reply assertion(s)\n", failures);
        return 1;
    }
    printf("ares reply extraction unit test PASSED (4 wire shapes)\n");
    return 0;
}