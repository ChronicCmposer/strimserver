/*
 * doh.c: DoH JSON reply extraction (see doh.h).
 *
 * Guard clauses at the top of the scan; every failure path funnels through
 * the single `out` label so the yyjson document is always freed.
 */
#include "doh.h"

#include "yyjson.h"

#include <arpa/inet.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

char *doh_extract_ipv4(const char *json, size_t len, bool *oom) {
    *oom = false;
    yyjson_doc *doc = yyjson_read(json, len, 0);
    if (doc == NULL) {
        return NULL; /* unparseable reply: not resolved */
    }

    char *ip = NULL;
    yyjson_val *root = yyjson_doc_get_root(doc);

    yyjson_val *status = yyjson_obj_get(root, "Status");
    if (!yyjson_is_int(status) || yyjson_get_int(status) != 0) {
        goto out; /* non-zero DNS status: not resolved */
    }

    yyjson_val *answer = yyjson_obj_get(root, "Answer");
    if (!yyjson_is_arr(answer)) {
        goto out; /* missing Answer array: not resolved */
    }

    size_t idx, max;
    yyjson_val *item;
    yyjson_arr_foreach(answer, idx, max, item) {
        yyjson_val *type = yyjson_obj_get(item, "type");
        if (!yyjson_is_int(type) || yyjson_get_int(type) != 1) {
            continue; /* skip CNAME etc.; only A records carry IPv4 */
        }
        const char *data = yyjson_get_str(yyjson_obj_get(item, "data"));
        if (data == NULL) {
            continue;
        }
        struct in_addr addr;
        if (inet_pton(AF_INET, data, &addr) != 1) {
            continue; /* data was not a valid IPv4 address */
        }
        ip = strdup(data);
        if (ip == NULL) {
            *oom = true; /* fail loud upstream: NULL + *oom means OOM */
        }
        break;
    }

out:
    yyjson_doc_free(doc);
    return ip;
}