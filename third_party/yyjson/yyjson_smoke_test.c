/*
 * yyjson smoke test.
 *
 * Verifies the vendored amalgamated yyjson.c + yyjson.h compile and link for
 * the target architecture, and that the read + mutable write APIs round-trip:
 *   1. parse a small JSON document and read scalar/array/null values back;
 *   2. build a document with the mutable API;
 *   3. write it back to a string;
 *   4. re-parse the written output.
 */
#include "yyjson.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void die(const char *message) {
    fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
}

int main(void) {
    /* 1. Parse a small JSON document and read values back. */
    const char *input = "{\"name\":\"strimserver\",\"port\":1234,"
                        "\"enabled\":true,\"tags\":[\"json\",\"fast\"],\"nil\":null}";
    yyjson_doc *doc = yyjson_read(input, strlen(input), 0);
    if (doc == NULL) die("yyjson_read failed on a valid document");
    yyjson_val *root = yyjson_doc_get_root(doc);
    if (root == NULL) die("root is null");

    const char *name = yyjson_get_str(yyjson_obj_get(root, "name"));
    if (name == NULL || strcmp(name, "strimserver") != 0) die("name field mismatch");

    yyjson_val *port = yyjson_obj_get(root, "port");
    if (!yyjson_is_int(port) || yyjson_get_int(port) != 1234) die("port field mismatch");

    yyjson_val *enabled = yyjson_obj_get(root, "enabled");
    if (!yyjson_is_bool(enabled) || yyjson_get_bool(enabled) != true) {
        die("enabled field mismatch");
    }

    yyjson_val *tags = yyjson_obj_get(root, "tags");
    if (!yyjson_is_arr(tags) || yyjson_arr_size(tags) != 2) die("tags array mismatch");
    yyjson_val *first_tag = yyjson_arr_get_first(tags);
    if (first_tag == NULL || strcmp(yyjson_get_str(first_tag), "json") != 0) {
        die("tags[0] mismatch");
    }

    yyjson_val *nil = yyjson_obj_get(root, "nil");
    if (!yyjson_is_null(nil)) die("nil field mismatch");

    yyjson_doc_free(doc);

    /* 2. Build a document with the mutable API. */
    yyjson_mut_doc *mdoc = yyjson_mut_doc_new(NULL);
    if (mdoc == NULL) die("yyjson_mut_doc_new failed");
    yyjson_mut_val *mroot = yyjson_mut_obj(mdoc);
    if (mroot == NULL) die("yyjson_mut_obj failed");
    if (!yyjson_mut_obj_add_str(mdoc, mroot, "lib", "yyjson")) die("add_str failed");
    if (!yyjson_mut_obj_add_int(mdoc, mroot, "revision", 1300)) die("add_int failed");
    if (!yyjson_mut_obj_add_bool(mdoc, mroot, "ok", true)) die("add_bool failed");
    yyjson_mut_doc_set_root(mdoc, mroot);

    /* 3. Write the built document back to a string. */
    size_t len = 0;
    char *out = yyjson_mut_write(mdoc, 0, &len);
    if (out == NULL) die("yyjson_mut_write failed");
    if (len == 0) die("yyjson_mut_write returned empty output");
    if (strstr(out, "\"lib\":\"yyjson\"") == NULL) die("written output missing lib field");

    /* 4. Round-trip the written document: it must parse again. */
    yyjson_doc *rt = yyjson_read(out, len, 0);
    if (rt == NULL) die("round-trip parse failed");
    yyjson_val *rt_root = yyjson_doc_get_root(rt);
    yyjson_val *rt_ok = yyjson_obj_get(rt_root, "ok");
    if (!yyjson_is_bool(rt_ok) || yyjson_get_bool(rt_ok) != true) {
        die("round-trip ok mismatch");
    }
    yyjson_doc_free(rt);

    free(out);
    yyjson_mut_doc_free(mdoc);

    printf("yyjson smoke test PASSED (parse, read, mutate, write, re-parse)\n");
    return 0;
}