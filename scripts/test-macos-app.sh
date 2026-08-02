#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agentdock-macos-app-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

swiftc \
  -swift-version 5 \
  -parse-as-library \
  "$ROOT_DIR/desktop/macos/AgentDockApp/Sources/InstallerConfiguration.swift" \
  "$ROOT_DIR/desktop/macos/AgentDockApp/Tests/InstallerConfigurationTests.swift" \
  -o "$TMP_ROOT/installer-configuration-tests"
"$TMP_ROOT/installer-configuration-tests"

AGENTDOCK_MACOS_ARCHES="$(uname -m)" \
AGENTDOCK_MACOS_APP_OUTPUT_DIR="$TMP_ROOT/output" \
  "$ROOT_DIR/packaging/macos/build-app.sh"

APP="$TMP_ROOT/output/AgentDock.app"
ZIP="$TMP_ROOT/output/AgentDock-macos-universal.zip"
test -x "$APP/Contents/MacOS/AgentDock"
test -x "$APP/Contents/Resources/install-macos-platform.sh"
test -f "$ZIP"
test -f "$ZIP.sha256"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
test "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" = "com.uvwt.agentdock"
test "$(plutil -extract LSUIElement raw -o - "$APP/Contents/Info.plist")" = "true"
codesign --verify --deep --strict --verbose=2 "$APP"
(
  cd "$TMP_ROOT/output"
  shasum -a 256 -c "${ZIP:t}.sha256"
)
print -- "macOS menu app tests passed"
