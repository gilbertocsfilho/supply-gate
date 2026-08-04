#!/bin/sh
# Builds dist/supply-gate-<VERSION>.pkg and .dmg. MUST run on an actual Mac
# (or a macOS CI runner, e.g. GitHub Actions `macos-latest`): pkgbuild,
# productbuild and hdiutil are part of Apple's Xcode Command Line Tools and
# have no equivalent outside Darwin -- there is no way to produce a real,
# installable .pkg from Linux. Running `xcode-select --install` once gets
# these tools on any Mac that doesn't already have them.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
DIST_DIR="$SCRIPT_DIR/dist"
PAYLOAD_ROOT="$DIST_DIR/payload-root"
IDENTIFIER="com.tempest.supply-gate"
INSTALL_LOCATION="/usr/local/share/supply-gate"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: this must run on macOS -- pkgbuild/productbuild/hdiutil don't exist on $(uname -s)." >&2
  echo "Run it on a Mac, or a macOS CI runner (e.g. GitHub Actions macos-latest)." >&2
  exit 1
fi

for tool in pkgbuild productbuild hdiutil; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool not found. Install Xcode Command Line Tools: xcode-select --install" >&2
    exit 1
  fi
done

VERSION=$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")
if [ -z "$VERSION" ]; then
  echo "ERROR: $REPO_ROOT/VERSION is empty" >&2
  exit 1
fi

echo "Building supply-gate ${VERSION} (.pkg/.dmg)..."

rm -rf "$PAYLOAD_ROOT"
mkdir -p "$PAYLOAD_ROOT$INSTALL_LOCATION"

# Same production-only payload as build/deb/build-deb.sh -- see that script's
# comment for what's deliberately left out (tests/, docker/, local-policy.conf).
PAYLOAD_ITEMS="install.sh lib shims scripts policy README.md GUIDE.md VERSION"
for item in $PAYLOAD_ITEMS; do
  cp -a "$REPO_ROOT/$item" "$PAYLOAD_ROOT$INSTALL_LOCATION/$item"
done
rm -f "$PAYLOAD_ROOT$INSTALL_LOCATION/policy/local-policy.conf"
chmod 755 "$PAYLOAD_ROOT$INSTALL_LOCATION/install.sh"
find "$PAYLOAD_ROOT$INSTALL_LOCATION" -type f -name '*.sh' -exec chmod 755 {} \;

mkdir -p "$DIST_DIR"
COMPONENT_PKG="$DIST_DIR/supply-gate-component.pkg"
FINAL_PKG="$DIST_DIR/supply-gate-${VERSION}.pkg"
FINAL_DMG="$DIST_DIR/supply-gate-${VERSION}.dmg"

pkgbuild \
  --root "$PAYLOAD_ROOT" \
  --scripts "$SCRIPT_DIR/scripts" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location "/" \
  "$COMPONENT_PKG"

productbuild \
  --package "$COMPONENT_PKG" \
  "$FINAL_PKG"

rm -f "$COMPONENT_PKG"

DMG_STAGING="$DIST_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp "$FINAL_PKG" "$DMG_STAGING/"
hdiutil create \
  -volname "Supply Gate ${VERSION}" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$FINAL_DMG"
rm -rf "$DMG_STAGING"

echo "Built: $FINAL_PKG"
echo "Built: $FINAL_DMG"
echo
echo "NOTE: macOS .pkg has no built-in uninstaller. To remove supply-gate from a"
echo "machine, run: $INSTALL_LOCATION/install.sh uninstall --scope machine"
