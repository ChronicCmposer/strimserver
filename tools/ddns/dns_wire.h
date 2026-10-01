/*
 * dns_wire.h: minimal RFC 1035 DNS wire-format codec for the ddns test
 * double (ddns_test_server.c) and the focused A-record extraction test
 * (ares_reply_test.c).
 *
 * Deliberately tiny: it parses the header + question of an inbound query and
 * builds a response with a verbatim question echo plus a fixed list of
 * answer RRs. Names are encoded uncompressed (RFC 1035 allows this; no
 * compression pointers needed for a test double). This is test infrastructure
 * only -- the strim-ddns binary itself never touches raw DNS wire bytes; it
 * uses c-ares (ares_query + ares_parse_a_reply) for every parse at the
 * boundary.
 */
#ifndef STRIM_DDNS_DNS_WIRE_H
#define STRIM_DDNS_DNS_WIRE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* DNS record types / classes the test drives (RFC 1035 / RFC 3596). */
enum {
    DNS_WIRE_TYPE_A = 1,
    DNS_WIRE_TYPE_NS = 2,
    DNS_WIRE_TYPE_CNAME = 5,
    DNS_WIRE_TYPE_AAAA = 28,
    DNS_WIRE_CLASS_IN = 1,
};

/* DNS response codes (RFC 1035). */
enum {
    DNS_WIRE_RCODE_NOERROR = 0,
    DNS_WIRE_RCODE_SERVFAIL = 2,
    DNS_WIRE_RCODE_NXDOMAIN = 3,
    DNS_WIRE_RCODE_REFUSED = 5,
};

/* RFC 1035 caps a domain name at 255 octets and a label at 63. */
#define DNS_WIRE_NAME_MAX 255
#define DNS_WIRE_LABEL_MAX 63

/* Parsed view of an inbound DNS query. */
struct dns_wire_query {
    uint16_t id;
    uint16_t flags;
    /* Decoded QNAME as a dotted name without the trailing root dot
     * (e.g. "testhost.example.com"), lowercased, NUL-terminated. */
    char name[DNS_WIRE_NAME_MAX + 1];
    uint16_t qtype;
    uint16_t qclass;
    /* The raw question section (name+type+class, RFC 1035 caps a name at
     * 255 octets), copied out of the query and echoed verbatim into the
     * response so c-ares's question-match check passes. */
    unsigned char question_raw[DNS_WIRE_NAME_MAX + 1 + 4];
    size_t question_len;
};

/* One answer RR to append to a response. */
struct dns_wire_answer {
    const char *owner; /* dotted name, no trailing root dot */
    uint16_t type;     /* DNS_WIRE_TYPE_* */
    const char *data;  /* dotted-quad IPv4 for A; a dotted name for NS/CNAME */
    uint32_t ttl;
};

/* dns_wire_parse_query: parse a DNS query packet. Returns 0 on success, -1
 * on malformed input. */
int dns_wire_parse_query(const uint8_t *buf, size_t len, struct dns_wire_query *q);

/* dns_wire_build_response: build a response packet echoing q's question with
 * the given rcode and answer RRs. recursive selects the RA (recursion
 * available) header bit: set for a recursive-resolver reply, clear for an
 * authoritative reply. Returns the response length (>0) on success, or -1
 * when the packet would exceed out_cap. */
int dns_wire_build_response(const struct dns_wire_query *q, int rcode,
                            const struct dns_wire_answer *answers, size_t nanswers,
                            uint8_t *out, size_t out_cap, bool recursive);

#endif /* STRIM_DDNS_DNS_WIRE_H */