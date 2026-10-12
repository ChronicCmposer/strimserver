#!/usr/bin/env bash
# deploy_infra_test.sh -- drive deploy/aws/deploy-infra against the fake aws.
#
# Asserts decision 11b behaviour: the script keeps the stack deploy admin-run
# but writes the service-account key to a `[strimserver]` profile (NOT
# `[default]`), takes a timestamped backup of the credentials file, writes the
# profile's region into ~/.aws/config, ROTATES create-before-delete (a failed
# create must leave the old key intact), and asserts the minted identity via
# `aws sts get-caller-identity` showing `:user/strimserver`.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
deploy_infra="$script_dir/deploy-infra"
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

home="$(mktemp -d)"
mkdir -p "$home/.aws"
creds="$home/.aws/credentials"
config="$home/.aws/config"
printf '[default]\naws_access_key_id = OLDADMINKEY\naws_secret_access_key = OLDADMINSECRET\n\n[other]\naws_access_key_id = OTHERKEY\naws_secret_access_key = OTHERSECRET\n' >"$creds"
printf '[default]\nregion = eu-west-1\n' >"$config"

# Two pre-existing service-account keys, so the run must rotate them.
export FAKE_AWS_EXISTING_KEYS="OLDKEY1 OLDKEY2"

# run_deploy [home] [creds]: drive deploy-infra against the fake aws. Defaults to
# the primary fixture (used by the happy-path and identity-assertion cases); the
# CRLF fixture passes its own home/creds so the two runs never share state.
run_deploy() {
  local run_home="${1:-$home}" run_creds="${2:-$creds}"
  ( cd "$repo_root" && env -i \
      PATH="$PATH" HOME="$run_home" \
      AWS_SHARED_CREDENTIALS_FILE="$run_creds" \
      OPERATOR_CIDR="203.0.113.4/32" S3_BUCKET_NAME="" \
      FAKE_AWS_CALLS="$FAKE_AWS_CALLS" \
      FAKE_AWS_BINDIR="$FAKE_AWS_BINDIR" \
      FAKE_AWS_EXISTING_KEYS="$FAKE_AWS_EXISTING_KEYS" \
      ${FAKE_AWS_STRIM_ARN:+FAKE_AWS_STRIM_ARN="$FAKE_AWS_STRIM_ARN"} \
      bash "$deploy_infra" 2>&1 )
}

# --- happy path ---------------------------------------------------------------
output="$(run_deploy)"
rc=$?

check "deploy-infra exits 0" test "$rc" -eq 0
check "writes a [strimserver] profile" grep -Fq '[strimserver]' "$creds"
check "writes the new access key id under [strimserver]" grep -Fq 'aws_access_key_id = AKIAFAKEFAKEFAKEFAKE' "$creds"
check "writes the new secret under [strimserver]" grep -Fq 'aws_secret_access_key = wJalrFAKEsecret' "$creds"
check "preserves the pre-existing [default] profile" grep -Fq 'OLDADMINKEY' "$creds"
check "preserves an unrelated [other] profile" grep -Fq 'OTHERKEY' "$creds"
check "new key is NOT written under [default]" bash -c '! awk "/^\[default\]/{p=1;next} /^\[/{p=0} p" "$1" | grep -Fq AKIAFAKEFAKEFAKEFAKE' _ "$creds"
check "stdout/stderr advertise [strimserver], not [default]" bash -c 'grep -Fq "[strimserver]" <<<"$1" && ! grep -Fq "[default]" <<<"$1"' _ "$output"
check "takes a timestamped credentials backup" bash -c 'ls "$1"/credentials.bak.* >/dev/null 2>&1' _ "$home/.aws"
check "asserts identity via sts get-caller-identity --profile strimserver" \
  bash -c 'grep -Fq -- "sts get-caller-identity" "$1" && grep -Fq -- "--profile strimserver" "$1"' _ "$FAKE_AWS_CALLS"
check "rotates the service-account key (iam create-access-key)" grep -Fq 'iam create-access-key' "$FAKE_AWS_CALLS"

# --- m4: the profile's region is written to ~/.aws/config ---------------------
check "writes [profile strimserver] to ~/.aws/config" grep -Fq '[profile strimserver]' "$config"
check "writes region = us-east-2 to ~/.aws/config" grep -Fq 'region = us-east-2' "$config"
check "preserves the pre-existing [default] config section verbatim" grep -Fq 'region = eu-west-1' "$config"
check "takes a timestamped config backup" bash -c 'ls "$1"/config.bak.* >/dev/null 2>&1' _ "$home/.aws"

# --- m2: create-before-delete rotation ---------------------------------------
check "deletes the first superseded key (OLDKEY1)" grep -Fq -- '--access-key-id OLDKEY1' "$FAKE_AWS_CALLS"
check "deletes the second superseded key (OLDKEY2)" grep -Fq -- '--access-key-id OLDKEY2' "$FAKE_AWS_CALLS"
check "never deletes the freshly minted key" \
  bash -c '! grep -Fq -- "--access-key-id AKIAFAKEFAKEFAKEFAKE" "$1"' _ "$FAKE_AWS_CALLS"
create_line="$(grep -n 'iam create-access-key' "$FAKE_AWS_CALLS" | head -n1 | cut -d: -f1)"
delete_line="$(grep -n 'iam delete-access-key' "$FAKE_AWS_CALLS" | head -n1 | cut -d: -f1)"
check "creates the new key BEFORE deleting the old (create-before-delete)" \
  bash -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]' _ "${create_line:-}" "${delete_line:-}"

# --- m3: a failed create must leave the old key(s) intact ---------------------
# Intercept only `iam create-access-key` (return non-zero) and delegate every
# other call to the shared fake, so the failure is isolated to key creation.
fail_bindir="$(mktemp -d)"
cat >"$fail_bindir/aws" <<'WRAP_EOF'
#!/usr/bin/env bash
case "$*" in
  *"iam create-access-key"*)
    printf '%s\n' "$*" >>"${FAKE_AWS_CALLS:-/dev/null}"
    exit 1 ;;
  *) exec "$FAKE_AWS_BINDIR/aws" "$@" ;;
esac
WRAP_EOF
chmod +x "$fail_bindir/aws"

creds_before="$(cat "$creds")"
: >"$FAKE_AWS_CALLS"
PATH="$fail_bindir:$PATH" run_deploy >/dev/null 2>&1
rc=$?
check "fails loud when create-access-key fails" test "$rc" -ne 0
check "attempted the create that then failed" grep -Fq 'iam create-access-key' "$FAKE_AWS_CALLS"
check "does NOT delete any key when create failed" \
  bash -c '! grep -Fq "iam delete-access-key" "$1"' _ "$FAKE_AWS_CALLS"
check "leaves the previous [strimserver] credentials intact" test "$(cat "$creds")" = "$creds_before"
rm -rf "$fail_bindir"

# --- M1: a CRLF/padded [strimserver] header is replaced, not duplicated -------
home_crlf="$(mktemp -d)"
mkdir -p "$home_crlf/.aws"
creds_crlf="$home_crlf/.aws/credentials"
config_crlf="$home_crlf/.aws/config"
# A Windows/WSL-style CRLF file whose [strimserver] header also carries trailing
# spaces: both must be normalized before the header comparison, or the run
# appends a second [strimserver] section instead of replacing the stale one.
printf '[default]\r\naws_access_key_id = OLDADMINKEY\r\n\r\n[strimserver]  \r\naws_access_key_id = STALEKEY\r\naws_secret_access_key = STALESECRET\r\n\r\n[other]\r\naws_access_key_id = OTHERKEY\r\n' >"$creds_crlf"
printf '[default]\r\nregion = eu-west-1\r\n' >"$config_crlf"

run_deploy "$home_crlf" "$creds_crlf" >/dev/null 2>&1
rc=$?
strim_sections="$(awk '
  /^\[/ { l = $0; sub(/\r+$/, "", l); sub(/[[:space:]]+$/, "", l); if (l == "[strimserver]") n++ }
  END { print n + 0 }
' "$creds_crlf")"
check "CRLF fixture run exits 0" test "$rc" -eq 0
check "CRLF: exactly one [strimserver] section survives" test "$strim_sections" = 1
check "CRLF: the stale key is gone" bash -c '! grep -Fq STALEKEY "$1"' _ "$creds_crlf"
check "CRLF: the new key is written" grep -Fq 'AKIAFAKEFAKEFAKEFAKE' "$creds_crlf"
check "CRLF: unrelated [other] profile preserved" grep -Fq 'OTHERKEY' "$creds_crlf"

# --- identity assertion rejects a wrong identity ------------------------------
FAKE_AWS_STRIM_ARN="arn:aws:iam::999999999999:user/not-strimserver"
export FAKE_AWS_STRIM_ARN
run_deploy >/dev/null 2>&1
rc=$?
check "fails loud when the minted identity is not :user/strimserver" test "$rc" -ne 0

if [[ "$failures" -eq 0 ]]; then
  echo "PASS: deploy-infra operator-profile behaviour OK"
  exit 0
fi
echo "FAILED: $failures assertion(s)" >&2
exit 1
