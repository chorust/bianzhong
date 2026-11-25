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
trap 'rm -rf "$STAGE_DIR"' EXIT

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
DMGROOT="$STAGE_DIR/dmg"
mkdir -p "$DMGROOT"
ditto "$ROOT_DIR/dist/Bianzhong.app" "$DMGROOT/Bianzhong.app"
cp -R "$ROOT_DIR/templates" "$DMGROOT/templates"
ln -s /Applications "$DMGROOT/Applications"

cat > "$DMGROOT/INSTALL.txt" <<'EOF'
Bianzhong（编钟）for macOS 26 (arm64)
======================================

单应用安装步骤（或直接运行 .pkg 安装包）：
1. 将 Bianzhong.app 拖入 Applications 文件夹并打开。
2. 首次启动会自动：
   - 初始化 ~/.config/bianzhong/ 默认配置与示例规则
   - 自动将 bz 命令软链到 ~/.local/bin/bz（若 /opt/homebrew/bin 可写也会一并创建）
3. 如需接入终端慢命令钩子：点击菜单栏「集成 -> 写入 Zsh 慢命令钩子 (~/.zshrc)」，或运行：
   bz install-cli --zsh

权限与 Gatekeeper 说明（未配 Apple Developer ID 公证时）：
- 若首次打开提示“无法验证开发者/已损坏”，执行：
  xattr -cr /Applications/Bianzhong.app
- 如使用内置飞书通知监听，在「系统设置 -> 隐私与安全性 -> 完全磁盘访问权限」中授予 Bianzhong.app；
  不需要该监听时可在菜单栏「集成 -> 关闭飞书通知监听」关闭（完全零额外权限）。
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
