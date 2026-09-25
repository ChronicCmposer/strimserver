/*
 * oci_spec.c — OCI runtime-spec JSON builder for the containerd client.
 *
 * Reproduces containerd's oci.GenerateSpec output for the strimserver
 * factory. See oci_spec.h for the contract and the field-elision rules.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include "oci_spec.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* strim_default_unix_env is declared by spec.h and defined by the core lane
 * (core/spec.c); the container lane consumes it, never redefines it. */

/* containerd's defaultUnixCaps (pkg/oci/spec.go). */
static const char *const DEFAULT_CAPS[] = {
    "CAP_CHOWN",          "CAP_DAC_OVERRIDE",   "CAP_FSETID",
    "CAP_FOWNER",         "CAP_MKNOD",          "CAP_NET_RAW",
    "CAP_SETGID",         "CAP_SETUID",         "CAP_SETFCAP",
    "CAP_SETPCAP",        "CAP_NET_BIND_SERVICE", "CAP_SYS_CHROOT",
    "CAP_KILL",           "CAP_AUDIT_WRITE",
};

/* containerd's defaultMounts (pkg/oci/mounts.go). */
static const struct {
  const char *dest;
  const char *type;
  const char *source;
  const char *const *options;
} DEFAULT_MOUNTS[] = {
    {"/proc", "proc", "proc",
     (const char *const[]){"nosuid", "noexec", "nodev", NULL}},
    {"/dev", "tmpfs", "tmpfs",
     (const char *const[]){"nosuid", "strictatime", "mode=755", "size=65536k",
                           NULL}},
    {"/dev/pts", "devpts", "devpts",
     (const char *const[]){"nosuid", "noexec", "newinstance", "ptmxmode=0666",
                           "mode=0620", "gid=5", NULL}},
    {"/dev/shm", "tmpfs", "shm",
     (const char *const[]){"nosuid", "noexec", "nodev", "mode=1777",
                           "size=65536k", NULL}},
    {"/dev/mqueue", "mqueue", "mqueue",
     (const char *const[]){"nosuid", "noexec", "nodev", NULL}},
    {"/sys", "sysfs", "sysfs",
     (const char *const[]){"nosuid", "noexec", "nodev", "ro", NULL}},
    {"/run", "tmpfs", "tmpfs",
     (const char *const[]){"nosuid", "strictatime", "mode=755", "size=65536k",
                           NULL}},
};

/* containerd's default masked/readonly paths (pkg/oci/spec.go). */
static const char *const MASKED_PATHS[] = {
    "/proc/acpi", "/proc/asound", "/proc/kcore",
    "/proc/keys", "/proc/latency_stats", "/proc/timer_list",
    "/proc/timer_stats", "/proc/sched_debug", "/sys/firmware",
    "/sys/devices/virtual/powercap", "/proc/scsi",
};
static const char *const READONLY_PATHS[] = {
    "/proc/bus", "/proc/fs", "/proc/irq", "/proc/sys", "/proc/sysrq-trigger",
};

/* =========================================================================
 * Growable JSON buffer
 * ========================================================================= */

struct jbuf {
  char *data;
  size_t len;
  size_t cap;
};

static int jb_reserve(struct jbuf *b, size_t extra) {
  size_t need = b->len + extra;
  size_t ncap;
  char *np;
  if (need <= b->cap)
    return 0;
  ncap = b->cap ? b->cap : 256;
  while (ncap < need)
    ncap *= 2;
  np = (char *)realloc(b->data, ncap);
  if (np == NULL)
    return -1;
  b->data = np;
  b->cap = ncap;
  return 0;
}

static void jb_raw(struct jbuf *b, const char *s) {
  size_t n = strlen(s);
  if (jb_reserve(b, n) < 0)
    return;
  memcpy(b->data + b->len, s, n);
  b->len += n;
}

static void jb_ch(struct jbuf *b, char c) {
  if (jb_reserve(b, 1) < 0)
    return;
  b->data[b->len++] = c;
}

static void jb_quoted(struct jbuf *b, const char *s) {
  jb_ch(b, '"');
  if (s != NULL) {
    const unsigned char *p = (const unsigned char *)s;
    while (*p) {
      unsigned char c = *p++;
      switch (c) {
      case '"':
        jb_raw(b, "\\\"");
        break;
      case '\\':
        jb_raw(b, "\\\\");
        break;
      case '\b':
        jb_raw(b, "\\b");
        break;
      case '\f':
        jb_raw(b, "\\f");
        break;
      case '\n':
        jb_raw(b, "\\n");
        break;
      case '\r':
        jb_raw(b, "\\r");
        break;
      case '\t':
        jb_raw(b, "\\t");
        break;
      default:
        if (c < 0x20) {
          char esc[8];
          snprintf(esc, sizeof(esc), "\\u%04x", c);
          jb_raw(b, esc);
        } else {
          jb_ch(b, (char)c);
        }
        break;
      }
    }
  }
  jb_ch(b, '"');
}

static void jb_u32(struct jbuf *b, uint32_t v) {
  char tmp[16];
  int n = snprintf(tmp, sizeof(tmp), "%u", v);
  if (n > 0 && jb_reserve(b, (size_t)n) == 0) {
    memcpy(b->data + b->len, tmp, (size_t)n);
    b->len += (size_t)n;
  }
}

static void jb_i64(struct jbuf *b, int64_t v) {
  char tmp[24];
  int n = snprintf(tmp, sizeof(tmp), "%lld", (long long)v);
  if (n > 0 && jb_reserve(b, (size_t)n) == 0) {
    memcpy(b->data + b->len, tmp, (size_t)n);
    b->len += (size_t)n;
  }
}

static void jb_str_array(struct jbuf *b, const char *const *items, size_t n) {
  size_t i;
  jb_ch(b, '[');
  for (i = 0; i < n; i++) {
    if (i)
      jb_ch(b, ',');
    jb_quoted(b, items[i]);
  }
  jb_ch(b, ']');
}

static int cap_contains(const char *const *caps, size_t n, const char *cap) {
  size_t i;
  for (i = 0; i < n; i++)
    if (strcmp(caps[i], cap) == 0)
      return 1;
  return 0;
}

/* =========================================================================
 * User resolution (best-effort mirror of containerd's WithImageConfig user /
 * additional-GID handling; the media images run as root).
 * ========================================================================= */

struct resolved_user {
  uint32_t uid;
  uint32_t gid;
  uint32_t gids[16];
  size_t n_gids;
};

/* Parse "name", "uid", "name:group", "uid:gid". Returns 0 on success, -1 on
 * malformed input. */
static int parse_user_spec(const char *user, char *name_out, size_t name_cap,
                           char *group_out, size_t group_cap, int *is_numeric,
                           uint32_t *numeric_uid) {
  const char *colon;
  if (user == NULL || user[0] == '\0')
    return -1;
  colon = strchr(user, ':');
  if (colon != NULL) {
    size_t nlen = (size_t)(colon - user);
    if (nlen == 0 || nlen >= name_cap || strlen(colon + 1) >= group_cap)
      return -1;
    memcpy(name_out, user, nlen);
    name_out[nlen] = '\0';
    strcpy(group_out, colon + 1);
  } else {
    if (strlen(user) >= name_cap)
      return -1;
    strcpy(name_out, user);
    group_out[0] = '\0';
  }
  *is_numeric = 0;
  *numeric_uid = 0;
  if (name_out[0] >= '0' && name_out[0] <= '9') {
    char *end = NULL;
    unsigned long v = strtoul(name_out, &end, 10);
    if (end != NULL && *end == '\0' && name_out[0] != '\0') {
      *is_numeric = 1;
      *numeric_uid = (uint32_t)v;
    }
  }
  return 0;
}

/* Look up a user name in /etc/passwd (best-effort). Returns 0 + uid/gid on
 * success, -1 when the file is missing or the user is absent. */
static int passwd_lookup(const char *name, uint32_t *uid, uint32_t *gid) {
  FILE *f = fopen("/etc/passwd", "r");
  char line[512];
  if (f == NULL)
    return -1;
  while (fgets(line, sizeof(line), f) != NULL) {
    char *save = NULL;
    char *fields[7];
    char *tok = strtok_r(line, ":", &save);
    int i = 0;
    while (tok != NULL && i < 7) {
      fields[i++] = tok;
      tok = strtok_r(NULL, ":", &save);
    }
    if (i >= 4 && strcmp(fields[0], name) == 0) {
      char *end = NULL;
      unsigned long u = strtoul(fields[2], &end, 10);
      if (end == NULL || *end != '\0') {
        fclose(f);
        return -1;
      }
      end = NULL;
      unsigned long g = strtoul(fields[3], &end, 10);
      if (end == NULL || *end != '\0') {
        fclose(f);
        return -1;
      }
      *uid = (uint32_t)u;
      *gid = (uint32_t)g;
      fclose(f);
      return 0;
    }
  }
  fclose(f);
  return -1;
}

/* Look up a group name in /etc/group (best-effort). Returns 0 + gid, or -1. */
static int group_lookup(const char *name, uint32_t *gid) {
  FILE *f = fopen("/etc/group", "r");
  char line[512];
  if (f == NULL)
    return -1;
  while (fgets(line, sizeof(line), f) != NULL) {
    char *save = NULL;
    char *fields[4];
    char *tok = strtok_r(line, ":", &save);
    int i = 0;
    while (tok != NULL && i < 4) {
      fields[i++] = tok;
      tok = strtok_r(NULL, ":", &save);
    }
    if (i >= 3 && strcmp(fields[0], name) == 0) {
      char *end = NULL;
      unsigned long g = strtoul(fields[2], &end, 10);
      if (end == NULL || *end != '\0') {
        fclose(f);
        return -1;
      }
      *gid = (uint32_t)g;
      fclose(f);
      return 0;
    }
  }
  fclose(f);
  return -1;
}

/* Collect the group ids a user belongs to from /etc/group (best-effort). */
static void group_memberships(const char *username, uint32_t primary_gid,
                              uint32_t *gids, size_t *n_gids) {
  FILE *f = fopen("/etc/group", "r");
  char line[512];
  size_t n = 0;
  if (f == NULL)
    return;
  gids[n++] = primary_gid;
  while (fgets(line, sizeof(line), f) != NULL && n < 16) {
    char *save = NULL;
    char *fields[4];
    char *tok = strtok_r(line, ":", &save);
    int i = 0;
    while (tok != NULL && i < 4) {
      fields[i++] = tok;
      tok = strtok_r(NULL, ":", &save);
    }
    if (i >= 4 && fields[3][0] != '\0') {
      /* members list is comma-separated */
      char *msave = NULL;
      char *m = strtok_r(fields[3], ",", &msave);
      while (m != NULL) {
        /* strip trailing newline */
        size_t mlen = strlen(m);
        while (mlen > 0 && (m[mlen - 1] == '\n' || m[mlen - 1] == '\r'))
          m[--mlen] = '\0';
        if (strcmp(m, username) == 0) {
          char *end = NULL;
          unsigned long g = strtoul(fields[2], &end, 10);
          if (end != NULL && *end == '\0' && n < 16)
            gids[n++] = (uint32_t)g;
          break;
        }
        m = strtok_r(NULL, ",", &msave);
      }
    }
  }
  fclose(f);
  *n_gids = n;
}

/* Resolve the image config user string into uid/gid/additional gids. The
 * default (empty user) is root: uid=0 gid=0 additional=[0]. Best-effort:
 * a failed lookup falls back to root (documented deviation from Go, which
 * would error out). */
static void resolve_user(const strim_oci_image_config *image,
                         struct resolved_user *out) {
  char name[128];
  char group[128];
  int is_numeric;
  uint32_t numeric_uid;

  memset(out, 0, sizeof(*out));
  if (image->user == NULL || image->user[0] == '\0') {
    /* WithAdditionalGIDs("root") path. */
    out->uid = 0;
    out->gid = 0;
    out->gids[0] = 0;
    out->n_gids = 1;
    return;
  }

  if (parse_user_spec(image->user, name, sizeof(name), group, sizeof(group),
                      &is_numeric, &numeric_uid) < 0) {
    out->uid = 0;
    out->gid = 0;
    out->gids[0] = 0;
    out->n_gids = 1;
    return;
  }

  if (is_numeric) {
    out->uid = numeric_uid;
    out->gid = 0;
    if (group[0] != '\0') {
      uint32_t g;
      char *end = NULL;
      unsigned long gv = strtoul(group, &end, 10);
      if (end != NULL && *end == '\0' && group[0] != '\0')
        out->gid = (uint32_t)gv;
      else if (group_lookup(group, &g) == 0)
        out->gid = g;
    }
  } else {
    uint32_t uid, gid;
    if (passwd_lookup(name, &uid, &gid) == 0) {
      out->uid = uid;
      out->gid = gid;
      if (group[0] != '\0') {
        uint32_t g;
        if (group_lookup(group, &g) == 0)
          out->gid = g;
      }
    } else {
      out->uid = 0;
      out->gid = 0;
      if (group[0] != '\0') {
        uint32_t g;
        if (group_lookup(group, &g) == 0)
          out->gid = g;
      }
    }
  }

  /* Additional GIDs: primary gid + /etc/group memberships for the name (or
   * the uid string when numeric). */
  if (is_numeric) {
    char uidstr[16];
    snprintf(uidstr, sizeof(uidstr), "%u", out->uid);
    group_memberships(uidstr, out->gid, out->gids, &out->n_gids);
  } else {
    group_memberships(name, out->gid, out->gids, &out->n_gids);
  }
  if (out->n_gids == 0) {
    out->gids[0] = out->gid;
    out->n_gids = 1;
  }
}

/* =========================================================================
 * Spec assembly
 * ========================================================================= */

/* Length of the key of an "K=V" env entry (the whole string when no '='). */
static size_t env_key_len(const char *entry) {
  const char *eq = strchr(entry, '=');
  return (eq != NULL) ? (size_t)(eq - entry) : strlen(entry);
}

/* True when an env entry with the same key already appears in the list. */
static int env_has_key(const char *const *env, size_t n_env,
                       const char *entry) {
  size_t key_len = env_key_len(entry);
  size_t i;
  for (i = 0; i < n_env; i++) {
    if (env_key_len(env[i]) == key_len && memcmp(env[i], entry, key_len) == 0)
      return 1;
  }
  return 0;
}

static void emit_process(struct jbuf *b, const strim_spec *spec,
                         const strim_oci_image_config *image,
                         const strim_oci_cdi_edits *cdi) {
  const char *const *env = image->env;
  size_t n_env = image->n_env;
  const char *cwd = image->working_dir;
  const char *env_all[STRIM_SPEC_MAX_ENV];
  size_t n_env_all = 0;
  struct resolved_user ru;
  size_t i;
  size_t total_caps;

  /* Env: explicit strim env wins; else image env; else the default fallback.
   * The image config carries no env -> strim_default_unix_env (the
   * populateDefaultUnixSpec contract, spec.h). */
  if (spec->process.env != NULL && spec->process.n_env > 0) {
    env = spec->process.env;
    n_env = spec->process.n_env;
  } else if (env == NULL || n_env == 0) {
    env = strim_default_unix_env;
    n_env = 0;
    while (env[n_env] != NULL)
      n_env++;
  }

  /* Merge the base env with the CDI edits (applyEdits appends). A CDI env
   * var whose key the base env already sets (e.g. the image env's
   * NVIDIA_VISIBLE_DEVICES=all vs the nvidia CDI spec's =void) is dropped —
   * the base value wins. Duplicates INSIDE the CDI set (spec-level +
   * device-level edits) are preserved, matching strim_cdi_merge_edits. */
  for (i = 0; i < n_env && n_env_all < STRIM_SPEC_MAX_ENV; i++)
    env_all[n_env_all++] = env[i];
  if (cdi != NULL && cdi->env != NULL)
    for (i = 0; i < cdi->n_env && n_env_all < STRIM_SPEC_MAX_ENV; i++)
      if (!env_has_key(env, n_env, cdi->env[i]))
        env_all[n_env_all++] = cdi->env[i];
  env = env_all;
  n_env = n_env_all;

  if (cwd == NULL || cwd[0] == '\0')
    cwd = "/";

  resolve_user(image, &ru);
  if (cdi != NULL && cdi->additional_gids != NULL) {
    size_t cap = sizeof(ru.gids) / sizeof(ru.gids[0]);
    for (i = 0; i < cdi->n_additional_gids && ru.n_gids < cap; i++)
      ru.gids[ru.n_gids++] = cdi->additional_gids[i];
  }

  /* Capabilities: defaults + the controller's appended caps, dedup'd. */
  total_caps = sizeof(DEFAULT_CAPS) / sizeof(DEFAULT_CAPS[0]);
  {
    size_t extra = spec->process.n_capabilities;
    const char *caps[64];
    size_t n = 0;
    size_t ci;
    for (ci = 0; ci < total_caps && n < 64; ci++)
      caps[n++] = DEFAULT_CAPS[ci];
    for (ci = 0; ci < extra && n < 64; ci++) {
      if (!cap_contains(caps, n, spec->process.capabilities[ci]))
        caps[n++] = spec->process.capabilities[ci];
    }

    jb_raw(b, "\"process\":{\"user\":{");
    if (ru.uid != 0) {
      jb_raw(b, "\"uid\":");
      jb_u32(b, ru.uid);
    }
    if (ru.gid != 0) {
      if (ru.uid != 0)
        jb_ch(b, ',');
      jb_raw(b, "\"gid\":");
      jb_u32(b, ru.gid);
    }
    if (ru.n_gids > 0) {
      if (ru.uid != 0 || ru.gid != 0)
        jb_ch(b, ',');
      jb_raw(b, "\"additionalGids\":[");
      for (i = 0; i < ru.n_gids; i++) {
        if (i)
          jb_ch(b, ',');
        jb_u32(b, ru.gids[i]);
      }
      jb_ch(b, ']');
    }
    jb_ch(b, '}');

    /* Args: image entrypoint + (strim args if set else image cmd). */
    {
      const char *const *args_tail = image->cmd;
      size_t n_args_tail = image->n_cmd;
      if (spec->process.args != NULL && spec->process.n_args > 0) {
        args_tail = spec->process.args;
        n_args_tail = spec->process.n_args;
      }
      jb_raw(b, ",\"args\":[");
      for (i = 0; i < image->n_entrypoint; i++) {
        if (i)
          jb_ch(b, ',');
        jb_quoted(b, image->entrypoint[i]);
      }
      {
        size_t base = image->n_entrypoint;
        for (i = 0; i < n_args_tail; i++) {
          if (base + i)
            jb_ch(b, ',');
          jb_quoted(b, args_tail[i]);
        }
      }
      jb_ch(b, ']');
    }

    jb_raw(b, ",\"env\":");
    jb_str_array(b, env, n_env);

    jb_raw(b, ",\"cwd\":");
    jb_quoted(b, cwd);

    jb_raw(b, ",\"capabilities\":{");
    jb_raw(b, "\"bounding\":");
    jb_str_array(b, caps, n);
    jb_raw(b, ",\"effective\":");
    jb_str_array(b, caps, n);
    jb_raw(b, ",\"permitted\":");
    jb_str_array(b, caps, n);
    jb_ch(b, '}');

    jb_raw(b, ",\"rlimits\":[{\"type\":\"RLIMIT_NOFILE\",\"hard\":1024,\"soft\":1024}]");
    jb_raw(b, ",\"noNewPrivileges\":true}");
  }
}

static void emit_mounts(struct jbuf *b, const strim_spec *spec,
                        const strim_oci_cdi_edits *cdi) {
  size_t i;
  jb_raw(b, "\"mounts\":[");
  for (i = 0; i < sizeof(DEFAULT_MOUNTS) / sizeof(DEFAULT_MOUNTS[0]); i++) {
    size_t j;
    if (i)
      jb_ch(b, ',');
    jb_raw(b, "{\"destination\":");
    jb_quoted(b, DEFAULT_MOUNTS[i].dest);
    jb_raw(b, ",\"type\":");
    jb_quoted(b, DEFAULT_MOUNTS[i].type);
    jb_raw(b, ",\"source\":");
    jb_quoted(b, DEFAULT_MOUNTS[i].source);
    jb_raw(b, ",\"options\":[");
    for (j = 0; DEFAULT_MOUNTS[i].options[j] != NULL; j++) {
      if (j)
        jb_ch(b, ',');
      jb_quoted(b, DEFAULT_MOUNTS[i].options[j]);
    }
    jb_ch(b, ']');
    jb_ch(b, '}');
  }
  for (i = 0; i < spec->n_mounts; i++) {
    const strim_mount *m = &spec->mounts[i];
    jb_ch(b, ',');
    jb_raw(b, "{\"destination\":");
    jb_quoted(b, m->destination);
    jb_raw(b, ",\"type\":\"bind\",\"source\":");
    jb_quoted(b, m->source);
    jb_raw(b, ",\"options\":[\"rbind\",\"");
    jb_raw(b, m->read_write ? "rw" : "ro");
    jb_raw(b, "\"]}");
  }
  /* CDI mounts (applyEdits appends bind mounts with the CDI options). */
  if (cdi != NULL && cdi->mounts != NULL) {
    for (i = 0; i < cdi->n_mounts; i++) {
      const struct strim_oci_cdi_mount *m = &cdi->mounts[i];
      size_t j;
      jb_ch(b, ',');
      jb_raw(b, "{\"destination\":");
      jb_quoted(b, m->container_path);
      jb_raw(b, ",\"type\":\"bind\",\"source\":");
      jb_quoted(b, m->host_path);
      jb_raw(b, ",\"options\":[");
      for (j = 0; j < m->n_options; j++) {
        if (j)
          jb_ch(b, ',');
        jb_quoted(b, m->options[j]);
      }
      jb_ch(b, ']');
      jb_ch(b, '}');
    }
  }
  jb_ch(b, ']');
}

static void emit_linux(struct jbuf *b, const strim_spec *spec,
                       const char *namespace_, const char *container_id,
                       const strim_oci_cdi_edits *cdi) {
  size_t i;
  char cgpath[512];
  size_t n_ns = 4; /* pid, ipc, uts, mount */
  const char *ns_names[5] = {"pid", "ipc", "uts", "mount", "network"};
  int have_network = !spec->host_network;

  /* cgroupsPath: "/<namespace>/<container-id>" (filepath.Join("/", ns, id));
   * the strim spec may override it. */
  if (spec->cgroups_path != NULL && spec->cgroups_path[0] != '\0') {
    snprintf(cgpath, sizeof(cgpath), "%s", spec->cgroups_path);
  } else {
    snprintf(cgpath, sizeof(cgpath), "/%s/%s",
             namespace_ ? namespace_ : "default", container_id);
  }

  jb_raw(b, "\"linux\":{");

  jb_raw(b, "\"maskedPaths\":");
  jb_str_array(b, MASKED_PATHS, sizeof(MASKED_PATHS) / sizeof(MASKED_PATHS[0]));
  jb_raw(b, ",\"readonlyPaths\":");
  jb_str_array(b, READONLY_PATHS,
               sizeof(READONLY_PATHS) / sizeof(READONLY_PATHS[0]));

  jb_raw(b, ",\"cgroupsPath\":");
  jb_quoted(b, cgpath);

  /* Device-cgroup rules: the base deny-all FIRST, then one allow rule per
   * CDI character-device node. cgroup v2 installs this array as a device
   * eBPF program with last-match-wins semantics, so the allows MUST follow
   * the deny-all (a trailing deny-all vetoes them — the deployed bug).
   * Go's cdi.WithCDIDevices appends the allows after the deny-all; mirror it.
   * Nodes without a valid char-device identity (major/minor < 0 or a type
   * other than "c") get no allow rule — linux.devices still carries them. */
  jb_raw(b, ",\"resources\":{\"devices\":[{\"allow\":false,\"access\":\"rwm\"}");
  if (cdi != NULL) {
    for (i = 0; i < cdi->n_devices; i++) {
      const struct strim_oci_cdi_device *d = &cdi->devices[i];
      if (d->major < 0 || d->minor < 0)
        continue;
      if (d->type != NULL && strcmp(d->type, "c") != 0)
        continue;
      jb_raw(b, ",{\"allow\":true,\"type\":\"c\",\"major\":");
      jb_i64(b, d->major);
      jb_raw(b, ",\"minor\":");
      jb_i64(b, d->minor);
      jb_raw(b, ",\"access\":\"rwm\"}");
    }
  }
  jb_raw(b, "]}");

  jb_raw(b, ",\"namespaces\":[");
  {
    size_t emitted = 0;
    for (i = 0; i < n_ns; i++) {
      if (emitted)
        jb_ch(b, ',');
      jb_raw(b, "{\"type\":");
      jb_quoted(b, ns_names[i]);
      jb_ch(b, '}');
      emitted++;
    }
    if (have_network) {
      if (emitted)
        jb_ch(b, ',');
      jb_raw(b, "{\"type\":\"network\"}");
    }
  }
  jb_ch(b, ']');

  /* CDI device nodes -> linux.devices. */
  if (cdi != NULL && cdi->n_devices > 0) {
    jb_raw(b, ",\"devices\":[");
    for (i = 0; i < cdi->n_devices; i++) {
      const struct strim_oci_cdi_device *d = &cdi->devices[i];
      if (i)
        jb_ch(b, ',');
      jb_raw(b, "{\"path\":");
      jb_quoted(b, d->path);
      jb_raw(b, ",\"type\":");
      jb_quoted(b, d->type != NULL ? d->type : "c");
      jb_raw(b, ",\"major\":");
      jb_i64(b, d->major);
      jb_raw(b, ",\"minor\":");
      jb_i64(b, d->minor);
      if (d->file_mode != 0) {
        jb_raw(b, ",\"fileMode\":");
        jb_u32(b, d->file_mode);
      }
      if (d->uid != 0) {
        jb_raw(b, ",\"uid\":");
        jb_u32(b, d->uid);
      }
      if (d->gid != 0) {
        jb_raw(b, ",\"gid\":");
        jb_u32(b, d->gid);
      }
      jb_ch(b, '}');
    }
    jb_ch(b, ']');
  }

  jb_ch(b, '}');
}

/* Emit one OCI hook object {"path", "args"[], "env"[], "timeout"} with the
 * optional fields elided (Go json.Marshal field-elision). */
static void emit_hook_object(struct jbuf *b, const char *path,
                             const char *const *args, size_t n_args,
                             const char *const *env, size_t n_env,
                             int32_t timeout) {
  jb_raw(b, "{\"path\":");
  jb_quoted(b, path);
  if (args != NULL && n_args > 0) {
    jb_raw(b, ",\"args\":");
    jb_str_array(b, args, n_args);
  }
  if (env != NULL && n_env > 0) {
    jb_raw(b, ",\"env\":");
    jb_str_array(b, env, n_env);
  }
  if (timeout != 0) {
    jb_raw(b, ",\"timeout\":");
    jb_i64(b, timeout);
  }
  jb_ch(b, '}');
}

/* Emit the top-level "hooks" section. The createContainer array carries the
 * strim spec's own hooks first, then the CDI edit set's hooks (the same
 * base-then-append merge the env/mounts use); either list may be empty. */
static void emit_hooks(struct jbuf *b, const strim_spec *spec,
                       const strim_oci_cdi_edits *cdi) {
  size_t i;
  size_t n_cdi = (cdi != NULL) ? cdi->n_hooks : 0;
  if (spec->n_hooks == 0 && n_cdi == 0)
    return;
  jb_raw(b, ",\"hooks\":{");
  jb_raw(b, "\"createContainer\":[");
  for (i = 0; i < spec->n_hooks; i++) {
    if (i)
      jb_ch(b, ',');
    emit_hook_object(b, spec->hooks[i].path, spec->hooks[i].args,
                     spec->hooks[i].n_args, spec->hooks[i].env,
                     spec->hooks[i].n_env, spec->hooks[i].timeout);
  }
  for (i = 0; i < n_cdi; i++) {
    if (spec->n_hooks + i)
      jb_ch(b, ',');
    emit_hook_object(b, cdi->hooks[i].path, cdi->hooks[i].args,
                     cdi->hooks[i].n_args, cdi->hooks[i].env,
                     cdi->hooks[i].n_env, cdi->hooks[i].timeout);
  }
  jb_raw(b, "]}");
}

int strim_oci_build_spec(const strim_spec *spec,
                         const strim_oci_image_config *image,
                         const char *namespace_, const char *container_id,
                         const strim_oci_cdi_edits *cdi, char **out_json,
                         size_t *out_len) {
  struct jbuf b;

  if (spec == NULL || image == NULL || container_id == NULL || out_json == NULL ||
      out_len == NULL)
    return -1;

  memset(&b, 0, sizeof(b));

  jb_ch(&b, '{');
  jb_raw(&b, "\"ociVersion\":\"1.0.2\",");

  emit_process(&b, spec, image, cdi);
  jb_ch(&b, ',');

  jb_raw(&b, "\"root\":{\"path\":\"rootfs\"},");

  emit_mounts(&b, spec, cdi);
  jb_ch(&b, ',');

  emit_linux(&b, spec, namespace_, container_id, cdi);
  emit_hooks(&b, spec, cdi);
  jb_ch(&b, '}');
  jb_ch(&b, '\0');

  if (b.data == NULL)
    return -1;
  *out_json = b.data;
  *out_len = b.len - 1; /* exclude the NUL */
  return 0;
}