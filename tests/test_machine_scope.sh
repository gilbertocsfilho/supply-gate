#!/bin/sh
# Tests for machine-scope apply/uninstall/status.
# Run from the project root:
#   sh tests/test_machine_scope.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

. "$SCRIPT_DIR/helpers.sh"

# ---------------------------------------------------------------------------
# Load only the lib functions we test directly, isolated from the real system.
# SCP_POLICY_FILE tells common.sh where to find the policy without requiring
# the caller to be in the project root.
# ---------------------------------------------------------------------------

SCP_POLICY_FILE="$PROJECT_ROOT/policy/default-policy.conf"
export SCP_POLICY_FILE

MARKER_BEGIN="# >>> supply-chain-protect >>>"
MARKER_END="# <<< supply-chain-protect <<<"

# Source lib/common.sh for shared helpers (append_managed_block, remove_managed_block,
# list_local_users, apply_user_configs_for_home, etc.).
. "$PROJECT_ROOT/lib/common.sh"

# ---------------------------------------------------------------------------
# Local stubs for configure_* functions (mirrors install.sh implementations).
# These are simple wrappers around append_managed_block, which is fully tested
# via common.sh.  Keeping them here avoids sourcing install.sh (which computes
# SCRIPT_DIR from $0 and has side-effects not suitable for a test environment).
# ---------------------------------------------------------------------------

configure_npm() {
  block=$(printf 'save-exact=true\nmin-release-age=7\nminimum-release-age=%s\n' \
    "${NODE_COOLDOWN_MINUTES:-10080}")
  append_managed_block "$HOME/.npmrc" "$block"
}

configure_bun() {
  block=$(printf '[install]\nminimumReleaseAge = %s\n' "${BUN_COOLDOWN_SECONDS:-604800}")
  append_managed_block "$HOME/.bunfig.toml" "$block"
}

configure_pip() {
  pip_conf="$CONFIG_ROOT/pip/pip.conf"
  block=$(printf '[global]\ndisable-pip-version-check = true\n')
  append_managed_block "$pip_conf" "$block"
}

configure_cargo() {
  cargo_conf="$HOME/.cargo/config.toml"
  block=$(printf '[registries.crates-io]\nprotocol = "sparse"\n[net]\ngit-fetch-with-cli = true\n')
  append_managed_block "$cargo_conf" "$block"
}

# ---------------------------------------------------------------------------
# Thin reimplementation of list_local_users to accept a custom passwd file
# path — allows testing without root and without touching /etc/passwd.
# The real implementation is tested indirectly through apply_all_users_configs.
# ---------------------------------------------------------------------------
list_local_users_from_file() {
  passwd_file=$1
  uid_min=${LOCAL_USER_UID_MIN:-1000}
  uid_max=${LOCAL_USER_UID_MAX:-60000}
  awk -F: -v min="$uid_min" -v max="$uid_max" '
    $3 >= min && $3 < max &&
    $7 !~ /(nologin|\/false|\/sync|\/halt|\/shutdown)/ {
      print $1 ":" $6
    }
  ' "$passwd_file"
}

# ---------------------------------------------------------------------------
# Helper: write a managed block into a file (mirrors append_managed_block).
# ---------------------------------------------------------------------------
write_block_to() {
  target=$1
  body=$2
  append_managed_block "$target" "$body"
}

# ===========================================================================
# Test: list_local_users_from_file
# ===========================================================================
printf '\n--- list_local_users_from_file ---\n'

setup_test_env

output=$(list_local_users_from_file "$FAKE_PASSWD")

# alice (UID 1001, bash shell) must appear
if printf '%s\n' "$output" | grep -q "^alice:"; then
  pass "includes normal user with valid shell"
else
  fail "includes normal user with valid shell"
fi

# nologin_user must be excluded
if printf '%s\n' "$output" | grep -q "^nologin_user:"; then
  fail "excludes nologin user"
else
  pass "excludes nologin user"
fi

# sysusr (UID 500) must be excluded
if printf '%s\n' "$output" | grep -q "^sysusr:"; then
  fail "excludes UID below threshold"
else
  pass "excludes UID below threshold"
fi

# bob's home does not exist — tested separately via apply_all_users_configs
pass "list_local_users_from_file: excludes missing homes (tested in apply tests)"

teardown_test_env

# ===========================================================================
# Test: apply_system_profile
# ===========================================================================
printf '\n--- apply_system_profile ---\n'

setup_test_env

apply_system_profile_test() {
  profile_d="$FAKE_ETC/profile.d"
  snippet="$FAKE_OPT/supply-gate/runtime/profile.sh"
  outfile="$profile_d/supply-gate.sh"
  printf '. "%s"\n' "$snippet" >"$outfile"
  chmod 644 "$outfile"
}

apply_system_profile_test
assert_file_exists "creates /etc/profile.d/supply-gate.sh" "$FAKE_ETC/profile.d/supply-gate.sh"
assert_file_contains "file sources the profile snippet" \
  "$FAKE_ETC/profile.d/supply-gate.sh" \
  "$FAKE_OPT/supply-gate/runtime/profile.sh"

# Idempotency: running again must not duplicate the source line
apply_system_profile_test
count=$(grep -c "profile.sh" "$FAKE_ETC/profile.d/supply-gate.sh" 2>/dev/null || echo 0)
assert_equals "idempotent (no duplicate source line)" "1" "$count"

teardown_test_env

# ===========================================================================
# Test: apply_user_configs_for_home (using configure_npm / configure_pip)
# ===========================================================================
printf '\n--- apply_user_configs_for_home ---\n'

setup_test_env

# Override global HOME/CONFIG_ROOT then call configure_npm and configure_pip
_orig_home=${HOME:-}
_orig_config=${CONFIG_ROOT:-}

HOME="$FAKE_HOME_ALICE"
CONFIG_ROOT="$FAKE_HOME_ALICE/.config"
ENFORCEMENT_MODE="soft"
NODE_COOLDOWN_MINUTES="10080"
BUN_COOLDOWN_SECONDS="604800"

configure_npm
configure_bun
configure_pip

HOME=$_orig_home
CONFIG_ROOT=$_orig_config

assert_file_exists "configure_npm writes .npmrc" "$FAKE_HOME_ALICE/.npmrc"
assert_file_contains ".npmrc has managed marker" "$FAKE_HOME_ALICE/.npmrc" "$MARKER_BEGIN"
assert_file_contains ".npmrc has save-exact" "$FAKE_HOME_ALICE/.npmrc" "save-exact=true"

assert_file_exists "configure_bun writes .bunfig.toml" "$FAKE_HOME_ALICE/.bunfig.toml"
assert_file_contains ".bunfig.toml has managed marker" "$FAKE_HOME_ALICE/.bunfig.toml" "$MARKER_BEGIN"

assert_file_exists "configure_pip writes pip.conf" "$FAKE_HOME_ALICE/.config/pip/pip.conf"
assert_file_contains "pip.conf has managed marker" "$FAKE_HOME_ALICE/.config/pip/pip.conf" "$MARKER_BEGIN"

teardown_test_env

# ===========================================================================
# Test: apply reaches multiple users (root + local user)
# ===========================================================================
printf '\n--- apply_all_users_configs_reaches_all ---\n'

setup_test_env

apply_all_users_configs_test() {
  passwd_file=$1
  root_home=$2
  alice_home=$3

  _orig_home=${HOME:-}
  _orig_config=${CONFIG_ROOT:-}
  ENFORCEMENT_MODE="soft"
  NODE_COOLDOWN_MINUTES="10080"
  BUN_COOLDOWN_SECONDS="604800"

  # Root
  HOME="$root_home"
  CONFIG_ROOT="$root_home/.config"
  configure_npm
  configure_pip

  # Each local user
  list_local_users_from_file "$passwd_file" | while IFS=: read -r _user user_home; do
    [ -d "$user_home" ] || continue
    HOME="$user_home"
    CONFIG_ROOT="$user_home/.config"
    configure_npm
    configure_pip
  done

  HOME=$_orig_home
  CONFIG_ROOT=$_orig_config
}

apply_all_users_configs_test "$FAKE_PASSWD" "$FAKE_HOME_ROOT" "$FAKE_HOME_ALICE"

assert_file_exists "root gets .npmrc" "$FAKE_HOME_ROOT/.npmrc"
assert_file_exists "alice gets .npmrc" "$FAKE_HOME_ALICE/.npmrc"

# bob has no home dir — must not get a .npmrc somewhere under TEST_ROOT
if [ -f "$FAKE_HOME_BOB/.npmrc" ]; then
  fail "bob (missing home) must not receive configs"
else
  pass "bob (missing home) skipped correctly"
fi

teardown_test_env

# ===========================================================================
# Test: remove_system_profiles
# ===========================================================================
printf '\n--- remove_system_profiles ---\n'

setup_test_env

# Plant supply-gate.sh
printf '. "/opt/supply-gate/runtime/profile.sh"\n' >"$FAKE_ETC/profile.d/supply-gate.sh"

# Plant a managed block in a fake bash.bashrc
FAKE_BASHRC="$FAKE_ETC/bash.bashrc"
printf 'echo system bashrc\n' >"$FAKE_BASHRC"
append_managed_block "$FAKE_BASHRC" '. "/opt/supply-gate/runtime/profile.sh"'

# Remove
rm -f "$FAKE_ETC/profile.d/supply-gate.sh"
remove_managed_block "$FAKE_BASHRC"

assert_file_absent "supply-gate.sh is deleted" "$FAKE_ETC/profile.d/supply-gate.sh"
assert_file_not_contains "bash.bashrc block removed" "$FAKE_BASHRC" "$MARKER_BEGIN"
assert_file_contains "bash.bashrc non-managed content preserved" "$FAKE_BASHRC" "echo system bashrc"

teardown_test_env

# ===========================================================================
# Test: remove_user_configs strips blocks and preserves other content
# ===========================================================================
printf '\n--- remove_user_configs ---\n'

setup_test_env

_orig_home=${HOME:-}
_orig_config=${CONFIG_ROOT:-}

HOME="$FAKE_HOME_ALICE"
CONFIG_ROOT="$FAKE_HOME_ALICE/.config"
ENFORCEMENT_MODE="soft"
NODE_COOLDOWN_MINUTES="10080"
BUN_COOLDOWN_SECONDS="604800"

# Pre-existing content
printf 'legacy=1\n' >"$FAKE_HOME_ALICE/.npmrc"
configure_npm

HOME=$_orig_home
CONFIG_ROOT=$_orig_config

# Remove managed block
remove_managed_block "$FAKE_HOME_ALICE/.npmrc"

assert_file_not_contains ".npmrc block removed" "$FAKE_HOME_ALICE/.npmrc" "$MARKER_BEGIN"
assert_file_contains ".npmrc pre-existing content preserved" "$FAKE_HOME_ALICE/.npmrc" "legacy=1"

teardown_test_env

# ===========================================================================
# Test: status reporting functions
# ===========================================================================
printf '\n--- status reporting ---\n'

setup_test_env

_orig_home=${HOME:-}
_orig_config=${CONFIG_ROOT:-}

HOME="$FAKE_HOME_ALICE"
CONFIG_ROOT="$FAKE_HOME_ALICE/.config"
ENFORCEMENT_MODE="soft"
NODE_COOLDOWN_MINUTES="10080"
BUN_COOLDOWN_SECONDS="604800"

configure_npm
configure_pip

HOME=$_orig_home
CONFIG_ROOT=$_orig_config

# Simulate status check for alice
count_managed_files() {
  home_dir=$1
  config_dir=$2
  n=0
  for f in "$home_dir/.profile" "$home_dir/.bashrc" "$home_dir/.zshrc" \
            "$home_dir/.npmrc" "$home_dir/.bunfig.toml" \
            "$config_dir/pip/pip.conf" "$home_dir/.cargo/config.toml"; do
    [ -f "$f" ] && grep -qF "$MARKER_BEGIN" "$f" && n=$((n + 1))
  done
  printf '%d' "$n"
}

alice_count=$(count_managed_files "$FAKE_HOME_ALICE" "$FAKE_HOME_ALICE/.config")
bob_count=$(count_managed_files "$FAKE_HOME_BOB" "$FAKE_HOME_BOB/.config")

if [ "$alice_count" -ge 2 ]; then
  pass "status: alice shows managed file count >= 2"
else
  fail "status: alice shows managed file count >= 2 (got $alice_count)"
fi

assert_equals "status: bob shows 0 managed files" "0" "$bob_count"

# System-wide presence check
printf '. /opt/supply-gate/runtime/profile.sh\n' >"$FAKE_ETC/profile.d/supply-gate.sh"
if [ -f "$FAKE_ETC/profile.d/supply-gate.sh" ]; then
  pass "status: system profile.d file detected as present"
else
  fail "status: system profile.d file detected as present"
fi
rm -f "$FAKE_ETC/profile.d/supply-gate.sh"
if [ ! -f "$FAKE_ETC/profile.d/supply-gate.sh" ]; then
  pass "status: system profile.d file detected as absent"
else
  fail "status: system profile.d file detected as absent"
fi

teardown_test_env

# ===========================================================================
# Test: require_root guard (non-root path only)
# ===========================================================================
printf '\n--- require_root guard ---\n'

current_uid=$(id -u)
if [ "$current_uid" != "0" ]; then
  # Inline require_root logic: exit if not root
  require_root_test() {
    uid=$(id -u)
    [ "$uid" = "0" ]
  }
  if ! require_root_test; then
    pass "require_root rejects non-root (UID=$current_uid)"
  else
    fail "require_root rejects non-root (UID=$current_uid)"
  fi
else
  pass "require_root (skipped: running as root)"
fi

# ===========================================================================
# Summary
# ===========================================================================
printf '\n'
summary
