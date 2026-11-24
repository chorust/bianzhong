#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RAW_VERSION="${1:-${VERSION:-0.1.0}}"
CLEAN_VERSION="${RAW_VERSION#v}"
PKG_VERSION="$(echo "$CLEAN_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*$/\1/')"
if [[ ! "$PKG_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  PKG_VERSION="0.1.0"
fi

ARCH="${BIANZHONG_ARCH:-arm64}"
ARTIFACT_BASE="Bianzhong-${CLEAN_VERSION}-macos26-${ARCH}"

VERSION="$CLEAN_VERSION" bash "$ROOT_DIR/scripts/bundle-app.sh"

RELEASE_DIR="$ROOT_DIR/dist/release"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

STAGE_DIR="$(mktemp -d /tmp/bz-release-XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT

# 1. Build macOS Installer (.pkg) installing apps into /Applications and CLI into /usr/local/bin/bz
PKGROOT="$STAGE_DIR/pkgroot"
mkdir -p "$PKGROOT/Applications" "$PKGROOT/usr/local/bin"
ditto "$ROOT_DIR/dist/Bianzhong.app" "$PKGROOT/Applications/Bianzhong.app"
ditto "$ROOT_DIR/dist/BianzhongFeishuSensor.app" "$PKGROOT/Applications/BianzhongFeishuSensor.app"
cp "$ROOT_DIR/dist/bz" "$PKGROOT/usr/local/bin/bz"
chmod 755 "$PKGROOT/usr/local/bin/bz"

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

# 2. Build drag-and-drop macOS Disk Image (.dmg)
DMGROOT="$STAGE_DIR/dmg"
mkdir -p "$DMGROOT/bin"
ditto "$ROOT_DIR/dist/Bianzhong.app" "$DMGROOT/Bianzhong.app"
ditto "$ROOT_DIR/dist/BianzhongFeishuSensor.app" "$DMGROOT/BianzhongFeishuSensor.app"
cp "$ROOT_DIR/dist/bz" "$DMGROOT/bin/bz"
chmod 755 "$DMGROOT/bin/bz"
cp -R "$ROOT_DIR/templates" "$DMGROOT/templates"
ln -s /Applications "$DMGROOT/Applications"

cat > "$DMGROOT/INSTALL.txt" <<'EOF'
Bianzhong（编钟）for macOS 26 (arm64)
======================================

推荐方式（或直接运行 .pkg 安装包）：
1. 将 Bianzhong.app 与 BianzhongFeishuSensor.app 拖入 Applications 文件夹。
2. 安装 CLI 工具：
   sudo install -m 755 bin/bz /usr/local/bin/bz
3. 初始化默认规则并启动配置助手：
   bz init
   bz config

重要说明（未配 Apple Developer ID 公证时）：
- 若首次打开提示“无法验证开发者/已损坏”，执行：
  xattr -cr /Applications/Bianzhong.app /Applications/BianzhongFeishuSensor.app
- Full Disk Access 仅需授予 /Applications/BianzhongFeishuSensor.app
  （主程序 Bianzhong.app 与下游 Agent 保持 Zero-TCC）。
EOF

DMG_PATH="$RELEASE_DIR/${ARTIFACT_BASE}.dmg"
hdiutil create \
  -volname "Bianzhong ${CLEAN_VERSION}" \
  -srcfolder "$DMGROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

# 3. Build portable tarball (.tar.gz)
TARROOT="$STAGE_DIR/tar/Bianzhong-${CLEAN_VERSION}"
mkdir -p "$TARROOT"
ditto "$ROOT_DIR/dist/Bianzhong.app" "$TARROOT/Bianzhong.app"
ditto "$ROOT_DIR/dist/BianzhongFeishuSensor.app" "$TARROOT/BianzhongFeishuSensor.app"
cp "$ROOT_DIR/dist/bz" "$TARROOT/bz"
chmod 755 "$TARROOT/bz"
cp -R "$ROOT_DIR/templates" "$TARROOT/templates"
cp "$ROOT_DIR/README.md" "$TARROOT/README.md"

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
