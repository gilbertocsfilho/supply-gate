#!/bin/sh
# End-to-end scenario. Runs INSIDE a container as root: it writes to /etc and
# /opt and creates users, so it refuses to run on a real host.
#
# Invoked by tests/docker/run.sh. Repo is mounted read-only at /src.

set -u

if [ ! -f /.dockerenv ] && [ "${SCP_TEST_ALLOW_HOST:-0}" != "1" ]; then
  echo "REFUSING: not in a container. This installs Supply Gate for real." >&2
  echo "Run tests/docker/run.sh instead." >&2
  exit 1
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
step() { printf '\n=== %s ===\n' "$1"; }

# Exit code of a command, without set -e aborting us.
rc_of() {
  "$@" >/tmp/last.log 2>&1
  printf '%s' "$?"
}

# `command -v npm` as alice, in a given shell invocation style.
resolves_to() {
  su alice -c "$1" 2>/dev/null
}

expect_shim() {
  out=$(resolves_to "$2")
  case "$out" in
    /opt/supply-gate/shims/npm) ok "$1" ;;
    "") no "$1 (npm not found at all)" ;;
    *) no "$1 (got $out -- real binary, not intercepted)" ;;
  esac
}

step "0. preconditions"
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  # Bounded, and its exit status reported. A distro mirror that accepts the
  # connection and then stalls hangs apt indefinitely; with the output
  # discarded, that looks exactly like the lane freezing right after this
  # banner with nothing to explain it. Three minutes is generous for two
  # index fetches and one small package.
  timeout 180 apt-get update -qq >/dev/null 2>&1 || \
    no "apt-get update failed or stalled (exit $?) -- distro mirror problem, not Supply Gate"
  # zsh MUST be installed before apply: apply_system_profiles gates the zlogin
  # write on `command -v zsh`.
  timeout 180 apt-get install -y -qq zsh >/dev/null 2>&1 || \
    no "apt-get install zsh failed or stalled (exit $?) -- distro mirror problem, not Supply Gate"
fi
command -v zsh >/dev/null 2>&1 && ok "zsh present before apply" || no "zsh missing"

# /etc/bashrc is the RHEL/macOS name for the system bash rc. Ubuntu has no such
# file, so create it to prove apply writes both names.
: >/etc/bashrc

useradd -m -s /bin/bash alice
mkdir -p /home/alice/.local/bin
for rc in .zshrc .bashrc; do
  cat >"/home/alice/$rc" <<'EOF'
# alice's own line, must survive uninstall
export PATH="$HOME/.local/bin:$PATH"
EOF
  chown alice:alice "/home/alice/$rc"
done

# Fake npm: interception is observable with no network and no node.
printf '#!/bin/sh\necho "REAL-NPM-RAN args=$*"\n' >/usr/local/bin/npm
chmod 755 /usr/local/bin/npm

cd /src || exit 1

step "1. status before install"
code=$(rc_of ./install.sh status)
[ "$code" = "2" ] && ok "exit 2 (not installed)" || no "exit $code, expected 2"
grep -q "not installed" /tmp/last.log && ok "says not installed" || no "no 'not installed' in output"

step "2. apply --scope machine --mode soft"
code=$(rc_of ./install.sh apply --scope machine --mode soft)
[ "$code" = "0" ] && ok "exit 0" || { no "exit $code"; tail -15 /tmp/last.log | sed 's/^/    /'; }

step "3. status after apply"
code=$(rc_of ./install.sh status)
[ "$code" = "0" ] && ok "exit 0 (healthy)" || { no "exit $code, expected 0"; sed 's/^/    /' /tmp/last.log; }
grep -q "scope: machine" /tmp/last.log && ok "inferred machine scope" || no "did not infer machine scope"

step "4. /etc/bashrc got the block (the RHEL/macOS name)"
grep -q "supply-chain-protect" /etc/bashrc 2>/dev/null \
  && ok "/etc/bashrc carries the managed block" || no "/etc/bashrc has no block"
grep -q "supply-chain-protect" /etc/bash.bashrc 2>/dev/null \
  && ok "/etc/bash.bashrc carries the managed block" || no "/etc/bash.bashrc has no block"

step "5. PATH interception per shell style"
# Only -lc and -ic are expected to work: a non-interactive non-login shell
# sources no startup file at all, by design.
expect_shim "zsh -lc  (login)      " 'zsh -lc "command -v npm"'
expect_shim "zsh -ic  (interactive)" 'zsh -ic "command -v npm"'
expect_shim "bash -lc (login)      " 'bash -lc "command -v npm"'
expect_shim "bash -ic (interactive)" 'bash -ic "command -v npm"'

step "6. wrapper really runs, as alice"
out=$(su alice -c 'zsh -lc "npm install lodash"' 2>&1)
printf '%s\n' "$out" | grep -q "REAL-NPM-RAN args=install lodash" \
  && ok "real npm reached with args intact" || no "real npm did not run"
grep -q '"tool":"npm"' /opt/supply-gate/logs/events.jsonl 2>/dev/null \
  && ok "npm event in events.jsonl" || no "no npm event"
grep -q '"user":"alice"' /opt/supply-gate/logs/events.jsonl 2>/dev/null \
  && ok "event attributed to alice (1777 log dir works)" || no "event not attributed to alice"

step "7. alice owns her own dotfiles"
for f in /home/alice/.zshrc /home/alice/.npmrc /home/alice/.config/pip/pip.conf; do
  if [ -e "$f" ]; then
    owner=$(stat -c '%U' "$f")
    [ "$owner" = "alice" ] && ok "$f owned by alice" || no "$f owned by $owner"
  else
    no "$f missing"
  fi
done

step "8. runtime drift is detected (content, not just presence)"
printf '# drifted\n' >>/opt/supply-gate/runtime/common.sh
code=$(rc_of ./install.sh status)
[ "$code" = "1" ] && ok "exit 1 (degraded)" || no "exit $code, expected 1"
grep -q "runtime.common_current" /tmp/last.log \
  && ok "names runtime.common_current" || no "does not name the drifted file"
# audit only checks presence, so it must NOT catch this -- documents the gap
# that motivated these checks.
code=$(rc_of ./install.sh audit --scope machine)
[ "$code" = "0" ] && ok "audit still passes on drift (known: presence-only)" \
  || ok "audit also caught the drift"

step "9. repair --scope machine fixes it"
code=$(rc_of ./install.sh repair --scope machine)
[ "$code" = "0" ] && ok "repair exit 0" || { no "repair exit $code"; tail -10 /tmp/last.log | sed 's/^/    /'; }
code=$(rc_of ./install.sh status)
[ "$code" = "0" ] && ok "status healthy again" || { no "status exit $code"; sed 's/^/    /' /tmp/last.log; }

step "10. repair with NO --scope, as root, still repairs the machine install"
rm -f /opt/supply-gate/runtime/common.sh
code=$(rc_of ./install.sh repair)
[ "$code" = "0" ] && ok "repair exit 0" || no "repair exit $code"
[ -f /opt/supply-gate/runtime/common.sh ] \
  && ok "machine runtime restored (scope inferred)" \
  || no "machine runtime NOT restored -- repair did a user-scope apply"
[ -d /root/.local/share/supply-chain-protect ] \
  && no "repair created a stray user-scope install under /root" \
  || ok "no stray user-scope install"

step "11. missing per-user block is repaired"
# Strip alice's npmrc block, as if she edited the file.
sed -i '/supply-chain-protect/,/supply-chain-protect/d' /home/alice/.npmrc
rc_of ./install.sh repair >/dev/null
grep -q "supply-chain-protect" /home/alice/.npmrc 2>/dev/null \
  && ok "alice's .npmrc block restored" || no "alice's .npmrc block not restored"

step "12. hard mode with placeholder registries fails closed"
code=$(rc_of ./install.sh apply --scope machine --mode hard)
[ "$code" != "0" ] && ok "apply --mode hard refused with placeholder URLs (exit $code)" \
  || no "apply --mode hard accepted placeholder registry URLs"
# Force the recorded mode to hard so the check can be exercised directly: this
# is the state a host lands in if policy is edited to a placeholder after a
# successful hard apply.
sed -i 's/^ENFORCEMENT_MODE=.*/ENFORCEMENT_MODE="hard"/' /opt/supply-gate/runtime/state.conf
code=$(rc_of ./install.sh status --scope machine)
[ "$code" = "2" ] && ok "status exit 2 (manual action)" || no "status exit $code, expected 2"
grep -q "mode.registries" /tmp/last.log \
  && ok "names mode.registries" || no "does not name mode.registries"
grep -q "Manual action required" /tmp/last.log \
  && ok "reported as manual, not repairable" || no "not reported as manual"

step "13. uninstall.sh --scope all"
rc_of ./install.sh apply --scope machine --mode soft >/dev/null
code=$(rc_of ./uninstall.sh --scope all)
[ "$code" = "0" ] && ok "uninstall.sh exit 0" || no "uninstall.sh exit $code"
[ -f /etc/profile.d/supply-gate.sh ] && no "profile.d left behind" || ok "profile.d removed"
[ -d /opt/supply-gate ] && no "/opt/supply-gate left behind" || ok "/opt/supply-gate removed"
for f in /etc/bashrc /etc/bash.bashrc /etc/zsh/zlogin /home/alice/.zshrc; do
  grep -q "supply-chain-protect" "$f" 2>/dev/null \
    && no "block left in $f" || ok "block removed from $f"
done
grep -q "alice's own line" /home/alice/.zshrc 2>/dev/null \
  && ok "alice's own content preserved" || no "alice's own content destroyed"
code=$(rc_of ./install.sh status)
[ "$code" = "2" ] && ok "status exit 2 after uninstall" || no "status exit $code, expected 2"

printf '\n=====================================\nPASS=%s  FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
