/*
 * cdi_test.c — CDI resolution + OCI edit merge tests.
 *
 * Wave 1 (containerd lane). Writes a fixture CDI spec (nvidia.com/gpu with a
 * device "0") into a temp dir, scans it via the internal test hook, resolves
 * "nvidia.com/gpu=0", and verifies the merged containerEdits (env, device
 * nodes, mounts, hooks, additional GIDs) that the OCI spec builder applies.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cdi.h"
#include "cdi_internal.h"

static int failures = 0;

#define CHECK(cond)                                                       \
    do {                                                                  \
        if (!(cond)) {                                                    \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                   \
        }                                                                 \
    } while (0)

static const char FIXTURE[] =
    "{"
    "  \"cdiVersion\": \"0.5.0\","
    "  \"kind\": \"nvidia.com/gpu\","
    "  \"containerEdits\": {"
    "    \"env\": [\"NVIDIA_VISIBLE_DEVICES=0\"]"
    "  },"
    "  \"devices\": ["
    "    {"
    "      \"name\": \"0\","
    "      \"containerEdits\": {"
    "        \"env\": [\"NVIDIA_DRIVER_CAPABILITIES=video,compute,utility\"],"
    "        \"deviceNodes\": ["
    "          {\"path\": \"/dev/nvidia0\", \"type\": \"c\","
    "           \"major\": 195, \"minor\": 0, \"fileMode\": 420,"
    "           \"uid\": 0, \"gid\": 0}"
    "        ],"
    "        \"mounts\": ["
    "          {\"hostPath\": \"/usr/lib/x86_64-linux-gnu/libcuda.so.1\","
    "           \"containerPath\": \"/usr/lib/x86_64-linux-gnu/libcuda.so.1\","
    "           \"options\": [\"bind\", \"rw\", \"nosuid\"]}"
    "        ],"
    "        \"hooks\": ["
    "          {\"createContainer\": ["
    "            {\"path\": \"/usr/bin/nvidia-container-cli\","
    "             \"args\": [\"nvidia-container-cli\", \"--load-kmods\", \"configure\"],"
    "             \"env\": [\"PATH=/usr/bin\"],"
    "             \"timeout\": 30}"
    "          ]}"
    "        ],"
    "        \"additionalGIDs\": [44]"
    "      }"
    "    },"
    "    {"
    "      \"name\": \"1\","
    "      \"containerEdits\": {\"env\": [\"NVIDIA_VISIBLE_DEVICES=1\"]}"
    "    }"
    "  ]"
    "}";

int main(void) {
  char dir[] = "/tmp/strim-cdi-test-XXXXXX";
  char path[256];
  strim_cdi_ref ref;
  uint32_t n_devices = 0;
  strim_spec spec;
  const strim_cdi_edit_set *edits = NULL;
  FILE *f;

  /* --- ref parse --- */
  CHECK(strim_cdi_ref_parse("nvidia.com/gpu=0", &ref) == 0);
  CHECK(strcmp(ref.vendor, "nvidia.com") == 0);
  CHECK(strcmp(ref.device_class, "gpu") == 0);
  CHECK(strcmp(ref.id, "0") == 0);
  CHECK(strim_cdi_ref_parse("no-equals", &ref) == STRIM_CDI_ERR_BADARG);
  CHECK(strim_cdi_ref_parse("bad/", &ref) == STRIM_CDI_ERR_BADARG);

  /* --- fixture dir + scan --- */
  if (mkdtemp(dir) == NULL) {
    fprintf(stderr, "mkdtemp failed\n");
    return 1;
  }
  snprintf(path, sizeof(path), "%s/nvidia.json", dir);
  f = fopen(path, "w");
  if (f == NULL) {
    fprintf(stderr, "cannot write fixture\n");
    return 1;
  }
  fwrite(FIXTURE, 1, strlen(FIXTURE), f);
  fclose(f);

  CHECK(strim_cdi_test_scan_dir(dir) == 0);

  /* --- resolve --- */
  CHECK(strim_cdi_resolve(&ref, &n_devices) == 0);
  CHECK(n_devices == 2); /* 1 device node + 1 mount */

  /* --- merge + inspect the OCI-facing edit set --- */
  memset(&spec, 0, sizeof(spec));
  CHECK(strim_cdi_merge_edits(&spec) == 0);
  CHECK(strim_cdi_get_pending_edits(&edits) == 0);
  CHECK(edits != NULL);

  CHECK(edits->oci.n_env == 2);
  CHECK(strcmp(edits->oci.env[0], "NVIDIA_VISIBLE_DEVICES=0") == 0);
  CHECK(strcmp(edits->oci.env[1],
               "NVIDIA_DRIVER_CAPABILITIES=video,compute,utility") == 0);

  CHECK(edits->oci.n_devices == 1);
  CHECK(strcmp(edits->oci.devices[0].path, "/dev/nvidia0") == 0);
  CHECK(strcmp(edits->oci.devices[0].type, "c") == 0);
  CHECK(edits->oci.devices[0].major == 195);
  CHECK(edits->oci.devices[0].minor == 0);
  CHECK(edits->oci.devices[0].file_mode == 420);

  CHECK(edits->oci.n_mounts == 1);
  CHECK(strcmp(edits->oci.mounts[0].host_path,
               "/usr/lib/x86_64-linux-gnu/libcuda.so.1") == 0);
  CHECK(strcmp(edits->oci.mounts[0].container_path,
               "/usr/lib/x86_64-linux-gnu/libcuda.so.1") == 0);
  CHECK(edits->oci.mounts[0].n_options == 3);
  CHECK(strcmp(edits->oci.mounts[0].options[0], "bind") == 0);
  CHECK(strcmp(edits->oci.mounts[0].options[1], "rw") == 0);

  CHECK(edits->oci.n_hooks == 1);
  CHECK(strcmp(edits->oci.hooks[0].path, "/usr/bin/nvidia-container-cli") == 0);
  CHECK(edits->oci.hooks[0].n_args == 3);
  CHECK(strcmp(edits->oci.hooks[0].args[2], "configure") == 0);
  CHECK(edits->oci.hooks[0].n_env == 1);
  CHECK(edits->oci.hooks[0].timeout == 30);

  CHECK(edits->oci.n_additional_gids == 1);
  CHECK(edits->oci.additional_gids[0] == 44);

  /* A second successful resolve replaces the pending set (merged = spec-level
   * containerEdits + the device's own edits, exactly like containerd's
   * pkg/cdi applyEdits). */
  {
    strim_cdi_ref other;
    CHECK(strim_cdi_ref_parse("nvidia.com/gpu=1", &other) == 0);
    CHECK(strim_cdi_resolve(&other, NULL) == 0);
    CHECK(strim_cdi_merge_edits(&spec) == 0);
    CHECK(strim_cdi_get_pending_edits(&edits) == 0);
    CHECK(edits->oci.n_env == 2);
    CHECK(strcmp(edits->oci.env[0], "NVIDIA_VISIBLE_DEVICES=0") == 0);
    CHECK(strcmp(edits->oci.env[1], "NVIDIA_VISIBLE_DEVICES=1") == 0);
  }

  /* Unknown device id -> NOTFOUND. A failed resolve invalidates whatever was
   * pending, so a subsequent merge is rejected. */
  {
    strim_cdi_ref other;
    CHECK(strim_cdi_ref_parse("nvidia.com/gpu=99", &other) == 0);
    CHECK(strim_cdi_resolve(&other, &n_devices) == STRIM_CDI_ERR_NOTFOUND);
    CHECK(strim_cdi_merge_edits(&spec) == STRIM_CDI_ERR_BADARG);
  }

  /* cleanup */
  unlink(path);
  rmdir(dir);

  if (failures == 0) {
    printf("cdi tests: OK\n");
    return 0;
  }
  fprintf(stderr, "cdi tests: %d FAILURE(S)\n", failures);
  return 1;
}