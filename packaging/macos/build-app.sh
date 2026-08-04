#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h:h}"
SOURCE_DIR="$ROOT_DIR/desktop/macos/AgentDockApp/Sources"
LOGIN_HELPER_SOURCE="$ROOT_DIR/desktop/macos/AgentDockLoginHelper/main.swift"
INSTALLER_SCRIPT="$ROOT_DIR/scripts/install-macos-platform.sh"
BROWSER_INSTALLER_SCRIPT="$ROOT_DIR/scripts/install-browser-runner-macos.sh"
BROWSER_RUNNER_SOURCE="$ROOT_DIR/tools/browser-runner"
OUTPUT_DIR="${AGENTDOCK_MACOS_APP_OUTPUT_DIR:-$ROOT_DIR/dist/macos-app}"
ARCH_LIST="${AGENTDOCK_MACOS_ARCHES:-$(uname -m)}"
OFFLINE_PAYLOAD_DIR="${AGENTDOCK_MACOS_OFFLINE_PAYLOAD_DIR:-}"
MIN_VERSION="${AGENTDOCK_MACOS_MIN_VERSION:-13.0}"
BUNDLE_ID="com.uvwt.agentdock"
APP_ICON_SOURCE="$ROOT_DIR/packaging/assets/agentdock.png"

usage() {
  cat <<'USAGE'
用法：
  packaging/macos/build-app.sh [版本]

环境变量：
  AGENTDOCK_MACOS_ARCHES        逗号分隔架构，默认当前架构；Release 使用 arm64,x86_64
  AGENTDOCK_MACOS_APP_OUTPUT_DIR 输出目录，默认 dist/macos-app
  AGENTDOCK_MACOS_OFFLINE_PAYLOAD_DIR
                               双架构离线载荷目录，构建 DMG 时必须提供
  AGENTDOCK_MACOS_MIN_VERSION   最低 macOS 版本，默认 13.0
USAGE
}

die() {
  print -u2 -- "ERROR: $*"
  exit 1
}

if (( $# > 1 )); then
  usage
  exit 2
fi

for command_name in codesign ditto file hdiutil iconutil lipo npm plutil shasum sips swiftc xcrun; do
  command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：$command_name"
done
[[ -d "$SOURCE_DIR" ]] || die "缺少 macOS App 源码：$SOURCE_DIR"
[[ -f "$APP_ICON_SOURCE" && ! -L "$APP_ICON_SOURCE" ]] || die "缺少 macOS App 图标：$APP_ICON_SOURCE"
[[ -f "$LOGIN_HELPER_SOURCE" && ! -L "$LOGIN_HELPER_SOURCE" ]] || die "缺少 macOS 登录代理源码：$LOGIN_HELPER_SOURCE"
[[ -f "$INSTALLER_SCRIPT" && ! -L "$INSTALLER_SCRIPT" ]] || die "缺少 macOS 安装脚本：$INSTALLER_SCRIPT"
[[ -f "$BROWSER_INSTALLER_SCRIPT" && ! -L "$BROWSER_INSTALLER_SCRIPT" ]] || die "缺少浏览器支持安装脚本：$BROWSER_INSTALLER_SCRIPT"
[[ -d "$BROWSER_RUNNER_SOURCE" && ! -L "$BROWSER_RUNNER_SOURCE" ]] || die "缺少 browser-runner 源码：$BROWSER_RUNNER_SOURCE"
[[ -f "$BROWSER_RUNNER_SOURCE/package-lock.json" && ! -L "$BROWSER_RUNNER_SOURCE/package-lock.json" ]] || die "缺少 browser-runner package-lock.json"
[[ -n "$OFFLINE_PAYLOAD_DIR" ]] || die "构建 macOS DMG 必须设置 AGENTDOCK_MACOS_OFFLINE_PAYLOAD_DIR"
[[ -d "$OFFLINE_PAYLOAD_DIR" && ! -L "$OFFLINE_PAYLOAD_DIR" ]] || die "离线载荷目录无效：$OFFLINE_PAYLOAD_DIR"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(sed -n 's/^[[:space:]]*Version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT_DIR/internal/config/config.go" | head -n 1)"
fi
[[ "$VERSION" == <->.<->.<->* ]] || die "无法解析 App 版本：$VERSION"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentdock-macos-app.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

BROWSER_RUNNER_BUNDLE="$TMP_DIR/browser-runner"
ditto "$BROWSER_RUNNER_SOURCE" "$BROWSER_RUNNER_BUNDLE"
print -- "==> 安装 browser-runner 生产依赖"
(
  cd "$BROWSER_RUNNER_BUNDLE"
  npm ci --omit=dev --ignore-scripts --no-bin-links >/dev/null
)
[[ -f "$BROWSER_RUNNER_BUNDLE/node_modules/playwright-core/package.json" && ! -L "$BROWSER_RUNNER_BUNDLE/node_modules/playwright-core/package.json" ]] || \
  die "browser-runner 生产依赖安装失败"
if find "$BROWSER_RUNNER_BUNDLE" -type l -print -quit | grep -q .; then
  die "browser-runner Bundle 不能包含符号链接"
fi

mkdir -p "$OUTPUT_DIR"
rm -rf \
  "$OUTPUT_DIR/AgentDock.app" \
  "$OUTPUT_DIR/AgentDock-macos-universal.dmg" \
  "$OUTPUT_DIR/AgentDock-macos-universal.dmg.sha256" \
  "$OUTPUT_DIR/AgentDock-macos-universal.zip" \
  "$OUTPUT_DIR/AgentDock-macos-universal.zip.sha256"

IFS=',' read -rA architectures <<< "$ARCH_LIST"
(( ${#architectures[@]} > 0 )) || die "没有可构建的架构"
compiled_binaries=()
login_helper_binaries=()
release_architectures=()
for architecture in "${architectures[@]}"; do
  architecture="${architecture//[[:space:]]/}"
  case "$architecture" in
    arm64) release_architecture="arm64" ;;
    x86_64) release_architecture="amd64" ;;
    *) die "不支持的 App 架构：$architecture" ;;
  esac
  release_architectures+=("$release_architecture")
  binary="$TMP_DIR/AgentDock-$architecture"
  print -- "==> 编译 AgentDock.app：$architecture"
  xcrun swiftc \
    -swift-version 5 \
    -O \
    -whole-module-optimization \
    -target "$architecture-apple-macosx$MIN_VERSION" \
    -sdk "$SDK_PATH" \
    "$SOURCE_DIR"/*.swift \
    -o "$binary"
  compiled_binaries+=("$binary")

  login_helper="$TMP_DIR/AgentDockLoginHelper-$architecture"
  xcrun swiftc \
    -swift-version 5 \
    -O \
    -whole-module-optimization \
    -target "$architecture-apple-macosx$MIN_VERSION" \
    -sdk "$SDK_PATH" \
    "$LOGIN_HELPER_SOURCE" \
    -o "$login_helper"
  login_helper_binaries+=("$login_helper")
done

APP_DIR="$OUTPUT_DIR/AgentDock.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
LOGIN_ITEM_APP="$CONTENTS_DIR/Library/LoginItems/AgentDockLoginHelper.app"
LOGIN_ITEM_CONTENTS="$LOGIN_ITEM_APP/Contents"
LOGIN_ITEM_MACOS="$LOGIN_ITEM_CONTENTS/MacOS"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$LOGIN_ITEM_MACOS"

if (( ${#compiled_binaries[@]} == 1 )); then
  cp -p "$compiled_binaries[1]" "$MACOS_DIR/AgentDock"
else
  lipo -create "${compiled_binaries[@]}" -output "$MACOS_DIR/AgentDock"
fi
chmod 0755 "$MACOS_DIR/AgentDock"

if (( ${#login_helper_binaries[@]} == 1 )); then
  cp -p "$login_helper_binaries[1]" "$LOGIN_ITEM_MACOS/AgentDockLoginHelper"
else
  lipo -create "${login_helper_binaries[@]}" -output "$LOGIN_ITEM_MACOS/AgentDockLoginHelper"
fi
chmod 0755 "$LOGIN_ITEM_MACOS/AgentDockLoginHelper"

cat > "$LOGIN_ITEM_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>AgentDockLoginHelper</string>
  <key>CFBundleIdentifier</key>
  <string>com.uvwt.agentdock.login-helper</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>AgentDockLoginHelper</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_VERSION</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST
plutil -lint "$LOGIN_ITEM_CONTENTS/Info.plist" >/dev/null

cp -p "$INSTALLER_SCRIPT" "$RESOURCES_DIR/install-macos-platform.sh"
cp -p "$BROWSER_INSTALLER_SCRIPT" "$RESOURCES_DIR/install-browser-runner-macos.sh"
ditto "$BROWSER_RUNNER_BUNDLE" "$RESOURCES_DIR/browser-runner"
chmod 0755 "$RESOURCES_DIR/install-macos-platform.sh" "$RESOURCES_DIR/install-browser-runner-macos.sh"
find "$RESOURCES_DIR/browser-runner" -type d -exec chmod 0755 {} +
find "$RESOURCES_DIR/browser-runner" -type f -exec chmod 0644 {} +

ICONSET_DIR="$TMP_DIR/AgentDock.iconset"
mkdir -p "$ICONSET_DIR"
icon_specs=(
  'icon_16x16.png:16'
  'icon_16x16@2x.png:32'
  'icon_32x32.png:32'
  'icon_32x32@2x.png:64'
  'icon_128x128.png:128'
  'icon_128x128@2x.png:256'
  'icon_256x256.png:256'
  'icon_256x256@2x.png:512'
  'icon_512x512.png:512'
  'icon_512x512@2x.png:1024'
)
for icon_spec in "${icon_specs[@]}"; do
  icon_name="${icon_spec%%:*}"
  icon_size="${icon_spec##*:}"
  sips -z "$icon_size" "$icon_size" "$APP_ICON_SOURCE" --out "$ICONSET_DIR/$icon_name" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AgentDock.icns"
[[ -f "$RESOURCES_DIR/AgentDock.icns" && ! -L "$RESOURCES_DIR/AgentDock.icns" ]] || \
  die "macOS App 图标生成失败"

# 图形安装器必须在断网环境中完成核心和 Tunnel 安装。构建阶段只接受已经
# 生成并带 SHA-256 的载荷，避免 App 在运行时静默回退到网络下载。
OFFLINE_RESOURCES_DIR="$RESOURCES_DIR/offline-payload"
mkdir -p "$OFFLINE_RESOURCES_DIR"
for release_architecture in "${release_architectures[@]}"; do
  agentdock_archive="agentdock_darwin_${release_architecture}.tar.gz"
  agentdock_checksum="$agentdock_archive.sha256"
  cloudflared_binary="cloudflared_darwin_${release_architecture}"
  cloudflared_checksum="$cloudflared_binary.sha256"

  for payload_name in "$agentdock_archive" "$agentdock_checksum" "$cloudflared_binary" "$cloudflared_checksum"; do
    payload_path="$OFFLINE_PAYLOAD_DIR/$payload_name"
    [[ -f "$payload_path" && ! -L "$payload_path" ]] || die "缺少离线载荷：$payload_path"
  done

  (
    cd "$OFFLINE_PAYLOAD_DIR"
    shasum -a 256 -c "$agentdock_checksum"
    shasum -a 256 -c "$cloudflared_checksum"
  )

  payload_check_dir="$TMP_DIR/payload-check-$release_architecture"
  mkdir -p "$payload_check_dir"
  tar -xzf "$OFFLINE_PAYLOAD_DIR/$agentdock_archive" -C "$payload_check_dir"
  [[ -f "$payload_check_dir/bin/agentdock" && ! -L "$payload_check_dir/bin/agentdock" ]] || die "$agentdock_archive 缺少 bin/agentdock"
  [[ -f "$payload_check_dir/share/agentdock/core-skills/manifest.json" && ! -L "$payload_check_dir/share/agentdock/core-skills/manifest.json" ]] || \
    die "$agentdock_archive 缺少核心 Skill Bundle"

  case "$release_architecture" in
    arm64) expected_file_architecture="arm64" ;;
    amd64) expected_file_architecture="x86_64" ;;
  esac
  file "$payload_check_dir/bin/agentdock" | grep -q "$expected_file_architecture" || \
    die "$agentdock_archive 架构不匹配，期望 $expected_file_architecture"
  file "$OFFLINE_PAYLOAD_DIR/$cloudflared_binary" | grep -q "$expected_file_architecture" || \
    die "$cloudflared_binary 架构不匹配，期望 $expected_file_architecture"

  cp -p "$OFFLINE_PAYLOAD_DIR/$agentdock_archive" "$OFFLINE_RESOURCES_DIR/$agentdock_archive"
  cp -p "$OFFLINE_PAYLOAD_DIR/$agentdock_checksum" "$OFFLINE_RESOURCES_DIR/$agentdock_checksum"
  cp -p "$OFFLINE_PAYLOAD_DIR/$cloudflared_binary" "$OFFLINE_RESOURCES_DIR/$cloudflared_binary"
  cp -p "$OFFLINE_PAYLOAD_DIR/$cloudflared_checksum" "$OFFLINE_RESOURCES_DIR/$cloudflared_checksum"
  chmod 0644 "$OFFLINE_RESOURCES_DIR/$agentdock_archive" "$OFFLINE_RESOURCES_DIR/$agentdock_checksum" "$OFFLINE_RESOURCES_DIR/$cloudflared_checksum"
  chmod 0755 "$OFFLINE_RESOURCES_DIR/$cloudflared_binary"
done

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>AgentDock</string>
  <key>CFBundleExecutable</key>
  <string>AgentDock</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AgentDock.icns</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>AgentDock</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © AgentDock contributors</string>
</dict>
</plist>
PLIST
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null

print -- "==> ad-hoc 签名 AgentDock.app"
codesign --force --sign - --identifier "com.uvwt.agentdock.login-helper" "$LOGIN_ITEM_APP"
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

DMG_STAGE_DIR="$TMP_DIR/dmg-root"
DMG_PATH="$OUTPUT_DIR/AgentDock-macos-universal.dmg"
mkdir -p "$DMG_STAGE_DIR"
ditto "$APP_DIR" "$DMG_STAGE_DIR/AgentDock.app"
ln -s /Applications "$DMG_STAGE_DIR/Applications"

print -- "==> 创建 AgentDock DMG"
hdiutil create \
  -volname "AgentDock" \
  -srcfolder "$DMG_STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null
hdiutil verify "$DMG_PATH" >/dev/null
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "${DMG_PATH:t}" > "${DMG_PATH:t}.sha256"
)

print -- "built: $APP_DIR"
print -- "dmg: $DMG_PATH"
file "$MACOS_DIR/AgentDock"
