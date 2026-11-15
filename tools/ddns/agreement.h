/*
 * agreement.h: pure per-nameserver agreement helpers for the strim-ddns
 * `check` subcommand.
 *
 * The check queries every discovered nameserver separately and requires the
 * deployed name to resolve consistently across all of them. These helpers
 * hold the decision logic so it can be unit-tested (ares_reply_test) without
 * any networking: each nameserver is reduced to the set of IPv4 addresses it
 * returned, and agreement is a set operation.
 */
#ifndef STRIM_DDNS_AGREEMENT_H
#define STRIM_DDNS_AGREEMENT_H

#include <netinet/in.h>
#include <stdbool.h>
#include <stddef.h>

/* ns_observation: the IPv4 A records one nameserver returned for the name
 * under test. An empty observation (count == 0) means the nameserver was
 * unreachable, errored, or returned no A record -- "not yet". */
struct ns_observation {
    const struct in_addr *addrs;
    size_t count;
};

/* ip_in_set: true when want appears in addrs[0..count). */
bool ip_in_set(const struct in_addr *addrs, size_t count, struct in_addr want);

/* agreement_all_match: true when there is at least one nameserver and every
 * observation is non-empty and contains expected. This is the "expected IP"
 * mode: the deployed public IP must be returned by every nameserver via at
 * least one of its own addresses. */
bool agreement_all_match(const struct ns_observation *obs, size_t n,
                         struct in_addr expected);

/* agreement_common_ip: true when a single IPv4 address appears in every
 * observation, with *out set to it. Every observation must be non-empty; a
 * NULL address set with a positive count is rejected as an illegal state.
 * An empty observation or any disagreement yields false. (The check itself
 * requires an expected IP; this pure helper remains unit-tested set logic.) */
bool agreement_common_ip(const struct ns_observation *obs, size_t n,
                         struct in_addr *out);

#endif /* STRIM_DDNS_AGREEMENT_H */
