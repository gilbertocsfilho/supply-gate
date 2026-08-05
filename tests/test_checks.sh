#!/bin/sh
# Unit tests for lib/checks.sh (the engine behind `install.sh status`).
#   sh tests/test_checks.sh

set -eu

SCRIPT_DIR_TESTS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR_TESTS/.." && pwd)

. "$SCRIPT_DIR_TESTS/helpers.sh"

SCP_POLICY_FILE="$PROJECT_ROOT/policy/default-policy.conf"
export SCP_POLICY_FILE

FAKE_ROOT=$(mktemp -d)
INSTALL_ROOT_OVERRIDE="$FAKE_ROOT/state"
export INSTALL_ROOT_OVERRIDE

. "$PROJECT_ROOT/lib/common.sh"

# checks.sh compares the installed runtime against the shipped source at
# $SCRIPT_DIR; point it at the real repo.
SCRIPT_DIR=$PROJECT_ROOT
. "$PROJECT_ROOT/lib/checks.sh"

cleanup() { rm -rf "$FAKE_ROOT"; }
trap cleanup EXIT

reset_checks() {
  CHECK_RESULTS=""
  CHECK_OK=0
  CHECK_WARN=0
  CHECK_FAIL=0
  CHECK_UNKNOWN=0
  CHECK_SCOPE="user"
  CHECK_FULL=0
}

# Build a complete, healthy fake install so individual checks can be broken
# one at a time.
make_install() {
  rm -rf "$STATE_ROOT"
  mkdir -p "$RUNTIME_ROOT" "$SHIM_ROOT" "$LOG_ROOT" "$ATT_ROOT"
  cp "$PROJECT_ROOT/lib/common.sh" "$COMMON_RUNTIME"
  cp "$PROJECT_ROOT/shims/manager-wrapper.sh" "$WRAPPER_BIN"
  chmod 755 "$COMMON_RUNTIME" "$WRAPPER_BIN"
  cp "$PROJECT_ROOT/policy/default-policy.conf" "$RUNTIME_ROOT/policy.conf"
  printf 'export PATH="%s:$PATH"\n' "$SHIM_ROOT" >"$PROFILE_SNIPPET"
  cat >"$RUNSTATE_FILE" <<EOF
ENFORCEMENT_MODE="soft"
POLICY_VERSION_APPLIED="$POLICY_VERSION"
UPDATED_AT="2026-08-05T00:00:00Z"
EOF
  for t in $MANAGED_COMMANDS; do
    printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$WRAPPER_BIN" "$t" >"$SHIM_ROOT/$t"
    chmod 755 "$SHIM_ROOT/$t"
  done
  : >"$AGGREGATE_LOG"
  ENFORCEMENT_MODE="soft"
  POLICY_VERSION_APPLIED="$POLICY_VERSION"
}

# ===========================================================================
printf '\n--- verdict and exit codes ---\n'
# ===========================================================================
reset_checks
check_record "a.one" "ok" "fine"
assert_equals "all ok -> healthy" "healthy" "$(check_verdict)"
assert_equals "healthy -> exit 0" "0" "$(check_exit_code "$(check_verdict)")"

reset_checks
check_record "a.one" "fail" "broken" "repair"
assert_equals "repairable fail -> degraded" "degraded" "$(check_verdict)"
assert_equals "degraded -> exit 1" "1" "$(check_exit_code "$(check_verdict)")"

reset_checks
check_record "a.one" "fail" "broken" "manual"
assert_equals "manual fail -> action_required" "action_required" "$(check_verdict)"
assert_equals "action_required -> exit 2" "2" "$(check_exit_code "$(check_verdict)")"

reset_checks
check_record "a.one" "fail" "broken" "repair"
check_record "a.two" "fail" "worse" "manual"
assert_equals "manual outranks repair" "action_required" "$(check_verdict)"

reset_checks
check_record "a.one" "ok" "fine"
check_record "a.two" "unknown" "cannot tell"
assert_equals "unknown does not change verdict" "healthy" "$(check_verdict)"

reset_checks
check_record "a.one" "warn" "meh"
assert_equals "warn alone stays healthy" "healthy" "$(check_verdict)"

# ===========================================================================
printf '\n--- check_record hygiene ---\n'
# ===========================================================================
reset_checks
check_record "a.one" "fail" "$(printf 'line1\nline2\twith tab')" "repair"
rows=$(printf '%s' "$CHECK_RESULTS" | wc -l | tr -d ' ')
assert_equals "multi-line detail stays one row" "1" "$rows"
assert_output_contains "newline flattened out" "line1line2 with tab" "$CHECK_RESULTS"

reset_checks
check_record "a.one" "fail" "x" "repair"
check_record "a.two" "fail" "y" "manual"
assert_output_contains "repair list has only the repairable id" "a.one" "$(check_fails_with_fix repair)"
if printf '%s' "$(check_fails_with_fix repair)" | grep -q "a.two"; then
  fail "repair list must not include the manual id"
else
  pass "repair list must not include the manual id"
fi

# ===========================================================================
printf '\n--- placeholder detection ---\n'
# ===========================================================================
check_is_placeholder "" && pass "empty is placeholder" || fail "empty is placeholder"
check_is_placeholder "https://npm.example.corp/x" \
  && pass "example.corp is placeholder" || fail "example.corp is placeholder"
check_is_placeholder "https://npm.corp.internal" \
  && fail "real URL must not be a placeholder" || pass "real URL is not a placeholder"

# ===========================================================================
printf '\n--- not installed ---\n'
# ===========================================================================
reset_checks
rm -rf "$STATE_ROOT"
if check_install; then
  fail "check_install must return non-zero when nothing is installed"
else
  pass "check_install returns non-zero when nothing is installed"
fi
assert_equals "not installed -> action_required" "action_required" "$(check_verdict)"
assert_output_contains "names state_root" "install.state_root" "$CHECK_RESULTS"
if [ -d "$STATE_ROOT" ]; then
  fail "checks must not create STATE_ROOT"
else
  pass "checks did not create STATE_ROOT"
fi

# ===========================================================================
printf '\n--- runtime integrity ---\n'
# ===========================================================================
reset_checks
make_install
check_runtime
assert_equals "healthy install: no runtime failures" "0" "$CHECK_FAIL"

reset_checks
make_install
printf '# drifted\n' >>"$COMMON_RUNTIME"
check_runtime
assert_output_contains "content drift is detected" "runtime.common_current" "$(check_fails_with_fix repair)"

reset_checks
make_install
SCRIPT_DIR="$FAKE_ROOT/no-such-checkout"
check_runtime
SCRIPT_DIR=$PROJECT_ROOT
assert_equals "no shipped source -> unknown, not fail" "0" "$CHECK_FAIL"
assert_output_contains "unknown recorded" "unknown" "$CHECK_RESULTS"

reset_checks
make_install
: >"$RUNTIME_ROOT/binmap.conf"
check_runtime
assert_output_contains "stale binmap detected" "runtime.stale_binmap" "$(check_fails_with_fix repair)"

reset_checks
make_install
rm -f "$PROFILE_SNIPPET"
check_runtime
assert_output_contains "missing profile snippet detected" "runtime.profile_snippet" "$(check_fails_with_fix repair)"

# ===========================================================================
printf '\n--- shims ---\n'
# ===========================================================================
reset_checks
make_install
check_shims
assert_equals "all shims healthy" "0" "$CHECK_FAIL"

reset_checks
make_install
chmod 000 "$SHIM_ROOT/npm"
check_shims
assert_output_contains "non-executable shim detected" "shim.present" "$(check_fails_with_fix repair)"
chmod 755 "$SHIM_ROOT/npm"

reset_checks
make_install
printf '#!/bin/sh\nexec "/somewhere/else/manager-wrapper.sh" "npm" "$@"\n' >"$SHIM_ROOT/npm"
check_shims
assert_output_contains "wrong wrapper target detected" "shim.target" "$(check_fails_with_fix repair)"

# ===========================================================================
printf '\n--- evidence ---\n'
# ===========================================================================
reset_checks
make_install
check_evidence
assert_equals "writable log dir is healthy" "0" "$CHECK_FAIL"
probe_left=$(find "$LOG_ROOT" -name '.status-probe.*' 2>/dev/null | wc -l | tr -d ' ')
assert_equals "probe file was cleaned up" "0" "$probe_left"

reset_checks
make_install
rm -f "$AGGREGATE_LOG"
check_evidence
assert_output_contains "missing events.jsonl detected" "evidence.events" "$(check_fails_with_fix repair)"

# ===========================================================================
printf '\n--- read-only contract ---\n'
# ===========================================================================
reset_checks
make_install
before=$(find "$STATE_ROOT" -type f -exec sha256sum {} \; 2>/dev/null | sort)
check_install
check_runtime
check_shims
check_path
check_config
check_mode
check_jail
check_evidence
check_optional
after=$(find "$STATE_ROOT" -type f -exec sha256sum {} \; 2>/dev/null | sort)
assert_equals "a full check run changes nothing on disk" "$before" "$after"

# ===========================================================================
printf '\n'
summary
