#!/bin/sh

set -xeuo

set -a
. /strimserver.env
set +a

exec /strimserver-controller
