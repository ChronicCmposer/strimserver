#!/usr/bin/env bash
# deploy/aws/lib/aws_profile.sh -- the shared operator-profile contract.
#
# SOURCED (never executed) by the strimserver tooling scripts that call AWS. It
# owns exactly two things so no call site re-implements them:
#
#   aws_strim <args...>            run the aws CLI pinned to the project-scoped
#                                  operator profile. Every AWS call a caller
#                                  makes must go through it, so a stray ambient
#                                  admin credential can never act as, or be
#                                  mistaken for, this account.
#   require_strimserver_identity   return 0 iff that profile authenticates as
#                                  arn:...:user/strimserver; otherwise print a
#                                  descriptive error and return 1 (it never
#                                  exits, so each caller picks its own failure
#                                  policy, e.g. `require... || exit 1`).
#
# Sourcing exports AWS_PROFILE (default strimserver) as a deliberate, documented
# side effect: a bare `aws` call in the caller's shell then resolves to the same
# operator account instead of the ambient default. deploy/aws/deploy-infra does
# NOT source this file: it runs as the ADMIN identity that creates the operator
# account, so it must keep using the ambient credentials.
#
# Contract: callers run under `set -euo pipefail` themselves; this file sets no
# shell options and never calls exit.

AWS_PROFILE="${AWS_PROFILE:-strimserver}"
export AWS_PROFILE

# aws_strim: the single place that knows the profile flag, so a call site can
# never forget it.
aws_strim() { command aws --profile "${AWS_PROFILE:-strimserver}" "$@"; }

# require_strimserver_identity: gate every operator action on the pinned profile
# being the strimserver service account.
require_strimserver_identity() {
  local arn
  arn="$(aws_strim sts get-caller-identity --query Arn --output text 2>/dev/null)" || arn=""
  case "$arn" in
    *:user/strimserver) return 0 ;;
  esac
  printf 'error: AWS profile '\''%s'\'' authenticated as '\''%s'\'', expected ...:user/strimserver.\n' \
    "${AWS_PROFILE:-strimserver}" "${arn:-<none>}" >&2
  printf '       Run deploy/aws/deploy-infra (with admin credentials), then retry.\n' >&2
  return 1
}
