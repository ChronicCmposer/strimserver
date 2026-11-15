/*
 * agreement.c: pure decision logic for the per-nameserver agreement check
 * (see agreement.h).
 *
 * Every function is total and side-effect free: guards at the top reject the
 * illegal states (no nameservers, NULL sets, empty observations) so the core
 * loop needs no defensive branches. Comparing in_addr.s_addr is an exact
 * 32-bit IPv4 comparison.
 */
#include "agreement.h"

bool ip_in_set(const struct in_addr *addrs, size_t count, struct in_addr want) {
    if (addrs == NULL) {
        return false;
    }
    for (size_t i = 0; i < count; i++) {
        if (addrs[i].s_addr == want.s_addr) {
            return true;
        }
    }
    return false;
}

bool agreement_all_match(const struct ns_observation *obs, size_t n,
                         struct in_addr expected) {
    if (obs == NULL || n == 0) {
        return false;
    }
    for (size_t i = 0; i < n; i++) {
        if (!ip_in_set(obs[i].addrs, obs[i].count, expected)) {
            return false;
        }
    }
    return true;
}

bool agreement_common_ip(const struct ns_observation *obs, size_t n,
                         struct in_addr *out) {
    if (obs == NULL || out == NULL || n == 0) {
        return false;
    }
    /* A NULL address set with a positive count is an illegal state, not an
     * empty observation: reject it instead of dereferencing it. */
    for (size_t i = 0; i < n; i++) {
        if (obs[i].addrs == NULL && obs[i].count > 0) {
            return false;
        }
    }
    if (obs[0].count == 0) {
        return false;
    }
    /* The agreed address must be one the first nameserver returned; any
     * common address is necessarily in that set, so scanning it is complete. */
    for (size_t j = 0; j < obs[0].count; j++) {
        struct in_addr candidate = obs[0].addrs[j];
        bool present_in_all = true;
        for (size_t i = 1; i < n; i++) {
            if (!ip_in_set(obs[i].addrs, obs[i].count, candidate)) {
                present_in_all = false;
                break;
            }
        }
        if (present_in_all) {
            *out = candidate;
            return true;
        }
    }
    return false;
}
