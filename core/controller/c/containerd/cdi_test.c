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

/* Regression fixture for the nvidia-ctk `--format=json` hook form. Real
 * nvidia-container-toolkit output emits hooks as {"hookName": ..., "path": ...,
 * "args": ...} with NO createContainer array; containerd's pkg/cdi
 * (container-edits.go) maps hookName "createContainer" into the OCI spec's
 * createContainer array, so the parser must honor the same form. Mix a
 * hookName-form createContainer hook with one createContainer-array hook and
 * a non-createContainer hookName (prestart) that must be skipped, so the
 * parsed hook count must be 2. */
static const char HOOKNAME_FIXTURE[] =
    "{"
    "  \"cdiVersion\": \"0.5.0\","
    "  \"kind\": \"nvidia.com/gpu\","
    "  \"containerEdits\": {"
    "    \"env\": [\"NVIDIA_VISIBLE_DEVICES=0\"],"
    "    \"hooks\": ["
    "      {\"hookName\": \"createContainer\","
    "       \"path\": \"/usr/bin/nvidia-cdi-hook\","
    "       \"args\": [\"nvidia-cdi-hook\", \"create-symlinks\", \"--link\","
    "                  \"libcuda.so.595.91.07::/usr/lib64/libcuda.so.1\"],"
    "       \"env\": [\"NVIDIA_CTK_DEBUG=false\"],"
    "       \"timeout\": 30},"
    "      {\"createContainer\": ["
    "        {\"path\": \"/usr/bin/array-hook\","
    "         \"args\": [\"array-hook\", \"--device=all\"],"
    "         \"timeout\": 30}"
    "      ]},"
    "      {\"hookName\": \"prestart\","
    "       \"path\": \"/usr/bin/skipped-hook\","
    "       \"args\": [\"skipped-hook\"],"
    "       \"env\": [\"PATH=/usr/bin\"]}"
    "    ]"
    "  },"
    "  \"devices\": ["
    "    {\"name\": \"0\","
    "     \"containerEdits\": {\"env\": [\"NVIDIA_VISIBLE_DEVICES=0\"]}}"
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

  /* --- regression: nvidia-ctk "hookName"-form hooks (real --format=json) ---
   * Real nvidia-ctk `cdi generate --format=json` emits hooks in the CDI
   * hookName form ({"hookName":"createContainer","path":...,"args":...}).
   * containerd's pkg/cdi (container-edits.go) maps hookName "createContainer"
   * into spec.Hooks.CreateContainer, so the parser must produce the same
   * cdi_hook entries from that form. Pre-fix, parse_edits skipped every
   * hookName hook AND (before the v1.0.34 fix) counted them with a NULL path,
   * which strim_cdi_resolve's deep copy strdup(NULL)ed into a SIGSEGV
   * (cdi.c:678). Resolve below is that crash path: it must survive, the
   * hookName-form createContainer hook must parse with its own path/args/env/
   * timeout, the array-form hook must still parse, and the non-createContainer
   * hookName (prestart) must be skipped (not counted). */
  {
    char hdir[] = "/tmp/strim-cdi-hookname-XXXXXX";
    char hpath[256];
    strim_cdi_ref href;
    strim_spec hspec;
    const strim_cdi_edit_set *hedits = NULL;
    FILE *hf;

    CHECK(mkdtemp(hdir) != NULL);
    snprintf(hpath, sizeof(hpath), "%s/nvidia.json", hdir);
    hf = fopen(hpath, "w");
    CHECK(hf != NULL);
    if (hf != NULL) {
      fwrite(HOOKNAME_FIXTURE, 1, strlen(HOOKNAME_FIXTURE), hf);
      fclose(hf);
    }

    CHECK(strim_cdi_test_scan_dir(hdir) == 0);
    CHECK(strim_cdi_ref_parse("nvidia.com/gpu=0", &href) == 0);
    /* The pre-fix segfault happened here (deep copy -> strdup(NULL)). */
    CHECK(strim_cdi_resolve(&href, NULL) == 0);
    memset(&hspec, 0, sizeof(hspec));
    CHECK(strim_cdi_merge_edits(&hspec) == 0);
    CHECK(strim_cdi_get_pending_edits(&hedits) == 0);
    CHECK(hedits != NULL);
    /* Both createContainer hooks (hookName-form and array-form) count; the
     * non-createContainer hookName (prestart) is skipped. */
    CHECK(hedits->oci.n_hooks == 2);
    /* hook[0]: the hookName-form createContainer hook (first in the fixture
     * array), parsed from the SAME object's path/args/env/timeout. */
    CHECK(strcmp(hedits->oci.hooks[0].path, "/usr/bin/nvidia-cdi-hook") == 0);
    CHECK(hedits->oci.hooks[0].n_args == 4);
    CHECK(strcmp(hedits->oci.hooks[0].args[0], "nvidia-cdi-hook") == 0);
    CHECK(strcmp(hedits->oci.hooks[0].args[1], "create-symlinks") == 0);
    CHECK(strcmp(hedits->oci.hooks[0].args[2], "--link") == 0);
    CHECK(strcmp(hedits->oci.hooks[0].args[3],
                 "libcuda.so.595.91.07::/usr/lib64/libcuda.so.1") == 0);
    CHECK(hedits->oci.hooks[0].n_env == 1);
    CHECK(strcmp(hedits->oci.hooks[0].env[0], "NVIDIA_CTK_DEBUG=false") == 0);
    CHECK(hedits->oci.hooks[0].timeout == 30);
    /* hook[1]: the createContainer-array hook still parses. */
    CHECK(strcmp(hedits->oci.hooks[1].path, "/usr/bin/array-hook") == 0);
    CHECK(hedits->oci.hooks[1].n_args == 2);
    CHECK(strcmp(hedits->oci.hooks[1].args[1], "--device=all") == 0);
    CHECK(hedits->oci.hooks[1].timeout == 30);

    unlink(hpath);
    rmdir(hdir);
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