#!/bin/sh
# Hard mode, validated against the real proxy stack.
#
# Runs INSIDE the machine under test as root: it writes /etc, /opt and
# policy/local-policy.conf, so it refuses to start unless it is told the host
# is disposable. Invoked by tests/hard/run.sh, which brings compose.yaml up
# and maps the four corporate hostnames at 127.0.0.1 first.
#
# What only this lane can prove: soft mode needs no upstream services, so
# every other test can pass with the registries unreachable. Hard mode is the
# mode whose whole point is that installs resolve through the corporate proxy
# -- that claim is only tested by making a package manager actually fetch a
# package and then reading it back out of nginx's access log.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

if [ "${SCP_TEST_ALLOW_DESTRUCTIVE:-0}" != "1" ]; then
  echo "REFUSING: this installs Supply Gate for real (machine scope, /etc + /opt)." >&2
  echo "Run tests/hard/run.sh, or set SCP_TEST_ALLOW_DESTRUCTIVE=1 on a disposable host." >&2
  exit 1
fi
if [ "$(id -u)" != "0" ]; then
  echo "REFUSING: must run as root (machine scope)." >&2
  exit 1
fi

NPM_URL="http://npm-proxy.corp.example/"
PIP_URL="http://pypi-proxy.corp.example/root/pypi/+simple/"
CARGO_URL="sparse+http://cargo-proxy.corp.example/api/v1/crates/"
GO_URL="http://go-proxy.corp.example/"

LOCAL_POLICY="$REPO_ROOT/policy/local-policy.conf"
LOCAL_POLICY_BACKUP="/tmp/supply-gate-local-policy.bak.$$"
JAIL_STUB=/usr/local/bin/supply-gate-test-jail
WORK=/tmp/supply-gate-hard-work

PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
no()   { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  SKIP  %s\n' "$1"; }
step() { printf '\n=== %s ===\n' "$1"; }

# Exit code of a command without set -e aborting; output kept in /tmp/last.log.
rc_of() {
  "$@" >/tmp/last.log 2>&1
  printf '%s' "$?"
}

# Same, but bounded. A package manager talking to a proxy that accepts the
# connection and then stalls will wait far longer than any CI job allows (npm
# alone retries a 5-minute fetch timeout twice), and a lane that hangs teaches
# nothing -- it just burns the job timeout and produces no log. `timeout`
# reports 124, which the callers surface as a stall rather than a plain
# failure.
rc_of_timed() {
  _rt_secs=$1
  shift
  timeout "$_rt_secs" "$@" >/tmp/last.log 2>&1
  printf '%s' "$?"
}

report_op() {
  case "$2" in
    0)   ok "$1" ;;
    124) no "$1 -- TIMED OUT, the proxy accepted the connection and stalled"
         tail -20 /tmp/last.log | sed 's/^/    /' ;;
    *)   no "$1 (exit $2)"
         tail -20 /tmp/last.log | sed 's/^/    /' ;;
  esac
}

nginx_log() { sh "$SCRIPT_DIR/stack.sh" log "$1" 2>/dev/null; }

# curl writes the code and THEN exits non-zero on a connection failure, so an
# `|| echo 000` fallback would append a second one ("000000").
http_code() {
  _hc=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$1" 2>/dev/null || true)
  case "$_hc" in
    ''|*[!0-9]*) _hc=000 ;;
  esac
  printf '%s' "$_hc"
}

# A request that nginx routed to this vhost AND the upstream answered for.
# The log format ends with us="<upstream status>", so a 502 with no upstream
# would not match -- this is proof of a real proxied fetch, not just a hit.
proxy_served() {
  nginx_log "$1" | grep -E "$2" | grep -vE 'us="-"' >/dev/null 2>&1
}

write_local_policy() {
  cat >"$LOCAL_POLICY" <<POLEOF
# Written by tests/hard/scenario.sh -- points hard mode at the local
# compose.yaml proxy stack. Removed again when the scenario finishes.
NPM_REGISTRY_URL="$NPM_URL"
PYTHON_INDEX_URL="$PIP_URL"
CARGO_REGISTRY_URL="$CARGO_URL"
GO_PROXY_URL="$GO_URL"
$1
POLEOF
}

cleanup() {
  rm -f "$LOCAL_POLICY"
  if [ -f "$LOCAL_POLICY_BACKUP" ]; then
    cp "$LOCAL_POLICY_BACKUP" "$LOCAL_POLICY"
    rm -f "$LOCAL_POLICY_BACKUP"
  fi
  rm -f "$JAIL_STUB"
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

[ -f "$LOCAL_POLICY" ] && cp "$LOCAL_POLICY" "$LOCAL_POLICY_BACKUP"
mkdir -p "$WORK"
cd "$REPO_ROOT" || exit 1

# ---------------------------------------------------------------------------
step "0. the four proxy vhosts answer through nginx"
# ---------------------------------------------------------------------------
for pair in "npm-proxy.corp.example:/-/ping" \
            "pypi-proxy.corp.example:/root/pypi/+simple/" \
            "go-proxy.corp.example:/healthz" \
            "cargo-proxy.corp.example:/"; do
  host=${pair%%:*}
  path=${pair#*:}
  code=$(http_code "http://$host$path")
  case "$code" in
    2*|3*|4*) ok "$host$path -> HTTP $code" ;;
    *)        no "$host$path -> HTTP $code (stack not reachable)" ;;
  esac
done

# ---------------------------------------------------------------------------
step "1. hard mode is refused while the policy still has placeholder URLs"
# ---------------------------------------------------------------------------
rm -f "$LOCAL_POLICY"
code=$(rc_of ./install.sh apply --scope machine --mode hard)
if [ "$code" != "0" ]; then
  ok "apply --mode hard refused the shipped placeholders (exit $code)"
else
  no "apply --mode hard accepted registry.example.corp placeholders"
fi

# ---------------------------------------------------------------------------
step "2. apply --scope machine --mode hard with the proxy URLs"
# ---------------------------------------------------------------------------
write_local_policy ""
code=$(rc_of ./install.sh apply --scope machine --mode hard)
if [ "$code" = "0" ]; then
  ok "apply --mode hard exit 0"
else
  no "apply --mode hard exit $code"
  tail -20 /tmp/last.log | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
step "3. every package manager is pinned to its proxy, on disk"
# ---------------------------------------------------------------------------
grep -qF "registry=$NPM_URL" /root/.npmrc 2>/dev/null \
  && ok "/root/.npmrc pins the npm registry" || no "/root/.npmrc does not pin the registry"
grep -qF "index-url = $PIP_URL" /root/.config/pip/pip.conf 2>/dev/null \
  && ok "pip.conf pins index-url" || no "pip.conf does not pin index-url"
grep -qF "replace-with = \"corporate\"" /root/.cargo/config.toml 2>/dev/null \
  && ok "cargo config replaces the crates-io source" || no "cargo config does not replace crates-io"
grep -qF "registry = \"$CARGO_URL\"" /root/.cargo/config.toml 2>/dev/null \
  && ok "cargo config points at kellnr" || no "cargo config does not point at kellnr"
goproxy=$(go env GOPROXY 2>/dev/null | tr -d '\r')
[ "$goproxy" = "$GO_URL" ] \
  && ok "go env GOPROXY = $goproxy" || no "go env GOPROXY = '$goproxy', expected $GO_URL"

# The soft-mode value must NOT be what a hard apply leaves behind.
case "$goproxy" in
  *proxy.golang.org*) no "GOPROXY still carries the soft-mode public proxy" ;;
  *)                  ok "no public Go proxy left in GOPROXY" ;;
esac

# ---------------------------------------------------------------------------
step "4. hard mode fails CLOSED for AI CLIs while no jail launcher exists"
# ---------------------------------------------------------------------------
# The fake goes in a directory prepended to PATH for these invocations only,
# so it wins over any real claude the host happens to ship -- the wrapper
# resolves the real binary live off PATH, so whichever comes first decides.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho "REAL-CLAUDE-RAN args=$*"\n' >"$WORK/bin/claude"
chmod 755 "$WORK/bin/claude"
code=$(rc_of env "PATH=$WORK/bin:$PATH" /opt/supply-gate/shims/claude --version)
if [ "$code" != "0" ]; then
  ok "claude blocked in hard mode with no launcher (exit $code)"
else
  no "claude ran in hard mode with no jail launcher configured"
fi
grep -q '"event":"command.blocked"' /opt/supply-gate/logs/events.jsonl 2>/dev/null \
  && ok "block recorded in events.jsonl" || no "no command.blocked event recorded"
code=$(rc_of ./install.sh status --scope machine)
[ "$code" = "2" ] && ok "status exit 2 (manual action) while the jail is unconfigured" \
  || no "status exit $code, expected 2"
grep -q "jail" /tmp/last.log && ok "status names the jail section" || no "status does not name jail"

# ---------------------------------------------------------------------------
step "5. with a launcher configured, hard mode jails instead of blocking"
# ---------------------------------------------------------------------------
# Stands in for ai-jail: same contract (argv is REAL_BIN then the rest), so
# the wrapper's launcher path is exercised without installing a sandbox.
cat >"$JAIL_STUB" <<'JAILEOF'
#!/bin/sh
echo "JAILED-BY-STUB"
real=$1
shift
exec "$real" "$@"
JAILEOF
chmod 755 "$JAIL_STUB"
write_local_policy "AI_JAIL_LAUNCHER_LINUX=\"$JAIL_STUB\""
code=$(rc_of ./install.sh apply --scope machine --mode hard)
[ "$code" = "0" ] && ok "re-apply exit 0" || { no "re-apply exit $code"; tail -10 /tmp/last.log | sed 's/^/    /'; }

out=$(PATH="$WORK/bin:$PATH" /opt/supply-gate/shims/claude --version 2>&1)
printf '%s' "$out" | grep -q "JAILED-BY-STUB" \
  && ok "claude went through the jail launcher" || no "claude did not go through the launcher"
printf '%s' "$out" | grep -q "REAL-CLAUDE-RAN args=--version" \
  && ok "real claude reached with args intact" || no "real claude did not run"
grep -q '"event":"command.jailed"' /opt/supply-gate/logs/events.jsonl 2>/dev/null \
  && ok "command.jailed recorded" || no "no command.jailed event"

code=$(rc_of ./install.sh status --scope machine)
if [ "$code" = "0" ]; then
  ok "status exit 0 (healthy) in hard mode against the live proxies"
else
  no "status exit $code, expected 0"
  sed 's/^/    /' /tmp/last.log
fi
code=$(rc_of ./install.sh audit --scope machine)
[ "$code" = "0" ] && ok "audit exit 0" || { no "audit exit $code"; tail -20 /tmp/last.log | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
step "6. real installs actually travel through the proxies"
# ---------------------------------------------------------------------------

# --- npm -------------------------------------------------------------------
if command -v npm >/dev/null 2>&1; then
  mkdir -p "$WORK/node" && (cd "$WORK/node" && printf '{"name":"t","version":"1.0.0"}\n' >package.json)
  code=$(cd "$WORK/node" && rc_of_timed 180 /opt/supply-gate/shims/npm install lodash \
    --no-audit --no-fund --fetch-timeout=30000 --fetch-retries=1)
  if [ "$code" = "0" ] && [ ! -d "$WORK/node/node_modules/lodash" ]; then
    code=1
  fi
  report_op "npm install lodash succeeded through the shim" "$code"
  proxy_served npm-proxy '"GET /lodash' \
    && ok "verdaccio served the lodash metadata (nginx npm vhost)" \
    || no "no lodash metadata request in the npm vhost access log"
  proxy_served npm-proxy '\.tgz' \
    && ok "the tarball itself came from the proxy" \
    || no "no tarball request in the npm vhost access log"
else
  skip "npm not installed on this host"
fi

# --- pip -------------------------------------------------------------------
pip_tool=""
for candidate in pip3 pip; do
  command -v "$candidate" >/dev/null 2>&1 && { pip_tool=$candidate; break; }
done
if [ -n "$pip_tool" ]; then
  # download, not install: it exercises the index exactly the same way without
  # tripping PEP 668 on a system Python.
  #
  # --trusted-host is a property of THIS STACK, not of hard mode: compose.yaml
  # terminates plain HTTP on purpose to keep local bootstrap simple (see
  # docker/README.md), and pip ignores a plain-HTTP index unless told to trust
  # it. A real rollout puts TLS on the internal proxy and needs none of this,
  # which is why install.sh does not emit a trusted-host line.
  code=$(rc_of_timed 180 "/opt/supply-gate/shims/$pip_tool" download six --no-deps \
    --timeout 20 --retries 1 --trusted-host pypi-proxy.corp.example --dest "$WORK/pip")
  report_op "$pip_tool download six succeeded through the shim" "$code"
  proxy_served pypi-proxy '/root/pypi/\+simple/six' \
    && ok "devpi served the six index (nginx pypi vhost)" \
    || no "no six index request in the pypi vhost access log"
else
  skip "no pip on this host"
fi

# --- go --------------------------------------------------------------------
if command -v go >/dev/null 2>&1; then
  mkdir -p "$WORK/go"
  cat >"$WORK/go/go.mod" <<'GOEOF'
module example.com/supplygate/hardmode

go 1.21

require github.com/pkg/errors v0.9.1
GOEOF
  code=$(cd "$WORK/go" && rc_of_timed 240 env GOFLAGS=-mod=mod GOPATH="$WORK/gopath" \
    /opt/supply-gate/shims/go mod download github.com/pkg/errors)
  report_op "go mod download succeeded through the shim" "$code"
  proxy_served go-proxy '/github.com/pkg/errors/@v/' \
    && ok "athens served the module (nginx go vhost)" \
    || no "no module request in the go vhost access log"
else
  skip "go not installed on this host"
fi

# --- cargo -----------------------------------------------------------------
# kellnr is a private registry, not a crates.io mirror, so a real `cargo add`
# of a public crate cannot succeed against this stack -- and making it succeed
# by falling back to crates.io would defeat the point of the test. What is
# asserted instead: the source replacement is on disk (step 3) and the sparse
# index endpoint really answers through nginx.
code=$(http_code "http://cargo-proxy.corp.example/api/v1/crates/")
case "$code" in
  2*|3*|4*) ok "kellnr sparse index endpoint answers through nginx (HTTP $code)" ;;
  *)        no "kellnr sparse index endpoint returned HTTP $code" ;;
esac
if command -v cargo >/dev/null 2>&1; then
  out=$(/opt/supply-gate/shims/cargo --version 2>&1)
  # Assert INTERCEPTION, not that the host's cargo happens to be runnable
  # here. On a GitHub runner cargo is a rustup shim belonging to the
  # unprivileged user, so invoking it as root (different HOME, no RUSTUP_HOME)
  # makes rustup itself refuse -- "could not choose a version of cargo to run"
  # -- which says nothing about Supply Gate. What has to hold is that the shim
  # caught the call and resolved past itself to the real binary.
  printf '%s' "$out" | grep -q 'Intercepted command: cargo --version' \
    && ok "cargo intercepted by the shim" || no "cargo not intercepted: $out"
  printf '%s' "$out" | grep -q 'Delegating to real binary' \
    && ok "cargo delegated to the real binary" || no "cargo not delegated: $out"
else
  skip "cargo not installed on this host"
fi

# ---------------------------------------------------------------------------
step "7. every one of those runs left audit evidence"
# ---------------------------------------------------------------------------
for tool in npm go claude; do
  grep -q "\"tool\":\"$tool\"" /opt/supply-gate/logs/events.jsonl 2>/dev/null \
    && ok "events.jsonl records $tool" || no "events.jsonl has no $tool event"
done
grep -q '"event":"command.intercepted"' /opt/supply-gate/logs/events.jsonl 2>/dev/null \
  && ok "interception events present" || no "no interception events"

# ---------------------------------------------------------------------------
step "8. a placeholder creeping back into policy fails closed again"
# ---------------------------------------------------------------------------
sed -i 's#^NPM_REGISTRY_URL=.*#NPM_REGISTRY_URL="https://registry.example.corp/npm/"#' "$LOCAL_POLICY"
code=$(rc_of ./install.sh status --scope machine)
[ "$code" = "2" ] && ok "status exit 2" || no "status exit $code, expected 2"
grep -q "mode.registries" /tmp/last.log \
  && ok "status names mode.registries" || no "status does not name mode.registries"
code=$(rc_of ./install.sh apply --scope machine --mode hard)
[ "$code" != "0" ] && ok "apply --mode hard refused again (exit $code)" \
  || no "apply --mode hard accepted a placeholder registry"
# And the wrapper refuses at runtime too, not just at apply time. It reads the
# installed runtime copy of the policy (that is the whole point of installing
# one), so the placeholder has to be introduced there to test that path -- the
# state a host lands in when policy is edited after a successful hard apply.
sed -i 's#^NPM_REGISTRY_URL=.*#NPM_REGISTRY_URL="https://registry.example.corp/npm/"#' \
  /opt/supply-gate/runtime/policy.conf
code=$(rc_of /opt/supply-gate/shims/npm --version)
[ "$code" != "0" ] && ok "the wrapper itself blocks npm on a placeholder registry" \
  || no "the wrapper ran npm with a placeholder registry in hard mode"

# ---------------------------------------------------------------------------
step "9. uninstall leaves nothing behind"
# ---------------------------------------------------------------------------
code=$(rc_of ./uninstall.sh --scope all)
[ "$code" = "0" ] && ok "uninstall exit 0" || no "uninstall exit $code"
[ -d /opt/supply-gate ] && no "/opt/supply-gate left behind" || ok "/opt/supply-gate removed"
grep -q "supply-chain-protect" /root/.npmrc 2>/dev/null \
  && no "managed block left in /root/.npmrc" || ok "managed block removed from /root/.npmrc"

printf '\n=====================================\nPASS=%s  FAIL=%s  SKIP=%s\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = "0" ]
