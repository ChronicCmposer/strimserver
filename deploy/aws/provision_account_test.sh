#!/usr/bin/env bash
#
# provision_account_test.sh -- exercise deploy/aws/provision-account against the
# shared fake aws (testutil_fake_aws.sh). No AWS account is needed.
#
# Cases:
#   1. bootstrap: admin identity gate, stack deploy with the expected parameters,
#      exactly one access key for `strimserver`, [strimserver] credentials +
#      [profile strimserver] region, timestamped 0600 backups, unrelated
#      sections preserved, identity assertion, summary, no secret echoed.
#   2. re-run with a still-valid key is a no-op (reuse, exactly one key).
#   3. --rotate creates the new key BEFORE deleting the old one.
#   4. a failed admin identity aborts before any mutation.
#   5. no --yes + no confirmation aborts before any mutation.
#   6. an exported AWS_PROFILE does not leak into the admin gate (env -u).
#   7. the identity assertion retries a transient InvalidClientTokenId.
#   8. a persistent InvalidClientTokenId fails loud after bounded retries.
#   9. --stack-name / --region / --profile override the defaults.
#
# Usage: provision_account_test.sh <provision-account>

set -euo pipefail

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf 'ok: %s\n' "$*"; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Standalone: pass the script path. Under Bazel sh_test no argument is passed;
# the sibling provision-account is in the runfiles.
[ "$#" -le 1 ] || fail "usage: provision_account_test.sh [provision-account]"
provision="${1:-$here/provision-account}"
[ -r "$provision" ] || fail "missing provision-account: $provision"
provision="$(cd "$(dirname "$provision")" && pwd)/$(basename "$provision")"
script_dir="$(dirname "$provision")"
repo_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck source=testutil_fake_aws.sh
source "$script_dir/testutil_fake_aws.sh"

fake_aws_install
work="$(mktemp -d)"
trap 'fake_aws_cleanup; rm -rf "$work"' EXIT
mkdir -p "$work/home"

# run_provision <state> <calls> <creds> <config> [args...]
# EXTRA_ENV holds extra KEY=VALUE assignments for this invocation.
EXTRA_ENV=()
run_provision() {
  local state="$1" calls="$2" creds="$3" config="$4"; shift 4
  ( cd "$repo_root" && env -i \
      PATH="$PATH" HOME="$work/home" \
      AWS_SHARED_CREDENTIALS_FILE="$creds" \
      AWS_CONFIG_FILE="$config" \
      OPERATOR_CIDR="203.0.113.4/32" \
      S3_BUCKET_NAME="strimserver-deploy" \
      FAKE_AWS_STATE="$state" \
      FAKE_AWS_CALLS="$calls" \
      "${EXTRA_ENV[@]}" \
      bash "$provision" "$@" )
}

value_of_profile_key() { # value_of_profile_key <creds> <section>
  awk -v hdr="[$2]" '$0 == hdr { s = 1; next } /^\[/ { s = 0 }
    s && /^aws_access_key_id/ { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }' "$1"
}

# ---------------------------------------------------------------------------
# Case 1 -- bootstrap
# ---------------------------------------------------------------------------
c1="$work/c1"; mkdir -p "$c1/state" "$c1/.aws"
creds="$c1/.aws/credentials"; config="$c1/.aws/config"; calls="$c1/calls"
printf '[default]\naws_access_key_id = ADMINKEY\naws_secret_access_key = ADMINSECRET\n\n[other]\naws_access_key_id = OTHERKEY\n' >"$creds"
printf '[default]\nregion = eu-west-1\n' >"$config"

run_provision "$c1/state" "$calls" "$creds" "$config" --yes --region us-east-2 >"$c1/out" 2>&1 \
  || fail "bootstrap must succeed; output:\n$(cat "$c1/out")"

deploy_line="$(grep -m1 '^cloudformation deploy' "$calls" || true)"
[ -n "$deploy_line" ] || fail "no cloudformation deploy recorded; calls:\n$(cat "$calls")"
[[ "$deploy_line" == *"--template-file $script_dir/strimserver-infra.yaml"* ]] \
  || fail "deploy missing template: $deploy_line"
[[ "$deploy_line" == *"--stack-name strimserver"* ]] || fail "deploy missing stack name: $deploy_line"
[[ "$deploy_line" == *"--capabilities CAPABILITY_NAMED_IAM"* ]] || fail "deploy missing capabilities: $deploy_line"
[[ "$deploy_line" == *"--region us-east-2"* ]] || fail "deploy missing region: $deploy_line"
for param in CreateNetwork=true OperatorCidr=203.0.113.4/32 IngestCidr=203.0.113.4/32 \
             EnableExperimentalSsh=true DeploymentBucketName=strimserver-deploy; do
  [[ "$deploy_line" == *"$param"* ]] || fail "deploy missing parameter $param: $deploy_line"
done
ok "deploy carries the frozen template/stack/flags and env-driven parameters"

# The admin gate must run with the ambient identity, never a profile.
admin_sts="$(grep '^sts get-caller-identity ' "$calls" | grep -v -- '--profile' | head -n1 || true)"
[ -n "$admin_sts" ] || fail "admin gate did not run with the ambient identity; calls:\n$(cat "$calls")"
[[ "$admin_sts" == *"--region us-east-2"* ]] || fail "admin gate missing region: $admin_sts"
grep -q '^cloudformation deploy .*--region us-east-2' "$calls" \
  || fail "stack deploy did not run as admin"
[[ "$deploy_line" != *"--profile"* ]] || fail "stack deploy must not use --profile: $deploy_line"
ok "admin gate and stack deploy use ambient admin credentials"

create_count="$(grep -c '^iam create-access-key --user-name strimserver ' "$calls" || true)"
(( create_count == 1 )) || fail "expected exactly one create-access-key, saw $create_count"
ok "exactly one access key is minted"

grep -q '^\[strimserver\]$' "$creds" || fail "credentials missing [strimserver]"
kid="$(value_of_profile_key "$creds" strimserver)"
[ "$kid" = "AKIAFAKE0000001" ] || fail "credentials key '$kid' is not the created key"
grep -q '^aws_secret_access_key = fakesecret0000001$' "$creds" \
  || fail "credentials missing the created secret under [strimserver]"
grep -q '^\[profile strimserver\]$' "$config" || fail "config missing [profile strimserver]"
grep -q '^region = us-east-2$' "$config" || fail "config missing the region"
ok "credentials + config gain [strimserver] and its region"

ls "$creds".bak.* >/dev/null 2>&1 || fail "no timestamped credentials backup"
ls "$config".bak.* >/dev/null 2>&1 || fail "no timestamped config backup"
[ "$(stat -c '%a' "$creds")" = "600" ] || fail "credentials not 0600"
[ "$(stat -c '%a' "$config")" = "600" ] || fail "config not 0600"
creds_bak="$(ls "$creds".bak.* | head -n1)"
[ "$(stat -c '%a' "$creds_bak")" = "600" ] || fail "credentials backup not 0600"
ok "timestamped backups exist and every secret file is 0600"

grep -q 'ADMINKEY' "$creds" || fail "unrelated [default] credentials clobbered"
grep -q 'OTHERKEY' "$creds" || fail "unrelated [other] credentials clobbered"
grep -q 'region = eu-west-1' "$config" || fail "unrelated [default] config clobbered"
[ ! -e "$work/home/.aws/credentials" ] || fail "AWS_SHARED_CREDENTIALS_FILE not honored"
ok "unrelated sections preserved and env file paths honored"

grep -q '^--profile strimserver sts get-caller-identity ' "$calls" \
  || fail "identity assertion did not run for [strimserver]"
grep -q 'fakesecret0000001' "$c1/out" && fail "the access-key secret was echoed"
grep -q 'admin identity : arn:aws:iam::183438553939:user/admin' "$c1/out" \
  || fail "summary missing admin ARN:\n$(cat "$c1/out")"
grep -q 'operator user  : arn:aws:iam::183438553939:user/strimserver' "$c1/out" \
  || fail "summary missing operator ARN:\n$(cat "$c1/out")"
grep -q "profile        : strimserver ($creds)" "$c1/out" \
  || fail "summary missing profile path:\n$(cat "$c1/out")"
grep -q 'region         : us-east-2' "$c1/out" || fail "summary missing region:\n$(cat "$c1/out")"
grep -q 'stack          : strimserver' "$c1/out" || fail "summary missing stack:\n$(cat "$c1/out")"
grep -q 'next           : run deploy/aws/deploy-infra' "$c1/out" \
  || fail "summary missing the next-step hint:\n$(cat "$c1/out")"
ok "identity is asserted, the secret is not echoed, and the summary is complete"

# ---------------------------------------------------------------------------
# Case 2 -- a second run reuses the still-valid key (no-op)
# ---------------------------------------------------------------------------
c2="$work/c2"; mkdir -p "$c2/state" "$c2/.aws"
creds2="$c2/.aws/credentials"; config2="$c2/.aws/config"; calls2="$c2/calls"
run_provision "$c2/state" "$calls2" "$creds2" "$config2" --yes >/dev/null 2>&1 \
  || fail "first run must succeed"
kid_first="$(value_of_profile_key "$creds2" strimserver)"
cp "$creds2" "$c2/creds.after1"
baks_first="$(ls "$config2".bak.* 2>/dev/null | wc -l || true)"

run_provision "$c2/state" "$calls2" "$creds2" "$config2" --yes >"$c2/out" 2>&1 \
  || fail "second run must succeed; output:\n$(cat "$c2/out")"

total_create="$(grep -c '^iam create-access-key --user-name strimserver ' "$calls2" || true)"
(( total_create == 1 )) || fail "second run minted another key (total $total_create)"
kid_second="$(value_of_profile_key "$creds2" strimserver)"
[ "$kid_first" = "$kid_second" ] || fail "second run changed the profile key"
cmp -s "$c2/creds.after1" "$creds2" || fail "second run rewrote the credentials file"
baks_second="$(ls "$config2".bak.* 2>/dev/null | wc -l || true)"
[ "$baks_first" = "$baks_second" ] || fail "second run rewrote the config"
[ "$(grep -c . "$c2/state/keys-strimserver")" = "1" ] || fail "reuse did not leave exactly one key"
ok "second run reuses the key and is a no-op"

# ---------------------------------------------------------------------------
# Case 3 -- --rotate creates the new key first, then deletes the old
# ---------------------------------------------------------------------------
c3="$work/c3"; mkdir -p "$c3/state" "$c3/.aws"
creds3="$c3/.aws/credentials"; config3="$c3/.aws/config"; calls3="$c3/calls"
printf 'AKIAOLD0000000001\n' >"$c3/state/keys-strimserver"
printf '[strimserver]\naws_access_key_id = AKIAOLD0000000001\naws_secret_access_key = oldsecret\n' >"$creds3"

run_provision "$c3/state" "$calls3" "$creds3" "$config3" --yes --rotate >"$c3/out" 2>&1 \
  || fail "rotate must succeed; output:\n$(cat "$c3/out")"

create_ln="$(grep -n '^iam create-access-key --user-name strimserver ' "$calls3" | head -n1 | cut -d: -f1)"
delete_ln="$(grep -n '^iam delete-access-key --user-name strimserver ' "$calls3" | head -n1 | cut -d: -f1)"
[ -n "$create_ln" ] || fail "rotate did not create a new key"
[ -n "$delete_ln" ] || fail "rotate did not delete the old key"
(( create_ln < delete_ln )) || fail "rotate must create the new key before deleting the old one"
new_kid="$(value_of_profile_key "$creds3" strimserver)"
[ "$new_kid" != "AKIAOLD0000000001" ] || fail "rotate did not rewrite the profile key"
[ "$(cat "$c3/state/keys-strimserver")" = "$new_kid" ] || fail "surviving key is not the profile key"
grep -q 'AKIAOLD0000000001' "$c3/state/keys-strimserver" && fail "old key was not deleted"
ok "--rotate creates before deleting and leaves exactly the new key"

# ---------------------------------------------------------------------------
# Case 4 -- a failed admin identity aborts before any mutation
# ---------------------------------------------------------------------------
c4="$work/c4"; mkdir -p "$c4/state"
rc=0
EXTRA_ENV=(FAKE_AWS_ADMIN_FAIL=1)
run_provision "$c4/state" "$c4/calls" "$c4/cred" "$c4/cfg" --yes >"$c4/out" 2>&1 || rc=$?
EXTRA_ENV=()
(( rc != 0 )) || fail "a failed admin identity must exit non-zero"
grep -qi 'admin identity' "$c4/out" || fail "failed admin gate lacked a clear message:\n$(cat "$c4/out")"
if [ -f "$c4/calls" ] && grep -q '^cloudformation deploy' "$c4/calls"; then
  fail "deploy ran despite a failed admin identity"
fi
ok "failed admin identity exits non-zero and never deploys"

# ---------------------------------------------------------------------------
# Case 5 -- no confirmation aborts before any mutation
# ---------------------------------------------------------------------------
c5="$work/c5"; mkdir -p "$c5/state"
rc=0
run_provision "$c5/state" "$c5/calls" "$c5/cred" "$c5/cfg" </dev/null >"$c5/out" 2>&1 || rc=$?
(( rc != 0 )) || fail "without --yes and without confirmation the run must abort"
if [ -f "$c5/calls" ] && grep -q '^cloudformation deploy' "$c5/calls"; then
  fail "deploy ran without confirmation"
fi
ok "missing confirmation aborts before any AWS mutation"

# ---------------------------------------------------------------------------
# Case 6 -- an exported AWS_PROFILE does not leak into the admin gate
# ---------------------------------------------------------------------------
c6="$work/c6"; mkdir -p "$c6/state" "$c6/.aws"
EXTRA_ENV=(AWS_PROFILE=someone AWS_DEFAULT_PROFILE=someone)
run_provision "$c6/state" "$c6/calls" "$c6/.aws/credentials" "$c6/.aws/config" --yes >"$c6/out" 2>&1 \
  || fail "run under an exported AWS_PROFILE must succeed; output:\n$(cat "$c6/out")"
EXTRA_ENV=()
grep -q 'admin identity : arn:aws:iam::183438553939:user/admin' "$c6/out" \
  || fail "AWS_PROFILE leaked into the admin gate:\n$(cat "$c6/out")"
ok "an exported AWS_PROFILE does not leak into the admin gate"

# ---------------------------------------------------------------------------
# Case 7 -- a transient InvalidClientTokenId is retried to success
# ---------------------------------------------------------------------------
c7="$work/c7"; mkdir -p "$c7/state" "$c7/.aws"
EXTRA_ENV=(FAKE_AWS_STS_INVALID_TOKEN_FAILS=2 PROVISION_ASSERT_RETRY_DELAY=0)
rc=0
run_provision "$c7/state" "$c7/calls" "$c7/.aws/credentials" "$c7/.aws/config" --yes >"$c7/out" 2>&1 || rc=$?
EXTRA_ENV=()
(( rc == 0 )) || fail "a transient InvalidClientTokenId must be retried; output:\n$(cat "$c7/out")"
op_calls="$(grep -c '^--profile strimserver sts get-caller-identity ' "$c7/calls" || true)"
(( op_calls == 3 )) || fail "expected 3 operator sts calls (2 transient + 1 ok), saw $op_calls"
ok "the identity assertion retries a transient InvalidClientTokenId and then succeeds"

# ---------------------------------------------------------------------------
# Case 8 -- a persistent InvalidClientTokenId fails loud after bounded retries
# ---------------------------------------------------------------------------
c8="$work/c8"; mkdir -p "$c8/state" "$c8/.aws"
EXTRA_ENV=(FAKE_AWS_STS_INVALID_TOKEN_FAILS=100 PROVISION_ASSERT_RETRY_DELAY=0)
rc=0
run_provision "$c8/state" "$c8/calls" "$c8/.aws/credentials" "$c8/.aws/config" --yes >"$c8/out" 2>&1 || rc=$?
EXTRA_ENV=()
(( rc != 0 )) || fail "a persistent InvalidClientTokenId must exit non-zero"
op_calls="$(grep -c '^--profile strimserver sts get-caller-identity ' "$c8/calls" || true)"
(( op_calls > 1 )) || fail "a persistent transient error was not retried (calls=$op_calls)"
(( op_calls <= 10 )) || fail "transient retries are not bounded (calls=$op_calls)"
grep -qi 'eventual consistency' "$c8/out" \
  || fail "persistent transient error lacked an eventual-consistency message:\n$(cat "$c8/out")"
ok "a persistent transient error is retried a bounded number of times then fails loud"

# ---------------------------------------------------------------------------
# Case 9 -- --stack-name / --region / --profile override the defaults
# ---------------------------------------------------------------------------
c9="$work/c9"; mkdir -p "$c9/state" "$c9/.aws"
run_provision "$c9/state" "$c9/calls" "$c9/.aws/credentials" "$c9/.aws/config" \
  --yes --stack-name strim-staging --region eu-west-1 --profile ops >"$c9/out" 2>&1 \
  || fail "flag overrides must succeed; output:\n$(cat "$c9/out")"
deploy9="$(grep -m1 '^cloudformation deploy' "$c9/calls" || true)"
[[ "$deploy9" == *"--stack-name strim-staging"* ]] || fail "--stack-name not honored: $deploy9"
[[ "$deploy9" == *"--region eu-west-1"* ]] || fail "--region not honored: $deploy9"
grep -q '^\[profile ops\]$' "$c9/.aws/config" || fail "--profile not used for the config section"
grep -q '^\[ops\]$' "$c9/.aws/credentials" || fail "--profile not used for the credentials section"
ok "--stack-name / --region / --profile override the defaults"

printf 'PASS: provision_account_test\n'
