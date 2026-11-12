#!/bin/sh
# Controller container entrypoint. The env file holds secrets (the Twitch
# stream key), so xtrace stays off and the umask is tightened before sourcing.
set +x
set -eu
umask 027

ENV_FILE="${STRIMSERVER_ENV_FILE:-/strimserver.env}"
CONTROLLER="${STRIMSERVER_CONTROLLER:-/strimserver-controller}"

set -a
. "$ENV_FILE"
set +a

printf 'entrypoint: starting controller\n'
exec "$CONTROLLER"
