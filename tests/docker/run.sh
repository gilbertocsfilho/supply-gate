#!/bin/sh
# End-to-end validation in throwaway containers: real root, real /etc, real
# login shells (bash and zsh), multiple local users.
#
#   sh tests/docker/run.sh              # all lanes
#   sh tests/docker/run.sh ubuntu       # one lane
#
# The repo is mounted read-only, so a lane can never modify the working tree.
# Each lane is bounded, and a lane whose distro mirror will not serve zsh is
# reported as SKIP rather than FAIL -- half the scenario is about zsh, so such
# a lane tested nothing and calling that a Supply Gate failure is wrong. A run
# where EVERY lane skipped still fails: skipping is only tolerable while at
# least one lane actually asserted something.

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
passed=0
ran=0

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

  # Bounded. Step 0 of the scenario runs apt-get against a distro mirror, and a
  # mirror that accepts the connection then stalls hangs the lane forever: on a
  # CI runner that means the whole job is cancelled at its timeout, with a
  # truncated log that shows only where it stopped and no matrix summary at
  # all. A stall is reported as a stall instead (timeout exits 124), so the
  # remaining lanes still run and still report.
  if timeout --kill-after=30 600 \
       docker run --rm -v "$REPO_ROOT":/src:ro "$image" \
       sh -c "$pre sh /src/tests/docker/scenario.sh"; then
    results="$results
  PASS  $lane"
    passed=$((passed + 1))
    ran=$((ran + 1))
  else
    code=$?
    # 124 = timeout sent SIGTERM; 137 = it had to escalate to SIGKILL, which
    # is what `docker run` produces because it does not exit on SIGTERM here.
    if [ "$code" = "99" ]; then
      # The scenario declined to run: it could not get zsh from the distro
      # mirror, so it tested nothing. Not this project's failure.
      results="$results
  SKIP  $lane (distro mirror would not serve zsh)"
    elif [ "$code" = "124" ] || [ "$code" = "137" ]; then
      results="$results
  FAIL  $lane (TIMED OUT after 600s -- distro mirror or network stall)"
      rc=1
      ran=$((ran + 1))
    else
      results="$results
  FAIL  $lane (exit $code)"
      rc=1
      ran=$((ran + 1))
    fi
  fi
done

printf '\n############ matrix ############%s\n' "$results"

# A run where every lane skipped is not a pass. Skipping is only tolerable
# while at least one lane actually asserted something.
if [ "$passed" = "0" ] && [ "$rc" = "0" ]; then
  printf '\nNO LANE RAN -- every lane skipped, so nothing was verified.\n' >&2
  rc=1
fi
exit "$rc"
