#!/bin/sh
# End-to-end scenario for a REAL Mac.
#
#   sudo -E env "PATH=$PATH" SCP_TEST_ALLOW_DESTRUCTIVE=1 sh tests/macos/scenario.sh
#
# tests/docker/run.sh has a "macos-layout" lane, but it can only force the file
# LAYOUT macOS uses on top of a Linux container -- a Linux kernel cannot run
# Darwin, so the things that actually differ on a Mac are untested there:
# Directory Services user enumeration (dscl, not /etc/passwd), /var/root
# instead of /root, BSD userland (stat -f, no useradd), macOS's own
# /etc/zshrc + /etc/bashrc + path_helper startup order, and a zsh that really
# reads /etc/zlogin. This runs the same shape of scenario on the real thing.
#
# It installs Supply Gate machine-wide for real, so it refuses to start unless
# told the host is disposable.

set -u

if [ "${SCP_TEST_ALLOW_DESTRUCTIVE:-0}" != "1" ]; then
  echo "REFUSING: this installs Supply Gate for real (machine scope, /etc + /opt)." >&2
  echo "Set SCP_TEST_ALLOW_DESTRUCTIVE=1 only on a disposable Mac (a CI runner, a VM)." >&2
  exit 1
fi
if [ "$(uname -s)" != "Darwin" ]; then
  echo "REFUSING: this scenario is for macOS; use tests/docker/run.sh on Linux." >&2
  exit 1
fi
if [ "$(id -u)" != "0" ]; then
  echo "REFUSING: must run as root (machine scope). Use sudo." >&2
  exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

# The unprivileged account whose shells and dotfiles we assert on. On a GitHub
# runner that is `runner`; SUDO_USER makes it work on any other Mac too.
TEST_USER=${SUDO_USER:-$(stat -f '%Su' /dev/console 2>/dev/null || echo runner)}
TEST_HOME=$(dscl . -read "/Users/$TEST_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
TEST_HOME=${TEST_HOME:-/Users/$TEST_USER}
SHIM=/opt/supply-gate/shims
FAKE_TOOL=/usr/local/bin/bun          # a managed command no runner ships

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
no()   { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
step() { printf '\n=== %s ===\n' "$1"; }

rc_of() {
  "$@" >/tmp/last.log 2>&1
  printf '%s' "$?"
}

as_user() { sudo -u "$TEST_USER" -H sh -c "$1" 2>/dev/null; }

expect_shim() {
  out=$(as_user "$2")
  case "$out" in
    "$SHIM/npm") ok "$1" ;;
    "")          no "$1 (npm not found at all)" ;;
    *)           no "$1 (got $out -- real binary, not intercepted)" ;;
  esac
}

cleanup() { rm -f "$FAKE_TOOL"; }
trap cleanup EXIT INT TERM

cd "$REPO_ROOT" || exit 1

step "0. preconditions"
printf 'test user: %s (%s)\n' "$TEST_USER" "$TEST_HOME"
[ -d "$TEST_HOME" ] && ok "test user's home exists" || no "no home for $TEST_USER"
command -v zsh >/dev/null 2>&1 && ok "zsh present (it is the macOS default shell)" || no "zsh missing"
# The scenario asserts on files that only exist on macOS; make the difference
# from the Linux lanes explicit rather than implied.
[ -f /etc/zshrc ] && ok "/etc/zshrc exists (macOS sysconfdir layout)" || no "/etc/zshrc missing"
[ -f /etc/bashrc ] && ok "/etc/bashrc exists (macOS uses the RHEL name)" || no "/etc/bashrc missing"
[ ! -d /etc/zsh ] && ok "/etc/zsh absent, as on stock macOS" || no "/etc/zsh exists on this Mac"
mkdir -p /usr/local/bin
printf '#!/bin/sh\necho "REAL-BUN-RAN args=$*"\n' >"$FAKE_TOOL"
chmod 755 "$FAKE_TOOL"

step "1. status before install"
code=$(rc_of ./install.sh status)
[ "$code" = "2" ] && ok "exit 2 (not installed)" || no "exit $code, expected 2"
grep -q "not installed" /tmp/last.log && ok "says not installed" || no "no 'not installed' in output"

step "2. apply --scope machine --mode soft"
code=$(rc_of ./install.sh apply --scope machine --mode soft)
[ "$code" = "0" ] && ok "exit 0" || { no "exit $code"; tail -20 /tmp/last.log | sed 's/^/    /'; }

step "3. status after apply"
code=$(rc_of ./install.sh status)
[ "$code" = "0" ] && ok "exit 0 (healthy)" || { no "exit $code, expected 0"; sed 's/^/    /' /tmp/last.log; }
grep -q "scope: machine" /tmp/last.log && ok "inferred machine scope" || no "did not infer machine scope"
grep -q "platform: macos" /tmp/last.log && ok "detected platform macos" || no "platform not detected as macos"

step "4. the macOS system rc files carry the managed block"
for f in /etc/bashrc /etc/zshrc /etc/zlogin; do
  grep -q "supply-chain-protect" "$f" 2>/dev/null \
    && ok "$f carries the managed block" || no "$f has no block"
done
[ -f /etc/zsh/zlogin ] && no "/etc/zsh/zlogin created on a Mac that has no /etc/zsh" \
  || ok "no stray /etc/zsh/zlogin"

step "5. root's configs land in /var/root, not /root"
for f in "$TEST_HOME/.npmrc" /var/root/.npmrc /var/root/.config/pip/pip.conf; do
  grep -q "supply-chain-protect" "$f" 2>/dev/null \
    && ok "$f configured" || no "$f not configured"
done
[ -e /root ] && no "/root was created on macOS" || ok "no /root created"

step "6. dscl enumeration reached the real local account"
# list_local_users_macos, not /etc/passwd -- on macOS the login accounts are
# not in /etc/passwd at all, which is why this cannot be tested in a container.
grep -q "supply-chain-protect" "$TEST_HOME/.config/pip/pip.conf" 2>/dev/null \
  && ok "$TEST_USER's pip.conf configured via dscl enumeration" \
  || no "$TEST_USER's pip.conf missing -- dscl enumeration did not reach them"
owner=$(stat -f '%Su' "$TEST_HOME/.npmrc" 2>/dev/null || echo "?")
[ "$owner" = "$TEST_USER" ] && ok ".npmrc owned by $TEST_USER" || no ".npmrc owned by $owner"

step "7. PATH interception from real macOS login shells"
expect_shim "zsh -lc  (login)      " 'zsh -lc "command -v npm"'
expect_shim "zsh -ic  (interactive)" 'zsh -ic "command -v npm"'
expect_shim "bash -lc (login)      " 'bash -lc "command -v npm"'
expect_shim "bash -ic (interactive)" 'bash -ic "command -v npm"'

step "8. the wrapper really runs, as $TEST_USER"
out=$(as_user 'zsh -lc "bun install lodash"')
printf '%s\n' "$out" | grep -q "REAL-BUN-RAN args=install lodash" \
  && ok "real binary reached with args intact" || no "real binary did not run (got: $out)"
grep -q '"tool":"bun"' /opt/supply-gate/logs/events.jsonl 2>/dev/null \
  && ok "bun event in events.jsonl" || no "no bun event"
grep -q "\"user\":\"$TEST_USER\"" /opt/supply-gate/logs/events.jsonl 2>/dev/null \
  && ok "event attributed to $TEST_USER (1777 log dir works)" || no "event not attributed to $TEST_USER"

step "9. runtime drift is detected by content, not presence"
printf '# drifted\n' >>/opt/supply-gate/runtime/common.sh
code=$(rc_of ./install.sh status)
[ "$code" = "1" ] && ok "exit 1 (degraded)" || no "exit $code, expected 1"
grep -q "runtime" /tmp/last.log && ok "names the runtime section" || no "does not name runtime"

step "10. repair fixes it"
code=$(rc_of ./install.sh repair --scope machine)
[ "$code" = "0" ] && ok "repair exit 0" || { no "repair exit $code"; tail -10 /tmp/last.log | sed 's/^/    /'; }
code=$(rc_of ./install.sh status)
[ "$code" = "0" ] && ok "status healthy again" || { no "status exit $code"; sed 's/^/    /' /tmp/last.log; }

step "11. hard mode with placeholder registries fails closed"
code=$(rc_of ./install.sh apply --scope machine --mode hard)
[ "$code" != "0" ] && ok "apply --mode hard refused placeholder URLs (exit $code)" \
  || no "apply --mode hard accepted placeholder registry URLs"

step "12. AI CLIs are unjailed-but-warned in soft mode on macOS"
# AI_JAIL_LAUNCHER_MACOS is its own key: a Linux launcher must never satisfy a
# Mac. Soft mode fails open, so this warns rather than blocks.
code=$(rc_of ./install.sh status --full --scope machine)
grep -q "AI_JAIL_LAUNCHER_MACOS" /tmp/last.log \
  && ok "status names the macOS launcher key specifically" \
  || no "status does not name AI_JAIL_LAUNCHER_MACOS"

step "13. uninstall --scope all"
code=$(rc_of ./uninstall.sh --scope all)
[ "$code" = "0" ] && ok "uninstall exit 0" || { no "uninstall exit $code"; tail -10 /tmp/last.log | sed 's/^/    /'; }
[ -d /opt/supply-gate ] && no "/opt/supply-gate left behind" || ok "/opt/supply-gate removed"
[ -f /etc/profile.d/supply-gate.sh ] && no "profile.d left behind" || ok "profile.d removed"
for f in /etc/bashrc /etc/zshrc /etc/zlogin /var/root/.npmrc "$TEST_HOME/.zshrc" "$TEST_HOME/.npmrc"; do
  grep -q "supply-chain-protect" "$f" 2>/dev/null \
    && no "block left in $f" || ok "block removed from $f"
done
code=$(rc_of ./install.sh status)
[ "$code" = "2" ] && ok "status exit 2 after uninstall" || no "status exit $code, expected 2"

printf '\n=====================================\nPASS=%s  FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
