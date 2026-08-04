#!/bin/sh
# Builds dist/supply-gate_<VERSION>_all.deb from the repo root's VERSION file
# and this directory's debian/ control data. Run from anywhere; paths are
# resolved relative to this script. Requires dpkg-deb (any Debian/Ubuntu box
# has it already -- no extra packages to install).
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
DIST_DIR="$SCRIPT_DIR/dist"
PKGROOT="$DIST_DIR/pkgroot"

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "ERROR: dpkg-deb not found. Build on a Debian/Ubuntu host (or in a container based on one)." >&2
  exit 1
fi

VERSION=$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")
if [ -z "$VERSION" ]; then
  echo "ERROR: $REPO_ROOT/VERSION is empty" >&2
  exit 1
fi

echo "Building supply-gate ${VERSION} (.deb)..."

rm -rf "$PKGROOT"
mkdir -p "$PKGROOT/DEBIAN" "$PKGROOT/usr/share/supply-gate"

# Payload: the production runtime only -- no tests/, docker/, fleet/,
# compose.yaml, .env.example (dev/reference material, not needed on a
# managed endpoint). policy/local-policy.conf never ships: it's
# machine-specific and gitignored, never present in a checkout to copy.
PAYLOAD_ITEMS="install.sh lib shims scripts policy README.md GUIDE.md VERSION"
for item in $PAYLOAD_ITEMS; do
  cp -a "$REPO_ROOT/$item" "$PKGROOT/usr/share/supply-gate/$item"
done
# Never ship a local-policy.conf even if the builder's checkout has one staged.
rm -f "$PKGROOT/usr/share/supply-gate/policy/local-policy.conf"

sed "s/@VERSION@/$VERSION/" "$SCRIPT_DIR/debian/control.in" >"$PKGROOT/DEBIAN/control"
for hook in postinst prerm postrm; do
  cp "$SCRIPT_DIR/debian/$hook" "$PKGROOT/DEBIAN/$hook"
  chmod 755 "$PKGROOT/DEBIAN/$hook"
done

find "$PKGROOT/usr/share/supply-gate" -type f -name '*.sh' -exec chmod 755 {} \;
chmod 755 "$PKGROOT/usr/share/supply-gate/install.sh"

mkdir -p "$DIST_DIR"
DEB_FILE="$DIST_DIR/supply-gate_${VERSION}_all.deb"
dpkg-deb --build --root-owner-group "$PKGROOT" "$DEB_FILE" >/dev/null

echo "Built: $DEB_FILE"
if command -v lintian >/dev/null 2>&1; then
  echo "--- lintian ---"
  lintian "$DEB_FILE" || true
fi
