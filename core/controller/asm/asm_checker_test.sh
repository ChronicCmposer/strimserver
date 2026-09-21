#!/usr/bin/env bash
#
# Phase 5 CI wrapper for the assembly playbook checkers.
#
# check-isa.sh / check-clobbers.sh take the asm module include dir via -I
# (the modules #include cc_platform.h/cc_layout.inc/cc_<module>.h; the
# preprocessing pass needs the include dir). A Bazel sh_test runs from the
# runfiles root and its args support $(location)/$(rootpath) expansion but
# NOT $(dirname ...) (verified on Bazel 9.2: "$(dirname) not defined"), so
# the include dir cannot be derived inside the BUILD file. This wrapper
# derives it from the first module's runfiles path at runtime and execs the
# (unchanged) checker with -I <dir>.
#
# The checker scripts themselves are never modified by this wiring.
#
# USAGE
#   asm_checker_test.sh <checker> <module.S> [module.S ...]
#     <checker>   runfiles path of check-isa.sh or check-clobbers.sh
#     <module.S>  runfiles path of a cc_*.S module (first one supplies the
#                 include dir; the rest are checked)
set -euo pipefail

checker="$1"
first="$2"
shift 2

incdir="$(dirname "$first")"
exec "$checker" -I "$incdir" "$first" "$@"