#!/usr/bin/env bash
# Generates com.chroniccmposer.strimserver.sdPlugin/manifest.json from
# manifest.json.tpl, injecting the StreamDeck Version field.
#
# The version is derived from the GIT_TAG environment variable (a vX.Y.Z git
# tag -- the same convention scripts/bump-version.sh enforces). Elgato's
# manifest schema requires exactly four numeric dot-separated segments with no
# v-prefix and no suffix, so:
#   - GIT_TAG empty (dev build)  -> 0.0.0.0
#   - GIT_TAG=v1.2.3             -> 1.2.3.0 (strip v, append .0)
#   - GIT_TAG=anything else      -> fail loudly (exit 1)
#
# Runs as a Bazel genrule, so both paths arrive as arguments (cwd is the
# execroot runfiles tree, never assumed). GIT_TAG reaches the action via
# --action_env=GIT_TAG (see the Makefile).
#
# Usage: gen-manifest.sh <template> <output>
set -euo pipefail

TEMPLATE="${1:?usage: gen-manifest.sh <template> <output>}"
OUTPUT="${2:?usage: gen-manifest.sh <template> <output>}"

GIT_TAG="${GIT_TAG:-}"

# Guard clauses: resolve the version up front, before touching the template.
if [[ -z "${GIT_TAG}" ]]; then
    VERSION="0.0.0.0"
elif [[ "${GIT_TAG}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.0"
else
    echo "ERROR: GIT_TAG='${GIT_TAG}' is not a valid vX.Y.Z git tag." >&2
    echo "Expected exactly ^v[0-9]+\\.[0-9]+\\.[0-9]+$ (e.g. v1.2.3)." >&2
    echo "Leave GIT_TAG unset/empty for the dev default 0.0.0.0." >&2
    exit 1
fi

# VERSION is always four dot-separated decimal segments (never contains '/'),
# so it is safe to substitute directly into the sed expression.
sed "s/__VERSION__/${VERSION}/" "${TEMPLATE}" > "${OUTPUT}"