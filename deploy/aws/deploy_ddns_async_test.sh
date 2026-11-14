#!/usr/bin/env bash
# deploy_ddns_async_test.sh -- deploy.sh must not block on DDNS verification.
#
# With ENABLE_DDNS=true the old deploy looped 24x with a 5s sleep between
# attempts, adding up to two minutes to every deploy. The fast path keeps the
# image import and the one-shot refresh, then arms a strim-ddns-verify.service
# generated from deploy/aws/strim-ddns-verify.service.template. The retry loop
# lives INSIDE that oneshot unit; deploy.sh itself never sleeps or runs
# `ctr ... check`.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deploy_sh="$script_dir/deploy.sh"
template="$script_dir/strim-ddns-verify.service.template"
# shellcheck source=testutil_fake_gpu.sh
source "$script_dir/testutil_fake_gpu.sh"

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
has_call() { grep -Eq "$1" "${FAKE_GPU_CALLS:?}"; }
not_called() { ! grep -Eq "$1" "${FAKE_GPU_CALLS:?}"; }

case_tmp="$(mktemp -d)"
case_out="$case_tmp/deploy.out"
case_path="$PATH"
export FAKE_ARCH=x86_64 FAKE_PROC_VERSION=620.70.06 FAKE_REPORTED_DRIVER=620.70.06
export FAKE_PUBLIC_IP=203.0.113.10
fake_gpu_install
fake_deploy_install
fake_deploy_seed_baseline

# Enable DDNS and provide the password the deploy installs.
printf 'ENABLE_DDNS=true\nDDNS_HOST=strim\nDDNS_DOMAIN=example.com\n' \
  >"$FAKE_DEPLOY_ROOT/config/strimserver.env"
printf 'ddns-secret\n' >"$FAKE_DEPLOY_ROOT/ddns-password"

rc=0
( cd "$FAKE_DEPLOY_ROOT" && bash "$deploy_sh" ) >"$case_out" 2>&1 || rc=$?

check "ddns async: deploy.sh exits 0" test "$rc" -eq 0
check "ddns async: no blocking sleeps in deploy.sh" \
  test ! -s "$FAKE_DEPLOY_SLEEP_LOG"
check "ddns async: deploy.sh never runs ctr ... check itself" \
  not_called '/strim-ddns check'
check "ddns async: prints status guidance" \
  grep -q 'systemctl status strim-ddns-verify' "$case_out"
check "ddns async: imports the strim-ddns image" \
  has_call ' i import strim-ddns-container.tar'
check "ddns async: performs the one-shot refresh" \
  has_call 'systemctl start strim-ddns.service'
check "ddns async: arms the verify unit" \
  has_call 'systemctl enable strim-ddns-verify.service'
check "ddns async: installs the verify unit" \
  grep -q 'strim-ddns-verify.service' "$FAKE_GPU_CALLS"

unit="$FAKE_SYSROOT/etc/systemd/system/strim-ddns-verify.service"
check "ddns async: derived verify unit exists" test -f "$unit"
check "ddns async: unit runs the existing check subcommand" \
  grep -q '/strim-ddns check' "$unit"
check "ddns async: unit owns the bounded retry loop" \
  grep -qE 'for attempt in .*seq 1 24|sleep 5' "$unit"
check "ddns async: unit bakes the expected public IP" \
  grep -q '203.0.113.10' "$unit"
check "ddns async: template contains the retry loop" \
  bash -c 'grep -qE "for attempt in .*seq 1 24|sleep 5" "$1"' _ "$template"
check "ddns async: template uses __EXPECTED_IP__ placeholder" \
  bash -c 'grep -q "__EXPECTED_IP__" "$1"' _ "$template"

fake_deploy_cleanup

# --- missing template fails fast (no inline fallback) -----------------------
# The template is the single source of truth. deploy.sh must refuse to arm a
# verification unit it did not derive from that file.
missing_dir="$(mktemp -d)"
"$FAKE_REAL_CP" "$deploy_sh" "$missing_dir/deploy.sh"
ln -s "$script_dir/lib" "$missing_dir/lib"

fake_deploy_install
fake_deploy_seed_baseline
printf 'ENABLE_DDNS=true\nDDNS_HOST=strim\nDDNS_DOMAIN=example.com\n' \
  >"$FAKE_DEPLOY_ROOT/config/strimserver.env"
printf 'ddns-secret\n' >"$FAKE_DEPLOY_ROOT/ddns-password"

missing_out="$case_tmp/missing.out"
rc=0
( cd "$FAKE_DEPLOY_ROOT" && bash "$missing_dir/deploy.sh" ) >"$missing_out" 2>&1 || rc=$?
unit_missing="$FAKE_SYSROOT/etc/systemd/system/strim-ddns-verify.service"

check "missing template: deploy.sh exits non-zero" test "$rc" -ne 0
check "missing template: error names the missing template" \
  grep -q 'strim-ddns-verify.service.template' "$missing_out"
check "missing template: no verify unit installed" test ! -f "$unit_missing"

fake_deploy_cleanup
fake_gpu_cleanup
PATH="$case_path"
rm -rf "$case_tmp" "$missing_dir"

if [ "$failures" -ne 0 ]; then
  printf '\n%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall DDNS async tests passed\n'
