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
  "$ROOT_DIR/desktop/macos/AgentDockApp/Tests/InstallerConfigurationTests.swift" \
  -o "$TMP_ROOT/installer-configuration-tests"
"$TMP_ROOT/installer-configuration-tests"

mkdir -p "$TMP_ROOT/output"
: > "$TMP_ROOT/output/AgentDock-macos-universal.zip"
: > "$TMP_ROOT/output/AgentDock-macos-universal.zip.sha256"

AGENTDOCK_MACOS_ARCHES="$(uname -m)" \
AGENTDOCK_MACOS_APP_OUTPUT_DIR="$TMP_ROOT/output" \
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
hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED=false

print -- "macOS menu app DMG tests passed"
