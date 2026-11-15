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
#include "agreement.h"
#include "dns_wire.h"

#include <ares.h>

#include <arpa/inet.h>
#include <netinet/in.h>
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

/* make_addr: parse a dotted-quad for the agreement tests. */
static struct in_addr make_addr(const char *ip) {
    struct in_addr a;
    if (inet_pton(AF_INET, ip, &a) != 1) {
        fprintf(stderr, "FAIL: internal bad address '%s'\n", ip);
        exit(2);
    }
    return a;
}

/* check_agreement_helpers: the per-nameserver decision logic in isolation. */
static void check_agreement_helpers(void) {
    struct in_addr one_two = make_addr("1.2.3.4");
    struct in_addr five_six = make_addr("5.6.7.8");
    struct in_addr nine = make_addr("9.9.9.9");

    struct in_addr ns1[] = {one_two, five_six};
    struct in_addr ns2[] = {one_two};
    struct in_addr ns3[] = {nine};

    if (!ip_in_set(ns1, 2, one_two) || !ip_in_set(ns1, 2, five_six) ||
        ip_in_set(ns1, 2, nine)) {
        fprintf(stderr, "FAIL agreement: ip_in_set membership\n");
        failures++;
    }

    struct ns_observation agree[] = {{ns1, 2}, {ns2, 1}};
    struct ns_observation disagree[] = {{ns1, 2}, {ns3, 1}};
    struct ns_observation empty_last[] = {{ns1, 2}, {ns2, 0}};

    if (!agreement_all_match(agree, 2, one_two)) {
        fprintf(stderr, "FAIL agreement: all_match should accept common IP\n");
        failures++;
    }
    if (agreement_all_match(agree, 2, nine) ||
        agreement_all_match(disagree, 2, one_two) ||
        agreement_all_match(empty_last, 2, one_two)) {
        fprintf(stderr, "FAIL agreement: all_match false positives\n");
        failures++;
    }

    struct in_addr out;
    if (!agreement_common_ip(agree, 2, &out) ||
        out.s_addr != one_two.s_addr) {
        fprintf(stderr, "FAIL agreement: common_ip should pick 1.2.3.4\n");
        failures++;
    }
    if (agreement_common_ip(disagree, 2, &out) ||
        agreement_common_ip(empty_last, 2, &out)) {
        fprintf(stderr, "FAIL agreement: common_ip false positives\n");
        failures++;
    }
    struct ns_observation single[] = {{ns1, 2}};
    if (!agreement_common_ip(single, 1, &out) ||
        out.s_addr != one_two.s_addr) {
        fprintf(stderr, "FAIL agreement: single observation trivially agrees\n");
        failures++;
    }
    /* A NULL address set with count > 0 is an illegal state, not an empty
     * observation; it must be rejected rather than dereferenced. */
    struct ns_observation null_first[] = {{NULL, 1}};
    struct ns_observation null_later[] = {{ns2, 1}, {NULL, 2}};
    if (agreement_common_ip(null_first, 1, &out) ||
        agreement_common_ip(null_later, 2, &out)) {
        fprintf(stderr,
                "FAIL agreement: common_ip must reject NULL address sets\n");
        failures++;
    }
}

/* check_multiple_a_and_ipv4_only: several A records are all surfaced, and an
 * AAAA-only answer never yields an IPv4 (only A-record NS addresses are used). */
static void check_multiple_a_and_ipv4_only(void) {
    struct dns_wire_answer answers[2];
    memset(answers, 0, sizeof(answers));
    answers[0].owner = "testhost.example.com";
    answers[0].type = DNS_WIRE_TYPE_A;
    answers[0].data = "1.2.3.4";
    answers[0].ttl = 300;
    answers[1].owner = "testhost.example.com";
    answers[1].type = DNS_WIRE_TYPE_A;
    answers[1].data = "5.6.7.8";
    answers[1].ttl = 300;

    uint8_t wire[512];
    int len = build_response(DNS_WIRE_RCODE_NOERROR, answers, 2, wire,
                             sizeof(wire));
    struct ares_addrttl addrs[8];
    int n_addrs = 8;
    int rc = ares_parse_a_reply(wire, len, NULL, addrs, &n_addrs);
    if (rc != ARES_SUCCESS || n_addrs != 2) {
        fprintf(stderr, "FAIL multi-A: expected 2 addresses, rc=%d n=%d\n", rc,
                n_addrs);
        failures++;
    } else {
        struct in_addr parsed[2] = {addrs[0].ipaddr, addrs[1].ipaddr};
        struct ns_observation obs[] = {{parsed, 2}};
        if (!agreement_all_match(obs, 1, make_addr("5.6.7.8"))) {
            fprintf(stderr, "FAIL multi-A: second address should match\n");
            failures++;
        }
    }

    struct dns_wire_answer aaaa;
    memset(&aaaa, 0, sizeof(aaaa));
    aaaa.owner = "testhost.example.com";
    aaaa.type = DNS_WIRE_TYPE_AAAA;
    aaaa.data = "2001:db8::1";
    aaaa.ttl = 300;
    len = build_response(DNS_WIRE_RCODE_NOERROR, &aaaa, 1, wire, sizeof(wire));
    n_addrs = 8;
    rc = ares_parse_a_reply(wire, len, NULL, addrs, &n_addrs);
    if (rc == ARES_SUCCESS && n_addrs > 0) {
        fprintf(stderr, "FAIL ipv4-only: AAAA answer surfaced as IPv4\n");
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

    check_agreement_helpers();
    check_multiple_a_and_ipv4_only();

    if (failures != 0) {
        fprintf(stderr, "FAIL: %d ares_reply assertion(s)\n", failures);
        return 1;
    }
    printf("ares reply extraction unit test PASSED "
           "(4 wire shapes + agreement + ipv4-only)\n");
    return 0;
}