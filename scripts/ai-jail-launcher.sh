#!/bin/sh
# supply-gate -> ai-jail launcher adapter.
#
# The manager wrapper invokes a configured AI jail launcher as:
#     AI_JAIL_LAUNCHER "$real_bin" "$@"
# i.e. the real tool binary path followed by the user's arguments, with
# SCP_IN_AIJAIL=1 already exported.
#
# We translate that into ai-jail's *preset* form (`ai-jail claude ...`,
# `ai-jail gemini ...`, ...) so the tool-specific sandbox profile is applied,
# instead of `ai-jail /abs/path/to/claude` which ai-jail would treat as a
# generic passthrough command and run WITHOUT the preset.
#
# ai-jail then runs the tool by name inside the jail, which resolves back to
# our shim -> manager wrapper. Because SCP_IN_AIJAIL=1 is set, that wrapper
# delegates straight to the real binary instead of recursing into a new jail.
set -eu

if [ "$#" -lt 1 ]; then
  echo "ai-jail-launcher.sh: missing real binary argument" >&2
  exit 2
fi

real_bin=$1
shift
tool=$(basename "$real_bin")

if ! command -v ai-jail >/dev/null 2>&1; then
  echo "ai-jail-launcher.sh: 'ai-jail' not found on PATH" >&2
  exit 127
fi

exec ai-jail "$tool" "$@"
