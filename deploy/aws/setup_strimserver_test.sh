#!/usr/bin/env bash
# Bazel sh_test wrapper: the deploy/aws suite is shell-based, so run the
# pure-stdlib setup_strimserver NVMe tests through the same sh_test shape.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$script_dir/setup_strimserver_test.py"
