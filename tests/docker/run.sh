#!/bin/sh
# End-to-end validation in throwaway containers: real root, real /etc, real
# login shells (bash and zsh), multiple local users.
#
#   sh tests/docker/run.sh              # all lanes
#   sh tests/docker/run.sh ubuntu       # one lane
#
# The repo is mounted read-only, so a lane can never modify the working tree.
# Fedora is included but needs network access to its mirrors; if metadata
# download fails the lane is reported as skipped, not failed.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

# lane:image
LANES="ubuntu:ubuntu:24.04
debian:debian:12
macos-layout:ubuntu:24.04"

want=${1:-}
results=""
rc=0

for entry in $LANES; do
  lane=${entry%%:*}
  image=${entry#*:}
  [ -z "$want" ] || [ "$want" = "$lane" ] || continue

  printf '\n############ lane: %s (%s) ############\n' "$lane" "$image"

  # macos-layout forces the file layout macOS uses (sysconfdir=/etc, no
  # /etc/zsh) so the arm real Macs take is exercised. It cannot make Ubuntu's
  # zsh *read* /etc/zshrc -- that is compiled in -- so it asserts on which
  # files apply writes, which is what our code decides.
  pre=""
  if [ "$lane" = "macos-layout" ]; then
    pre='rm -rf /etc/zsh; : >/etc/zshrc;'
  fi

  if docker run --rm -v "$REPO_ROOT":/src:ro "$image" \
       sh -c "$pre sh /src/tests/docker/scenario.sh"; then
    results="$results
  PASS  $lane"
  else
    code=$?
    results="$results
  FAIL  $lane (exit $code)"
    rc=1
  fi
done

printf '\n############ matrix ############%s\n' "$results"
exit "$rc"
