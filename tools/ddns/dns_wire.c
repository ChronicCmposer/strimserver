/*
 * dns_wire.c: minimal RFC 1035 DNS wire-format codec (see dns_wire.h).
 *
 * Guard clauses at the top of each function: every malformed-input path
 * returns -1 immediately. Names are encoded uncompressed (no compression
 * pointers); the answer owner names and rdata names are written as plain
 * label sequences, which every resolver accepts. Only the wire shapes the
 * test doubles need are supported (A, NS, CNAME answers), so the codec stays
 * tiny.
 */
#include "dns_wire.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <stdbool.h>
#include <string.h>

#define DNS_WIRE_HDR_LEN 12

/* encode_name: write name as a sequence of length-prefixed labels plus the
 * root zero octet. Returns the number of octets written, or -1 on overflow
 * or an over-long label. */
static int encode_name(const char *name, uint8_t *out, size_t cap, size_t off) {
    size_t pos = off;
    while (*name != '\0') {
        const char *dot = strchr(name, '.');
        size_t n = dot ? (size_t)(dot - name) : strlen(name);
        if (n == 0 || n > DNS_WIRE_LABEL_MAX) {
            return -1;
        }
        if (pos + 1 + n > cap) {
            return -1;
        }
        out[pos++] = (uint8_t)n;
        memcpy(out + pos, name, n);
        pos += n;
        name = dot ? dot + 1 : name + n;
    }
    if (pos + 1 > cap) {
        return -1;
    }
    out[pos++] = 0;
    return (int)(pos - off);
}

int dns_wire_parse_query(const uint8_t *buf, size_t len, struct dns_wire_query *q) {
    if (buf == NULL || q == NULL || len < DNS_WIRE_HDR_LEN) {
        return -1;
    }
    if ((buf[2] & 0x80) != 0) {
        return -1; /* not a query (QR bit set) */
    }
    uint16_t qdcount = (uint16_t)((buf[4] << 8) | buf[5]);
    if (qdcount != 1) {
        return -1;
    }
    q->id = (uint16_t)((buf[0] << 8) | buf[1]);
    q->flags = (uint16_t)((buf[2] << 8) | buf[3]);
    size_t question_start = DNS_WIRE_HDR_LEN;

    size_t pos = DNS_WIRE_HDR_LEN;
    size_t name_len = 0;
    while (pos < len && buf[pos] != 0) {
        uint8_t l = buf[pos];
        if ((l & 0xC0) != 0) {
            return -1; /* compression pointers not valid in a query */
        }
        if (l > DNS_WIRE_LABEL_MAX) {
            return -1;
        }
        pos++;
        if (pos + l > len || name_len + l + 1 > DNS_WIRE_NAME_MAX) {
            return -1;
        }
        if (name_len > 0) {
            q->name[name_len++] = '.';
        }
        for (uint8_t i = 0; i < l; i++) {
            q->name[name_len++] = (char)tolower(buf[pos + i]);
        }
        pos += l;
    }
    if (pos >= len) {
        return -1; /* ran off the end before the root label */
    }
    q->name[name_len] = '\0';
    pos++; /* skip the root label */

    if (pos + 4 > len) {
        return -1;
    }
    q->qtype = (uint16_t)((buf[pos] << 8) | buf[pos + 1]);
    q->qclass = (uint16_t)((buf[pos + 2] << 8) | buf[pos + 3]);
    pos += 4;
    /* Copy the question bytes (root label included) for the verbatim echo. */
    q->question_len = pos - question_start;
    memcpy(q->question_raw, buf + question_start, q->question_len);
    return 0;
}

/* append_answer: write one answer RR at *off. Returns 0 on success, -1 on
 * overflow or bad rdata. */
static int append_answer(const struct dns_wire_answer *a, uint8_t *out,
                         size_t cap, size_t *off) {
    size_t pos = *off;
    int n = encode_name(a->owner, out, cap, pos);
    if (n < 0) {
        return -1;
    }
    pos += (size_t)n;
    if (pos + 10 > cap) {
        return -1;
    }
    out[pos++] = (uint8_t)(a->type >> 8);
    out[pos++] = (uint8_t)(a->type & 0xFF);
    out[pos++] = 0;
    out[pos++] = 1; /* class IN */
    out[pos++] = (uint8_t)(a->ttl >> 24);
    out[pos++] = (uint8_t)(a->ttl >> 16);
    out[pos++] = (uint8_t)(a->ttl >> 8);
    out[pos++] = (uint8_t)(a->ttl & 0xFF);

    if (a->type == DNS_WIRE_TYPE_A) {
        struct in_addr addr;
        if (inet_pton(AF_INET, a->data, &addr) != 1) {
            return -1;
        }
        if (pos + 6 > cap) {
            return -1;
        }
        out[pos++] = 0;
        out[pos++] = 4;
        memcpy(out + pos, &addr, 4);
        pos += 4;
    } else if (a->type == DNS_WIRE_TYPE_NS || a->type == DNS_WIRE_TYPE_CNAME) {
        if (pos + 2 > cap) {
            return -1;
        }
        size_t rdlength_off = pos;
        out[pos++] = 0;
        out[pos++] = 0;
        size_t rdata_start = pos;
        n = encode_name(a->data, out, cap, pos);
        if (n < 0) {
            return -1;
        }
        pos += (size_t)n;
        uint16_t rdlength = (uint16_t)(pos - rdata_start);
        out[rdlength_off] = (uint8_t)(rdlength >> 8);
        out[rdlength_off + 1] = (uint8_t)(rdlength & 0xFF);
    } else {
        return -1; /* unsupported answer type */
    }
    *off = pos;
    return 0;
}

int dns_wire_build_response(const struct dns_wire_query *q, int rcode,
                            const struct dns_wire_answer *answers, size_t nanswers,
                            uint8_t *out, size_t out_cap, bool recursive) {
    if (q == NULL || out == NULL || out_cap < DNS_WIRE_HDR_LEN) {
        return -1;
    }
    /* Echo the query's question section verbatim (parse-don't-validate: the
     * bytes were already validated and copied by dns_wire_parse_query). */
    if (q->question_len > out_cap - DNS_WIRE_HDR_LEN) {
        return -1;
    }
    out[0] = (uint8_t)(q->id >> 8);
    out[1] = (uint8_t)(q->id & 0xFF);
    /* QR=1, opcode from the query, AA=1 (authoritative-style answer),
     * RA=recursive (recursion available only for the resolver role), rcode
     * from the caller. */
    uint16_t flags = (uint16_t)(0x8000 | 0x0400 | (recursive ? 0x0080 : 0) |
                                (q->flags & 0x7800) | (rcode & 0x000F));
    out[2] = (uint8_t)(flags >> 8);
    out[3] = (uint8_t)(flags & 0xFF);
    out[4] = 0;
    out[5] = 1; /* QDCOUNT=1 (question echoed) */
    out[6] = (uint8_t)(nanswers >> 8);
    out[7] = (uint8_t)(nanswers & 0xFF);
    out[8] = 0;
    out[9] = 0; /* NSCOUNT=0 */
    out[10] = 0;
    out[11] = 0; /* ARCOUNT=0 */

    size_t pos = DNS_WIRE_HDR_LEN;
    memcpy(out + pos, q->question_raw, q->question_len);
    pos += q->question_len;
    for (size_t i = 0; i < nanswers; i++) {
        if (append_answer(&answers[i], out, out_cap, &pos) != 0) {
            return -1;
        }
    }
    if (pos > out_cap) {
        return -1;
    }
    return (int)pos;
}