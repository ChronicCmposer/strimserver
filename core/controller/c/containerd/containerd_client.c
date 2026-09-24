/*
 * containerd_client.c — the containerd client contract implementation.
 *
 * Wave 1 (containerd lane). Implements containerd_client.h on top of the
 * hand-rolled h2c/gRPC framing layer (h2c.c), the nanopb codecs
 * (//core/controller/c:codecs), and the hand-rolled Snapshots/Content service
 * clients (snapshots.c / content.c). Reproduces the Go oracle's construction
 * contract 1:1 (core/controller/container_factory.go):
 *
 *   - NewContainer: GetImage -> resolve the image's rootfs chain ID from its
 *     OCI config (Content service + SHA-256 identity.ChainID) ->
 *     Snapshots/Prepare(key=snapshot_id, parent=chain_id) [NEVER
 *     empty-parented] -> build the OCI spec JSON (oci_spec.c, the
 *     oci.GenerateSpec reproduction) -> Containers/Create.
 *   - NewTask: Snapshots/Mounts(container snapshot) -> Tasks/Create with the
 *     rootfs mounts + the log-file stdio URI (cio.LogFile).
 *   - stop path primitives: LoadContainer, LoadTask (Tasks/Get), Wait
 *     (Tasks/Wait on a dedicated connection so it can run concurrently with
 *     Kill), Kill(SIGTERM, All=false — the Go default), Delete(force=0
 *     requires exited; force=1 = WithProcessKill: Kill(SIGKILL, All=true),
 *     wait for exit, then Delete), DeleteContainer (snapshot Remove +
 *     Containers/Delete).
 *   - Subscribe: Events/Subscribe on a dedicated h2c connection; envelopes
 *     are decoded with the nanopb codecs and dispatched by type_url suffix
 *     (TaskStart -> Running, TaskExit -> Stopped).
 *
 * THREADING: the interface contract says a client is used "from one thread
 * at a time", but the Wave-1 controller drives stage ops on a 4-thread
 * worker pool, so multiple threads can enter this client concurrently. Every
 * public API call that touches the shared h2c connection therefore takes the
 * client's internal mutex for the whole RPC sequence (the Go client is
 * goroutine-safe; the C port needs the explicit lock). Task Wait and event
 * streams use their OWN h2c connections and never contend on the shared fd;
 * they are exempt from the mutex (their connection handles are private).
 *
 * CONNECTION LIFECYCLE (Wave 3, reconnect design): strim_containerd_connect
 * is LAZY, matching Go's containerd.New — it never dials. The shared h2c
 * connection is established by the first RPC (shared_conn_locked) and is
 * re-established by the next RPC whenever a transport-level failure tears it
 * down (shared_conn_reset_locked on H2C_ERR_IO / GOAWAY / PROTO / NOCONN /
 * CLOSED / NOSTREAM). Consequences, identical to Go:
 *
 *   - A containerd daemon that is down at boot is NOT fatal: connect returns
 *     a valid client, the first RPC fails with STRIM_CTRD_ERR_CONNECT, and
 *     every later RPC retries the connection, so the controller recovers
 *     when the daemon comes up.
 *   - A daemon that dies mid-flight is recovered the same way: the failed
 *     RPC returns STRIM_CTRD_ERR_IO (or the server's gRPC status), the dead
 *     connection is discarded, and the next RPC dials afresh.
 *
 * Task Wait and event Subscribe open their own per-call h2c connections, so
 * they are inherently lazy and reconnect per call; only the shared
 * connection needs the explicit lifecycle above.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include "containerd_client.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <pb.h>
#include <pb_decode.h>
#include <pb_encode.h>

#include <google/protobuf/any.pb.h>
#include <google/protobuf/empty.pb.h>
#include <services/containers/v1/containers.pb.h>
#include <services/events/v1/events.pb.h>
#include <services/images/v1/images.pb.h>
#include <services/tasks/v1/tasks.pb.h>
#include <types/event.pb.h>
#include <events/task.pb.h>

#include "cdi_internal.h"
#include "content.h"
#include "h2c.h"
#include "oci_spec.h"
#include "sha256.h"
#include "snapshots.h"
#include "yyjson.h"

/* stdio.h defines stdout/stderr as macros; the hermetic musl toolchain
 * compiles C translation units in C++ mode (the zig c++ driver), where they
 * expand and break the nanopb CreateTaskRequest.stdout/.stderr field
 * accessors. The task request is the only consumer; nothing in this file
 * uses the FILE globals. */
#undef stdout
#undef stderr

/* =========================================================================
 * Wire constants (verified against containerd api v1.12.0)
 * ========================================================================= */

#define SPEC_TYPE_URL "types.containerd.io/opencontainers/runtime-spec/1/Spec"
#define EV_START_SUFFIX "containerd.events.TaskStart"
#define EV_EXIT_SUFFIX "containerd.events.TaskExit"

#define M_IMAGES_GET      "/containerd.services.images.v1.Images/Get"
#define M_CONTAINERS_GET  "/containerd.services.containers.v1.Containers/Get"
#define M_CONTAINERS_CREATE "/containerd.services.containers.v1.Containers/Create"
#define M_CONTAINERS_DELETE "/containerd.services.containers.v1.Containers/Delete"
#define M_TASKS_CREATE    "/containerd.services.tasks.v1.Tasks/Create"
#define M_TASKS_START     "/containerd.services.tasks.v1.Tasks/Start"
#define M_TASKS_KILL      "/containerd.services.tasks.v1.Tasks/Kill"
#define M_TASKS_DELETE    "/containerd.services.tasks.v1.Tasks/Delete"
#define M_TASKS_GET       "/containerd.services.tasks.v1.Tasks/Get"
#define M_TASKS_WAIT      "/containerd.services.tasks.v1.Tasks/Wait"
#define M_EVENTS_SUBSCRIBE "/containerd.services.events.v1.Events/Subscribe"

#define CTRD_TIMEOUT_MS 30000
#define SIGKILL 9

/* Bounded post-SIGKILL wait inside the force-delete path (Go's
 * WithProcessKill waits for the exit before Tasks/Delete; a task that ignores
 * SIGKILL is pathological, so 10 s is generous). */
#define CTRD_FORCE_KILL_WAIT_MS 10000

/* =========================================================================
 * Handles
 * ========================================================================= */

struct strim_containerd_client {
  pthread_mutex_t lock; /* serializes RPCs on the shared h2c connection */
  strim_h2c *h2c;
  char *socket_path;
  char *namespace_;
  struct strim_event_stream *streams; /* streams opened on this client   */
  /* Derived handles (owned by the client per containerd_client.h: "owned by
   * the client and stays valid until close"); freed by Close. */
  struct strim_image *images;
  struct strim_container *containers;
  struct strim_task *tasks;
};

struct strim_image {
  strim_containerd_client *client;
  struct strim_image *next;
  char *name;
  char *target_digest;
  char *target_media_type;
  int64_t target_size;
};

struct strim_container {
  strim_containerd_client *client;
  struct strim_container *next;
  char *id;
  char *image;
  char *runtime_name;
  char *snapshotter;
  char *snapshot_key;
};

struct strim_task {
  strim_container *container;
  struct strim_task *next;
  char *container_id;
  char *stdout_uri; /* log file URI from NewTask (owned) */
  uint32_t pid;
};

struct strim_event_stream {
  strim_containerd_client *client;
  strim_h2c *conn;             /* dedicated h2c connection              */
  strim_h2c_stream *h2c_stream;
  int closed;
  struct strim_event_envelope *current; /* last decoded envelope         */
  struct strim_event_stream *next;      /* client stream list            */
};

struct strim_event_envelope {
  strim_event_stream *stream;
  containerd_types_Envelope env;
  int payload_ready; /* 0 = none, 1 = TaskStart, 2 = TaskExit decoded */
  containerd_events_TaskStart task_start;
  containerd_events_TaskExit task_exit;
};

/* =========================================================================
 * Error mapping
 * ========================================================================= */

static int map_grpc_err(int rc) {
  if (rc >= 0) {
    switch (rc) {
    case H2C_STATUS_OK:
      return 0;
    case H2C_STATUS_NOT_FOUND:
      return STRIM_CTRD_ERR_NOTFOUND;
    case H2C_STATUS_DEADLINE_EXCEEDED:
      return STRIM_CTRD_ERR_TIMEOUT;
    case H2C_STATUS_ALREADY_EXISTS:
      return STRIM_CTRD_ERR_IO; /* caller decides whether to tolerate */
    default:
      return STRIM_CTRD_ERR_IO;
    }
  }
  switch (rc) {
  case H2C_ERR_TIMEOUT:
    return STRIM_CTRD_ERR_TIMEOUT;
  case H2C_ERR_CLOSED:
    return STRIM_CTRD_ERR_CLOSED;
  case H2C_ERR_TOOBIG:
  case H2C_ERR_PROTO:
    return STRIM_CTRD_ERR_PROTO;
  default:
    return STRIM_CTRD_ERR_IO;
  }
}

/* =========================================================================
 * Shared-connection lifecycle (lazy connect + reconnect-on-dead-transport)
 *
 * The Go client is created with a non-blocking dial (containerd.New) and
 * gRPC-go manages the connection: the first RPC establishes it and, after a
 * transport failure, the next RPC transparently reconnects. The C client
 * reproduces that on its SHARED h2c connection: it is dialed on first use and
 * re-dialed after every teardown. Task Wait and event Subscribe open their
 * own per-call connections and need none of this.
 *
 * The caller holds the client lock for all four helpers.
 * ========================================================================= */

/* Whether a negative h2c error means the shared connection is unusable and
 * must be rebuilt (the gRPC-go TRANSIENT_FAILURE case). Timeouts and local
 * buffer limits leave the connection healthy and are deliberately NOT
 * resets. */
static int transport_is_dead(int rc) {
  switch (rc) {
  case H2C_ERR_IO:
  case H2C_ERR_GOAWAY:
  case H2C_ERR_PROTO:
  case H2C_ERR_NOSTREAM:
  case H2C_ERR_NOCONN:
  case H2C_ERR_CLOSED:
    return 1;
  default:
    return 0;
  }
}

/* Discard the shared connection so the next RPC dials a fresh one. */
static void shared_conn_reset_locked(strim_containerd_client *client) {
  if (client->h2c != NULL) {
    h2c_close(client->h2c);
    client->h2c = NULL;
  }
}

/* Ensure the shared connection exists (the lazy dial): establish it on the
 * first RPC and re-establish it after every teardown, so a daemon that was
 * down is retried on every call. Returns 0 + *out, or STRIM_CTRD_ERR_CONNECT
 * when the daemon is unreachable. */
static int shared_conn_locked(strim_containerd_client *client,
                              strim_h2c **out) {
  if (client->h2c == NULL) {
    int rc = h2c_connect(&client->h2c, client->socket_path,
                         client->namespace_);
    if (rc != 0)
      return STRIM_CTRD_ERR_CONNECT;
  }
  *out = client->h2c;
  return 0;
}

/* Run a unary RPC on the shared connection, tearing the connection down on a
 * dead-transport result so the next RPC reconnects. Returns 0, a positive
 * gRPC status, or a negative H2C_ERR_* / STRIM_CTRD_ERR_CONNECT (the caller
 * maps via map_rpc_err / the public error space). */
static int shared_unary_locked(strim_containerd_client *client,
                               const char *method, const uint8_t *req,
                               uint32_t req_len, uint8_t *resp,
                               uint32_t resp_cap, uint32_t *resp_len,
                               int64_t timeout_ms) {
  strim_h2c *conn;
  int rc;
  rc = shared_conn_locked(client, &conn);
  if (rc != 0)
    return rc;
  rc = h2c_unary(conn, method, req, req_len, resp, resp_cap, resp_len,
                 timeout_ms);
  if (rc < 0 && transport_is_dead(rc))
    shared_conn_reset_locked(client);
  return rc;
}

/* Map an RPC result (0, a gRPC status, a negative H2C_ERR_*, or the
 * STRIM_CTRD_ERR_CONNECT that shared_conn_locked returns) to the public
 * error space. STRIM_CTRD_ERR_CONNECT (-2) deliberately aliases H2C_ERR_IO's
 * value, so it must be checked before map_grpc_err would fold it into
 * STRIM_CTRD_ERR_IO. */
static int map_rpc_err(int rc) {
  if (rc == STRIM_CTRD_ERR_CONNECT)
    return STRIM_CTRD_ERR_CONNECT;
  return map_grpc_err(rc);
}

/* =========================================================================
 * Image config resolution (Content service + yyjson)
 * ========================================================================= */

struct image_config {
  strim_oci_image_config cfg;
  char *blob; /* owned config blob */
  size_t blob_len;
  char **diff_ids;
  size_t n_diff_ids;
  char **env;
  char **entrypoint;
  char **cmd;
};

static void image_config_free(struct image_config *ic) {
  size_t i;
  free(ic->blob);
  for (i = 0; i < ic->n_diff_ids; i++)
    free(ic->diff_ids[i]);
  free(ic->diff_ids);
  for (i = 0; i < ic->cfg.n_env; i++)
    free(ic->env[i]);
  free(ic->env);
  for (i = 0; i < ic->cfg.n_entrypoint; i++)
    free(ic->entrypoint[i]);
  free(ic->entrypoint);
  for (i = 0; i < ic->cfg.n_cmd; i++)
    free(ic->cmd[i]);
  free(ic->cmd);
  free((void *)ic->cfg.working_dir);
  free((void *)ic->cfg.user);
  memset(ic, 0, sizeof(*ic));
}

static char *dup_yy_str(yyjson_val *v) {
  size_t len;
  const char *s;
  char *out;
  if (v == NULL || !yyjson_is_str(v))
    return NULL;
  s = yyjson_get_str(v);
  if (s == NULL)
    return NULL;
  len = yyjson_get_len(v);
  out = (char *)malloc(len + 1);
  if (out == NULL)
    return NULL;
  memcpy(out, s, len);
  out[len] = '\0';
  return out;
}

static char **dup_str_array(yyjson_val *arr, size_t *out_n) {
  size_t n;
  size_t i;
  char **out;
  if (!yyjson_is_arr(arr))
    return NULL;
  n = yyjson_arr_size(arr);
  if (n == 0)
    return NULL;
  out = (char **)calloc(n, sizeof(char *));
  if (out == NULL)
    return NULL;
  for (i = 0; i < n; i++) {
    out[i] = dup_yy_str(yyjson_arr_get(arr, i));
    if (out[i] == NULL) {
      size_t j;
      for (j = 0; j < i; j++)
        free(out[j]);
      free(out);
      return NULL;
    }
  }
  *out_n = n;
  return out;
}

/* Parse the OCI image config JSON blob into a struct image_config. Returns
 * 0, or -1 on malformed JSON / missing diff-ids. */
static int parse_image_config(const uint8_t *blob, size_t len,
                              struct image_config *out) {
  yyjson_doc *doc;
  yyjson_val *root;
  yyjson_val *config;
  yyjson_val *rootfs;
  yyjson_val *v;
  int rc = -1;

  memset(out, 0, sizeof(*out));
  doc = yyjson_read((const char *)blob, len, 0);
  if (doc == NULL)
    return -1;
  root = yyjson_doc_get_root(doc);
  if (!yyjson_is_obj(root))
    goto done;

  config = yyjson_obj_get(root, "config");
  rootfs = yyjson_obj_get(root, "rootfs");
  if (!yyjson_is_obj(rootfs))
    goto done;

  v = yyjson_obj_get(rootfs, "diff_ids");
  out->diff_ids = dup_str_array(v, &out->n_diff_ids);
  if (out->diff_ids == NULL || out->n_diff_ids == 0)
    goto done;

  if (yyjson_is_obj(config)) {
    v = yyjson_obj_get(config, "env");
    out->env = dup_str_array(v, &out->cfg.n_env);
    out->cfg.env = (const char *const *)out->env;
    v = yyjson_obj_get(config, "entrypoint");
    out->entrypoint = dup_str_array(v, &out->cfg.n_entrypoint);
    out->cfg.entrypoint = (const char *const *)out->entrypoint;
    v = yyjson_obj_get(config, "cmd");
    out->cmd = dup_str_array(v, &out->cfg.n_cmd);
    out->cfg.cmd = (const char *const *)out->cmd;
    v = yyjson_obj_get(config, "workingdir");
    out->cfg.working_dir = dup_yy_str(v);
    v = yyjson_obj_get(config, "user");
    out->cfg.user = dup_yy_str(v);
  }

  rc = 0;
done:
  yyjson_doc_free(doc);
  if (rc != 0)
    image_config_free(out);
  return rc;
}

/* Read the manifest (or index) blob and resolve the config descriptor
 * digest, honoring a platform-index (matching the host arch). Returns 0 +
 * a malloc'd digest string, or a negative H2C_ERR_* / gRPC status. */
static int resolve_config_digest(strim_h2c *h2c, const char *target_digest,
                                 char **out_digest) {
  uint8_t *blob = NULL;
  size_t blob_len = 0;
  int rc;

  rc = content_read_blob(h2c, target_digest, 4 * 1024 * 1024, &blob,
                         &blob_len);
  if (rc != 0)
    return rc;

  {
    yyjson_doc *doc = yyjson_read((const char *)blob, blob_len, 0);
    yyjson_val *root;
    char *config_digest = NULL;
    if (doc == NULL) {
      free(blob);
      return H2C_ERR_PROTO;
    }
    root = yyjson_doc_get_root(doc);
    if (!yyjson_is_obj(root)) {
      yyjson_doc_free(doc);
      free(blob);
      return H2C_ERR_PROTO;
    }

    {
      yyjson_val *manifests = yyjson_obj_get(root, "manifests");
      if (yyjson_is_arr(manifests) && yyjson_arr_size(manifests) > 0) {
        /* Manifest index: pick the platform matching the host arch, else
         * the first entry. */
        yyjson_val *chosen = yyjson_arr_get(manifests, 0);
        size_t n = yyjson_arr_size(manifests);
        size_t i;
        for (i = 0; i < n; i++) {
          yyjson_val *m = yyjson_arr_get(manifests, i);
          yyjson_val *platform = m ? yyjson_obj_get(m, "platform") : NULL;
          yyjson_val *arch = platform ? yyjson_obj_get(platform, "architecture") : NULL;
          yyjson_val *osv = platform ? yyjson_obj_get(platform, "os") : NULL;
          const char *os = osv ? yyjson_get_str(osv) : NULL;
#if defined(__aarch64__)
          const char *want_arch = "arm64";
#else
          const char *want_arch = "amd64";
#endif
          if (arch != NULL && yyjson_is_str(arch) &&
              strcmp(yyjson_get_str(arch), want_arch) == 0 &&
              (os == NULL || strcmp(os, "linux") == 0)) {
            chosen = m;
            break;
          }
        }
        if (chosen != NULL) {
          char *m_digest = dup_yy_str(yyjson_obj_get(chosen, "digest"));
          if (m_digest != NULL) {
            uint8_t *mblob = NULL;
            size_t mlen = 0;
            int mrc = content_read_blob(h2c, m_digest, 4 * 1024 * 1024,
                                        &mblob, &mlen);
            free(m_digest);
            if (mrc != 0) {
              yyjson_doc_free(doc);
              free(blob);
              return mrc;
            }
            free(blob);
            blob = mblob;
            blob_len = mlen;
            yyjson_doc_free(doc);
            doc = yyjson_read((const char *)blob, blob_len, 0);
            if (doc == NULL) {
              free(blob);
              return H2C_ERR_PROTO;
            }
            root = yyjson_doc_get_root(doc);
          }
        }
      }
    }

    {
      yyjson_val *configv = yyjson_obj_get(root, "config");
      if (yyjson_is_obj(configv))
        config_digest = dup_yy_str(yyjson_obj_get(configv, "digest"));
    }
    yyjson_doc_free(doc);
    free(blob);
    if (config_digest == NULL)
      return H2C_ERR_PROTO;
    *out_digest = config_digest;
    return 0;
  }
}

/* Compute identity.ChainID over the diff-ids (opencontainers/image-spec
 * identity): chain = sha256(chain + " " + diff_id) for each subsequent. */
static char *compute_chain_id(char *const *diff_ids, size_t n) {
  char *chain = NULL;
  size_t i;

  for (i = 0; i < n; i++) {
    if (chain == NULL) {
      chain = strdup(diff_ids[i]);
    } else {
      size_t clen = strlen(chain);
      size_t dlen = strlen(diff_ids[i]);
      char *joined = (char *)malloc(clen + 1 + dlen + 1);
      uint8_t digest[32];
      char fmt[72];
      if (joined == NULL) {
        free(chain);
        return NULL;
      }
      memcpy(joined, chain, clen);
      joined[clen] = ' ';
      memcpy(joined + clen + 1, diff_ids[i], dlen);
      joined[clen + 1 + dlen] = '\0';
      strim_sha256((const uint8_t *)joined, clen + 1 + dlen, digest);
      strim_sha256_format(digest, fmt);
      free(chain);
      free(joined);
      chain = strdup(fmt);
    }
  }
  return chain;
}

/* =========================================================================
 * nanopb helpers
 * ========================================================================= */

static int pb_encode_to_mem(const pb_msgdesc_t *fields, const void *msg,
                            uint8_t **out, size_t *out_len) {
  size_t size = 0;
  pb_ostream_t os;
  if (!pb_get_encoded_size(&size, fields, msg))
    return -1;
  *out = (uint8_t *)malloc(size ? size : 1);
  if (*out == NULL)
    return -1;
  os = pb_ostream_from_buffer(*out, size);
  if (!pb_encode(&os, fields, msg)) {
    free(*out);
    *out = NULL;
    return -1;
  }
  *out_len = os.bytes_written;
  return 0;
}

/* A heap-allocated pb_bytes_array_t big enough for `len` payload bytes. */
static pb_bytes_array_t *pb_bytes_new(const void *data, size_t len) {
  pb_bytes_array_t *a = (pb_bytes_array_t *)malloc(PB_BYTES_ARRAY_T_ALLOCSIZE(len));
  if (a == NULL)
    return NULL;
  a->size = (pb_size_t)len;
  if (len)
    memcpy(a->bytes, data, len);
  return a;
}

/* =========================================================================
 * Internal (lock-held) helpers
 * ========================================================================= */

static int get_image_locked(strim_containerd_client *client, const char *ref,
                            strim_image **out);

static int kill_locked(strim_task *task, int signum, int all);

static void image_free(strim_image *image);
static void container_free(strim_container *c);
static void task_free(strim_task *task);

/* Register a derived handle on the client's ownership list. The caller must
 * hold the client lock. */
static void image_register(strim_containerd_client *client,
                           strim_image *image) {
  image->next = client->images;
  client->images = image;
}

static void container_register(strim_containerd_client *client,
                               strim_container *c) {
  c->next = client->containers;
  client->containers = c;
}

static void task_register(strim_containerd_client *client, strim_task *t) {
  t->next = client->tasks;
  client->tasks = t;
}

/* Unregister a handle (the caller holds the lock and frees it). */
static void container_unregister(strim_container *c) {
  strim_containerd_client *client = c->client;
  strim_container **link;
  for (link = &client->containers; *link != NULL; link = &(*link)->next) {
    if (*link == c) {
      *link = c->next;
      return;
    }
  }
}

static void task_unregister(strim_task *t) {
  strim_containerd_client *client = t->container->client;
  strim_task **link;
  for (link = &client->tasks; *link != NULL; link = &(*link)->next) {
    if (*link == t) {
      *link = t->next;
      return;
    }
  }
}

/* =========================================================================
 * Public API — client lifecycle
 * ========================================================================= */

int strim_containerd_connect(const char *socket_path, const char *ns,
                             strim_containerd_client **out) {
  strim_containerd_client *client;

  if (out == NULL)
    return STRIM_CTRD_ERR_BADARG;
  *out = NULL;
  if (socket_path == NULL || socket_path[0] == '\0' || ns == NULL ||
      ns[0] == '\0')
    return STRIM_CTRD_ERR_BADARG;

  client = (strim_containerd_client *)calloc(1, sizeof(*client));
  if (client == NULL)
    return STRIM_CTRD_ERR_NOMEM;
  pthread_mutex_init(&client->lock, NULL);

  /* LAZY connect, matching Go's containerd.New: no socket work here. The
   * first RPC establishes the connection (shared_conn_locked); a daemon that
   * is down at boot is therefore NOT an error here — the first RPC fails
   * with STRIM_CTRD_ERR_CONNECT and later RPCs retry, so the controller
   * recovers when the daemon comes up. */
  client->socket_path = strdup(socket_path);
  client->namespace_ = strdup(ns);
  if (client->socket_path == NULL || client->namespace_ == NULL) {
    strim_containerd_close(client);
    return STRIM_CTRD_ERR_NOMEM;
  }
  *out = client;
  return 0;
}

static void event_stream_close_locked(strim_event_stream *stream);

void strim_containerd_close(strim_containerd_client *client) {
  struct strim_event_stream *s;
  struct strim_image *img;
  struct strim_container *c;
  struct strim_task *t;
  if (client == NULL)
    return;
  pthread_mutex_lock(&client->lock);
  for (s = client->streams; s != NULL;) {
    struct strim_event_stream *next = s->next;
    event_stream_close_locked(s);
    s = next;
  }
  client->streams = NULL;
  /* Free every derived handle (owned by the client until close). */
  while ((img = client->images) != NULL) {
    client->images = img->next;
    image_free(img);
  }
  while ((t = client->tasks) != NULL) {
    client->tasks = t->next;
    task_free(t);
  }
  while ((c = client->containers) != NULL) {
    client->containers = c->next;
    container_free(c);
  }
  h2c_close(client->h2c);
  pthread_mutex_unlock(&client->lock);
  pthread_mutex_destroy(&client->lock);
  free(client->socket_path);
  free(client->namespace_);
  free(client);
}

/* =========================================================================
 * Public API — images
 * ========================================================================= */

static void image_free(strim_image *image) {
  if (image == NULL)
    return;
  /* Unregister from the owning client's list (idempotent: a handle that is
   * not registered — e.g. mid-Close, or a temporary image already popped
   * from the list head — is simply not found). The caller must hold the
   * client lock. */
  if (image->client != NULL) {
    strim_image **link;
    for (link = &image->client->images; *link != NULL;
         link = &(*link)->next) {
      if (*link == image) {
        *link = image->next;
        break;
      }
    }
  }
  free(image->name);
  free(image->target_digest);
  free(image->target_media_type);
  free(image);
}

static int get_image_locked(strim_containerd_client *client, const char *ref,
                            strim_image **out) {
  containerd_services_images_v1_GetImageRequest req =
      containerd_services_images_v1_GetImageRequest_init_zero;
  containerd_services_images_v1_GetImageResponse resp =
      containerd_services_images_v1_GetImageResponse_init_zero;
  uint8_t *req_buf = NULL;
  size_t req_len = 0;
  uint8_t resp_buf[16384];
  uint32_t resp_len = 0;
  strim_image *image = NULL;
  int rc;

  req.name = (char *)ref;
  if (pb_encode_to_mem(containerd_services_images_v1_GetImageRequest_fields,
                       &req, &req_buf, &req_len) < 0)
    return STRIM_CTRD_ERR_NOMEM;
  rc = shared_unary_locked(client, M_IMAGES_GET, req_buf, (uint32_t)req_len,
                           resp_buf, sizeof(resp_buf), &resp_len,
                           CTRD_TIMEOUT_MS);
  free(req_buf);
  if (rc != 0)
    return map_rpc_err(rc);

  {
    pb_istream_t is = pb_istream_from_buffer(resp_buf, resp_len);
    if (!pb_decode(&is, containerd_services_images_v1_GetImageResponse_fields,
                   &resp))
      return STRIM_CTRD_ERR_PROTO;
  }
  if (!resp.has_image) {
    pb_release(containerd_services_images_v1_GetImageResponse_fields, &resp);
    return STRIM_CTRD_ERR_PROTO;
  }

  image = (strim_image *)calloc(1, sizeof(*image));
  if (image == NULL) {
    pb_release(containerd_services_images_v1_GetImageResponse_fields, &resp);
    return STRIM_CTRD_ERR_NOMEM;
  }
  image->client = client;
  image->name = strdup(ref);
  if (resp.image.target.digest != NULL)
    image->target_digest = strdup(resp.image.target.digest);
  if (resp.image.target.media_type != NULL)
    image->target_media_type = strdup(resp.image.target.media_type);
  image->target_size = resp.image.target.size;
  if (image->name == NULL || (resp.image.target.digest != NULL &&
                              image->target_digest == NULL)) {
    image_free(image);
    pb_release(containerd_services_images_v1_GetImageResponse_fields, &resp);
    return STRIM_CTRD_ERR_NOMEM;
  }
  pb_release(containerd_services_images_v1_GetImageResponse_fields, &resp);

  image_register(client, image);
  *out = image;
  return 0;
}

int strim_containerd_get_image(strim_containerd_client *client,
                               const char *ref, strim_image **out) {
  int rc;
  if (client == NULL || ref == NULL || out == NULL)
    return STRIM_CTRD_ERR_BADARG;
  *out = NULL;
  pthread_mutex_lock(&client->lock);
  rc = get_image_locked(client, ref, out);
  pthread_mutex_unlock(&client->lock);
  return rc;
}

/* =========================================================================
 * Public API — containers
 * ========================================================================= */

static strim_container *container_new(strim_containerd_client *client,
                                      const char *id, const char *image,
                                      const char *runtime_name,
                                      const char *snapshotter,
                                      const char *snapshot_key) {
  strim_container *c = (strim_container *)calloc(1, sizeof(*c));
  if (c == NULL)
    return NULL;
  c->client = client;
  c->id = strdup(id);
  c->image = image ? strdup(image) : NULL;
  c->runtime_name = runtime_name ? strdup(runtime_name) : NULL;
  c->snapshotter = snapshotter ? strdup(snapshotter) : NULL;
  c->snapshot_key = snapshot_key ? strdup(snapshot_key) : NULL;
  if (c->id == NULL) {
    free(c->image);
    free(c->runtime_name);
    free(c->snapshotter);
    free(c->snapshot_key);
    free(c);
    return NULL;
  }
  return c;
}

static void container_free(strim_container *c) {
  if (c == NULL)
    return;
  free(c->id);
  free(c->image);
  free(c->runtime_name);
  free(c->snapshotter);
  free(c->snapshot_key);
  free(c);
}

static int new_container_locked(strim_containerd_client *client,
                                const char *id, const char *snapshot_id,
                                const char *image_name, const strim_spec *spec,
                                strim_container **out) {
  containerd_services_containers_v1_CreateContainerRequest req =
      containerd_services_containers_v1_CreateContainerRequest_init_zero;
  containerd_services_containers_v1_CreateContainerResponse resp =
      containerd_services_containers_v1_CreateContainerResponse_init_zero;
  uint8_t *req_buf = NULL;
  size_t req_len = 0;
  uint8_t resp_buf[16384];
  uint32_t resp_len = 0;
  strim_image *image = NULL;
  char *config_digest = NULL;
  struct image_config ic;
  char *chain_id = NULL;
  char *json = NULL;
  size_t json_len = 0;
  pb_bytes_array_t *spec_value = NULL;
  const strim_cdi_edit_set *cdi = NULL;
  strim_container *ctr = NULL;
  int rc;

  /* 1. Resolve the image (Go: GetImage). */
  rc = get_image_locked(client, image_name, &image);
  if (rc != 0)
    return rc;
  if (image->target_digest == NULL) {
    image_free(image);
    return STRIM_CTRD_ERR_PROTO;
  }

  /* 2. Read the image config via the Content service and compute the rootfs
   *    chain ID (identity.ChainID of diff-ids). */
  rc = resolve_config_digest(client->h2c, image->target_digest, &config_digest);
  if (rc != 0) {
    if (transport_is_dead(rc))
      shared_conn_reset_locked(client);
    image_free(image);
    return map_grpc_err(rc);
  }
  {
    uint8_t *config_blob = NULL;
    size_t config_len = 0;
    rc = content_read_blob(client->h2c, config_digest, 4 * 1024 * 1024,
                           &config_blob, &config_len);
    free(config_digest);
    if (rc != 0) {
      if (transport_is_dead(rc))
        shared_conn_reset_locked(client);
      image_free(image);
      return map_grpc_err(rc);
    }
    if (parse_image_config(config_blob, config_len, &ic) < 0) {
      free(config_blob);
      image_free(image);
      return STRIM_CTRD_ERR_PROTO;
    }
    free(config_blob);
  }
  chain_id = compute_chain_id(ic.diff_ids, ic.n_diff_ids);
  if (chain_id == NULL) {
    image_config_free(&ic);
    image_free(image);
    return STRIM_CTRD_ERR_NOMEM;
  }

  /* 3. Create the snapshot parented on the image's chain (WithNewSnapshot:
   *    NEVER empty-parented). An AlreadyExists snapshot is tolerated (the
   *    Go client tolerates IsAlreadyExists). */
  rc = snapshots_prepare(client->h2c, STRIM_CTRD_DEFAULT_SNAPSHOTTER,
                         snapshot_id, chain_id, NULL, NULL);
  free(chain_id);
  if (rc != 0 && rc != H2C_STATUS_ALREADY_EXISTS) {
    if (transport_is_dead(rc))
      shared_conn_reset_locked(client);
    image_config_free(&ic);
    image_free(image);
    return map_grpc_err(rc);
  }

  /* 4. Build the OCI spec JSON (oci.GenerateSpec reproduction) with any
   *    pending CDI edits. */
  if (strim_cdi_get_pending_edits(&cdi) != 0)
    cdi = NULL;
  rc = strim_oci_build_spec(spec, &ic.cfg, client->namespace_, id,
                            cdi ? &cdi->oci : NULL, &json, &json_len);
  image_config_free(&ic);
  if (rc != 0) {
    image_free(image);
    return STRIM_CTRD_ERR_NOMEM;
  }

  /* 5. Containers/Create. */
  req.has_container = true;
  req.container.id = (char *)id;
  req.container.image = (char *)image_name;
  req.container.has_runtime = true;
  req.container.runtime.name = (char *)STRIM_CTRD_DEFAULT_RUNTIME;
  req.container.has_spec = true;
  req.container.spec.type_url = (char *)SPEC_TYPE_URL;
  spec_value = pb_bytes_new(json, json_len);
  free(json);
  if (spec_value == NULL) {
    image_free(image);
    return STRIM_CTRD_ERR_NOMEM;
  }
  req.container.spec.value = spec_value;
  req.container.snapshotter = (char *)STRIM_CTRD_DEFAULT_SNAPSHOTTER;
  req.container.snapshot_key = (char *)snapshot_id;

  if (pb_encode_to_mem(
          containerd_services_containers_v1_CreateContainerRequest_fields,
          &req, &req_buf, &req_len) < 0) {
    free(spec_value);
    image_free(image);
    return STRIM_CTRD_ERR_NOMEM;
  }
  rc = shared_unary_locked(client, M_CONTAINERS_CREATE, req_buf,
                           (uint32_t)req_len, resp_buf, sizeof(resp_buf),
                           &resp_len, CTRD_TIMEOUT_MS);
  free(req_buf);
  free(spec_value);
  if (rc != 0) {
    image_free(image);
    return map_rpc_err(rc);
  }

  {
    pb_istream_t is = pb_istream_from_buffer(resp_buf, resp_len);
    if (!pb_decode(&is,
                   containerd_services_containers_v1_CreateContainerResponse_fields,
                   &resp)) {
      image_free(image);
      return STRIM_CTRD_ERR_PROTO;
    }
  }

  ctr = container_new(client, id, image_name, STRIM_CTRD_DEFAULT_RUNTIME,
                      STRIM_CTRD_DEFAULT_SNAPSHOTTER, snapshot_id);
  pb_release(containerd_services_containers_v1_CreateContainerResponse_fields,
             &resp);
  image_free(image);
  if (ctr == NULL)
    return STRIM_CTRD_ERR_NOMEM;
  container_register(client, ctr);

  *out = ctr;
  return 0;
}

int strim_containerd_new_container(strim_containerd_client *client,
                                   const char *id, const char *snapshot_id,
                                   const char *image_name,
                                   const strim_spec *spec,
                                   strim_container **out) {
  int rc;
  if (client == NULL || id == NULL || snapshot_id == NULL || image_name == NULL ||
      spec == NULL || out == NULL)
    return STRIM_CTRD_ERR_BADARG;
  *out = NULL;
  pthread_mutex_lock(&client->lock);
  rc = new_container_locked(client, id, snapshot_id, image_name, spec, out);
  pthread_mutex_unlock(&client->lock);
  return rc;
}

static int load_container_locked(strim_containerd_client *client,
                                 const char *id, strim_container **out) {
  containerd_services_containers_v1_GetContainerRequest req =
      containerd_services_containers_v1_GetContainerRequest_init_zero;
  containerd_services_containers_v1_GetContainerResponse resp =
      containerd_services_containers_v1_GetContainerResponse_init_zero;
  uint8_t *req_buf = NULL;
  size_t req_len = 0;
  /* The response carries the container's full OCI spec Any (JSON), so give
   * the decode a generous fixed buffer. */
  uint8_t resp_buf[65536];
  uint32_t resp_len = 0;
  strim_container *ctr = NULL;
  int rc;

  req.id = (char *)id;
  if (pb_encode_to_mem(containerd_services_containers_v1_GetContainerRequest_fields,
                       &req, &req_buf, &req_len) < 0)
    return STRIM_CTRD_ERR_NOMEM;
  rc = shared_unary_locked(client, M_CONTAINERS_GET, req_buf,
                           (uint32_t)req_len, resp_buf, sizeof(resp_buf),
                           &resp_len, CTRD_TIMEOUT_MS);
  free(req_buf);
  if (rc != 0)
    return map_rpc_err(rc);

  {
    pb_istream_t is = pb_istream_from_buffer(resp_buf, resp_len);
    if (!pb_decode(&is, containerd_services_containers_v1_GetContainerResponse_fields,
                   &resp))
      return STRIM_CTRD_ERR_PROTO;
  }
  if (!resp.has_container) {
    pb_release(containerd_services_containers_v1_GetContainerResponse_fields,
               &resp);
    return STRIM_CTRD_ERR_PROTO;
  }

  ctr = container_new(client, id,
                      resp.container.image, resp.container.runtime.name,
                      resp.container.snapshotter, resp.container.snapshot_key);
  pb_release(containerd_services_containers_v1_GetContainerResponse_fields,
             &resp);
  if (ctr == NULL)
    return STRIM_CTRD_ERR_NOMEM;
  container_register(client, ctr);

  *out = ctr;
  return 0;
}

int strim_containerd_load_container(strim_containerd_client *client,
                                    const char *id, strim_container **out) {
  int rc;
  if (client == NULL || id == NULL || out == NULL)
    return STRIM_CTRD_ERR_BADARG;
  *out = NULL;
  pthread_mutex_lock(&client->lock);
  rc = load_container_locked(client, id, out);
  pthread_mutex_unlock(&client->lock);
  return rc;
}

static int delete_container_locked(strim_container *container,
                                   int cleanup_snapshot) {
  containerd_services_containers_v1_DeleteContainerRequest req =
      containerd_services_containers_v1_DeleteContainerRequest_init_zero;
  uint8_t *req_buf = NULL;
  size_t req_len = 0;
  uint8_t resp_buf[64];
  uint32_t resp_len = 0;
  int rc;

  /* WithSnapshotCleanup: remove the snapshot FIRST, then the container
   * (the v2 client's Delete opts run before the Containers/Delete call).
   * NotFound on the snapshot is tolerated. */
  if (cleanup_snapshot && container->snapshot_key != NULL &&
      container->snapshot_key[0] != '\0') {
    rc = snapshots_remove(container->client->h2c,
                          container->snapshotter != NULL
                              ? container->snapshotter
                              : STRIM_CTRD_DEFAULT_SNAPSHOTTER,
                          container->snapshot_key);
    if (rc != 0 && rc != H2C_STATUS_NOT_FOUND) {
      if (transport_is_dead(rc))
        shared_conn_reset_locked(container->client);
      return map_grpc_err(rc);
    }
  }

  req.id = container->id;
  if (pb_encode_to_mem(
          containerd_services_containers_v1_DeleteContainerRequest_fields, &req,
          &req_buf, &req_len) < 0)
    return STRIM_CTRD_ERR_NOMEM;
  rc = shared_unary_locked(container->client, M_CONTAINERS_DELETE, req_buf,
                           (uint32_t)req_len, resp_buf, sizeof(resp_buf),
                           &resp_len, CTRD_TIMEOUT_MS);
  free(req_buf);
  if (rc != 0)
    return map_rpc_err(rc);

  container_unregister(container);
  container_free(container);
  return 0;
}

int strim_containerd_delete_container(strim_container *container,
                                      int cleanup_snapshot) {
  strim_containerd_client *client;
  int rc;
  if (container == NULL || container->client == NULL)
    return STRIM_CTRD_ERR_BADARG;
  /* Capture the client before the call: delete_container_locked frees the
   * container handle. */
  client = container->client;
  pthread_mutex_lock(&client->lock);
  rc = delete_container_locked(container, cleanup_snapshot);
  pthread_mutex_unlock(&client->lock);
  return rc;
}

/* =========================================================================
 * Public API — tasks
 * ========================================================================= */

static void task_free(strim_task *task) {
  if (task == NULL)
    return;
  free(task->container_id);
  free(task->stdout_uri);
  free(task);
}

/* Build the cio.LogFile URI: url.URL{Scheme:"file", Path:path}.String() is
 * "file://<path>". */
static char *logfile_uri(const char *logfile) {
  size_t len = strlen(logfile);
  char *uri = (char *)malloc(len + 8);
  if (uri == NULL)
    return NULL;
  memcpy(uri, "file://", 7);
  strcpy(uri + 7, logfile);
  return uri;
}

static int new_task_locked(strim_container *container, const char *logfile,
                           strim_task **out) {
  containerd_services_tasks_v1_CreateTaskRequest req =
      containerd_services_tasks_v1_CreateTaskRequest_init_zero;
  containerd_services_tasks_v1_CreateTaskResponse resp =
      containerd_services_tasks_v1_CreateTaskResponse_init_zero;
  containerd_types_Mount *mounts = NULL;
  pb_size_t n_mounts = 0;
  uint8_t *req_buf = NULL;
  size_t req_len = 0;
  uint8_t resp_buf[4096];
  uint32_t resp_len = 0;
  char *uri = NULL;
  strim_task *task = NULL;
  int rc;

  /* Rootfs mounts come from the container's snapshot (the v2 client's
   * handleMounts path: snapshotter.Mounts(container.SnapshotKey)). */
  if (container->snapshot_key != NULL && container->snapshot_key[0] != '\0') {
    rc = snapshots_mounts(container->client->h2c,
                          container->snapshotter != NULL
                              ? container->snapshotter
                              : STRIM_CTRD_DEFAULT_SNAPSHOTTER,
                          container->snapshot_key, &mounts, &n_mounts);
    if (rc != 0) {
      if (transport_is_dead(rc))
        shared_conn_reset_locked(container->client);
      return map_grpc_err(rc);
    }
  }

  if (logfile != NULL && logfile[0] != '\0') {
    uri = logfile_uri(logfile);
    if (uri == NULL) {
      snapshots_free_mounts(mounts, n_mounts);
      return STRIM_CTRD_ERR_NOMEM;
    }
  }

  req.container_id = container->id;
  req.rootfs = mounts;
  req.rootfs_count = n_mounts;
  req.stdout = uri;
  req.stderr = uri;
  req.terminal = false;

  if (pb_encode_to_mem(containerd_services_tasks_v1_CreateTaskRequest_fields,
                       &req, &req_buf, &req_len) < 0) {
    snapshots_free_mounts(mounts, n_mounts);
    free(uri);
    return STRIM_CTRD_ERR_NOMEM;
  }
  rc = shared_unary_locked(container->client, M_TASKS_CREATE, req_buf,
                           (uint32_t)req_len, resp_buf, sizeof(resp_buf),
                           &resp_len, CTRD_TIMEOUT_MS);
  free(req_buf);
  snapshots_free_mounts(mounts, n_mounts);
  if (rc != 0) {
    free(uri);
    return map_rpc_err(rc);
  }

  {
    pb_istream_t is = pb_istream_from_buffer(resp_buf, resp_len);
    if (!pb_decode(&is, containerd_services_tasks_v1_CreateTaskResponse_fields,
                   &resp)) {
      free(uri);
      return STRIM_CTRD_ERR_PROTO;
    }
  }
  task = (strim_task *)calloc(1, sizeof(*task));
  if (task == NULL) {
    pb_release(containerd_services_tasks_v1_CreateTaskResponse_fields, &resp);
    free(uri);
    return STRIM_CTRD_ERR_NOMEM;
  }
  task->container = container;
  task->container_id = strdup(container->id);
  task->stdout_uri = uri;
  task->pid = resp.pid;
  pb_release(containerd_services_tasks_v1_CreateTaskResponse_fields, &resp);
  if (task->container_id == NULL) {
    task_free(task);
    return STRIM_CTRD_ERR_NOMEM;
  }
  task_register(container->client, task);

  *out = task;
  return 0;
}

int strim_containerd_new_task(strim_container *container, const char *logfile,
                              strim_task **out) {
  int rc;
  if (container == NULL || container->client == NULL || out == NULL)
    return STRIM_CTRD_ERR_BADARG;
  *out = NULL;
  pthread_mutex_lock(&container->client->lock);
  rc = new_task_locked(container, logfile, out);
  pthread_mutex_unlock(&container->client->lock);
  return rc;
}

static int load_task_locked(strim_container *container, strim_task **out) {
  containerd_services_tasks_v1_GetRequest req =
      containerd_services_tasks_v1_GetRequest_init_zero;
  containerd_services_tasks_v1_GetResponse resp =
      containerd_services_tasks_v1_GetResponse_init_zero;
  uint8_t *req_buf = NULL;
  size_t req_len = 0;
  uint8_t resp_buf[4096];
  uint32_t resp_len = 0;
  strim_task *task = NULL;
  int rc;

  req.container_id = container->id;
  if (pb_encode_to_mem(containerd_services_tasks_v1_GetRequest_fields, &req,
                       &req_buf, &req_len) < 0)
    return STRIM_CTRD_ERR_NOMEM;
  rc = shared_unary_locked(container->client, M_TASKS_GET, req_buf,
                           (uint32_t)req_len, resp_buf, sizeof(resp_buf),
                           &resp_len, CTRD_TIMEOUT_MS);
  free(req_buf);
  if (rc != 0)
    return map_rpc_err(rc);

  {
    pb_istream_t is = pb_istream_from_buffer(resp_buf, resp_len);
    if (!pb_decode(&is, containerd_services_tasks_v1_GetResponse_fields, &resp))
      return STRIM_CTRD_ERR_PROTO;
  }

  task = (strim_task *)calloc(1, sizeof(*task));
  if (task == NULL) {
    pb_release(containerd_services_tasks_v1_GetResponse_fields, &resp);
    return STRIM_CTRD_ERR_NOMEM;
  }
  task->container = container;
  task->container_id = strdup(container->id);
  task->pid = resp.process.pid;
  pb_release(containerd_services_tasks_v1_GetResponse_fields, &resp);
  if (task->container_id == NULL) {
    task_free(task);
    return STRIM_CTRD_ERR_NOMEM;
  }
  task_register(container->client, task);

  *out = task;
  return 0;
}

int strim_containerd_load_task(strim_container *container, strim_task **out) {
  int rc;
  if (container == NULL || container->client == NULL || out == NULL)
    return STRIM_CTRD_ERR_BADARG;
  *out = NULL;
  pthread_mutex_lock(&container->client->lock);
  rc = load_task_locked(container, out);
  pthread_mutex_unlock(&container->client->lock);
  return rc;
}

static int task_start_locked(strim_task *task) {
  containerd_services_tasks_v1_StartRequest req =
      containerd_services_tasks_v1_StartRequest_init_zero;
  uint8_t *req_buf = NULL;
  size_t req_len = 0;
  uint8_t resp_buf[64];
  uint32_t resp_len = 0;
  int rc;

  req.container_id = task->container_id;
  if (pb_encode_to_mem(containerd_services_tasks_v1_StartRequest_fields, &req,
                       &req_buf, &req_len) < 0)
    return STRIM_CTRD_ERR_NOMEM;
  rc = shared_unary_locked(task->container->client, M_TASKS_START, req_buf,
                           (uint32_t)req_len, resp_buf, sizeof(resp_buf),
                           &resp_len, CTRD_TIMEOUT_MS);
  free(req_buf);
  return map_rpc_err(rc);
}

int strim_containerd_task_start(strim_task *task) {
  int rc;
  if (task == NULL || task->container == NULL || task->container->client == NULL)
    return STRIM_CTRD_ERR_BADARG;
  pthread_mutex_lock(&task->container->client->lock);
  rc = task_start_locked(task);
  pthread_mutex_unlock(&task->container->client->lock);
  return rc;
}

/* The shared Kill implementation. The graceful path uses All=false (the Go
 * default for task.Kill without options); the force-delete path uses
 * All=true (Go's WithKillAll inside WithProcessKill). */
static int kill_locked(strim_task *task, int signum, int all) {
  containerd_services_tasks_v1_KillRequest req =
      containerd_services_tasks_v1_KillRequest_init_zero;
  uint8_t *req_buf = NULL;
  size_t req_len = 0;
  uint8_t resp_buf[64];
  uint32_t resp_len = 0;
  int rc;

  req.container_id = task->container_id;
  req.signal = (uint32_t)signum;
  req.all = all ? true : false;
  if (pb_encode_to_mem(containerd_services_tasks_v1_KillRequest_fields, &req,
                       &req_buf, &req_len) < 0)
    return STRIM_CTRD_ERR_NOMEM;
  rc = shared_unary_locked(task->container->client, M_TASKS_KILL, req_buf,
                           (uint32_t)req_len, resp_buf, sizeof(resp_buf),
                           &resp_len, CTRD_TIMEOUT_MS);
  free(req_buf);
  return rc;
}

int strim_containerd_task_kill(strim_task *task, int signum) {
  int rc;
  if (task == NULL || task->container == NULL || task->container->client == NULL)
    return STRIM_CTRD_ERR_BADARG;
  pthread_mutex_lock(&task->container->client->lock);
  rc = kill_locked(task, signum, 0);
  pthread_mutex_unlock(&task->container->client->lock);
  if (rc == H2C_STATUS_NOT_FOUND)
    return 0; /* NotFound is tolerated (task already gone) */
  return map_rpc_err(rc);
}

int strim_containerd_task_wait(strim_task *task, int64_t timeout_ms,
                               int32_t *exit_code) {
  containerd_services_tasks_v1_WaitRequest req =
      containerd_services_tasks_v1_WaitRequest_init_zero;
  containerd_services_tasks_v1_WaitResponse resp =
      containerd_services_tasks_v1_WaitResponse_init_zero;
  strim_h2c *conn = NULL;
  uint8_t *req_buf = NULL;
  size_t req_len = 0;
  uint8_t resp_buf[4096];
  uint32_t resp_len = 0;
  int rc;

  if (task == NULL || task->container == NULL || task->container->client == NULL ||
      exit_code == NULL)
    return STRIM_CTRD_ERR_BADARG;

  /* Tasks/Wait is a blocking RPC; the Go stop path runs it concurrently
   * with Kill. The wait therefore uses a DEDICATED h2c connection so the
   * controller thread can call Kill on the main connection while this
   * call blocks — and it is deliberately NOT under the client mutex. */
  rc = h2c_connect(&conn, task->container->client->socket_path,
                   task->container->client->namespace_);
  if (rc != 0)
    return STRIM_CTRD_ERR_CONNECT;

  req.container_id = task->container_id;
  if (pb_encode_to_mem(containerd_services_tasks_v1_WaitRequest_fields, &req,
                       &req_buf, &req_len) < 0) {
    h2c_close(conn);
    return STRIM_CTRD_ERR_NOMEM;
  }
  rc = h2c_unary(conn, M_TASKS_WAIT, req_buf, (uint32_t)req_len, resp_buf,
                 sizeof(resp_buf), &resp_len, timeout_ms);
  free(req_buf);
  h2c_close(conn);
  if (rc != 0)
    return map_grpc_err(rc);

  {
    pb_istream_t is = pb_istream_from_buffer(resp_buf, resp_len);
    if (!pb_decode(&is, containerd_services_tasks_v1_WaitResponse_fields, &resp))
      return STRIM_CTRD_ERR_PROTO;
  }
  *exit_code = (int32_t)resp.exit_status;
  pb_release(containerd_services_tasks_v1_WaitResponse_fields, &resp);
  return 0;
}

static int task_delete_locked(strim_task *task, int force) {
  containerd_services_tasks_v1_DeleteTaskRequest req =
      containerd_services_tasks_v1_DeleteTaskRequest_init_zero;
  uint8_t *req_buf = NULL;
  size_t req_len = 0;
  uint8_t resp_buf[4096];
  uint32_t resp_len = 0;
  int rc;

  /* force: the Go WithProcessKill contract — Kill(SIGKILL, All=true), wait
   * for the exit, then Delete. The wait uses a dedicated connection so it
   * does not contend on the shared fd. NotFound anywhere is tolerated (the
   * task may already be gone). */
  if (force) {
    int32_t code = 0;
    rc = kill_locked(task, SIGKILL, 1);
    if (rc != 0 && rc != H2C_STATUS_NOT_FOUND)
      return map_rpc_err(rc);
    rc = strim_containerd_task_wait(task, CTRD_FORCE_KILL_WAIT_MS, &code);
    if (rc != 0 && rc != STRIM_CTRD_ERR_NOTFOUND && rc != STRIM_CTRD_ERR_TIMEOUT)
      return rc;
  }

  req.container_id = task->container_id;
  if (pb_encode_to_mem(containerd_services_tasks_v1_DeleteTaskRequest_fields,
                       &req, &req_buf, &req_len) < 0)
    return STRIM_CTRD_ERR_NOMEM;
  rc = shared_unary_locked(task->container->client, M_TASKS_DELETE, req_buf,
                           (uint32_t)req_len, resp_buf, sizeof(resp_buf),
                           &resp_len, CTRD_TIMEOUT_MS);
  free(req_buf);
  if (rc == H2C_STATUS_NOT_FOUND)
    return 0; /* NotFound is tolerated (already gone) */
  if (rc != 0)
    return map_rpc_err(rc);

  task_unregister(task);
  task_free(task);
  return 0;
}

int strim_containerd_task_delete(strim_task *task, int force) {
  strim_containerd_client *client;
  int rc;
  if (task == NULL || task->container == NULL || task->container->client == NULL)
    return STRIM_CTRD_ERR_BADARG;
  /* Capture the client before the call: task_delete_locked frees the task
   * handle. */
  client = task->container->client;
  pthread_mutex_lock(&client->lock);
  rc = task_delete_locked(task, force);
  pthread_mutex_unlock(&client->lock);
  return rc;
}

/* =========================================================================
 * Public API — event subscription (typeurl dispatch)
 * ========================================================================= */

static int subscribe_locked(strim_containerd_client *client,
                            const char *const *filters, size_t n_filters,
                            strim_event_stream **out) {
  containerd_services_events_v1_SubscribeRequest req =
      containerd_services_events_v1_SubscribeRequest_init_zero;
  uint8_t *req_buf = NULL;
  size_t req_len = 0;
  strim_h2c *conn = NULL;
  strim_h2c_stream *h2c_stream = NULL;
  strim_event_stream *stream = NULL;
  int rc;

  /* The event stream gets its own h2c connection so the event-listener
   * thread never contends with the controller thread's unary calls. */
  rc = h2c_connect(&conn, client->socket_path, client->namespace_);
  if (rc != 0)
    return STRIM_CTRD_ERR_CONNECT;

  req.filters = (char **)filters;
  req.filters_count = (pb_size_t)n_filters;
  if (pb_encode_to_mem(containerd_services_events_v1_SubscribeRequest_fields,
                       &req, &req_buf, &req_len) < 0) {
    h2c_close(conn);
    return STRIM_CTRD_ERR_NOMEM;
  }
  rc = h2c_stream_open(conn, M_EVENTS_SUBSCRIBE, req_buf, (uint32_t)req_len,
                       &h2c_stream);
  free(req_buf);
  if (rc != 0) {
    h2c_close(conn);
    return map_grpc_err(rc);
  }

  stream = (strim_event_stream *)calloc(1, sizeof(*stream));
  if (stream == NULL) {
    h2c_stream_close(h2c_stream);
    h2c_close(conn);
    return STRIM_CTRD_ERR_NOMEM;
  }
  stream->client = client;
  stream->conn = conn;
  stream->h2c_stream = h2c_stream;
  stream->next = client->streams;
  client->streams = stream;

  *out = stream;
  return 0;
}

int strim_containerd_subscribe(strim_containerd_client *client,
                               const char *const *filters, size_t n_filters,
                               strim_event_stream **out) {
  int rc;
  if (client == NULL || filters == NULL || n_filters == 0 || out == NULL)
    return STRIM_CTRD_ERR_BADARG;
  *out = NULL;
  pthread_mutex_lock(&client->lock);
  rc = subscribe_locked(client, filters, n_filters, out);
  pthread_mutex_unlock(&client->lock);
  return rc;
}

static void envelope_release(strim_event_envelope *e) {
  if (e == NULL)
    return;
  pb_release(containerd_types_Envelope_fields, &e->env);
  if (e->payload_ready == 1)
    pb_release(containerd_events_TaskStart_fields, &e->task_start);
  else if (e->payload_ready == 2)
    pb_release(containerd_events_TaskExit_fields, &e->task_exit);
  e->payload_ready = 0;
  memset(&e->env, 0, sizeof(e->env));
}

int strim_event_stream_next(strim_event_stream *stream, int64_t timeout_ms,
                            strim_event_envelope **out) {
  const uint8_t *msg;
  uint32_t msg_len;
  int rc;

  if (stream == NULL || out == NULL)
    return STRIM_CTRD_ERR_BADARG;
  *out = NULL;
  if (stream->closed)
    return STRIM_CTRD_ERR_CLOSED;

  rc = h2c_stream_next(stream->h2c_stream, timeout_ms, &msg, &msg_len);
  if (rc != 0) {
    switch (rc) {
    case H2C_ERR_TIMEOUT:
      return STRIM_CTRD_ERR_TIMEOUT;
    case H2C_ERR_CLOSED:
      return STRIM_CTRD_ERR_CLOSED;
    default:
      return STRIM_CTRD_ERR_IO; /* stream ended / daemon error */
    }
  }

  if (stream->current == NULL) {
    stream->current = (strim_event_envelope *)calloc(1, sizeof(*stream->current));
    if (stream->current == NULL)
      return STRIM_CTRD_ERR_NOMEM;
    stream->current->stream = stream;
  } else {
    envelope_release(stream->current);
  }

  {
    pb_istream_t is = pb_istream_from_buffer(msg, msg_len);
    if (!pb_decode(&is, containerd_types_Envelope_fields,
                   &stream->current->env))
      return STRIM_CTRD_ERR_PROTO;
  }

  *out = stream->current;
  return 0;
}

/* Internal close: release the dedicated connection and unregister the stream
 * from the client's list. The caller must hold the client lock when the
 * stream still references a client (strim_containerd_close /
 * strim_event_stream_close). */
static void event_stream_close_locked(strim_event_stream *stream) {
  strim_event_stream **link;
  if (stream == NULL)
    return;
  if (!stream->closed) {
    stream->closed = 1;
    h2c_stream_close(stream->h2c_stream);
    h2c_close(stream->conn);
  }
  if (stream->current != NULL) {
    envelope_release(stream->current);
    free(stream->current);
    stream->current = NULL;
  }
  /* Unregister from the client's stream list. */
  if (stream->client != NULL) {
    for (link = &stream->client->streams; *link != NULL;
         link = &(*link)->next) {
      if (*link == stream) {
        *link = stream->next;
        break;
      }
    }
  }
  free(stream);
}

void strim_event_stream_close(strim_event_stream *stream) {
  strim_containerd_client *client;
  if (stream == NULL)
    return;
  client = stream->client;
  if (client != NULL)
    pthread_mutex_lock(&client->lock);
  event_stream_close_locked(stream);
  if (client != NULL)
    pthread_mutex_unlock(&client->lock);
}

static int type_url_has_suffix(const char *type_url, const char *suffix) {
  size_t tlen;
  size_t slen;
  if (type_url == NULL)
    return 0;
  tlen = strlen(type_url);
  slen = strlen(suffix);
  if (slen > tlen)
    return 0;
  return strcmp(type_url + tlen - slen, suffix) == 0;
}

/* Decode the envelope's Any payload as TaskStart / TaskExit (lazy, once). */
static int ensure_payload_decoded(strim_event_envelope *e) {
  int is_start;
  const uint8_t *payload;
  size_t payload_len;

  if (e->payload_ready != 0)
    return e->payload_ready;
  if (!e->env.has_event || e->env.event.value == NULL)
    return 0;
  is_start = type_url_has_suffix(e->env.event.type_url, EV_START_SUFFIX);
  if (!is_start && !type_url_has_suffix(e->env.event.type_url, EV_EXIT_SUFFIX))
    return 0; /* unknown type: STRIM_EVENT_OTHER */
  payload = e->env.event.value->bytes;
  payload_len = e->env.event.value->size;

  if (is_start) {
    pb_istream_t is = pb_istream_from_buffer(payload, payload_len);
    if (!pb_decode(&is, containerd_events_TaskStart_fields, &e->task_start))
      return 0;
    e->payload_ready = 1;
  } else {
    pb_istream_t is = pb_istream_from_buffer(payload, payload_len);
    if (!pb_decode(&is, containerd_events_TaskExit_fields, &e->task_exit))
      return 0;
    e->payload_ready = 2;
  }
  return e->payload_ready;
}

strim_event_kind strim_event_get_kind(const strim_event_envelope *envelope) {
  int ready;
  if (envelope == NULL || envelope->env.event.type_url == NULL)
    return STRIM_EVENT_OTHER;
  if (type_url_has_suffix(envelope->env.event.type_url, EV_START_SUFFIX))
    ready = ensure_payload_decoded((strim_event_envelope *)envelope);
  else if (type_url_has_suffix(envelope->env.event.type_url, EV_EXIT_SUFFIX))
    ready = ensure_payload_decoded((strim_event_envelope *)envelope);
  else
    return STRIM_EVENT_OTHER;
  if (ready == 1)
    return STRIM_EVENT_TASK_START;
  if (ready == 2)
    return STRIM_EVENT_TASK_EXIT;
  return STRIM_EVENT_OTHER; /* payload failed to unmarshal */
}

int strim_event_container_id(const strim_event_envelope *envelope, char *buf,
                             size_t cap) {
  int ready;
  const char *id = NULL;
  size_t len;

  if (envelope == NULL || buf == NULL || cap == 0)
    return STRIM_CTRD_ERR_BADARG;
  ready = ensure_payload_decoded((strim_event_envelope *)envelope);
  if (ready == 1)
    id = envelope->task_start.container_id;
  else if (ready == 2)
    id = envelope->task_exit.container_id;
  else
    return STRIM_CTRD_ERR_PROTO; /* no container id in this payload */
  if (id == NULL)
    return STRIM_CTRD_ERR_PROTO;
  len = strlen(id);
  if (len >= cap)
    return STRIM_CTRD_ERR_PROTO;
  memcpy(buf, id, len + 1);
  return (int)len;
}