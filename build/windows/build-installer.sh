#!/bin/sh
# Builds dist/SupplyGate-<VERSION>-setup.exe from the repo root's VERSION
# file and this directory's supply-gate.nsi. Uses NSIS (`makensis`), which
# compiles the same on Linux or Windows -- no WiX/dotnet/MSI toolchain, and
# no Windows host needed to build (only to actually install and test the
# output, which has been done for real -- see docs/windows-support.md).
#
# One-time setup if `makensis` isn't already on PATH:
#   sudo apt-get install nsis   (Debian/Ubuntu)
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
DIST_DIR="$SCRIPT_DIR/dist"

if ! command -v makensis >/dev/null 2>&1; then
  echo "ERROR: makensis (NSIS) not found on PATH." >&2
  echo "Install with: sudo apt-get install nsis" >&2
  exit 1
fi

VERSION=$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")
if [ -z "$VERSION" ]; then
  echo "ERROR: $REPO_ROOT/VERSION is empty" >&2
  exit 1
fi

echo "Building Supply Gate ${VERSION} (.exe)..."

mkdir -p "$DIST_DIR"

makensis -DVERSION="$VERSION" "$SCRIPT_DIR/supply-gate.nsi"

echo "Built: $DIST_DIR/SupplyGate-${VERSION}-setup.exe"
