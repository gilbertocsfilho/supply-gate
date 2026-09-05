#!/bin/sh
# Hard mode, end to end, against the real proxy stack.
#
#   sh tests/hard/run.sh
#
# Brings compose.yaml up (nginx + verdaccio + devpi + athens + kellnr), maps
# the four corporate hostnames at 127.0.0.1, then installs Supply Gate in hard
# mode on THIS machine and asserts that npm, pip and go really fetch through
# the proxies. Installing for real is the point -- run it on a disposable host
# (a CI runner, a VM), never on a workstation you care about.
#
# Needs root (machine scope, /etc/hosts, /opt) and docker.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "$(id -u)" != "0" ]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E env "PATH=$PATH" "HOME=/root" sh "$0" "$@"
  fi
  echo "ERROR: needs root (machine-scope install, /etc/hosts, docker)" >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: 'docker compose' is required" >&2
  exit 1
fi

rc=0
cleanup() { sh "$SCRIPT_DIR/stack.sh" down >/dev/null 2>&1 || true; }

if ! sh "$SCRIPT_DIR/stack.sh" up; then
  echo "ERROR: could not bring the proxy stack up" >&2
  cleanup
  exit 1
fi

# Outer bound as well as the per-operation ones inside: whatever stalls, the
# lane must still reach the routing evidence below and the teardown after it.
SCP_TEST_ALLOW_DESTRUCTIVE=1 timeout 900 sh "$SCRIPT_DIR/scenario.sh" || rc=$?
if [ "$rc" = "124" ]; then
  printf '\nSCENARIO TIMED OUT after 900s\n' >&2
  rc=1
elif [ "$rc" != "0" ]; then
  rc=1
fi

printf '\n############ nginx routing evidence ############\n'
sh "$SCRIPT_DIR/stack.sh" logs || true

cleanup
exit "$rc"
