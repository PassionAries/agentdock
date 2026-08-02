#!/bin/sh
set -eu

umask 077

DEFAULT_BASE_URL="https://github.com/uvwt/agentdock/releases/latest/download"
BASE_URL="${AGENTDOCK_INSTALLER_BASE_URL:-$DEFAULT_BASE_URL}"
TMP_ROOT=""

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT HUP INT TERM

download_file() {
  url="$1"
  destination="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$destination"
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$destination" "$url"
    return
  fi
  die "缺少 curl 或 wget，无法下载安装器。"
}

sha256_file() {
  file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
    return
  fi
  die "缺少 SHA-256 校验工具（sha256sum、shasum 或 openssl）。"
}

verify_checksum() {
  file="$1"
  checksum_file="$2"
  expected="$(awk 'NF { print $1; exit }' "$checksum_file" | tr '[:upper:]' '[:lower:]')"
  actual="$(sha256_file "$file" | tr '[:upper:]' '[:lower:]')"

  [ -n "$expected" ] || die "校验文件为空：$checksum_file"
  [ "$actual" = "$expected" ] || die "安装器 SHA-256 校验失败：$file"
}

case "$(uname -s 2>/dev/null || true)" in
  Linux)
    PLATFORM_INSTALLER="install-linux-platform.sh"
    PLATFORM_SHELL="bash"
    ;;
  Darwin)
    PLATFORM_INSTALLER="install-macos-platform.sh"
    PLATFORM_SHELL="zsh"
    ;;
  *)
    die "当前系统不受 install.sh 支持；Windows 请使用 install.ps1。"
    ;;
esac

command -v "$PLATFORM_SHELL" >/dev/null 2>&1 || die "缺少 $PLATFORM_SHELL，无法运行 $PLATFORM_INSTALLER。"

# 源码开发需要显式开启本地模式；Release 用户始终下载并校验平台安装器。
if [ "${AGENTDOCK_USE_LOCAL_PLATFORM_INSTALLER:-false}" = "true" ]; then
  case "$0" in
    */*) SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)" ;;
    *) die "本地平台安装器模式要求从文件路径执行 install.sh。" ;;
  esac
  [ -f "$SCRIPT_DIR/$PLATFORM_INSTALLER" ] || die "找不到本地平台安装器：$SCRIPT_DIR/$PLATFORM_INSTALLER"
  exec "$PLATFORM_SHELL" "$SCRIPT_DIR/$PLATFORM_INSTALLER" "$@"
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agentdock-installer.XXXXXX")"
INSTALLER_PATH="$TMP_ROOT/$PLATFORM_INSTALLER"
CHECKSUM_PATH="$INSTALLER_PATH.sha256"

log "下载 AgentDock 平台安装器：$PLATFORM_INSTALLER"
download_file "$BASE_URL/$PLATFORM_INSTALLER" "$INSTALLER_PATH"
download_file "$BASE_URL/$PLATFORM_INSTALLER.sha256" "$CHECKSUM_PATH"
verify_checksum "$INSTALLER_PATH" "$CHECKSUM_PATH"
chmod 700 "$INSTALLER_PATH"

"$PLATFORM_SHELL" "$INSTALLER_PATH" "$@"
