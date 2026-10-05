#!/usr/bin/env bash
# Runs the pure version-helper unit tests under Node's built-in test runner.
# The node binary is supplied as $1 by the sh_test (selected for the host arch;
# see the host_node filegroup in BUILD.bazel) and the test file as $2.
set -euo pipefail

NODE="${1:?usage: version_test.sh <node> <test-file>}"
TEST_FILE="${2:?usage: version_test.sh <node> <test-file>}"

exec "${NODE}" --test "${TEST_FILE}"
