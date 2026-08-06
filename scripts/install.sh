#!/bin/sh
set -eu

umask 077

DEFAULT_BASE_URL="https://github.com/uvwt/agentdock/releases/latest/download"
BASE_URL="${AGENTDOCK_INSTALLER_BASE_URL:-$DEFAULT_BASE_URL}"
TMP_ROOT=""
CLEAR_PUBLIC_URL=false
ENV_BACKUP=""
ENV_BACKUP_ACTIVE=false
TTY_IN="${AGENTDOCK_TTY_IN:-/dev/tty}"
TTY_OUT="${AGENTDOCK_TTY_OUT:-/dev/tty}"

if [ ! -r "$TTY_IN" ]; then
  TTY_IN="/dev/stdin"
fi
if [ ! -w "$TTY_OUT" ]; then
  TTY_OUT="/dev/stderr"
fi

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ "${ENV_BACKUP_ACTIVE:-false}" = true ] && [ -f "${ENV_BACKUP:-}" ]; then
    run_root cp "$ENV_BACKUP" "$(linux_env_file)" >/dev/null 2>&1 || true
  fi
  if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT HUP INT TERM

is_true() {
  case "${1:-false}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

run_root() {
  if is_true "${AGENTDOCK_NO_SUDO:-false}" || [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "需要 root 权限，请安装 sudo 或使用 root 运行。"
  fi
}

usage() {
  cat <<'USAGE'
AgentDock 安装与维护入口。

用法：
  sh install.sh                 简洁安装；已安装时显示维护菜单
  sh install.sh --advanced      使用完整高级安装流程
  sh install.sh --uninstall     Linux：移除服务，保留程序、配置和数据
  sh install.sh --uninstall --purge-config
                                同时清除配置，便于重新安装
  sh install.sh --uninstall --purge-data
                                完全清除 AgentDock 程序、配置和数据
USAGE
}

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

prompt_choice() {
  label="$1"
  default_value="$2"
  answer=""
  printf '%s [%s]: ' "$label" "$default_value" >>"$TTY_OUT"
  IFS= read -r answer <"$TTY_IN" || true
  printf '%s' "${answer:-$default_value}"
}

prompt_value() {
  label="$1"
  default_value="${2:-}"
  answer=""
  if [ -n "$default_value" ]; then
    printf '%s [%s]: ' "$label" "$default_value" >>"$TTY_OUT"
  else
    printf '%s: ' "$label" >>"$TTY_OUT"
  fi
  IFS= read -r answer <"$TTY_IN" || true
  printf '%s' "${answer:-$default_value}"
}

prompt_secret_required() {
  label="$1"
  answer=""
  printf '%s（输入不回显）: ' "$label" >>"$TTY_OUT"
  if [ -t 0 ] || [ "$TTY_IN" = "/dev/tty" ]; then
    stty -echo <"$TTY_IN" 2>/dev/null || true
    IFS= read -r answer <"$TTY_IN" || true
    stty echo <"$TTY_IN" 2>/dev/null || true
    printf '\n' >>"$TTY_OUT"
  else
    IFS= read -r answer <"$TTY_IN" || true
  fi
  [ -n "$answer" ] || die "$label 不能为空。"
  printf '%s' "$answer"
}

root_file_exists() {
  run_root test -f "$1"
}

read_env_assignment() {
  file="$1"
  key="$2"
  root_file_exists "$file" || return 0
  run_root awk -F= -v key="$key" '$1 == key {value=substr($0, index($0, "=") + 1)} END {print value}' "$file"
}

linux_env_file() {
  printf '%s' "${AGENTDOCK_ENV_FILE:-/etc/agentdock/agentdock.env}"
}

linux_cloudflared_env_file() {
  env_file="$(linux_env_file)"
  printf '%s/cloudflared.env' "$(dirname "$env_file")"
}

linux_tunnel_service_name() {
  printf '%s-cloudflared' "${AGENTDOCK_SERVICE_NAME:-agentdock}"
}

current_tunnel_mode() {
  mode="${AGENTDOCK_TUNNEL_MODE:-}"
  if [ -z "$mode" ]; then
    mode="$(read_env_assignment "$(linux_cloudflared_env_file)" AGENTDOCK_TUNNEL_MODE)"
  fi
  printf '%s' "${mode:-none}"
}

choose_public_access() {
  cat >>"$TTY_OUT" <<'CHOICE'

公网访问：
1) 仅本机
2) 临时公网地址
3) Cloudflare 固定地址
CHOICE
  choice="$(prompt_choice '选择' 1)"
  case "$choice" in
    1|none)
      AGENTDOCK_TUNNEL_MODE="none"
      CLEAR_PUBLIC_URL=true
      unset AGENTDOCK_SERVER_URL AGENTDOCK_CLOUDFLARE_TUNNEL_TOKEN 2>/dev/null || true
      ;;
    2|quick)
      AGENTDOCK_TUNNEL_MODE="quick"
      CLEAR_PUBLIC_URL=false
      unset AGENTDOCK_SERVER_URL AGENTDOCK_CLOUDFLARE_TUNNEL_TOKEN 2>/dev/null || true
      ;;
    3|named)
      AGENTDOCK_TUNNEL_MODE="named"
      CLEAR_PUBLIC_URL=false
      existing_url="$(read_env_assignment "$(linux_env_file)" AGENTDOCK_SERVER_URL)"
      AGENTDOCK_SERVER_URL="$(prompt_value 'HTTPS 公网地址' "$existing_url")"
      [ -n "$AGENTDOCK_SERVER_URL" ] || die "HTTPS 公网地址不能为空。"
      AGENTDOCK_CLOUDFLARE_TUNNEL_TOKEN="$(prompt_secret_required 'Cloudflare Tunnel Token')"
      ;;
    *) die "无效选择：$choice" ;;
  esac
  export AGENTDOCK_TUNNEL_MODE
  if [ -n "${AGENTDOCK_SERVER_URL:-}" ]; then
    export AGENTDOCK_SERVER_URL
  fi
  if [ -n "${AGENTDOCK_CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
    export AGENTDOCK_CLOUDFLARE_TUNNEL_TOKEN
  fi
}

backup_and_clear_public_url() {
  env_file="$(linux_env_file)"
  root_file_exists "$env_file" || return 0

  ENV_BACKUP="$TMP_ROOT/agentdock.env.before-public-reset"
  filtered_file="$TMP_ROOT/agentdock.env.without-public-url"
  run_root cp "$env_file" "$ENV_BACKUP"
  ENV_BACKUP_ACTIVE=true
  run_root awk '
    $0 !~ /^[[:space:]]*(export[[:space:]]+)?AGENTDOCK_SERVER_URL[[:space:]]*=/ { print }
  ' "$env_file" >"$filtered_file"
  run_root cp "$filtered_file" "$env_file"
}

restore_env_backup() {
  [ -n "$ENV_BACKUP" ] || return 0
  [ -f "$ENV_BACKUP" ] || return 0
  run_root cp "$ENV_BACKUP" "$(linux_env_file)"
  ENV_BACKUP_ACTIVE=false
}

commit_env_backup() {
  ENV_BACKUP_ACTIVE=false
}

require_safe_removal_path() {
  label="$1"
  path="$2"
  case "$path" in
    /*) ;;
    *) die "$label 必须是绝对路径：$path" ;;
  esac
  case "$path" in
    *"/../"*|*"/.."|*"/./"*|*"/.")
      die "拒绝删除包含路径跳转的目录（$label）：$path"
      ;;
  esac
  normalized_path="$path"
  while [ "$normalized_path" != "/" ] && [ "${normalized_path%/}" != "$normalized_path" ]; do
    normalized_path="${normalized_path%/}"
  done
  case "$normalized_path" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "拒绝删除危险路径（$label）：$path"
      ;;
  esac
}

install_quick_tunnel_retry_guard() {
  mode="$1"
  [ "$mode" = "quick" ] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0

  systemd_dir="${AGENTDOCK_SYSTEMD_DIR:-/etc/systemd/system}"
  service_name="$(linux_tunnel_service_name)"
  dropin_dir="$systemd_dir/$service_name.service.d"
  temp_file="$TMP_ROOT/agentdock-retry-limit.conf"

  cat >"$temp_file" <<'UNIT'
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
RestartSec=30
UNIT
  run_root mkdir -p "$dropin_dir"
  run_root install -m 0644 "$temp_file" "$dropin_dir/retry-limit.conf"
  run_root systemctl daemon-reload >/dev/null 2>&1 || true
  run_root systemctl reset-failed "$service_name" >/dev/null 2>&1 || true
}

remove_quick_tunnel_retry_guard() {
  systemd_dir="${AGENTDOCK_SYSTEMD_DIR:-/etc/systemd/system}"
  service_name="$(linux_tunnel_service_name)"
  dropin_dir="$systemd_dir/$service_name.service.d"
  managed_file="$dropin_dir/retry-limit.conf"
  if run_root test -e "$managed_file"; then
    run_root rm -f "$managed_file"
    run_root rmdir "$dropin_dir" >/dev/null 2>&1 || true
    if command -v systemctl >/dev/null 2>&1; then
      run_root systemctl daemon-reload >/dev/null 2>&1 || true
    fi
  fi
}

quick_tunnel_rate_limited() {
  log_file="$1"
  if grep -Eq '429 Too Many Requests|error code: 1015|status_code=.?429' "$log_file" 2>/dev/null; then
    return 0
  fi
  command -v journalctl >/dev/null 2>&1 || return 1
  service_name="$(linux_tunnel_service_name)"
  run_root journalctl -u "$service_name" -n 100 --no-pager 2>/dev/null \
    | grep -Eq '429 Too Many Requests|error code: 1015|status_code=.?429'
}

stop_rate_limited_tunnel() {
  command -v systemctl >/dev/null 2>&1 || return 0
  service_name="$(linux_tunnel_service_name)"
  run_root systemctl disable --now "$service_name" >/dev/null 2>&1 || true
}

print_linux_summary() {
  env_file="$(linux_env_file)"
  host="$(read_env_assignment "$env_file" AGENTDOCK_HOST)"
  port="$(read_env_assignment "$env_file" AGENTDOCK_PORT)"
  token="$(read_env_assignment "$env_file" AGENTDOCK_AUTH_TOKEN)"
  oauth_password="$(read_env_assignment "$env_file" AGENTDOCK_OAUTH_PASSWORD)"
  public_url="$(read_env_assignment "$env_file" AGENTDOCK_SERVER_URL)"
  mode="$(current_tunnel_mode)"
  host="${host:-127.0.0.1}"
  port="${port:-8765}"

  cat >>"$TTY_OUT" <<DONE

AgentDock 安装完成
本机地址：http://$host:$port/mcp
DONE
  if [ "$mode" != "none" ] && [ -n "$public_url" ]; then
    printf '公网地址：%s/mcp\n' "${public_url%/}" >>"$TTY_OUT"
  fi
  if [ -n "$token" ]; then
    printf 'Bearer Token：%s\n' "$token" >>"$TTY_OUT"
  fi
  if [ -n "$oauth_password" ]; then
    printf 'OAuth 密码：%s\n' "$oauth_password" >>"$TTY_OUT"
  fi
  printf '重新配置或卸载：再次运行 install.sh\n' >>"$TTY_OUT"
}

run_simple_linux_install() {
  installer_path="$1"
  shift
  mode="$(current_tunnel_mode)"
  install_quick_tunnel_retry_guard "$mode"
  if [ "$CLEAR_PUBLIC_URL" = true ]; then
    backup_and_clear_public_url
  fi

  install_log="$TMP_ROOT/linux-install.log"
  log "正在安装 AgentDock（公网模式：$mode）"
  status=0
  AGENTDOCK_NONINTERACTIVE=true \
    "$PLATFORM_SHELL" "$installer_path" "$@" >"$install_log" 2>&1 || status=$?

  if [ "$status" -ne 0 ]; then
    if quick_tunnel_rate_limited "$install_log"; then
      stop_rate_limited_tunnel
      printf 'ERROR: Cloudflare 临时 Tunnel 请求受限（429/1015），已停止 Tunnel 服务，避免持续重试。\n' >&2
      printf '请稍后重新运行安装器，或改用 Cloudflare 固定地址。\n' >&2
      restore_env_backup
      return "$status"
    fi
    restore_env_backup
    cat "$install_log" >&2
    return "$status"
  fi

  commit_env_backup
  if [ "$mode" != "quick" ]; then
    remove_quick_tunnel_retry_guard
  fi
  print_linux_summary
}

run_direct_linux_install() {
  installer_path="$1"
  guard_mode="$2"
  shift 2
  install_quick_tunnel_retry_guard "$guard_mode"

  status=0
  "$PLATFORM_SHELL" "$installer_path" "$@" || status=$?
  if [ "$status" -eq 0 ] && [ "$(current_tunnel_mode)" != "quick" ]; then
    remove_quick_tunnel_retry_guard
  fi
  return "$status"
}

linux_uninstall() {
  purge_config="$1"
  purge_data="$2"
  service_name="${AGENTDOCK_SERVICE_NAME:-agentdock}"
  tunnel_service_name="$service_name-cloudflared"
  systemd_dir="${AGENTDOCK_SYSTEMD_DIR:-/etc/systemd/system}"
  openrc_dir="${AGENTDOCK_OPENRC_DIR:-/etc/init.d}"
  env_file="$(linux_env_file)"
  config_dir="$(dirname "$env_file")"
  source_dir="${AGENTDOCK_SOURCE_DIR:-/opt/agentdock}"
  data_dir="${AGENTDOCK_DATA_DIR:-/srv/agentdock}"

  if is_true "$purge_config"; then
    require_safe_removal_path "配置目录" "$config_dir"
  fi
  if is_true "$purge_data"; then
    require_safe_removal_path "安装目录" "$source_dir"
    require_safe_removal_path "数据目录" "$data_dir"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    run_root systemctl disable --now "$tunnel_service_name" >/dev/null 2>&1 || true
    run_root systemctl disable --now "$service_name" >/dev/null 2>&1 || true
    run_root rm -f "$systemd_dir/$tunnel_service_name.service" "$systemd_dir/$service_name.service"
    run_root rm -rf "$systemd_dir/$tunnel_service_name.service.d"
    run_root systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  if [ -e "$openrc_dir/$tunnel_service_name" ] || [ -e "$openrc_dir/$service_name" ]; then
    if command -v rc-service >/dev/null 2>&1; then
      run_root rc-service "$tunnel_service_name" stop >/dev/null 2>&1 || true
      run_root rc-service "$service_name" stop >/dev/null 2>&1 || true
    fi
    if command -v rc-update >/dev/null 2>&1; then
      run_root rc-update del "$tunnel_service_name" default >/dev/null 2>&1 || true
      run_root rc-update del "$service_name" default >/dev/null 2>&1 || true
    fi
    run_root rm -f "$openrc_dir/$tunnel_service_name" "$openrc_dir/$service_name"
  fi

  if is_true "$purge_config"; then
    run_root rm -rf "$config_dir"
  fi
  if is_true "$purge_data"; then
    run_root rm -rf "$source_dir" "$data_dir"
  fi

  printf '\nAgentDock 已卸载。\n' >>"$TTY_OUT"
  if ! is_true "$purge_config"; then
    printf '已保留配置：%s\n' "$config_dir" >>"$TTY_OUT"
  fi
  if ! is_true "$purge_data"; then
    printf '已保留程序和数据：%s、%s\n' "$source_dir" "$data_dir" >>"$TTY_OUT"
  fi
  printf 'cloudflared 未删除，避免影响其他服务。\n' >>"$TTY_OUT"
}

choose_uninstall_scope() {
  cat >>"$TTY_OUT" <<'CHOICE'

卸载范围：
1) 仅移除服务，保留配置和数据
2) 同时清除配置，便于重新安装
3) 完全清除程序、配置和数据
CHOICE
  choice="$(prompt_choice '选择' 1)"
  case "$choice" in
    1) linux_uninstall false false ;;
    2) linux_uninstall true false ;;
    3) linux_uninstall true true ;;
    *) die "无效选择：$choice" ;;
  esac
}

linux_existing_menu() {
  cat >>"$TTY_OUT" <<'MENU'

检测到已安装 AgentDock：
1) 更新或修复（保留当前配置）
2) 修改公网访问
3) 卸载
4) 高级安装
MENU
  choice="$(prompt_choice '选择' 1)"
  case "$choice" in
    1) SIMPLE_INSTALL=true ;;
    2) choose_public_access; SIMPLE_INSTALL=true ;;
    3) choose_uninstall_scope; exit 0 ;;
    4) ADVANCED=true ;;
    *) die "无效选择：$choice" ;;
  esac
}

ADVANCED=false
UNINSTALL=false
PURGE_CONFIG=false
PURGE_DATA=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --advanced)
      ADVANCED=true
      shift
      ;;
    --uninstall)
      UNINSTALL=true
      shift
      ;;
    --purge-config)
      PURGE_CONFIG=true
      shift
      ;;
    --purge-data)
      PURGE_CONFIG=true
      PURGE_DATA=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

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

if [ "$UNINSTALL" = true ]; then
  [ "$PLATFORM_INSTALLER" = "install-linux-platform.sh" ] || die "--uninstall 当前仅支持 Linux。"
  linux_uninstall "$PURGE_CONFIG" "$PURGE_DATA"
  exit 0
fi
if [ "$PURGE_CONFIG" = true ] || [ "$PURGE_DATA" = true ]; then
  die "--purge-config/--purge-data 必须与 --uninstall 一起使用。"
fi

command -v "$PLATFORM_SHELL" >/dev/null 2>&1 || die "缺少 $PLATFORM_SHELL，无法运行 $PLATFORM_INSTALLER。"

# 源码开发需要显式开启本地模式；Release 用户始终下载并校验平台安装器。
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agentdock-installer.XXXXXX")"

if [ "${AGENTDOCK_USE_LOCAL_PLATFORM_INSTALLER:-false}" = "true" ]; then
  case "$0" in
    */*) SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)" ;;
    *) die "本地平台安装器模式要求从文件路径执行 install.sh。" ;;
  esac
  INSTALLER_PATH="$SCRIPT_DIR/$PLATFORM_INSTALLER"
  [ -f "$INSTALLER_PATH" ] || die "找不到本地平台安装器：$INSTALLER_PATH"
else
  INSTALLER_PATH="$TMP_ROOT/$PLATFORM_INSTALLER"
  CHECKSUM_PATH="$INSTALLER_PATH.sha256"

  log "下载 AgentDock 平台安装器：$PLATFORM_INSTALLER"
  download_file "$BASE_URL/$PLATFORM_INSTALLER" "$INSTALLER_PATH"
  download_file "$BASE_URL/$PLATFORM_INSTALLER.sha256" "$CHECKSUM_PATH"
  verify_checksum "$INSTALLER_PATH" "$CHECKSUM_PATH"
  chmod 700 "$INSTALLER_PATH"
fi

if [ "$PLATFORM_INSTALLER" != "install-linux-platform.sh" ]; then
  "$PLATFORM_SHELL" "$INSTALLER_PATH" "$@"
  exit $?
fi

if is_true "${AGENTDOCK_NONINTERACTIVE:-false}"; then
  run_direct_linux_install "$INSTALLER_PATH" "$(current_tunnel_mode)" "$@"
  exit $?
fi

SIMPLE_INSTALL=false
if [ "$ADVANCED" = true ]; then
  # 高级流程可能在脚本内部选择 Quick Tunnel，因此预先安装保护；成功后按实际模式清理。
  run_direct_linux_install "$INSTALLER_PATH" quick "$@"
  exit $?
fi

if root_file_exists "$(linux_env_file)"; then
  linux_existing_menu
else
  if [ -z "${AGENTDOCK_TUNNEL_MODE:-}" ]; then
    choose_public_access
  fi
  SIMPLE_INSTALL=true
fi

if [ "$ADVANCED" = true ]; then
  run_direct_linux_install "$INSTALLER_PATH" quick "$@"
  exit $?
fi

if [ "$SIMPLE_INSTALL" = true ]; then
  run_simple_linux_install "$INSTALLER_PATH" "$@"
  exit $?
fi

die "未选择安装操作。"
