#!/bin/sh
# Run every unit test file. Exits non-zero if any file failed.
#   sh tests/run.sh
#
# These run against temp trees and never touch the real system. For end-to-end
# coverage (real root, real /etc, zsh login shells) use tests/docker/run.sh.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
rc=0

for t in "$SCRIPT_DIR"/test_*.sh; do
  printf '\n================ %s ================\n' "$(basename "$t")"
  if ! sh "$t"; then
    rc=1
  fi
done

printf '\n'
if [ "$rc" = "0" ]; then
  printf 'all test files passed\n'
else
  printf 'SOME TEST FILES FAILED\n'
fi
exit "$rc"
