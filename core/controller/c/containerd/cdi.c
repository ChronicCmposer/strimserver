/*
 * cdi.c — CDI (Container Device Interface) resolution + OCI edit merge.
 *
 * Implements cdi.h. Scans the host CDI spec directories (/etc/cdi and
 * /var/run/cdi), parses every *.json with yyjson (vendored at
 * //third_party/yyjson), indexes devices by vendor/class, and resolves a
 * "vendor/class=id" reference (e.g. "nvidia.com/gpu=0") into the merged
 * containerEdits (env, mounts, deviceNodes, hooks, additionalGIDs) that the
 * OCI spec builder applies — the same behavior as containerd's pkg/cdi.
 *
 * MERGE MODEL: strim_spec's env/mounts arrays are const (fixed-arity
 * contract), so strim_cdi_merge_edits validates the merged edit set against
 * the fixed-array bounds and records it as the "pending" merge;
 * strim_containerd_new_container then applies the full edit set to the OCI
 * spec via strim_cdi_get_pending_edits + strim_oci_build_spec — exactly
 * where containerd applies CDI edits (the OCI spec, not an intermediate
 * struct).
 *
 * The module keeps a single index + one pending edit set; the controller is
 * single-threaded (one-time resolve per boot), so a plain flag guards state.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include "cdi.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "cdi_internal.h"
#include "yyjson.h"

/* Bounds for the fixed index. */
#define CDI_MAX_SPECS   64
#define CDI_MAX_DEVICES 256
#define CDI_MAX_EDITS   (STRIM_SPEC_MAX_ENV + STRIM_SPEC_MAX_MOUNTS + 32)

/* =========================================================================
 * Owned edit set (deep copy of one containerEdits object)
 * ========================================================================= */

typedef struct cdi_mount {
  char *host_path;
  char *container_path;
  char **options;
  size_t n_options;
} cdi_mount;

typedef struct cdi_device_node {
  char *path;
  char *type;
  int64_t major;
  int64_t minor;
  uint32_t file_mode;
  uint32_t uid;
  uint32_t gid;
} cdi_device_node;

typedef struct cdi_hook {
  char *path;
  char **args;
  size_t n_args;
  char **env;
  size_t n_env;
  int32_t timeout;
} cdi_hook;

typedef struct cdi_edits {
  char **env;
  size_t n_env;
  cdi_mount *mounts;
  size_t n_mounts;
  cdi_device_node *devices;
  size_t n_devices;
  cdi_hook *hooks;
  size_t n_hooks;
  uint32_t *gids;
  size_t n_gids;
} cdi_edits;

static void cdi_edits_free(cdi_edits *e) {
  size_t i;
  for (i = 0; i < e->n_env; i++)
    free(e->env[i]);
  free(e->env);
  for (i = 0; i < e->n_mounts; i++) {
    size_t j;
    free(e->mounts[i].host_path);
    free(e->mounts[i].container_path);
    for (j = 0; j < e->mounts[i].n_options; j++)
      free(e->mounts[i].options[j]);
    free(e->mounts[i].options);
  }
  free(e->mounts);
  for (i = 0; i < e->n_devices; i++) {
    free(e->devices[i].path);
    free(e->devices[i].type);
  }
  free(e->devices);
  for (i = 0; i < e->n_hooks; i++) {
    size_t j;
    free(e->hooks[i].path);
    for (j = 0; j < e->hooks[i].n_args; j++)
      free(e->hooks[i].args[j]);
    free(e->hooks[i].args);
    for (j = 0; j < e->hooks[i].n_env; j++)
      free(e->hooks[i].env[j]);
    free(e->hooks[i].env);
  }
  free(e->hooks);
  free(e->gids);
  memset(e, 0, sizeof(*e));
}

/* =========================================================================
 * Index
 * ========================================================================= */

typedef struct cdi_device {
  char *name;
  cdi_edits edits;
} cdi_device;

typedef struct cdi_spec_entry {
  char *kind; /* "vendor/class" */
  cdi_edits spec_edits;
  cdi_device *devices;
  size_t n_devices;
} cdi_spec_entry;

static cdi_spec_entry *g_specs;
static size_t g_n_specs;
static int g_scanned;

static cdi_edits g_pending;      /* merged resolved edit set (deep copy) */
static int g_pending_valid;

static void index_free_all(void) {
  size_t i;
  for (i = 0; i < g_n_specs; i++) {
    size_t j;
    free(g_specs[i].kind);
    cdi_edits_free(&g_specs[i].spec_edits);
    for (j = 0; j < g_specs[i].n_devices; j++) {
      free(g_specs[i].devices[j].name);
      cdi_edits_free(&g_specs[i].devices[j].edits);
    }
    free(g_specs[i].devices);
  }
  free(g_specs);
  g_specs = NULL;
  g_n_specs = 0;
  g_scanned = 0;
}

/* =========================================================================
 * yyjson -> cdi_edits
 * ========================================================================= */

static char *dup_val_str(yyjson_val *v) {
  if (v == NULL || !yyjson_is_str(v))
    return NULL;
  {
    size_t len;
    const char *s = yyjson_get_str(v);
    if (s == NULL)
      return NULL;
    len = yyjson_get_len(v);
    {
      char *out = (char *)malloc(len + 1);
      if (out == NULL)
        return NULL;
      memcpy(out, s, len);
      out[len] = '\0';
      return out;
    }
  }
}

static int parse_edits(yyjson_val *obj, cdi_edits *out) {
  yyjson_val *v;

  memset(out, 0, sizeof(*out));

  v = yyjson_obj_get(obj, "env");
  if (yyjson_is_arr(v)) {
    size_t n = yyjson_arr_size(v);
    size_t i;
    if (n > 0) {
      out->env = (char **)calloc(n, sizeof(char *));
      if (out->env == NULL)
        return -1;
      for (i = 0; i < n; i++) {
        out->env[i] = dup_val_str(yyjson_arr_get(v, i));
        if (out->env[i] == NULL) {
          cdi_edits_free(out);
          return -1;
        }
      }
      out->n_env = n;
    }
  }

  v = yyjson_obj_get(obj, "mounts");
  if (yyjson_is_arr(v)) {
    size_t n = yyjson_arr_size(v);
    size_t i;
    if (n > 0) {
      out->mounts = (cdi_mount *)calloc(n, sizeof(cdi_mount));
      if (out->mounts == NULL) {
        cdi_edits_free(out);
        return -1;
      }
      out->n_mounts = n;
      for (i = 0; i < n; i++) {
        yyjson_val *m = yyjson_arr_get(v, i);
        yyjson_val *opts;
        if (!yyjson_is_obj(m)) {
          cdi_edits_free(out);
          return -1;
        }
        out->mounts[i].host_path = dup_val_str(yyjson_obj_get(m, "hostPath"));
        out->mounts[i].container_path =
            dup_val_str(yyjson_obj_get(m, "containerPath"));
        if (out->mounts[i].host_path == NULL ||
            out->mounts[i].container_path == NULL) {
          cdi_edits_free(out);
          return -1;
        }
        opts = yyjson_obj_get(m, "options");
        if (yyjson_is_arr(opts)) {
          size_t on = yyjson_arr_size(opts);
          size_t j;
          out->mounts[i].options = (char **)calloc(on, sizeof(char *));
          if (out->mounts[i].options == NULL) {
            cdi_edits_free(out);
            return -1;
          }
          out->mounts[i].n_options = on;
          for (j = 0; j < on; j++) {
            out->mounts[i].options[j] = dup_val_str(yyjson_arr_get(opts, j));
            if (out->mounts[i].options[j] == NULL) {
              cdi_edits_free(out);
              return -1;
            }
          }
        }
      }
    }
  }

  v = yyjson_obj_get(obj, "deviceNodes");
  if (yyjson_is_arr(v)) {
    size_t n = yyjson_arr_size(v);
    size_t i;
    if (n > 0) {
      out->devices = (cdi_device_node *)calloc(n, sizeof(cdi_device_node));
      if (out->devices == NULL) {
        cdi_edits_free(out);
        return -1;
      }
      out->n_devices = n;
      for (i = 0; i < n; i++) {
        yyjson_val *d = yyjson_arr_get(v, i);
        yyjson_val *f;
        if (!yyjson_is_obj(d)) {
          cdi_edits_free(out);
          return -1;
        }
        out->devices[i].path = dup_val_str(yyjson_obj_get(d, "path"));
        out->devices[i].type = dup_val_str(yyjson_obj_get(d, "type"));
        if (out->devices[i].path == NULL) {
          cdi_edits_free(out);
          return -1;
        }
        f = yyjson_obj_get(d, "major");
        if (yyjson_is_int(f) || yyjson_is_uint(f))
          out->devices[i].major = yyjson_get_int(f);
        f = yyjson_obj_get(d, "minor");
        if (yyjson_is_int(f) || yyjson_is_uint(f))
          out->devices[i].minor = yyjson_get_int(f);
        f = yyjson_obj_get(d, "fileMode");
        if (yyjson_is_uint(f))
          out->devices[i].file_mode = (uint32_t)yyjson_get_uint(f);
        f = yyjson_obj_get(d, "uid");
        if (yyjson_is_uint(f))
          out->devices[i].uid = (uint32_t)yyjson_get_uint(f);
        f = yyjson_obj_get(d, "gid");
        if (yyjson_is_uint(f))
          out->devices[i].gid = (uint32_t)yyjson_get_uint(f);
      }
    }
  }

  v = yyjson_obj_get(obj, "hooks");
  if (yyjson_is_arr(v)) {
    size_t n = yyjson_arr_size(v);
    size_t i;
    if (n > 0) {
      out->hooks = (cdi_hook *)calloc(n, sizeof(cdi_hook));
      if (out->hooks == NULL) {
        cdi_edits_free(out);
        return -1;
      }
      out->n_hooks = n;
      for (i = 0; i < n; i++) {
        yyjson_val *h = yyjson_arr_get(v, i);
        yyjson_val *cc;
        if (!yyjson_is_obj(h)) {
          cdi_edits_free(out);
          return -1;
        }
        /* Only createContainer hooks are honored (the controller's CDI
         * usage — nvidia — uses createContainer). */
        cc = yyjson_obj_get(h, "createContainer");
        if (yyjson_is_arr(cc) && yyjson_arr_size(cc) > 0) {
          yyjson_val *one = yyjson_arr_get(cc, 0);
          yyjson_val *args;
          yyjson_val *env;
          yyjson_val *timeout;
          if (!yyjson_is_obj(one)) {
            cdi_edits_free(out);
            return -1;
          }
          out->hooks[i].path = dup_val_str(yyjson_obj_get(one, "path"));
          if (out->hooks[i].path == NULL) {
            cdi_edits_free(out);
            return -1;
          }
          args = yyjson_obj_get(one, "args");
          if (yyjson_is_arr(args)) {
            size_t an = yyjson_arr_size(args);
            size_t j;
            out->hooks[i].args = (char **)calloc(an, sizeof(char *));
            if (out->hooks[i].args == NULL) {
              cdi_edits_free(out);
              return -1;
            }
            out->hooks[i].n_args = an;
            for (j = 0; j < an; j++) {
              out->hooks[i].args[j] = dup_val_str(yyjson_arr_get(args, j));
              if (out->hooks[i].args[j] == NULL) {
                cdi_edits_free(out);
                return -1;
              }
            }
          }
          env = yyjson_obj_get(one, "env");
          if (yyjson_is_arr(env)) {
            size_t en = yyjson_arr_size(env);
            size_t j;
            out->hooks[i].env = (char **)calloc(en, sizeof(char *));
            if (out->hooks[i].env == NULL) {
              cdi_edits_free(out);
              return -1;
            }
            out->hooks[i].n_env = en;
            for (j = 0; j < en; j++) {
              out->hooks[i].env[j] = dup_val_str(yyjson_arr_get(env, j));
              if (out->hooks[i].env[j] == NULL) {
                cdi_edits_free(out);
                return -1;
              }
            }
          }
          timeout = yyjson_obj_get(one, "timeout");
          if (yyjson_is_int(timeout))
            out->hooks[i].timeout = (int32_t)yyjson_get_int(timeout);
        }
      }
    }
  }

  v = yyjson_obj_get(obj, "additionalGIDs");
  if (yyjson_is_arr(v)) {
    size_t n = yyjson_arr_size(v);
    size_t i;
    if (n > 0) {
      out->gids = (uint32_t *)calloc(n, sizeof(uint32_t));
      if (out->gids == NULL) {
        cdi_edits_free(out);
        return -1;
      }
      for (i = 0; i < n; i++) {
        yyjson_val *g = yyjson_arr_get(v, i);
        if (yyjson_is_uint(g))
          out->gids[i] = (uint32_t)yyjson_get_uint(g);
      }
      out->n_gids = n;
    }
  }

  return 0;
}

/* =========================================================================
 * Spec file parsing
 * ========================================================================= */

static int parse_spec_file(const char *path, cdi_spec_entry *out) {
  FILE *f;
  long sz;
  char *text;
  yyjson_doc *doc;
  yyjson_val *root;
  yyjson_val *kind;
  yyjson_val *devices;
  size_t i;
  int rc = -1;

  memset(out, 0, sizeof(*out));

  f = fopen(path, "rb");
  if (f == NULL)
    return -1;
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return -1;
  }
  sz = ftell(f);
  if (sz < 0 || sz > (1 << 20)) { /* CDI specs are small; fail loud beyond */
    fclose(f);
    return -1;
  }
  rewind(f);
  text = (char *)malloc((size_t)sz + 1);
  if (text == NULL) {
    fclose(f);
    return -1;
  }
  if (fread(text, 1, (size_t)sz, f) != (size_t)sz) {
    free(text);
    fclose(f);
    return -1;
  }
  text[sz] = '\0';
  fclose(f);

  doc = yyjson_read(text, (size_t)sz, 0);
  free(text);
  if (doc == NULL)
    return -1;
  root = yyjson_doc_get_root(doc);
  if (!yyjson_is_obj(root))
    goto done;

  kind = yyjson_obj_get(root, "kind");
  out->kind = dup_val_str(kind);
  if (out->kind == NULL)
    goto done;

  {
    yyjson_val *spec_edits = yyjson_obj_get(root, "containerEdits");
    if (yyjson_is_obj(spec_edits) && parse_edits(spec_edits, &out->spec_edits) < 0)
      goto done;
  }

  devices = yyjson_obj_get(root, "devices");
  if (yyjson_is_arr(devices)) {
    size_t n = yyjson_arr_size(devices);
    if (n > CDI_MAX_DEVICES)
      goto done;
    out->devices = (cdi_device *)calloc(n ? n : 1, sizeof(cdi_device));
    if (out->devices == NULL)
      goto done;
    for (i = 0; i < n; i++) {
      yyjson_val *d = yyjson_arr_get(devices, i);
      yyjson_val *name;
      yyjson_val *edits;
      if (!yyjson_is_obj(d))
        goto done;
      name = yyjson_obj_get(d, "name");
      out->devices[i].name = dup_val_str(name);
      if (out->devices[i].name == NULL)
        goto done;
      edits = yyjson_obj_get(d, "containerEdits");
      if (yyjson_is_obj(edits) && parse_edits(edits, &out->devices[i].edits) < 0)
        goto done;
    }
    out->n_devices = n;
  }

  rc = 0;
done:
  yyjson_doc_free(doc);
  if (rc != 0) {
    free(out->kind);
    out->kind = NULL;
    cdi_edits_free(&out->spec_edits);
    for (i = 0; i < out->n_devices; i++) {
      free(out->devices[i].name);
      cdi_edits_free(&out->devices[i].edits);
    }
    free(out->devices);
    out->devices = NULL;
    out->n_devices = 0;
  }
  return rc;
}

static int scan_dir(const char *dir) {
  DIR *d;
  struct dirent *ent;

  d = opendir(dir);
  if (d == NULL)
    return 0; /* a missing directory is not an error */
  while ((ent = readdir(d)) != NULL) {
    size_t nlen = strlen(ent->d_name);
    char path[1024];
    cdi_spec_entry entry;
    if (nlen < 6 || strcmp(ent->d_name + nlen - 5, ".json") != 0)
      continue;
    snprintf(path, sizeof(path), "%s/%s", dir, ent->d_name);
    if (parse_spec_file(path, &entry) < 0) {
      closedir(d);
      return -1; /* fail loud on a malformed spec */
    }
    if (g_n_specs >= CDI_MAX_SPECS) {
      cdi_edits_free(&entry.spec_edits);
      {
        size_t i;
        for (i = 0; i < entry.n_devices; i++) {
          free(entry.devices[i].name);
          cdi_edits_free(&entry.devices[i].edits);
        }
      }
      free(entry.devices);
      free(entry.kind);
      closedir(d);
      return -1;
    }
    g_specs[g_n_specs++] = entry;
  }
  closedir(d);
  return 0;
}

/* =========================================================================
 * Deep-copy one edit set into g_pending (merged).
 * ========================================================================= */

static int pending_append_edits(const cdi_edits *src) {
  size_t i;
  size_t total_env = g_pending.n_env + src->n_env;
  size_t total_mounts = g_pending.n_mounts + src->n_mounts;
  size_t total_devices = g_pending.n_devices + src->n_devices;
  size_t total_hooks = g_pending.n_hooks + src->n_hooks;
  size_t total_gids = g_pending.n_gids + src->n_gids;
  char **env;
  cdi_mount *mounts;
  cdi_device_node *devices;
  cdi_hook *hooks;
  uint32_t *gids;

  if (total_env > 0) {
    env = (char **)realloc(g_pending.env, total_env * sizeof(char *));
    if (env == NULL)
      return -1;
    g_pending.env = env;
    for (i = 0; i < src->n_env; i++) {
      g_pending.env[g_pending.n_env] = strdup(src->env[i]);
      if (g_pending.env[g_pending.n_env] == NULL)
        return -1;
      g_pending.n_env++;
    }
  }
  if (total_mounts > 0) {
    mounts = (cdi_mount *)realloc(g_pending.mounts, total_mounts * sizeof(cdi_mount));
    if (mounts == NULL)
      return -1;
    g_pending.mounts = mounts;
    for (i = 0; i < src->n_mounts; i++) {
      cdi_mount *dst = &g_pending.mounts[g_pending.n_mounts];
      size_t j;
      memset(dst, 0, sizeof(*dst));
      dst->host_path = strdup(src->mounts[i].host_path);
      dst->container_path = strdup(src->mounts[i].container_path);
      if (dst->host_path == NULL || dst->container_path == NULL)
        return -1;
      if (src->mounts[i].n_options > 0) {
        dst->options = (char **)calloc(src->mounts[i].n_options, sizeof(char *));
        if (dst->options == NULL)
          return -1;
        for (j = 0; j < src->mounts[i].n_options; j++) {
          dst->options[j] = strdup(src->mounts[i].options[j]);
          if (dst->options[j] == NULL)
            return -1;
        }
        dst->n_options = src->mounts[i].n_options;
      }
      g_pending.n_mounts++;
    }
  }
  if (total_devices > 0) {
    devices = (cdi_device_node *)realloc(g_pending.devices,
                                         total_devices * sizeof(cdi_device_node));
    if (devices == NULL)
      return -1;
    g_pending.devices = devices;
    for (i = 0; i < src->n_devices; i++) {
      cdi_device_node *dst = &g_pending.devices[g_pending.n_devices];
      memset(dst, 0, sizeof(*dst));
      dst->path = strdup(src->devices[i].path);
      dst->type = src->devices[i].type ? strdup(src->devices[i].type) : strdup("c");
      if (dst->path == NULL || dst->type == NULL)
        return -1;
      dst->major = src->devices[i].major;
      dst->minor = src->devices[i].minor;
      dst->file_mode = src->devices[i].file_mode;
      dst->uid = src->devices[i].uid;
      dst->gid = src->devices[i].gid;
      g_pending.n_devices++;
    }
  }
  if (total_hooks > 0) {
    hooks = (cdi_hook *)realloc(g_pending.hooks, total_hooks * sizeof(cdi_hook));
    if (hooks == NULL)
      return -1;
    g_pending.hooks = hooks;
    for (i = 0; i < src->n_hooks; i++) {
      cdi_hook *dst = &g_pending.hooks[g_pending.n_hooks];
      size_t j;
      memset(dst, 0, sizeof(*dst));
      dst->path = strdup(src->hooks[i].path);
      if (dst->path == NULL)
        return -1;
      if (src->hooks[i].n_args > 0) {
        dst->args = (char **)calloc(src->hooks[i].n_args, sizeof(char *));
        if (dst->args == NULL)
          return -1;
        for (j = 0; j < src->hooks[i].n_args; j++) {
          dst->args[j] = strdup(src->hooks[i].args[j]);
          if (dst->args[j] == NULL)
            return -1;
        }
        dst->n_args = src->hooks[i].n_args;
      }
      if (src->hooks[i].n_env > 0) {
        dst->env = (char **)calloc(src->hooks[i].n_env, sizeof(char *));
        if (dst->env == NULL)
          return -1;
        for (j = 0; j < src->hooks[i].n_env; j++) {
          dst->env[j] = strdup(src->hooks[i].env[j]);
          if (dst->env[j] == NULL)
            return -1;
        }
        dst->n_env = src->hooks[i].n_env;
      }
      dst->timeout = src->hooks[i].timeout;
      g_pending.n_hooks++;
    }
  }
  if (total_gids > 0) {
    gids = (uint32_t *)realloc(g_pending.gids, total_gids * sizeof(uint32_t));
    if (gids == NULL)
      return -1;
    g_pending.gids = gids;
    for (i = 0; i < src->n_gids; i++)
      g_pending.gids[g_pending.n_gids++] = src->gids[i];
  }
  return 0;
}

/* =========================================================================
 * Public API
 * ========================================================================= */

int strim_cdi_ref_parse(const char *dev, strim_cdi_ref *out) {
  const char *slash;
  const char *eq;
  size_t vlen, clen, ilen;

  if (dev == NULL || out == NULL)
    return STRIM_CDI_ERR_BADARG;

  slash = strchr(dev, '/');
  eq = strchr(dev, '=');
  if (slash == NULL || eq == NULL || eq <= slash)
    return STRIM_CDI_ERR_BADARG;
  vlen = (size_t)(slash - dev);
  clen = (size_t)(eq - slash - 1);
  ilen = strlen(eq + 1);
  if (vlen == 0 || clen == 0 || ilen == 0)
    return STRIM_CDI_ERR_BADARG;
  if (vlen >= STRIM_CDI_VENDOR_MAX || clen >= STRIM_CDI_CLASS_MAX ||
      ilen >= STRIM_CDI_ID_MAX)
    return STRIM_CDI_ERR_BADARG;

  memcpy(out->vendor, dev, vlen);
  out->vendor[vlen] = '\0';
  memcpy(out->device_class, slash + 1, clen);
  out->device_class[clen] = '\0';
  memcpy(out->id, eq + 1, ilen);
  out->id[ilen] = '\0';
  return 0;
}

static int scan_into_index(const char *dir) {
  return scan_dir(dir);
}

/* Shared implementation: free the old index and scan the given directory
 * set. A missing directory is not an error; both missing is NODIR. */
static int scan_dirs(const char *const *dirs, size_t n_dirs) {
  size_t i;
  int any_exists = 0;

  index_free_all();
  cdi_edits_free(&g_pending);
  g_pending_valid = 0;

  g_specs = (cdi_spec_entry *)calloc(CDI_MAX_SPECS, sizeof(cdi_spec_entry));
  if (g_specs == NULL)
    return STRIM_CDI_ERR_NOMEM;

  for (i = 0; i < n_dirs; i++) {
    struct stat st;
    if (stat(dirs[i], &st) == 0)
      any_exists = 1;
    if (scan_into_index(dirs[i]) != 0) {
      index_free_all();
      return STRIM_CDI_ERR_PARSE;
    }
  }
  if (!any_exists) {
    index_free_all();
    return STRIM_CDI_ERR_NODIR;
  }

  g_scanned = 1;
  return 0;
}

int strim_cdi_scan(void) {
  static const char *const dirs[] = {STRIM_CDI_DIR_ETC, STRIM_CDI_DIR_VAR_RUN};
  return scan_dirs(dirs, 2);
}

int strim_cdi_test_scan_dir(const char *dir) {
  const char *dirs[1];
  if (dir == NULL || dir[0] == '\0')
    return STRIM_CDI_ERR_BADARG;
  dirs[0] = dir;
  return scan_dirs(dirs, 1);
}

int strim_cdi_resolve(const strim_cdi_ref *ref, uint32_t *out_n_devices) {
  char kind[STRIM_CDI_VENDOR_MAX + STRIM_CDI_CLASS_MAX + 2];
  size_t i;
  cdi_spec_entry *spec = NULL;

  if (ref == NULL)
    return STRIM_CDI_ERR_BADARG;
  if (!g_scanned || g_specs == NULL)
    return STRIM_CDI_ERR_NODIR;

  snprintf(kind, sizeof(kind), "%s/%s", ref->vendor, ref->device_class);
  for (i = 0; i < g_n_specs; i++) {
    if (strcmp(g_specs[i].kind, kind) == 0) {
      spec = &g_specs[i];
      break;
    }
  }
  if (spec == NULL)
    return STRIM_CDI_ERR_NOTFOUND;

  cdi_edits_free(&g_pending);
  g_pending_valid = 0;

  /* Merged edits = spec-level containerEdits + the device's own. */
  if (pending_append_edits(&spec->spec_edits) < 0) {
    cdi_edits_free(&g_pending);
    return STRIM_CDI_ERR_NOMEM;
  }
  for (i = 0; i < spec->n_devices; i++) {
    if (strcmp(spec->devices[i].name, ref->id) == 0) {
      if (pending_append_edits(&spec->devices[i].edits) < 0) {
        cdi_edits_free(&g_pending);
        return STRIM_CDI_ERR_NOMEM;
      }
      g_pending_valid = 1;
      break;
    }
  }
  if (!g_pending_valid) {
    cdi_edits_free(&g_pending);
    return STRIM_CDI_ERR_NOTFOUND;
  }

  if (out_n_devices != NULL) {
    uint64_t n = (uint64_t)g_pending.n_devices + (uint64_t)g_pending.n_mounts;
    *out_n_devices = (n > STRIM_CDI_MAX_DEVICES) ? STRIM_CDI_MAX_DEVICES
                                                 : (uint32_t)n;
  }
  return 0;
}

int strim_cdi_merge_edits(strim_spec *spec) {
  if (spec == NULL)
    return STRIM_CDI_ERR_BADARG;
  if (!g_pending_valid)
    return STRIM_CDI_ERR_BADARG;

  /* The strim_spec env/mounts arrays are const and cannot be physically
   * grown; validate the merged edit set fits the fixed-array bounds so the
   * OCI spec builder (which applies the full edit set) never overflows. */
  if (g_pending.n_env > STRIM_SPEC_MAX_ENV)
    return STRIM_CDI_ERR_PARSE;
  if (g_pending.n_mounts > STRIM_SPEC_MAX_MOUNTS)
    return STRIM_CDI_ERR_PARSE;
  if (g_pending.n_devices + g_pending.n_hooks > STRIM_CDI_MAX_DEVICES)
    return STRIM_CDI_ERR_PARSE;
  return 0;
}

int strim_cdi_get_pending_edits(const strim_cdi_edit_set **out) {
  if (out == NULL)
    return STRIM_CDI_ERR_BADARG;
  if (!g_pending_valid)
    return STRIM_CDI_ERR_BADARG;
  /* Rebuild the OCI-facing view from the pending state. */
  {
    static strim_oci_cdi_mount oci_mounts[STRIM_SPEC_MAX_MOUNTS];
    static strim_oci_cdi_device oci_devices[STRIM_CDI_MAX_DEVICES];
    static strim_oci_cdi_hook oci_hooks[STRIM_CDI_MAX_DEVICES];
    static uint32_t oci_gids[16];
    static strim_cdi_edit_set set;
    size_t i;

    memset(&set, 0, sizeof(set));
    set.oci.env = (const char *const *)g_pending.env;
    set.oci.n_env = g_pending.n_env;
    for (i = 0; i < g_pending.n_mounts; i++) {
      oci_mounts[i].host_path = g_pending.mounts[i].host_path;
      oci_mounts[i].container_path = g_pending.mounts[i].container_path;
      oci_mounts[i].options = (const char *const *)g_pending.mounts[i].options;
      oci_mounts[i].n_options = g_pending.mounts[i].n_options;
    }
    set.oci.mounts = oci_mounts;
    set.oci.n_mounts = g_pending.n_mounts;
    for (i = 0; i < g_pending.n_devices; i++) {
      oci_devices[i].path = g_pending.devices[i].path;
      oci_devices[i].type = g_pending.devices[i].type;
      oci_devices[i].major = g_pending.devices[i].major;
      oci_devices[i].minor = g_pending.devices[i].minor;
      oci_devices[i].file_mode = g_pending.devices[i].file_mode;
      oci_devices[i].uid = g_pending.devices[i].uid;
      oci_devices[i].gid = g_pending.devices[i].gid;
    }
    set.oci.devices = oci_devices;
    set.oci.n_devices = g_pending.n_devices;
    for (i = 0; i < g_pending.n_hooks; i++) {
      oci_hooks[i].path = g_pending.hooks[i].path;
      oci_hooks[i].args = (const char *const *)g_pending.hooks[i].args;
      oci_hooks[i].n_args = g_pending.hooks[i].n_args;
      oci_hooks[i].env = (const char *const *)g_pending.hooks[i].env;
      oci_hooks[i].n_env = g_pending.hooks[i].n_env;
      oci_hooks[i].timeout = g_pending.hooks[i].timeout;
    }
    set.oci.hooks = oci_hooks;
    set.oci.n_hooks = g_pending.n_hooks;
    for (i = 0; i < g_pending.n_gids && i < 16; i++)
      oci_gids[i] = g_pending.gids[i];
    set.oci.additional_gids = oci_gids;
    set.oci.n_additional_gids =
        (g_pending.n_gids < 16) ? g_pending.n_gids : 16;

    *out = &set;
  }
  return 0;
}