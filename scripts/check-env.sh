#!/usr/bin/env bash
set -euo pipefail
ENV_FILE="${1:-core/strimserver.env}"
set -a; . "$ENV_FILE"; set +a
cd core/controller && exec  go run . -check-env   # or the built binary on the box
