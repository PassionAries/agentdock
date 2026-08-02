#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
INSTALLER="$ROOT_DIR/scripts/install-browser-runner-macos.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agentdock-browser-installer-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

SOURCE="$TMP_ROOT/source"
STATE="$TMP_ROOT/state"
RESULT="$TMP_ROOT/result.json"
mkdir -p "$SOURCE/node_modules/playwright-core"
cp "$ROOT_DIR/tools/browser-runner/browser-runner.js" "$SOURCE/browser-runner.js"
cp "$ROOT_DIR/tools/browser-runner/package.json" "$SOURCE/package.json"
cp "$ROOT_DIR/tools/browser-runner/package-lock.json" "$SOURCE/package-lock.json"
print -- '{"name":"playwright-core","version":"test"}' > "$SOURCE/node_modules/playwright-core/package.json"

AGENTDOCK_STATE_DIR="$STATE" \
AGENTDOCK_BROWSER_NODE_BINARY="$(command -v node)" \
  "$INSTALLER" --source-dir "$SOURCE" --result-file "$RESULT"

test -f "$STATE/browser-runner/browser-runner.js"
test -f "$STATE/browser-runner/node_modules/playwright-core/package.json"
test "$(stat -f '%Lp' "$STATE")" = "700"
test "$(stat -f '%Lp' "$STATE/browser-runner/browser-runner.js")" = "600"
test "$(plutil -extract ok raw -o - "$RESULT")" = "true"
test "$(plutil -extract runner_dir raw -o - "$RESULT")" = "$STATE/browser-runner"
node_path="$(plutil -extract node_path raw -o - "$RESULT")"
test -x "$node_path"

# 重装必须原子替换旧 Runner，不能残留旧文件。
print -- stale > "$STATE/browser-runner/stale.txt"
AGENTDOCK_STATE_DIR="$STATE" \
AGENTDOCK_BROWSER_NODE_BINARY="$(command -v node)" \
  "$INSTALLER" --source-dir "$SOURCE" --result-file "$RESULT"
test ! -e "$STATE/browser-runner/stale.txt"

# 资源包含符号链接时必须拒绝，现有安装保持不变。
ln -s /tmp "$SOURCE/unsafe-link"
if AGENTDOCK_STATE_DIR="$STATE" \
  AGENTDOCK_BROWSER_NODE_BINARY="$(command -v node)" \
  "$INSTALLER" --source-dir "$SOURCE" --result-file "$RESULT" >"$TMP_ROOT/fail.log" 2>&1; then
  print -u2 -- "expected symlink source rejection"
  exit 1
fi
test -f "$STATE/browser-runner/browser-runner.js"
grep -q '不能包含符号链接' "$TMP_ROOT/fail.log"
rm -f "$SOURCE/unsafe-link"

# 没有系统 Node 时，必须下载、校验并使用托管运行时。
case "$(uname -m)" in
  arm64|aarch64) node_arch=arm64 ;;
  x86_64|amd64) node_arch=x64 ;;
esac
NODE_VERSION=v22.14.0
DIST="$TMP_ROOT/dist"
NODE_DIR="node-${NODE_VERSION}-darwin-${node_arch}"
ASSET="$NODE_DIR.tar.gz"
mkdir -p "$DIST/$NODE_DIR/bin"
cat > "$DIST/$NODE_DIR/bin/node" <<SCRIPT
#!/bin/zsh
exec "$(command -v node)" "\$@"
SCRIPT
chmod 0755 "$DIST/$NODE_DIR/bin/node"
(
  cd "$DIST"
  tar -czf "$ASSET" "$NODE_DIR"
  shasum -a 256 "$ASSET" > SHASUMS256.txt
)
MANAGED_STATE="$TMP_ROOT/managed-state"
MANAGED_RESULT="$TMP_ROOT/managed-result.json"
AGENTDOCK_STATE_DIR="$MANAGED_STATE" \
AGENTDOCK_BROWSER_FORCE_MANAGED_NODE=true \
AGENTDOCK_NODE_DIST_BASE_URL="file://$DIST" \
  "$INSTALLER" --source-dir "$SOURCE" --result-file "$MANAGED_RESULT"
managed_node="$(plutil -extract node_path raw -o - "$MANAGED_RESULT")"
test "$managed_node" = "$MANAGED_STATE/browser-runtime/$NODE_DIR/bin/node"
test -x "$managed_node"
test "$("$managed_node" --version)" = "$(node --version)"

print -- "macOS browser runner installer tests passed"
