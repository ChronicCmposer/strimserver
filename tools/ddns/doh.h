/*
 * doh.h: DNS-over-HTTPS (DoH) JSON reply extraction for strim-ddns check.
 *
 * The extraction lives in its own translation unit (doh.c) so the pure
 * JSON -> A-record function can be unit-tested directly against the vendored
 * yyjson parser (see doh_extract_test.c).
 */
#ifndef STRIM_DDNS_DOH_H
#define STRIM_DDNS_DOH_H

#include <stdbool.h>
#include <stddef.h>

/* doh_extract_ipv4: parse a DoH JSON reply body (Google / RFC 8484 JSON
 * response format) and return the first IPv4 address found.
 *
 * Parse-don't-validate: the raw reply bytes are parsed at the boundary and
 * only typed values flow through the extraction. The function requires a
 * top-level object with Status == 0 and an Answer array, then scans
 * Answer[] for the first element whose type is 1 (an A record) and whose
 * data parses as an IPv4 address (inet_pton); CNAME and other record types
 * are skipped.
 *
 * Returns a malloc'd NUL-terminated dotted-quad string on success, or NULL
 * when the reply is not a resolved A answer (unparseable JSON, Status != 0,
 * missing/non-array Answer, no type==1 element, non-IPv4 data). Sets *oom
 * to true iff the NULL came from an out-of-memory condition (strdup
 * failure); callers must distinguish that from a genuine not-resolved
 * answer.
 */
char *doh_extract_ipv4(const char *json, size_t len, bool *oom);

#endif /* STRIM_DDNS_DOH_H */