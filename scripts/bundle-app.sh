#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then
  CONFIG="debug"
fi

CLEAN_VERSION="${VERSION:-0.1.0}"
CLEAN_VERSION="${CLEAN_VERSION#v}"

echo "Building Bianzhong ($CONFIG, version $CLEAN_VERSION)..."
swift build -c "$CONFIG"
BIN_DIR="$ROOT_DIR/.build/$CONFIG"

DIST_DIR="$ROOT_DIR/dist"
rm -rf "$DIST_DIR/Bianzhong.app" "$DIST_DIR/BianzhongFeishuSensor.app" "$DIST_DIR/bz"
mkdir -p "$DIST_DIR/Bianzhong.app/Contents/MacOS"
mkdir -p "$DIST_DIR/BianzhongFeishuSensor.app/Contents/MacOS"

cp "$ROOT_DIR/Sources/BianzhongApp/Info.plist" "$DIST_DIR/Bianzhong.app/Contents/Info.plist"
cp "$BIN_DIR/BianzhongApp" "$DIST_DIR/Bianzhong.app/Contents/MacOS/BianzhongApp"
cp "$BIN_DIR/bz" "$DIST_DIR/Bianzhong.app/Contents/MacOS/bz"
chmod 755 "$DIST_DIR/Bianzhong.app/Contents/MacOS/BianzhongApp" "$DIST_DIR/Bianzhong.app/Contents/MacOS/bz"

cp "$ROOT_DIR/Sources/bz-feishu-sensor/Info.plist" "$DIST_DIR/BianzhongFeishuSensor.app/Contents/Info.plist"
cp "$BIN_DIR/bz-feishu-sensor" "$DIST_DIR/BianzhongFeishuSensor.app/Contents/MacOS/bz-feishu-sensor"
chmod 755 "$DIST_DIR/BianzhongFeishuSensor.app/Contents/MacOS/bz-feishu-sensor"

cp "$BIN_DIR/bz" "$DIST_DIR/bz"
chmod 755 "$DIST_DIR/bz"

for plist in \
  "$DIST_DIR/Bianzhong.app/Contents/Info.plist" \
  "$DIST_DIR/BianzhongFeishuSensor.app/Contents/Info.plist"
do
  if /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CLEAN_VERSION" "$plist"
  fi
done

USE_HARDENED_RUNTIME=false
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  SIGN_ID="$CODESIGN_IDENTITY"
  if [[ "$SIGN_ID" != "-" ]]; then
    USE_HARDENED_RUNTIME=true
  fi
else
  LOCAL_HASH="$(security find-identity -v -p codesigning 2>/dev/null | grep -F '"Bianzhong Local Signer"' | head -n1 | sed -E 's/.*\) ([0-9A-F]{40}) .*/\1/' || true)"
  SIGN_ID="${LOCAL_HASH:--}"
fi

echo "Signing bundles with identity: $SIGN_ID (hardened_runtime=$USE_HARDENED_RUNTIME)"
if [[ "$USE_HARDENED_RUNTIME" == true ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$DIST_DIR/bz"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$DIST_DIR/Bianzhong.app/Contents/MacOS/bz"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$DIST_DIR/Bianzhong.app"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$DIST_DIR/BianzhongFeishuSensor.app"
else
  codesign --force --sign "$SIGN_ID" "$DIST_DIR/bz"
  codesign --force --sign "$SIGN_ID" "$DIST_DIR/Bianzhong.app/Contents/MacOS/bz"
  codesign --force --deep --sign "$SIGN_ID" "$DIST_DIR/Bianzhong.app"
  codesign --force --deep --sign "$SIGN_ID" "$DIST_DIR/BianzhongFeishuSensor.app"
fi

echo "Bundled:"
echo "  $DIST_DIR/Bianzhong.app"
echo "  $DIST_DIR/BianzhongFeishuSensor.app"
echo "  $DIST_DIR/bz"
