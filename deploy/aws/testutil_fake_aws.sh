#!/usr/bin/env bash
# testutil_fake_aws.sh -- sourceable fake `aws` for offline tests.
#
# fake_aws_install puts a stub `aws` first on PATH and points the recorder at a
# temp file; the stub answers the handful of calls deploy/aws tooling makes and
# records every invocation (one per line) to $FAKE_AWS_CALLS.
#
# Response knobs (read at call time, so tests may change them mid-run):
#   FAKE_AWS_STRIM_ARN    ARN for `--profile strimserver` sts calls
#                         (default arn:aws:iam::183438553939:user/strimserver)
#   FAKE_AWS_DEFAULT_ARN  ARN for sts calls with no/other profile
#                         (default arn:aws:iam::183438553939:user/admin)
#   FAKE_AWS_STS_FAIL     when 1, every sts call fails (rc 255)
#   FAKE_AWS_EXISTING_KEYS  tab/space-separated key ids for iam list-access-keys
#   FAKE_AWS_ACCESS_KEY_ID / FAKE_AWS_SECRET_ACCESS_KEY  create-access-key output
#
# Not intended to be executed directly.

fake_aws_install() {
  FAKE_AWS_BINDIR="$(mktemp -d)"
  FAKE_AWS_CALLS="$(mktemp)"
  export FAKE_AWS_BINDIR FAKE_AWS_CALLS

  cat >"$FAKE_AWS_BINDIR/aws" <<'FAKE_AWS_EOF'
#!/usr/bin/env bash
# Stub aws: record argv, then answer the calls the strimserver tooling makes.
printf '%s\n' "$*" >>"${FAKE_AWS_CALLS:-/dev/null}"
args="$*"

profile_is_strim=0
[[ "$args" == *"--profile strimserver"* ]] && profile_is_strim=1

case "$args" in
  *"sts get-caller-identity"*)
    [[ "${FAKE_AWS_STS_FAIL:-}" == "1" ]] && exit 255
    if [[ "$profile_is_strim" == "1" ]]; then
      arn="${FAKE_AWS_STRIM_ARN:-arn:aws:iam::183438553939:user/strimserver}"
    else
      arn="${FAKE_AWS_DEFAULT_ARN:-arn:aws:iam::183438553939:user/admin}"
    fi
    case "$args" in
      *"--query Account"*) printf '183438553939\n' ;;
      *"--query Arn"*)     printf '%s\n' "$arn" ;;
      *)                   printf '{"UserId":"AIDAFake","Account":"183438553939","Arn":"%s"}\n' "$arn" ;;
    esac
    ;;
  *"iam list-access-keys"*)
    printf '%s' "${FAKE_AWS_EXISTING_KEYS:-}"
    ;;
  *"iam create-access-key"*)
    printf '%s\t%s\n' \
      "${FAKE_AWS_ACCESS_KEY_ID:-AKIAFAKEFAKEFAKEFAKE}" \
      "${FAKE_AWS_SECRET_ACCESS_KEY:-wJalrFAKEsecretFAKEsecretFAKEsecretFAKEkey}"
    ;;
esac

exit "${FAKE_AWS_RC:-0}"
FAKE_AWS_EOF

  chmod +x "$FAKE_AWS_BINDIR/aws"
  PATH="$FAKE_AWS_BINDIR:$PATH"
  export PATH
}

# Print the recorded calls (one per line).
fake_aws_calls() {
  cat "${FAKE_AWS_CALLS:?fake_aws_install must run first}"
}

# Remove the fake bin + recorder.
fake_aws_cleanup() {
  [[ -n "${FAKE_AWS_BINDIR:-}" ]] && rm -rf "$FAKE_AWS_BINDIR"
  [[ -n "${FAKE_AWS_CALLS:-}" ]] && rm -f "$FAKE_AWS_CALLS"
}
