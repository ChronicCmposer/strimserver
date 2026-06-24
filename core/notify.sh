#!/bin/sh
# =============================================================================
# notify.sh <path> <status>
#
# POSTs a controller-compatible PathEvent to the local controller /event
# endpoint. Intended to be called from mediamtx runOnReady/runOnNotReady hooks
# inside the FROM scratch image, where /bin/sh and wget are busybox applets.
#
#   path   -- ingress0 | normalized
#   status -- ready | not-ready | unknown
#
# The controller validates these server-side; an invalid path/status or a bad
# body comes back as a non-2xx, which wget turns into a non-zero exit here.
# =============================================================================

set -eu

# NB: not PATH/STATUS -- PATH is the executable search path; clobbering it would
# break every later command (including wget).
path_name="${1:?usage: notify.sh <path> <status>}"
path_status="${2:?usage: notify.sh <path> <status>}"

# Auto-export everything sourced so CONTROLLER_HTTP_PORT lands in the env.
set -a
. /strimserver.env
set +a

: "${CONTROLLER_HTTP_PORT:?CONTROLLER_HTTP_PORT is required (set it in /strimserver.env)}"

# PathEvent shape the controller decodes: {"path": "...", "status": "..."}
body="{\"path\":\"${path_name}\",\"status\":\"${path_status}\"}"

# busybox wget: -q quiet, -O- discard body to stdout (the controller replies 204
# No Content on success). The controller listens on loopback; mediamtx shares the
# host network namespace, so 127.0.0.1 reaches it.
wget -q -O- \
   --header='Content-Type: application/json' \
   --post-data="${body}" \
   "http://127.0.0.1:${CONTROLLER_HTTP_PORT}/event"

