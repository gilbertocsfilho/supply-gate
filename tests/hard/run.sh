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

SCP_TEST_ALLOW_DESTRUCTIVE=1 sh "$SCRIPT_DIR/scenario.sh" || rc=1

printf '\n############ nginx routing evidence ############\n'
sh "$SCRIPT_DIR/stack.sh" logs || true

cleanup
exit "$rc"
