#!/usr/bin/env bash
# launch_ssm_test.sh -- launch resolves the baked-AMI SSM parameter first.
#
# The CloudFormation Image Builder pipeline publishes its AMI id to
# /strimserver/ami/baked/latest. Behavioural checks drive deploy/aws/launch
# end-to-end against the fake aws and assert:
#   1. a value at that parameter becomes the run-instances --image-id;
#   2. a missing parameter falls back to the pinned DLAMI ami-0198b63ccfac121e8
#      AND warns loudly (stderr) that deploy will fail-fast on the driver floor
#      until the pipeline produces an AMI;
#   3. an explicit AMI_ID override still wins (existing precedence preserved).
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
launch="$script_dir/launch"
pinned_ami="ami-0198b63ccfac121e8"
baked_param="/strimserver/ami/baked/latest"
# shellcheck source=testutil_fake_aws.sh
source "$script_dir/testutil_fake_aws.sh"

failures=0
check() {
  local desc="$1"
  shift
  if "$@"; then
    printf 'ok: %s\n' "$desc"
  else
    printf 'FAIL: %s\n' "$desc" >&2
    failures=$((failures + 1))
  fi
}

fake_aws_install
trap fake_aws_cleanup EXIT

tmp="$(mktemp -d)"

# run_launch [AMI_ID]: drive deploy/aws/launch (no --wait) against the fake aws.
# Stdout is returned; stderr is captured to $tmp/stderr. All infra inputs are
# supplied via env so the script never needs cloudformation/describe lookups.
run_launch() {
  local ami_override="${1:-}"
  ( cd "$repo_root" && env -i \
      PATH="$PATH" HOME="$tmp" \
      KEY_NAME=test-key INSTANCE_TYPE=g4dn.xlarge \
      SECURITY_GROUP_ID=sg-test IAM_INSTANCE_PROFILE=test-profile \
      SUBNET_ID=subnet-test \
      AMI_ID="$ami_override" \
      FAKE_AWS_CALLS="$FAKE_AWS_CALLS" \
      FAKE_AWS_SSM_BAKED_AMI="${FAKE_AWS_SSM_BAKED_AMI:-}" \
      ${FAKE_AWS_STRIM_ARN:+FAKE_AWS_STRIM_ARN="$FAKE_AWS_STRIM_ARN"} \
      python3 "$launch" 2>"$tmp/stderr" )
}

# --- case 1: baked-AMI SSM parameter present -> used as the instance AMI -----
: >"$FAKE_AWS_CALLS"
FAKE_AWS_SSM_BAKED_AMI="ami-0bakedbakedbaked1"
export FAKE_AWS_SSM_BAKED_AMI
run_launch >/dev/null
rc=$?
check "present param: launch exits 0" test "$rc" -eq 0
check "present param: launch reads the baked-AMI SSM parameter" \
  bash -c 'grep -Fq -- "ssm get-parameter" "$1" && grep -Fq -- "--name '"$baked_param"'" "$1"' _ "$FAKE_AWS_CALLS"
check "present param: run-instances uses the baked AMI id" \
  bash -c 'grep -Fq -- "--image-id ami-0bakedbakedbaked1" "$1"' _ "$FAKE_AWS_CALLS"
check "present param: does NOT fall back to the pinned DLAMI" \
  bash -c '! grep -Fq -- "--image-id '"$pinned_ami"'" "$1"' _ "$FAKE_AWS_CALLS"

# --- case 2: parameter missing -> pinned fallback + loud stderr warning ------
: >"$FAKE_AWS_CALLS"
FAKE_AWS_SSM_BAKED_AMI=""
export FAKE_AWS_SSM_BAKED_AMI
run_launch >/dev/null
rc=$?
check "missing param: launch still exits 0 (graceful fallback)" test "$rc" -eq 0
check "missing param: run-instances falls back to the pinned DLAMI" \
  bash -c 'grep -Fq -- "--image-id '"$pinned_ami"'" "$1"' _ "$FAKE_AWS_CALLS"
check "missing param: warning names the Image Builder pipeline" \
  grep -Fq 'Image Builder pipeline' "$tmp/stderr"
check "missing param: warning names the SSM parameter path" \
  grep -Fq "$baked_param" "$tmp/stderr"
check "missing param: warning says deploy will fail-fast on the driver floor" \
  bash -c 'grep -Fqi "fail-fast" "$1" && grep -Fqi "driver floor" "$1"' _ "$tmp/stderr"
check "missing param: warning says it lasts until the pipeline produces an AMI" \
  grep -Fqi 'until the pipeline produces an ami' "$tmp/stderr"

# --- case 3: explicit AMI_ID override beats the baked-AMI parameter ----------
: >"$FAKE_AWS_CALLS"
FAKE_AWS_SSM_BAKED_AMI="ami-0bakedbakedbaked1"
export FAKE_AWS_SSM_BAKED_AMI
run_launch "ami-0explicitexplicit1" >/dev/null
rc=$?
check "explicit AMI_ID: launch exits 0" test "$rc" -eq 0
check "explicit AMI_ID: run-instances uses the override, not the baked AMI" \
  bash -c 'grep -Fq -- "--image-id ami-0explicitexplicit1" "$1" && ! grep -Fq -- "--image-id ami-0bakedbakedbaked1" "$1"' _ "$FAKE_AWS_CALLS"
check "explicit AMI_ID: baked-AMI SSM is never read" \
  bash -c '! grep -Fq -- "ssm get-parameter" "$1"' _ "$FAKE_AWS_CALLS"

rm -rf "$tmp"

if [[ "$failures" -eq 0 ]]; then
  echo "PASS: launch resolves the baked AMI SSM parameter first"
  exit 0
fi
echo "FAILED: $failures assertion(s)" >&2
exit 1
