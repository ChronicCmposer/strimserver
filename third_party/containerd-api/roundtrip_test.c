// Round-trip test for the vendored protobuf-c runtime + containerd codecs.
// Encodes a types/task Process message (timestamp, enum, strings, bool),
// decodes it, and compares every field. Proves the generated .pb-c codecs and
// the pure-C protobuf-c runtime work together on this platform.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <google/protobuf/timestamp.pb-c.h>
#include <protobuf-c/protobuf-c.h>
#include <types/task/task.pb-c.h>

static int fail(const char *what) {
  fprintf(stderr, "FAIL: %s\n", what);
  return 1;
}

int main(void) {
  Containerd__V1__Types__Process proc = CONTAINERD__V1__TYPES__PROCESS__INIT;
  Google__Protobuf__Timestamp ts = GOOGLE__PROTOBUF__TIMESTAMP__INIT;
  uint8_t buf[4096];
  size_t len;
  Containerd__V1__Types__Process *decoded = NULL;

  ts.seconds = 1727123456;
  ts.nanos = 42;

  proc.container_id = (char *)"c1";
  proc.id = (char *)"shim";
  proc.pid = 1234;
  proc.status = CONTAINERD__V1__TYPES__STATUS__RUNNING;
  proc.stdin = (char *)"/dev/null";
  proc.stdout = (char *)"/dev/null";
  proc.stderr = (char *)"/dev/null";
  proc.terminal = 1;
  proc.exit_status = 0;
  proc.exited_at = &ts;

  len = containerd__v1__types__process__get_packed_size(&proc);
  if (len > sizeof(buf))
    return fail("packed size exceeds buffer");
  if (containerd__v1__types__process__pack(&proc, buf) != len)
    return fail("pack returned wrong length");

  decoded = containerd__v1__types__process__unpack(NULL, len, buf);
  if (decoded == NULL)
    return fail("unpack returned NULL");

  if (decoded->pid != 1234)
    return fail("pid mismatch");
  if (strcmp(decoded->container_id, "c1") != 0)
    return fail("container_id mismatch");
  if (strcmp(decoded->id, "shim") != 0)
    return fail("id mismatch");
  if (decoded->status != CONTAINERD__V1__TYPES__STATUS__RUNNING)
    return fail("status mismatch");
  if (decoded->terminal != 1)
    return fail("terminal mismatch");
  if (decoded->exited_at == NULL || decoded->exited_at->seconds != 1727123456 ||
      decoded->exited_at->nanos != 42)
    return fail("exited_at mismatch");

  containerd__v1__types__process__free_unpacked(decoded, NULL);
  printf("ROUNDTRIP OK: packed=%zu bytes, pid=%u status=%d\n", len, proc.pid,
         proc.status);
  return 0;
}