#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agentdock-macos-app-test.XXXXXX")"
MOUNT_POINT="$TMP_ROOT/mount"
MOUNTED=false

cleanup() {
  if [[ "$MOUNTED" == true ]]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

swiftc \
  -swift-version 5 \
  -parse-as-library \
  "$ROOT_DIR/desktop/macos/AgentDockApp/Sources/InstallerConfiguration.swift" \
  "$ROOT_DIR/desktop/macos/AgentDockApp/Sources/ManagedEnvironment.swift" \
  "$ROOT_DIR/desktop/macos/AgentDockApp/Sources/AppPaths.swift" \
  "$ROOT_DIR/desktop/macos/AgentDockApp/Sources/TunnelTokenStore.swift" \
  "$ROOT_DIR/desktop/macos/AgentDockApp/Sources/PublicEndpointChecker.swift" \
  "$ROOT_DIR/desktop/macos/AgentDockApp/Sources/ServicePortValidation.swift" \
  "$ROOT_DIR/desktop/macos/AgentDockApp/Tests/InstallerConfigurationTests.swift" \
  -o "$TMP_ROOT/installer-configuration-tests"
"$TMP_ROOT/installer-configuration-tests"

mkdir -p "$TMP_ROOT/output"
: > "$TMP_ROOT/output/AgentDock-macos-universal.zip"
: > "$TMP_ROOT/output/AgentDock-macos-universal.zip.sha256"

case "$(uname -m)" in
  arm64|aarch64) release_arch="arm64" ;;
  x86_64|amd64) release_arch="amd64" ;;
  *) print -u2 -- "unsupported test architecture: $(uname -m)"; exit 1 ;;
esac

# 构建当前架构的真实核心载荷和最小 cloudflared 替身，验证 DMG 构建只接受
# 带校验文件的 Mach-O 离线资源，不依赖测试期间访问公网。
payload_dir="$TMP_ROOT/offline-payload"
payload_build="$TMP_ROOT/offline-build"
mkdir -p "$payload_dir" "$payload_build/bin" "$payload_build/share/agentdock"
(
  cd "$ROOT_DIR"
  CGO_ENABLED=0 GOOS=darwin GOARCH="$release_arch" \
    go build -trimpath -o "$payload_build/bin/agentdock" ./cmd/agentdock
)
python3 "$ROOT_DIR/scripts/build-core-skill-bundle.py" \
  --output "$payload_build/share/agentdock/core-skills"
agentdock_archive="agentdock_darwin_${release_arch}.tar.gz"
tar -C "$payload_build" -czf "$payload_dir/$agentdock_archive" \
  bin/agentdock share/agentdock/core-skills
(
  cd "$payload_dir"
  shasum -a 256 "$agentdock_archive" > "$agentdock_archive.sha256"
)

cat > "$TMP_ROOT/cloudflared.go" <<'GO'
package main

import "fmt"

func main() {
	fmt.Println("cloudflared version test")
}
GO
cloudflared_binary="cloudflared_darwin_${release_arch}"
CGO_ENABLED=0 GOOS=darwin GOARCH="$release_arch" \
  go build -trimpath -o "$payload_dir/$cloudflared_binary" "$TMP_ROOT/cloudflared.go"
chmod 0755 "$payload_dir/$cloudflared_binary"
(
  cd "$payload_dir"
  shasum -a 256 "$cloudflared_binary" > "$cloudflared_binary.sha256"
)

AGENTDOCK_MACOS_ARCHES="$(uname -m)" \
AGENTDOCK_MACOS_APP_OUTPUT_DIR="$TMP_ROOT/output" \
AGENTDOCK_MACOS_OFFLINE_PAYLOAD_DIR="$payload_dir" \
  "$ROOT_DIR/packaging/macos/build-app.sh"

APP="$TMP_ROOT/output/AgentDock.app"
DMG="$TMP_ROOT/output/AgentDock-macos-universal.dmg"
ZIP="$TMP_ROOT/output/AgentDock-macos-universal.zip"
test -x "$APP/Contents/MacOS/AgentDock"
test -x "$APP/Contents/MacOS/AgentDockLoginHelper"
test -x "$APP/Contents/Resources/install-macos-platform.sh"
test -x "$APP/Contents/Resources/install-browser-runner-macos.sh"
test -f "$APP/Contents/Resources/browser-runner/browser-runner.js"
test -f "$APP/Contents/Resources/browser-runner/node_modules/playwright-core/package.json"
test -f "$APP/Contents/Resources/offline-payload/$agentdock_archive"
test -f "$APP/Contents/Resources/offline-payload/$agentdock_archive.sha256"
test -x "$APP/Contents/Resources/offline-payload/$cloudflared_binary"
test -f "$APP/Contents/Resources/offline-payload/$cloudflared_binary.sha256"
(
  cd "$APP/Contents/Resources/offline-payload"
  shasum -a 256 -c "$agentdock_archive.sha256"
  shasum -a 256 -c "$cloudflared_binary.sha256"
)
test -f "$DMG"
test -f "$DMG.sha256"
test ! -e "$ZIP"
test ! -e "$ZIP.sha256"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
test "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" = "com.uvwt.agentdock"
test "$(plutil -extract LSUIElement raw -o - "$APP/Contents/Info.plist")" = "true"
codesign --verify --deep --strict --verbose=2 "$APP"
hdiutil verify "$DMG" >/dev/null
(
  cd "$TMP_ROOT/output"
  shasum -a 256 -c "${DMG:t}.sha256"
)

mkdir -p "$MOUNT_POINT"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG" >/dev/null
MOUNTED=true
mounted_entries="$(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)"
test "$mounted_entries" = $'AgentDock.app\nApplications'
test -d "$MOUNT_POINT/AgentDock.app"
test -L "$MOUNT_POINT/Applications"
test "$(readlink "$MOUNT_POINT/Applications")" = "/Applications"
codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/AgentDock.app"
cmp "$APP/Contents/MacOS/AgentDock" "$MOUNT_POINT/AgentDock.app/Contents/MacOS/AgentDock"
cmp "$APP/Contents/MacOS/AgentDockLoginHelper" "$MOUNT_POINT/AgentDock.app/Contents/MacOS/AgentDockLoginHelper"
cmp \
  "$APP/Contents/Resources/offline-payload/$agentdock_archive" \
  "$MOUNT_POINT/AgentDock.app/Contents/Resources/offline-payload/$agentdock_archive"
cmp \
  "$APP/Contents/Resources/offline-payload/$cloudflared_binary" \
  "$MOUNT_POINT/AgentDock.app/Contents/Resources/offline-payload/$cloudflared_binary"
hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED=false

print -- "macOS menu app DMG tests passed"
