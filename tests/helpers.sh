#!/bin/sh
# Test helpers — sourced by test scripts.
# No external dependencies; POSIX sh only.

PASS=0
FAIL=0
ERRORS=""

pass() {
  PASS=$((PASS + 1))
  printf '  ok  %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  ERRORS="$ERRORS\n  FAIL: $1"
  printf '  FAIL %s\n' "$1"
}

assert_file_exists() {
  label=$1
  path=$2
  if [ -f "$path" ]; then
    pass "$label"
  else
    fail "$label (file not found: $path)"
  fi
}

assert_file_absent() {
  label=$1
  path=$2
  if [ ! -f "$path" ]; then
    pass "$label"
  else
    fail "$label (file should not exist: $path)"
  fi
}

assert_file_contains() {
  label=$1
  path=$2
  needle=$3
  if [ -f "$path" ] && grep -qF "$needle" "$path"; then
    pass "$label"
  else
    fail "$label (needle not found in $path: $needle)"
  fi
}

assert_file_not_contains() {
  label=$1
  path=$2
  needle=$3
  if [ ! -f "$path" ] || ! grep -qF "$needle" "$path"; then
    pass "$label"
  else
    fail "$label (needle should be absent from $path: $needle)"
  fi
}

assert_equals() {
  label=$1
  expected=$2
  actual=$3
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label (expected='$expected' actual='$actual')"
  fi
}

assert_exit_nonzero() {
  label=$1
  if eval "$2"; then
    fail "$label (command should have failed but exited 0)"
  else
    pass "$label"
  fi
}

assert_output_contains() {
  label=$1
  needle=$2
  output=$3
  if printf '%s' "$output" | grep -qF "$needle"; then
    pass "$label"
  else
    fail "$label (needle not found in output: $needle)"
  fi
}

summary() {
  total=$((PASS + FAIL))
  printf '\n%d/%d passed' "$PASS" "$total"
  if [ "$FAIL" -gt 0 ]; then
    printf '  (%d failed)' "$FAIL"
    printf '%b\n' "$ERRORS"
    printf '\n'
    return 1
  fi
  printf '\n'
  return 0
}

# Setup a temporary test root that mimics the filesystem layout the tests need.
# Sets TEST_ROOT, FAKE_ETC, FAKE_OPT, and exports them.
setup_test_env() {
  TEST_ROOT=$(mktemp -d)
  FAKE_ETC="$TEST_ROOT/etc"
  FAKE_OPT="$TEST_ROOT/opt"
  FAKE_HOME_ROOT="$TEST_ROOT/root"
  FAKE_HOME_ALICE="$TEST_ROOT/home/alice"
  FAKE_HOME_BOB="$TEST_ROOT/home/bob"
  FAKE_PASSWD="$FAKE_ETC/passwd"

  mkdir -p "$FAKE_ETC/profile.d"
  mkdir -p "$FAKE_OPT/supply-gate/runtime"
  mkdir -p "$FAKE_OPT/supply-gate/shims"
  mkdir -p "$FAKE_HOME_ROOT"
  mkdir -p "$FAKE_HOME_ALICE"
  # bob's home intentionally NOT created to test missing-home exclusion

  # Synthetic passwd — home paths point to the temp tree so existence checks work.
  cat >"$FAKE_PASSWD" <<EOF
root:x:0:0:root:/root:/bin/bash
alice:x:1001:1001:Alice:$FAKE_HOME_ALICE:/bin/bash
nologin_user:x:1002:1002:No Login:$TEST_ROOT/home/nologin_user:/sbin/nologin
sysusr:x:500:500:System:$TEST_ROOT/home/sysusr:/bin/bash
bob:x:1003:1003:Bob:$FAKE_HOME_BOB:/bin/bash
EOF

  # Minimal profile.sh in the fake opt tree
  printf 'export PATH="%s/shims:$PATH"\n' "$FAKE_OPT/supply-gate" \
    >"$FAKE_OPT/supply-gate/runtime/profile.sh"

  export TEST_ROOT FAKE_ETC FAKE_OPT FAKE_HOME_ROOT FAKE_HOME_ALICE FAKE_HOME_BOB FAKE_PASSWD
}

teardown_test_env() {
  [ -n "${TEST_ROOT:-}" ] && rm -rf "$TEST_ROOT"
}
