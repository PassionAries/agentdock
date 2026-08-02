#!/bin/zsh
set -euo pipefail

SOURCE_DIR=""
RESULT_FILE=""
NODE_VERSION="${AGENTDOCK_BROWSER_NODE_VERSION:-v22.14.0}"
NODE_DIST_BASE_URL="${AGENTDOCK_NODE_DIST_BASE_URL:-https://nodejs.org/dist/$NODE_VERSION}"
STATE_DIR="${AGENTDOCK_STATE_DIR:-$HOME/.agentdock}"
RUNNER_DIR="${AGENTDOCK_BROWSER_RUNNER_INSTALL_DIR:-$STATE_DIR/browser-runner}"
RUNTIME_ROOT="${AGENTDOCK_BROWSER_RUNTIME_DIR:-$STATE_DIR/browser-runtime}"
NODE_BINARY_OVERRIDE="${AGENTDOCK_BROWSER_NODE_BINARY:-}"
FORCE_MANAGED_NODE="${AGENTDOCK_BROWSER_FORCE_MANAGED_NODE:-false}"

usage() {
  cat <<'USAGE'
AgentDock macOS 浏览器支持安装器。

用法：
  install-browser-runner-macos.sh --source-dir PATH [--result-file PATH]

选项：
  --source-dir PATH   App 内随附的 browser-runner 目录
  --result-file PATH  写入 JSON 安装结果
  --node-version VER  托管 Node.js 版本，默认 v22.14.0
  -h, --help          显示帮助
USAGE
}

die() {
  print -u2 -- "ERROR: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

regular_directory() {
  [[ -d "$1" && ! -L "$1" ]]
}

regular_file() {
  [[ -f "$1" && ! -L "$1" ]]
}

node_major() {
  "$1" -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || true
}

resolve_existing_node() {
  local candidate resolved major
  local candidates=()
  [[ -z "$NODE_BINARY_OVERRIDE" ]] || candidates+=("$NODE_BINARY_OVERRIDE")
  candidates+=("/opt/homebrew/bin/node" "/usr/local/bin/node")
  candidate="$(command -v node 2>/dev/null || true)"
  [[ -z "$candidate" ]] || candidates+=("$candidate")

  for candidate in "${candidates[@]}"; do
    [[ -x "$candidate" ]] || continue
    resolved="$("$candidate" -p 'process.execPath' 2>/dev/null || true)"
    [[ -x "$resolved" && -f "$resolved" ]] || continue
    major="$(node_major "$resolved")"
    [[ "$major" == <20-> ]] || continue
    print -r -- "$resolved"
    return 0
  done
  return 1
}

install_managed_node() {
  local machine node_arch asset tmp_dir archive checksums expected actual extracted target stage
  machine="$(uname -m)"
  case "$machine" in
    arm64|aarch64) node_arch="arm64" ;;
    x86_64|amd64) node_arch="x64" ;;
    *) die "不支持的 macOS 架构：$machine" ;;
  esac

  asset="node-${NODE_VERSION}-darwin-${node_arch}.tar.gz"
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentdock-browser-node.XXXXXX")"
  archive="$tmp_dir/$asset"
  checksums="$tmp_dir/SHASUMS256.txt"
  print -u2 -- "==> 下载浏览器运行时：$asset"
  curl -fL --retry 3 --retry-delay 1 "${NODE_DIST_BASE_URL%/}/$asset" -o "$archive"
  curl -fL --retry 3 --retry-delay 1 "${NODE_DIST_BASE_URL%/}/SHASUMS256.txt" -o "$checksums"
  expected="$(awk -v asset="$asset" '$2 == asset { print $1; exit }' "$checksums")"
  [[ ${#expected} -eq 64 ]] && print -r -- "$expected" | grep -Eq '^[0-9a-fA-F]{64}$' || \
    die "Node.js 校验文件缺少 $asset"
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "${actual:l}" == "${expected:l}" ]] || die "Node.js SHA-256 校验失败"

  tar -xzf "$archive" -C "$tmp_dir"
  extracted="$tmp_dir/node-${NODE_VERSION}-darwin-${node_arch}"
  [[ -x "$extracted/bin/node" && -f "$extracted/bin/node" ]] || die "Node.js 压缩包缺少 bin/node"
  [[ "$(node_major "$extracted/bin/node")" == <20-> ]] || die "下载的 Node.js 版本不可用"

  mkdir -p "$RUNTIME_ROOT"
  chmod 0700 "$STATE_DIR" "$RUNTIME_ROOT"
  target="$RUNTIME_ROOT/node-${NODE_VERSION}-darwin-${node_arch}"
  if [[ ! -d "$target" ]]; then
    stage="$RUNTIME_ROOT/.${target:t}.stage.$$"
    rm -rf "$stage"
    mv "$extracted" "$stage"
    chmod -R go-rwx "$stage"
    mv "$stage" "$target"
  fi
  rm -rf "$tmp_dir"
  [[ -x "$target/bin/node" ]] || die "托管 Node.js 安装失败"
  print -r -- "$target/bin/node"
}

install_runner() {
  local node_path="$1"
  local parent stage backup
  parent="${RUNNER_DIR:h}"
  mkdir -p "$parent"
  chmod 0700 "$STATE_DIR" "$parent"
  stage="$parent/.${RUNNER_DIR:t}.stage.$$"
  backup="$parent/.${RUNNER_DIR:t}.backup.$$"
  rm -rf "$stage" "$backup"
  mkdir -p "$stage"
  ditto "$SOURCE_DIR" "$stage"
  if find "$stage" -type l -print -quit | grep -q .; then
    rm -rf "$stage"
    die "browser-runner 资源不能包含符号链接"
  fi
  "$node_path" --check "$stage/browser-runner.js" >/dev/null
  regular_file "$stage/node_modules/playwright-core/package.json" || {
    rm -rf "$stage"
    die "browser-runner 缺少 playwright-core 依赖"
  }
  find "$stage" -type d -exec chmod 0700 {} +
  find "$stage" -type f -exec chmod 0600 {} +

  if [[ -e "$RUNNER_DIR" || -L "$RUNNER_DIR" ]]; then
    regular_directory "$RUNNER_DIR" || {
      rm -rf "$stage"
      die "现有 browser-runner 路径不是普通目录：$RUNNER_DIR"
    }
    mv "$RUNNER_DIR" "$backup"
  fi
  if ! mv "$stage" "$RUNNER_DIR"; then
    [[ ! -d "$backup" ]] || mv "$backup" "$RUNNER_DIR"
    die "安装 browser-runner 失败"
  fi
  rm -rf "$backup"
}

write_result() {
  local node_path="$1"
  [[ -n "$RESULT_FILE" ]] || return 0
  local result_dir tmp
  result_dir="${RESULT_FILE:h}"
  [[ -n "$result_dir" ]] || result_dir="."
  mkdir -p "$result_dir"
  [[ ! -e "$RESULT_FILE" || ( -f "$RESULT_FILE" && ! -L "$RESULT_FILE" ) ]] || die "结果文件必须是普通文件：$RESULT_FILE"
  tmp="$result_dir/.${RESULT_FILE:t}.tmp.$$"
  rm -f "$tmp"
  plutil -create xml1 "$tmp"
  plutil -insert schema_version -integer 1 "$tmp"
  plutil -insert ok -bool true "$tmp"
  plutil -insert runner_dir -string "$RUNNER_DIR" "$tmp"
  plutil -insert node_path -string "$node_path" "$tmp"
  plutil -insert node_version -string "$("$node_path" --version)" "$tmp"
  plutil -convert json "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$RESULT_FILE"
}

while (( $# > 0 )); do
  case "$1" in
    --source-dir)
      (( $# >= 2 )) || die "--source-dir 需要值"
      SOURCE_DIR="$2"
      shift 2
      ;;
    --result-file)
      (( $# >= 2 )) || die "--result-file 需要值"
      RESULT_FILE="$2"
      shift 2
      ;;
    --node-version)
      (( $# >= 2 )) || die "--node-version 需要值"
      NODE_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "此脚本只支持 macOS"
for command_name in awk chmod curl ditto find grep mktemp mv plutil rm shasum tar uname; do
  require_command "$command_name"
done
[[ -n "$SOURCE_DIR" ]] || die "必须提供 --source-dir"
regular_directory "$SOURCE_DIR" || die "browser-runner 资源目录无效：$SOURCE_DIR"
for required_path in browser-runner.js package.json package-lock.json node_modules/playwright-core/package.json; do
  regular_file "$SOURCE_DIR/$required_path" || die "browser-runner 资源缺少普通文件：$required_path"
done
if find "$SOURCE_DIR" -type l -print -quit | grep -q .; then
  die "browser-runner 资源不能包含符号链接"
fi
mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"

node_path=""
if [[ "$FORCE_MANAGED_NODE" != true ]]; then
  node_path="$(resolve_existing_node || true)"
fi
if [[ -z "$node_path" ]]; then
  node_path="$(install_managed_node)"
fi
install_runner "$node_path"
write_result "$node_path"
print -- "installed browser runner: $RUNNER_DIR"
print -- "node: $node_path"
