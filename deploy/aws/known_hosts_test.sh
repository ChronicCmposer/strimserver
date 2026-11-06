#!/usr/bin/env bash
# Bazel sh_test wrapper: the deploy/aws test suite is shell-based, so run the
# pure-stdlib Python known_hosts tests through the same sh_test target shape.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$script_dir/known_hosts_test.py"
