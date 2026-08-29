#!/bin/sh

set -xeu

set -a
. /strimserver.env
set +a

exec /strimserver-controller
