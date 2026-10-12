#!/usr/bin/env bash
# aws_profile_test.sh -- decision 11b: every AWS-invoking strimserver tooling
# script pins the project-scoped `[strimserver]` profile (`--profile
# "${AWS_PROFILE:-strimserver}"`) and refuses to run as any other identity
# (ARN must end `:user/strimserver`).
#
# Static assertions cover the whole inventory; a behavioural check drives the
# two smallest publish scripts end-to-end against the fake aws.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
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

# Bash tooling that talks to AWS on the operator machine.
bash_scripts=(
  scripts/publish_all.sh
  scripts/publish_strimserver.sh
  scripts/upload-artifact.sh
  scripts/bucket-cidr-policy.sh
  tools/ffmpeg-dist/check-deps.sh
  tools/ffmpeg-dist/publish.sh
  tools/openssh/check-deps.sh
  tools/openssh/publish.sh
  tools/brb-screen/publish.sh
  tools/bandwidth-test/publish_iperf3.sh
  tools/streamdeck-plugin/publish_streamdeck.sh
)
python_scripts=(
  deploy/aws/launch
  deploy/aws/terminate
)
lib="$repo_root/deploy/aws/lib/aws_profile.sh"

# --- static guard: no bare `aws` invocation outside the shared wrapper --------
# A script that calls the AWS CLI directly (`aws s3 cp ...`) bypasses the
# profile pin + identity guard in lib/aws_profile.sh. Flag any command-word
# `aws` followed by a service subcommand. `aws_strim`, `deploy/aws/...` paths
# and the `command -v aws` probe do not match; comment / echo / printf lines
# are ignored because their prose (e.g. "run aws configure") is not a call.
bare_aws_re='(^|[^A-Za-z0-9_./-])aws[[:space:]]+(s3|s3api|sts|ec2|cloudformation|ssm|iam)([[:space:]]|$)'

has_no_bare_aws_invocation() {
  local f="$1" hits
  hits="$(grep -nE "$bare_aws_re" "$f" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*(#|echo([[:space:]]|$)|printf([[:space:]]|$))' || true)"
  [[ -z "$hits" ]]
}

detects_bare_aws() { ! has_no_bare_aws_invocation "$1"; }

# Negative/positive controls so the guard above can never pass vacuously.
tmp_stray="$(mktemp)"
printf 'aws s3 cp built.tar s3://bucket/\nacct="$(aws sts get-caller-identity)"\n' >"$tmp_stray"
check "guard detects synthetic bare aws calls (plain + command substitution)" \
  detects_bare_aws "$tmp_stray"
rm -f "$tmp_stray"
tmp_prose="$(mktemp)"
printf '# aws s3 cp is only mentioned here\necho "run aws sts get-caller-identity"\ncommand -v aws >/dev/null\n' >"$tmp_prose"
check "guard ignores comment / echo / probe mentions of aws" \
  has_no_bare_aws_invocation "$tmp_prose"
rm -f "$tmp_prose"

# The profile pin + identity guard live in ONE sourced library (m5); assert the
# library owns them and every bash script just sources it and calls aws_strim.
check "shared aws-profile lib exists" test -f "$lib"
check "shared lib pins AWS_PROFILE (default strimserver)" \
  bash -c 'grep -Fq "AWS_PROFILE:-strimserver" "$1"' _ "$lib"
check "shared lib pins --profile \"\${AWS_PROFILE:-strimserver}\"" \
  bash -c 'grep -Fq -- "--profile \"\${AWS_PROFILE:-strimserver}\"" "$1"' _ "$lib"
check "shared lib has the :user/strimserver identity guard" \
  bash -c 'grep -Fq ":user/strimserver" "$1"' _ "$lib"

for rel in "${bash_scripts[@]}"; do
  f="$repo_root/$rel"
  check "$rel sources the shared aws-profile lib" \
    bash -c 'grep -Fq "deploy/aws/lib/aws_profile.sh" "$1"' _ "$f"
  check "$rel uses the shared lib API (aws_strim / require_strimserver_identity)" \
    bash -c 'grep -Fq "aws_strim" "$1" || grep -Fq "require_strimserver_identity" "$1"' _ "$f"
  check "$rel does not re-define require_strimserver_identity" \
    bash -c '! grep -Fq "require_strimserver_identity()" "$1"' _ "$f"
  check "$rel has no bare 'aws' invocation (every call via aws_strim)" \
    has_no_bare_aws_invocation "$f"
done

for rel in "${python_scripts[@]}"; do
  f="$repo_root/$rel"
  check "$rel pins the strimserver profile" \
    bash -c 'grep -Fq "\"strimserver\"" "$1" && grep -Fq -- "--profile" "$1"' _ "$f"
  check "$rel has the :user/strimserver identity guard" \
    bash -c 'grep -Fq ":user/strimserver" "$1"' _ "$f"
done

# --- behavioural: guard accepts the operator identity, rejects others ---------
fake_aws_install
trap fake_aws_cleanup EXIT
tmp="$(mktemp -d)"
printf 'x' >"$tmp/a"
printf 'y' >"$tmp/b"

run_streamdeck() {
  ( cd "$repo_root" && env -i PATH="$PATH" HOME="$tmp" \
      S3_BUCKET="s3://example-bucket" \
      FAKE_AWS_CALLS="$FAKE_AWS_CALLS" \
      ${FAKE_AWS_STRIM_ARN:+FAKE_AWS_STRIM_ARN="$FAKE_AWS_STRIM_ARN"} \
      bash tools/streamdeck-plugin/publish_streamdeck.sh "$tmp/a" "$tmp/b" >/dev/null 2>&1 )
}

FAKE_AWS_STRIM_ARN="arn:aws:iam::183438553939:user/strimserver"
export FAKE_AWS_STRIM_ARN
run_streamdeck
rc=$?
check "publish_streamdeck.sh succeeds as :user/strimserver" test "$rc" -eq 0
check "its s3 cp calls carry --profile strimserver" \
  bash -c 'grep -Eq -- "--profile strimserver s3 cp" "$1"' _ "$FAKE_AWS_CALLS"

: >"$FAKE_AWS_CALLS"
FAKE_AWS_STRIM_ARN="arn:aws:iam::183438553939:user/someone-else"
export FAKE_AWS_STRIM_ARN
run_streamdeck
rc=$?
check "publish_streamdeck.sh rejects a non-strimserver identity" test "$rc" -ne 0
check "no s3 cp runs when the identity check fails" \
  bash -c '! grep -Fq "s3 cp" "$1"' _ "$FAKE_AWS_CALLS"

if [[ "$failures" -eq 0 ]]; then
  echo "PASS: operator-profile tooling pinning OK"
  exit 0
fi
echo "FAILED: $failures assertion(s)" >&2
exit 1
