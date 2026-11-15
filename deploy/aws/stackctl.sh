#!/usr/bin/env bash
# Thin wrapper: always run the pinned stackctl binary against deploy/aws.
set -euo pipefail

: "${STACKCTL_BIN:?run this target through bazel run}"

if [ -n "${RUNFILES_DIR:-}" ]; then
   runfiles="$RUNFILES_DIR"
elif [ -d "$0.runfiles" ]; then
   # `bazel run` does not always export RUNFILES_DIR; the launcher script's
   # sibling .runfiles tree is the same view.
   runfiles="$0.runfiles"
else
   printf 'stackctl: cannot locate runfiles; run this target through bazel run\n' >&2
   exit 1
fi

# stackctl resolves its VERSION runfile from RUNFILES_DIR; export the tree we
# just located so `--version` reports the pinned tag, not "unknown".
export RUNFILES_DIR="$runfiles"
exec "$runfiles/$STACKCTL_BIN" --project deploy/aws "$@"
