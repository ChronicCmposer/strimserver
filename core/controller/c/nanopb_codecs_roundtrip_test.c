/*
 * nanopb containerd codecs round-trip test (Wave 0-D).
 *
 * Verifies that the generated nanopb codecs (core/controller/c/gen) encode
 * and decode containerd messages losslessly with the FT_POINTER +
 * PB_ENABLE_MALLOC strategy:
 *
 *   1. A containerd.services.containers.v1.Container carrying the hard
 *      cases: an unbounded labels map<string,string>, an unbounded
 *      extensions map<string,google.protobuf.Any>, an Any runtime spec,
 *      and Timestamp fields.
 *   2. A containerd.types.Envelope (the events Subscribe stream message)
 *      whose Event Any wraps a serialized containerd.events.TaskStart --
 *      the Any payload is re-decoded with the TaskStart codec.
 *
 * Every decode is followed by pb_release() to prove the malloc'd pointer
 * fields are fully owned and freeable (leak check is manual/valgrind).
 *
 * License: project code (see LICENSE). The nanopb runtime is zlib.
 */

#include <stdio.h>
#include <string.h>

#include <pb.h>
#include <pb_decode.h>
#include <pb_encode.h>

#include <google/protobuf/any.pb.h>
#include <google/protobuf/timestamp.pb.h>
#include <services/containers/v1/containers.pb.h>
#include <types/event.pb.h>
#include <events/task.pb.h>

static int failures = 0;

#define CHECK(cond)                                                       \
    do {                                                                  \
        if (!(cond)) {                                                    \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                   \
        }                                                                 \
    } while (0)

/* Arbitrary but realistic type_url values (containerd's typeurl prefix). */
#define SPEC_URL "types.containerd.io/opencontainers/runtime-spec/specs-go/v1.Spec"
#define TASKSTART_URL "types.containerd.io/containerd.events.TaskStart"

/* =========================================================================
 * Container round-trip: labels map + extensions map<string,Any> + spec Any
 * ========================================================================= */
static void test_container_roundtrip(void) {
    containerd_services_containers_v1_Container msg =
        containerd_services_containers_v1_Container_init_zero;

    /* Labels: unbounded map<string,string>, two entries. */
    containerd_services_containers_v1_Container_LabelsEntry labels[2];
    labels[0].key = "app";
    labels[0].value = "strim";
    labels[1].key = "tier";
    labels[1].value = "streaming";
    msg.labels = labels;
    msg.labels_count = 2;

    /* Extensions: unbounded map<string,Any>, one entry whose Any payload is
     * an opaque blob (the test only round-trips the bytes). */
    containerd_services_containers_v1_Container_ExtensionsEntry extensions[1];
    static const uint8_t ext_payload[] = {0x0a, 0x03, 'o', 'c', 'i'};
    PB_BYTES_ARRAY_T(5) ext_value;
    ext_value.size = sizeof(ext_payload);
    memcpy(ext_value.bytes, ext_payload, sizeof(ext_payload));
    extensions[0].key = "com.strim.test";
    extensions[0].has_value = true;
    extensions[0].value.type_url = "types.containerd.io/containerd.test.Extension";
    extensions[0].value.value = (pb_bytes_array_t *)&ext_value;
    msg.extensions = extensions;
    msg.extensions_count = 1;

    /* Spec: Any wrapping an OCI runtime spec (opaque bytes here). */
    static const uint8_t spec_payload[] = {0x12, 0x04, 'b', 'u', 'n', 'd'};
    PB_BYTES_ARRAY_T(6) spec_value;
    spec_value.size = sizeof(spec_payload);
    memcpy(spec_value.bytes, spec_payload, sizeof(spec_payload));
    msg.has_spec = true;
    msg.spec.type_url = SPEC_URL;
    msg.spec.value = (pb_bytes_array_t *)&spec_value;

    /* Plain string fields. */
    msg.id = "ctr-1";
    msg.image = "docker.io/library/alpine:latest";
    msg.snapshotter = "overlayfs";
    msg.snapshot_key = "snap-1";
    msg.sandbox = "sbx-0";

    /* Runtime submessage: string + an absent (but present-flagged) options
     * Any is deliberately NOT set; encode must skip it. */
    msg.has_runtime = true;
    msg.runtime.name = "io.containerd.runc.v2";

    /* Timestamps. */
    msg.has_created_at = true;
    msg.created_at.seconds = 1700000000;
    msg.created_at.nanos = 123;
    msg.has_updated_at = true;
    msg.updated_at.seconds = 1700000001;

    /* Encode. */
    uint8_t buf[2048];
    pb_ostream_t ostream = pb_ostream_from_buffer(buf, sizeof(buf));
    CHECK(pb_encode(&ostream,
                    containerd_services_containers_v1_Container_fields, &msg));
    size_t encoded_len = ostream.bytes_written;
    CHECK(encoded_len > 0);

    /* Decode into a fresh struct (PB_ENABLE_MALLOC allocates all pointers). */
    containerd_services_containers_v1_Container dec =
        containerd_services_containers_v1_Container_init_zero;
    pb_istream_t istream = pb_istream_from_buffer(buf, encoded_len);
    CHECK(pb_decode(&istream,
                    containerd_services_containers_v1_Container_fields, &dec));

    /* Compare every field. */
    CHECK(dec.id != NULL && strcmp(dec.id, "ctr-1") == 0);
    CHECK(dec.image != NULL &&
          strcmp(dec.image, "docker.io/library/alpine:latest") == 0);
    CHECK(dec.snapshotter != NULL && strcmp(dec.snapshotter, "overlayfs") == 0);
    CHECK(dec.snapshot_key != NULL && strcmp(dec.snapshot_key, "snap-1") == 0);
    CHECK(dec.sandbox != NULL && strcmp(dec.sandbox, "sbx-0") == 0);

    /* Labels map. */
    CHECK(dec.labels_count == 2);
    CHECK(dec.labels != NULL);
    CHECK(dec.labels[0].key != NULL && strcmp(dec.labels[0].key, "app") == 0);
    CHECK(dec.labels[0].value != NULL &&
          strcmp(dec.labels[0].value, "strim") == 0);
    CHECK(dec.labels[1].key != NULL && strcmp(dec.labels[1].key, "tier") == 0);
    CHECK(dec.labels[1].value != NULL &&
          strcmp(dec.labels[1].value, "streaming") == 0);

    /* Runtime submessage. */
    CHECK(dec.has_runtime && dec.runtime.name != NULL &&
          strcmp(dec.runtime.name, "io.containerd.runc.v2") == 0);
    CHECK(!dec.runtime.has_options);

    /* Spec Any. */
    CHECK(dec.has_spec);
    CHECK(dec.spec.type_url != NULL && strcmp(dec.spec.type_url, SPEC_URL) == 0);
    CHECK(dec.spec.value != NULL && dec.spec.value->size == sizeof(spec_payload));
    CHECK(dec.spec.value != NULL &&
          memcmp(dec.spec.value->bytes, spec_payload, sizeof(spec_payload)) == 0);

    /* Extensions map<string,Any>. */
    CHECK(dec.extensions_count == 1);
    CHECK(dec.extensions != NULL);
    CHECK(dec.extensions[0].key != NULL &&
          strcmp(dec.extensions[0].key, "com.strim.test") == 0);
    CHECK(dec.extensions[0].has_value);
    CHECK(dec.extensions[0].value.type_url != NULL &&
          strcmp(dec.extensions[0].value.type_url,
                 "types.containerd.io/containerd.test.Extension") == 0);
    CHECK(dec.extensions[0].value.value != NULL &&
          dec.extensions[0].value.value->size == sizeof(ext_payload));
    CHECK(dec.extensions[0].value.value != NULL &&
          memcmp(dec.extensions[0].value.value->bytes, ext_payload,
                 sizeof(ext_payload)) == 0);

    /* Timestamps. */
    CHECK(dec.has_created_at && dec.created_at.seconds == 1700000000 &&
          dec.created_at.nanos == 123);
    CHECK(dec.has_updated_at && dec.updated_at.seconds == 1700000001);

    pb_release(containerd_services_containers_v1_Container_fields, &dec);
}

/* =========================================================================
 * Events envelope round-trip: Envelope.Event Any wrapping a TaskStart
 * ========================================================================= */
static void test_envelope_roundtrip(void) {
    /* Serialize the TaskStart event. */
    containerd_events_TaskStart ts = containerd_events_TaskStart_init_zero;
    ts.container_id = "ctr-1";
    ts.pid = 42;

    uint8_t tsbuf[64];
    pb_ostream_t ts_ostream = pb_ostream_from_buffer(tsbuf, sizeof(tsbuf));
    CHECK(pb_encode(&ts_ostream, containerd_events_TaskStart_fields, &ts));
    size_t ts_len = ts_ostream.bytes_written;
    CHECK(ts_len > 0);

    /* Wrap it in the events Envelope (the Subscribe stream message). */
    containerd_types_Envelope env = containerd_types_Envelope_init_zero;
    env.has_timestamp = true;
    env.timestamp.seconds = 1700000002;
    env.timestamp.nanos = 999;
    env.namespace = "default";
    env.topic = "/tasks/start";
    env.has_event = true;
    env.event.type_url = TASKSTART_URL;
    PB_BYTES_ARRAY_T(64) event_value;
    event_value.size = (pb_size_t)ts_len;
    memcpy(event_value.bytes, tsbuf, ts_len);
    env.event.value = (pb_bytes_array_t *)&event_value;

    uint8_t buf[512];
    pb_ostream_t ostream = pb_ostream_from_buffer(buf, sizeof(buf));
    CHECK(pb_encode(&ostream, containerd_types_Envelope_fields, &env));
    size_t encoded_len = ostream.bytes_written;
    CHECK(encoded_len > 0);

    containerd_types_Envelope dec = containerd_types_Envelope_init_zero;
    pb_istream_t istream = pb_istream_from_buffer(buf, encoded_len);
    CHECK(pb_decode(&istream, containerd_types_Envelope_fields, &dec));

    CHECK(dec.has_timestamp && dec.timestamp.seconds == 1700000002 &&
          dec.timestamp.nanos == 999);
    CHECK(dec.namespace != NULL && strcmp(dec.namespace, "default") == 0);
    CHECK(dec.topic != NULL && strcmp(dec.topic, "/tasks/start") == 0);
    CHECK(dec.has_event);
    CHECK(dec.event.type_url != NULL &&
          strcmp(dec.event.type_url, TASKSTART_URL) == 0);
    CHECK(dec.event.value != NULL && dec.event.value->size == ts_len);

    /* Re-decode the Any payload as a TaskStart. */
    containerd_events_TaskStart ts2 = containerd_events_TaskStart_init_zero;
    pb_istream_t payload_stream =
        pb_istream_from_buffer(dec.event.value->bytes, dec.event.value->size);
    CHECK(pb_decode(&payload_stream, containerd_events_TaskStart_fields, &ts2));
    CHECK(ts2.container_id != NULL && strcmp(ts2.container_id, "ctr-1") == 0);
    CHECK(ts2.pid == 42);

    pb_release(containerd_events_TaskStart_fields, &ts2);
    pb_release(containerd_types_Envelope_fields, &dec);
}

int main(void) {
    test_container_roundtrip();
    test_envelope_roundtrip();

    if (failures == 0) {
        printf("nanopb codecs round-trip: OK\n");
        return 0;
    }
    fprintf(stderr, "nanopb codecs round-trip: %d FAILURE(S)\n", failures);
    return 1;
}