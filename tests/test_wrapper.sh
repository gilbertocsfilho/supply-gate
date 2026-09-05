#!/bin/sh
# The shim -> manager-wrapper.sh -> real-binary chain, invoked for real inside
# a temp tree. The POSIX counterpart of tests/windows/test_wrapper.ps1, and
# for the same reason: the wrapper's argument handling and exit-code plumbing
# only misbehave when something actually runs through them.
#
#   sh tests/test_wrapper.sh
#
# Temp dirs only -- no /etc, no /opt, no real install.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

. "$SCRIPT_DIR/helpers.sh"

TEST_ROOT=$(mktemp -d)
RUNTIME="$TEST_ROOT/runtime"
REAL_BIN_DIR="$TEST_ROOT/realbin"
mkdir -p "$RUNTIME" "$REAL_BIN_DIR" "$TEST_ROOT/logs" "$TEST_ROOT/shims" "$TEST_ROOT/attestation"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT INT TERM

# A minimal installed runtime: the wrapper resolves everything relative to its
# own directory, exactly as install_runtime lays it out.
cp "$PROJECT_ROOT/lib/common.sh" "$RUNTIME/common.sh"
cp "$PROJECT_ROOT/shims/manager-wrapper.sh" "$RUNTIME/manager-wrapper.sh"
chmod 755 "$RUNTIME/manager-wrapper.sh"
{
  cat "$PROJECT_ROOT/policy/default-policy.conf"
  printf '\nINSTALL_ROOT_OVERRIDE="%s"\n' "$TEST_ROOT"
} >"$RUNTIME/policy.conf"
cat >"$RUNTIME/state.conf" <<STATEEOF
ENFORCEMENT_MODE="soft"
POLICY_VERSION_APPLIED="1.0.0"
STATE_ROOT="$TEST_ROOT"
STATEEOF

# Fake real binaries: one that succeeds, one that fails with a distinctive
# code. No network, no real npm needed -- the same trick the container
# scenario uses.
cat >"$REAL_BIN_DIR/npm" <<'NPMEOF'
#!/bin/sh
echo "REAL-NPM-RAN args=$*"
NPMEOF
cat >"$REAL_BIN_DIR/pnpm" <<'PNPMEOF'
#!/bin/sh
echo "REAL-PNPM-FAILING args=$*" >&2
exit 17
PNPMEOF
chmod 755 "$REAL_BIN_DIR/npm" "$REAL_BIN_DIR/pnpm"

run_wrapper() {
  _rw_tool=$1
  shift
  PATH="$REAL_BIN_DIR:$PATH" HOME="$TEST_ROOT/home" \
    sh "$RUNTIME/manager-wrapper.sh" "$_rw_tool" "$@" 2>&1
}

printf '\n--- arguments reach the real binary intact ---\n'
out=$(run_wrapper npm install lodash --save-exact)
rc=$?
assert_equals "npm exits 0 when the real binary succeeds" "0" "$rc"
assert_output_contains "args passed through unchanged" \
  "REAL-NPM-RAN args=install lodash --save-exact" "$out"

printf '\n--- a failing tool must NOT be reported as success ---\n'
# Regression: `rc=$?` after a closing `fi` reads the status of the `if`
# statement (0 when the condition was false and there is no else), not the
# status of the condition -- so every failed install used to leave the shim
# with exit 0 while logging "failure". A caller, a script or CI could not tell
# a refused install from a completed one.
run_wrapper pnpm install lodash >/dev/null 2>&1
rc=$?
assert_equals "the real binary's exit code propagates" "17" "$rc"

printf '\n--- the failure is in the audit trail too ---\n'
events="$TEST_ROOT/logs/events.jsonl"
assert_file_contains "failure recorded in events.jsonl" "$events" '"status":"failure"'
assert_file_contains "failure names the exit code" "$events" 'exit 17'
assert_file_contains "success recorded for the passing run" "$events" '"status":"success"'

printf '\n--- an unmanaged tool is refused ---\n'
run_wrapper definitely-not-managed >/dev/null 2>&1
rc=$?
assert_equals "unmanaged tool exits non-zero" "1" "$rc"

summary
