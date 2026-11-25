#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RAW_VERSION="${1:-${VERSION:-0.2.0}}"
CLEAN_VERSION="${RAW_VERSION#v}"
PKG_VERSION="$(echo "$CLEAN_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*$/\1/')"
if [[ ! "$PKG_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  PKG_VERSION="0.2.0"
fi

ARCH="${BIANZHONG_ARCH:-arm64}"
ARTIFACT_BASE="Bianzhong-${CLEAN_VERSION}-macos26-${ARCH}"

VERSION="$CLEAN_VERSION" bash "$ROOT_DIR/scripts/bundle-app.sh"

RELEASE_DIR="$ROOT_DIR/dist/release"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

STAGE_DIR="$(mktemp -d /tmp/bz-release-XXXXXX)"
cleanup() {
  if [[ -d "$STAGE_DIR/mnt" ]]; then
    hdiutil detach "$STAGE_DIR/mnt" -force -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

# 1. Build macOS Installer (.pkg) installing Bianzhong.app into /Applications and symlink /usr/local/bin/bz
PKGROOT="$STAGE_DIR/pkgroot"
mkdir -p "$PKGROOT/Applications" "$PKGROOT/usr/local/bin"
ditto "$ROOT_DIR/dist/Bianzhong.app" "$PKGROOT/Applications/Bianzhong.app"
ln -sf "/Applications/Bianzhong.app/Contents/MacOS/bz" "$PKGROOT/usr/local/bin/bz"

COMPONENTS_PLIST="$STAGE_DIR/components.plist"
pkgbuild --analyze --root "$PKGROOT" "$COMPONENTS_PLIST"
idx=0
while /usr/libexec/PlistBuddy -c "Print :$idx" "$COMPONENTS_PLIST" >/dev/null 2>&1; do
  if /usr/libexec/PlistBuddy -c "Print :$idx:BundleIsRelocatable" "$COMPONENTS_PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$idx:BundleIsRelocatable false" "$COMPONENTS_PLIST"
  fi
  idx=$((idx + 1))
done
plutil -lint "$COMPONENTS_PLIST"

PKG_PATH="$RELEASE_DIR/${ARTIFACT_BASE}.pkg"
PKG_ARGS=(
  --root "$PKGROOT"
  --component-plist "$COMPONENTS_PLIST"
  --identifier "dev.bianzhong.pkg"
  --version "$PKG_VERSION"
  --install-location "/"
)
if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
  PKG_ARGS+=(--sign "$INSTALLER_SIGN_IDENTITY")
fi
pkgbuild "${PKG_ARGS[@]}" "$PKG_PATH"

# 2. Build single-app drag-and-drop macOS Disk Image (.dmg)
VOL_NAME="Bianzhong ${CLEAN_VERSION}"
RW_DMG="$STAGE_DIR/rw.dmg"
MOUNT_DIR="$STAGE_DIR/mnt"
mkdir -p "$MOUNT_DIR"

hdiutil create \
  -size 48m \
  -fs HFS+ \
  -volname "$VOL_NAME" \
  -nospotlight \
  -type UDIF \
  -ov \
  "$RW_DMG"

hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  -nobrowse \
  -mountpoint "$MOUNT_DIR" \
  "$RW_DMG"

ditto "$ROOT_DIR/dist/Bianzhong.app" "$MOUNT_DIR/Bianzhong.app"
ln -s /Applications "$MOUNT_DIR/Applications"
cp "$ROOT_DIR/dist/Bianzhong.app/Contents/Resources/AppIcon.icns" "$MOUNT_DIR/.VolumeIcon.icns"

swift "$ROOT_DIR/scripts/generate-installer-assets.swift" \
  --dmg-bg "$MOUNT_DIR/.background.tiff"

chflags hidden "$MOUNT_DIR/.background.tiff" "$MOUNT_DIR/.VolumeIcon.icns" || true
SETFILE_BIN="$(command -v SetFile || xcrun --find SetFile 2>/dev/null || true)"
if [[ -n "$SETFILE_BIN" ]]; then
  "$SETFILE_BIN" -a V "$MOUNT_DIR/.background.tiff" "$MOUNT_DIR/.VolumeIcon.icns" || true
  "$SETFILE_BIN" -a C "$MOUNT_DIR" || true
fi
xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$MOUNT_DIR"

/usr/bin/python3 "$ROOT_DIR/scripts/build-dmg-dsstore.py" \
  --mount-dir "$MOUNT_DIR" \
  --vol-name "$VOL_NAME" \
  --bg-filename ".background.tiff" \
  --app-name "Bianzhong.app" \
  --verify

rm -rf "$MOUNT_DIR/.fseventsd" "$MOUNT_DIR/.Trashes" 2>/dev/null || true
sync
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet

DMG_PATH="$RELEASE_DIR/${ARTIFACT_BASE}.dmg"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH"
rm -f "$RW_DMG"

# 3. Build portable tarball (.tar.gz)
TARROOT="$STAGE_DIR/tar/Bianzhong-${CLEAN_VERSION}"
mkdir -p "$TARROOT"
ditto "$ROOT_DIR/dist/Bianzhong.app" "$TARROOT/Bianzhong.app"
cp -R "$ROOT_DIR/templates" "$TARROOT/templates"
cp "$ROOT_DIR/README.md" "$TARROOT/README.md"
[[ -f "$ROOT_DIR/README.en.md" ]] && cp "$ROOT_DIR/README.en.md" "$TARROOT/README.en.md"

TAR_PATH="$RELEASE_DIR/${ARTIFACT_BASE}.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$TAR_PATH" -C "$STAGE_DIR/tar" "Bianzhong-${CLEAN_VERSION}"

# 4. Generate SHA256 checksums
(
  cd "$RELEASE_DIR"
  shasum -a 256 \
    "$(basename "$PKG_PATH")" \
    "$(basename "$DMG_PATH")" \
    "$(basename "$TAR_PATH")" > SHA256SUMS.txt
)

echo "Release artifacts ready in $RELEASE_DIR:"
ls -lh "$RELEASE_DIR"
