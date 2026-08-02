#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h:h}"
SOURCE_DIR="$ROOT_DIR/desktop/macos/AgentDockApp/Sources"
LOGIN_HELPER_SOURCE="$ROOT_DIR/desktop/macos/AgentDockLoginHelper/main.swift"
INSTALLER_SCRIPT="$ROOT_DIR/scripts/install-macos-platform.sh"
BROWSER_INSTALLER_SCRIPT="$ROOT_DIR/scripts/install-browser-runner-macos.sh"
BROWSER_RUNNER_SOURCE="$ROOT_DIR/examples/browser-runner"
OUTPUT_DIR="${AGENTDOCK_MACOS_APP_OUTPUT_DIR:-$ROOT_DIR/dist/macos-app}"
ARCH_LIST="${AGENTDOCK_MACOS_ARCHES:-$(uname -m)}"
MIN_VERSION="${AGENTDOCK_MACOS_MIN_VERSION:-13.0}"
BUNDLE_ID="com.uvwt.agentdock"

usage() {
  cat <<'USAGE'
用法：
  packaging/macos/build-app.sh [版本]

环境变量：
  AGENTDOCK_MACOS_ARCHES        逗号分隔架构，默认当前架构；Release 使用 arm64,x86_64
  AGENTDOCK_MACOS_APP_OUTPUT_DIR 输出目录，默认 dist/macos-app
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

for command_name in codesign ditto file lipo npm plutil shasum swiftc xcrun; do
  command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：$command_name"
done
[[ -d "$SOURCE_DIR" ]] || die "缺少 macOS App 源码：$SOURCE_DIR"
[[ -f "$LOGIN_HELPER_SOURCE" && ! -L "$LOGIN_HELPER_SOURCE" ]] || die "缺少 macOS 登录代理源码：$LOGIN_HELPER_SOURCE"
[[ -f "$INSTALLER_SCRIPT" && ! -L "$INSTALLER_SCRIPT" ]] || die "缺少 macOS 安装脚本：$INSTALLER_SCRIPT"
[[ -f "$BROWSER_INSTALLER_SCRIPT" && ! -L "$BROWSER_INSTALLER_SCRIPT" ]] || die "缺少浏览器支持安装脚本：$BROWSER_INSTALLER_SCRIPT"
[[ -d "$BROWSER_RUNNER_SOURCE" && ! -L "$BROWSER_RUNNER_SOURCE" ]] || die "缺少 browser-runner 源码：$BROWSER_RUNNER_SOURCE"
[[ -f "$BROWSER_RUNNER_SOURCE/package-lock.json" && ! -L "$BROWSER_RUNNER_SOURCE/package-lock.json" ]] || die "缺少 browser-runner package-lock.json"

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
rm -rf "$OUTPUT_DIR/AgentDock.app" "$OUTPUT_DIR/AgentDock-macos-universal.zip" "$OUTPUT_DIR/AgentDock-macos-universal.zip.sha256"

IFS=',' read -rA architectures <<< "$ARCH_LIST"
(( ${#architectures[@]} > 0 )) || die "没有可构建的架构"
compiled_binaries=()
login_helper_binaries=()
for architecture in "${architectures[@]}"; do
  architecture="${architecture//[[:space:]]/}"
  case "$architecture" in
    arm64|x86_64) ;;
    *) die "不支持的 App 架构：$architecture" ;;
  esac
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
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

if (( ${#compiled_binaries[@]} == 1 )); then
  cp -p "$compiled_binaries[1]" "$MACOS_DIR/AgentDock"
else
  lipo -create "${compiled_binaries[@]}" -output "$MACOS_DIR/AgentDock"
fi
chmod 0755 "$MACOS_DIR/AgentDock"

if (( ${#login_helper_binaries[@]} == 1 )); then
  cp -p "$login_helper_binaries[1]" "$MACOS_DIR/AgentDockLoginHelper"
else
  lipo -create "${login_helper_binaries[@]}" -output "$MACOS_DIR/AgentDockLoginHelper"
fi
chmod 0755 "$MACOS_DIR/AgentDockLoginHelper"

cp -p "$INSTALLER_SCRIPT" "$RESOURCES_DIR/install-macos-platform.sh"
cp -p "$BROWSER_INSTALLER_SCRIPT" "$RESOURCES_DIR/install-browser-runner-macos.sh"
ditto "$BROWSER_RUNNER_BUNDLE" "$RESOURCES_DIR/browser-runner"
chmod 0755 "$RESOURCES_DIR/install-macos-platform.sh" "$RESOURCES_DIR/install-browser-runner-macos.sh"
find "$RESOURCES_DIR/browser-runner" -type d -exec chmod 0755 {} +
find "$RESOURCES_DIR/browser-runner" -type f -exec chmod 0644 {} +

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
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

ZIP_PATH="$OUTPUT_DIR/AgentDock-macos-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "${ZIP_PATH:t}" > "${ZIP_PATH:t}.sha256"
)

print -- "built: $APP_DIR"
print -- "archive: $ZIP_PATH"
file "$MACOS_DIR/AgentDock"
