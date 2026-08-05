#!/bin/sh
# Convenience entry point: `./uninstall.sh` reads better than
# `./install.sh uninstall`, which looks like a contradiction on an operator's
# screen and in a runbook.
#
# This is a thin delegation, NOT a second implementation. All removal logic
# stays in install.sh (uninstall_cmd / uninstall_user_cmd / uninstall_machine_cmd)
# so there is exactly one place where managed blocks and state are removed.
# The `install.sh uninstall` subcommand keeps working unchanged, because the
# .deb prerm hook (build/deb/debian/prerm) and any existing KACE job call it by
# that name.
#
# Usage:
#   ./uninstall.sh                      # user scope (machine scope if run as root)
#   ./uninstall.sh --scope user
#   sudo ./uninstall.sh --scope machine
#   sudo ./uninstall.sh --scope all

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ ! -x "$SCRIPT_DIR/install.sh" ]; then
  echo "ERROR: $SCRIPT_DIR/install.sh not found or not executable" >&2
  exit 1
fi

exec "$SCRIPT_DIR/install.sh" uninstall "$@"
