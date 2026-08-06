#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agentdock-install-entry-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

export AGENTDOCK_TTY_IN=/dev/stdin
export AGENTDOCK_TTY_OUT=/dev/stderr

RELEASE_DIR="$TMP_ROOT/release"
FAKE_BIN="$TMP_ROOT/bin"
ENTRY="$TMP_ROOT/install.sh"
mkdir -p "$RELEASE_DIR" "$FAKE_BIN"
cp "$ROOT_DIR/scripts/install.sh" "$ENTRY"
chmod +x "$ENTRY"

cat > "$FAKE_BIN/uname" <<'SH'
#!/bin/sh
printf '%s\n' "${TEST_UNAME:?}"
SH
chmod +x "$FAKE_BIN/uname"

cat > "$FAKE_BIN/zsh" <<'SH'
#!/bin/sh
exec /bin/sh "$@"
SH
chmod +x "$FAKE_BIN/zsh"

cat > "$FAKE_BIN/systemctl" <<'SH'
#!/bin/sh
if [ -n "${TEST_SYSTEMCTL_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$TEST_SYSTEMCTL_LOG"
fi
exit 0
SH
chmod +x "$FAKE_BIN/systemctl"

for command_name in rc-service rc-update; do
  cat > "$FAKE_BIN/$command_name" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$FAKE_BIN/$command_name"
done

write_installer() {
  asset="$1"
  cat > "$RELEASE_DIR/$asset" <<'SH'
#!/bin/sh
set -eu
if [ -n "${TEST_OUTPUT:-}" ]; then
  printf '%s\n' "$@" > "$TEST_OUTPUT"
fi
existing_server_url=''
if [ -n "${AGENTDOCK_ENV_FILE:-}" ] && [ -f "$AGENTDOCK_ENV_FILE" ]; then
  existing_server_url="$(awk -F= '$1 == "AGENTDOCK_SERVER_URL" {value=substr($0, index($0, "=") + 1)} END {print value}' "$AGENTDOCK_ENV_FILE")"
fi
if [ -n "${TEST_ENV_OUTPUT:-}" ]; then
  {
    printf 'noninteractive=%s\n' "${AGENTDOCK_NONINTERACTIVE:-}"
    printf 'tunnel_mode=%s\n' "${AGENTDOCK_TUNNEL_MODE:-}"
    printf 'server_url=%s\n' "${AGENTDOCK_SERVER_URL:-}"
    printf 'tunnel_token=%s\n' "${AGENTDOCK_CLOUDFLARE_TUNNEL_TOKEN:-}"
    printf 'existing_server_url=%s\n' "$existing_server_url"
  } > "$TEST_ENV_OUTPUT"
fi
if [ "${TEST_FAIL_RATE_LIMIT:-false}" = "true" ]; then
  printf '%s\n' 'error code: 1015 status_code="429 Too Many Requests"' >&2
  exit 1
fi
if [ "${TEST_WRITE_ENV:-false}" = "true" ]; then
  : "${AGENTDOCK_ENV_FILE:?}"
  config_dir="$(dirname "$AGENTDOCK_ENV_FILE")"
  mkdir -p "$config_dir"
  public_url="${AGENTDOCK_SERVER_URL:-}"
  if [ "${AGENTDOCK_TUNNEL_MODE:-none}" = "quick" ]; then
    public_url="https://quick-test.trycloudflare.com"
  fi
  cat > "$AGENTDOCK_ENV_FILE" <<ENV
AGENTDOCK_HOST=127.0.0.1
AGENTDOCK_PORT=8765
AGENTDOCK_AUTH_TOKEN=test-bearer-token
AGENTDOCK_OAUTH_PASSWORD=test-oauth-password
AGENTDOCK_SERVER_URL=$public_url
ENV
  printf 'AGENTDOCK_TUNNEL_MODE=%s\n' "${AGENTDOCK_TUNNEL_MODE:-none}" > "$config_dir/cloudflared.env"
fi
SH
  chmod +x "$RELEASE_DIR/$asset"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$RELEASE_DIR" && sha256sum "$asset" > "$asset.sha256")
  else
    (cd "$RELEASE_DIR" && shasum -a 256 "$asset" > "$asset.sha256")
  fi
}

assert_args() {
  output="$1"
  first="$(sed -n '1p' "$output")"
  second="$(sed -n '2p' "$output")"
  [ "$first" = "--mode" ]
  [ "$second" = "value with spaces" ]
}

assert_line() {
  expected="$1"
  file="$2"
  grep -Fqx "$expected" "$file"
}

write_installer install-linux-platform.sh
LINUX_OUTPUT="$TMP_ROOT/linux.args"
LINUX_ENV_OUTPUT="$TMP_ROOT/linux.env"
printf '\n' | PATH="$FAKE_BIN:$PATH" \
TEST_UNAME=Linux \
TEST_OUTPUT="$LINUX_OUTPUT" \
TEST_ENV_OUTPUT="$LINUX_ENV_OUTPUT" \
AGENTDOCK_ENV_FILE="$TMP_ROOT/linux-config/agentdock.env" \
AGENTDOCK_INSTALLER_BASE_URL="file://$RELEASE_DIR" \
  sh "$ENTRY" --mode "value with spaces"
assert_args "$LINUX_OUTPUT"
assert_line 'noninteractive=true' "$LINUX_ENV_OUTPUT"
assert_line 'tunnel_mode=none' "$LINUX_ENV_OUTPUT"

LOCAL_ROOT="$TMP_ROOT/local"
mkdir -p "$LOCAL_ROOT"
cp "$ENTRY" "$LOCAL_ROOT/install.sh"
cp "$RELEASE_DIR/install-linux-platform.sh" "$LOCAL_ROOT/install-linux-platform.sh"
printf '\n' | PATH="$FAKE_BIN:$PATH" \
TEST_UNAME=Linux \
TEST_ENV_OUTPUT="$LOCAL_ROOT/platform.env" \
AGENTDOCK_NO_SUDO=true \
AGENTDOCK_ENV_FILE="$LOCAL_ROOT/config/agentdock.env" \
AGENTDOCK_USE_LOCAL_PLATFORM_INSTALLER=true \
  sh "$LOCAL_ROOT/install.sh"
assert_line 'noninteractive=true' "$LOCAL_ROOT/platform.env"
assert_line 'tunnel_mode=none' "$LOCAL_ROOT/platform.env"

QUICK_ROOT="$TMP_ROOT/quick"
QUICK_ENV_OUTPUT="$QUICK_ROOT/platform.env"
QUICK_SYSTEMD="$QUICK_ROOT/systemd"
mkdir -p "$QUICK_ROOT"
printf '2\n' | PATH="$FAKE_BIN:$PATH" \
TEST_UNAME=Linux \
TEST_ENV_OUTPUT="$QUICK_ENV_OUTPUT" \
TEST_WRITE_ENV=true \
TEST_SYSTEMCTL_LOG="$QUICK_ROOT/systemctl.log" \
AGENTDOCK_NO_SUDO=true \
AGENTDOCK_ENV_FILE="$QUICK_ROOT/config/agentdock.env" \
AGENTDOCK_SYSTEMD_DIR="$QUICK_SYSTEMD" \
AGENTDOCK_INSTALLER_BASE_URL="file://$RELEASE_DIR" \
  sh "$ENTRY"
assert_line 'noninteractive=true' "$QUICK_ENV_OUTPUT"
assert_line 'tunnel_mode=quick' "$QUICK_ENV_OUTPUT"
QUICK_GUARD="$QUICK_SYSTEMD/agentdock-cloudflared.service.d/retry-limit.conf"
[ -f "$QUICK_GUARD" ]
grep -Fq 'StartLimitBurst=3' "$QUICK_GUARD"
grep -Fq 'RestartSec=30' "$QUICK_GUARD"

UPDATE_ROOT="$TMP_ROOT/update"
mkdir -p "$UPDATE_ROOT/config"
printf '%s\n' \
  'AGENTDOCK_HOST=127.0.0.1' \
  'AGENTDOCK_PORT=8765' \
  'AGENTDOCK_AUTH_TOKEN=preserved-token' \
  > "$UPDATE_ROOT/config/agentdock.env"
printf 'AGENTDOCK_TUNNEL_MODE=quick\n' > "$UPDATE_ROOT/config/cloudflared.env"
printf '\n' | PATH="$FAKE_BIN:$PATH" \
TEST_UNAME=Linux \
TEST_ENV_OUTPUT="$UPDATE_ROOT/platform.env" \
AGENTDOCK_NO_SUDO=true \
AGENTDOCK_ENV_FILE="$UPDATE_ROOT/config/agentdock.env" \
AGENTDOCK_SYSTEMD_DIR="$UPDATE_ROOT/systemd" \
AGENTDOCK_INSTALLER_BASE_URL="file://$RELEASE_DIR" \
  sh "$ENTRY"
assert_line 'noninteractive=true' "$UPDATE_ROOT/platform.env"
assert_line 'tunnel_mode=' "$UPDATE_ROOT/platform.env"
[ -f "$UPDATE_ROOT/systemd/agentdock-cloudflared.service.d/retry-limit.conf" ]

echo 'AGENTDOCK_SERVER_URL=https://old.example.com' >> "$UPDATE_ROOT/config/agentdock.env"
printf '2\n3\nhttps://new.example.com\nnew-tunnel-token\n' | PATH="$FAKE_BIN:$PATH" \
TEST_UNAME=Linux \
TEST_ENV_OUTPUT="$UPDATE_ROOT/reconfigure.env" \
TEST_WRITE_ENV=true \
AGENTDOCK_NO_SUDO=true \
AGENTDOCK_ENV_FILE="$UPDATE_ROOT/config/agentdock.env" \
AGENTDOCK_SYSTEMD_DIR="$UPDATE_ROOT/systemd-named" \
AGENTDOCK_INSTALLER_BASE_URL="file://$RELEASE_DIR" \
  sh "$ENTRY"
assert_line 'tunnel_mode=named' "$UPDATE_ROOT/reconfigure.env"
assert_line 'server_url=https://new.example.com' "$UPDATE_ROOT/reconfigure.env"
assert_line 'tunnel_token=new-tunnel-token' "$UPDATE_ROOT/reconfigure.env"
[ ! -d "$UPDATE_ROOT/systemd-named/agentdock-cloudflared.service.d" ]

NONE_SYSTEMD="$UPDATE_ROOT/systemd-none"
mkdir -p "$NONE_SYSTEMD/agentdock-cloudflared.service.d"
printf 'stale\n' > "$NONE_SYSTEMD/agentdock-cloudflared.service.d/retry-limit.conf"
printf 'custom\n' > "$NONE_SYSTEMD/agentdock-cloudflared.service.d/custom.conf"
printf 'AGENTDOCK_TUNNEL_MODE=quick\n' > "$UPDATE_ROOT/config/cloudflared.env"
printf '2\n1\n' | PATH="$FAKE_BIN:$PATH" \
TEST_UNAME=Linux \
TEST_ENV_OUTPUT="$UPDATE_ROOT/none.env" \
TEST_WRITE_ENV=true \
AGENTDOCK_NO_SUDO=true \
AGENTDOCK_ENV_FILE="$UPDATE_ROOT/config/agentdock.env" \
AGENTDOCK_SYSTEMD_DIR="$NONE_SYSTEMD" \
AGENTDOCK_INSTALLER_BASE_URL="file://$RELEASE_DIR" \
  sh "$ENTRY"
assert_line 'tunnel_mode=none' "$UPDATE_ROOT/none.env"
assert_line 'existing_server_url=' "$UPDATE_ROOT/none.env"
[ ! -e "$NONE_SYSTEMD/agentdock-cloudflared.service.d/retry-limit.conf" ]
[ -f "$NONE_SYSTEMD/agentdock-cloudflared.service.d/custom.conf" ]

RESTORE_ROOT="$TMP_ROOT/restore"
mkdir -p "$RESTORE_ROOT/config"
printf '%s\n' \
  'AGENTDOCK_HOST=127.0.0.1' \
  'AGENTDOCK_SERVER_URL=https://preserve.example.com' \
  > "$RESTORE_ROOT/config/agentdock.env"
printf 'AGENTDOCK_TUNNEL_MODE=named\n' > "$RESTORE_ROOT/config/cloudflared.env"
if printf '2\n1\n' | PATH="$FAKE_BIN:$PATH" \
  TEST_UNAME=Linux \
  TEST_FAIL_RATE_LIMIT=true \
  TEST_SYSTEMCTL_LOG="$RESTORE_ROOT/systemctl.log" \
  AGENTDOCK_NO_SUDO=true \
  AGENTDOCK_ENV_FILE="$RESTORE_ROOT/config/agentdock.env" \
  AGENTDOCK_SYSTEMD_DIR="$RESTORE_ROOT/systemd" \
  AGENTDOCK_INSTALLER_BASE_URL="file://$RELEASE_DIR" \
    sh "$ENTRY" >"$RESTORE_ROOT/stdout.log" 2>"$RESTORE_ROOT/stderr.log"; then
  printf 'failed reconfiguration unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fqx 'AGENTDOCK_SERVER_URL=https://preserve.example.com' "$RESTORE_ROOT/config/agentdock.env"

RATE_ROOT="$TMP_ROOT/rate-limit"
mkdir -p "$RATE_ROOT"
if printf '2\n' | PATH="$FAKE_BIN:$PATH" \
  TEST_UNAME=Linux \
  TEST_FAIL_RATE_LIMIT=true \
  TEST_SYSTEMCTL_LOG="$RATE_ROOT/systemctl.log" \
  AGENTDOCK_NO_SUDO=true \
  AGENTDOCK_ENV_FILE="$RATE_ROOT/config/agentdock.env" \
  AGENTDOCK_SYSTEMD_DIR="$RATE_ROOT/systemd" \
  AGENTDOCK_INSTALLER_BASE_URL="file://$RELEASE_DIR" \
    sh "$ENTRY" >"$RATE_ROOT/stdout.log" 2>"$RATE_ROOT/stderr.log"; then
  printf 'rate-limited installer unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fq '429/1015' "$RATE_ROOT/stderr.log"
grep -Fq 'disable --now agentdock-cloudflared' "$RATE_ROOT/systemctl.log"

UNINSTALL_ROOT="$TMP_ROOT/uninstall"
mkdir -p \
  "$UNINSTALL_ROOT/config" \
  "$UNINSTALL_ROOT/source" \
  "$UNINSTALL_ROOT/data" \
  "$UNINSTALL_ROOT/systemd/agentdock-cloudflared.service.d" \
  "$UNINSTALL_ROOT/openrc"
printf 'AGENTDOCK_HOST=127.0.0.1\n' > "$UNINSTALL_ROOT/config/agentdock.env"
printf 'unit\n' > "$UNINSTALL_ROOT/systemd/agentdock.service"
printf 'unit\n' > "$UNINSTALL_ROOT/systemd/agentdock-cloudflared.service"
printf 'dropin\n' > "$UNINSTALL_ROOT/systemd/agentdock-cloudflared.service.d/retry-limit.conf"
printf 'service\n' > "$UNINSTALL_ROOT/openrc/agentdock"
printf 'service\n' > "$UNINSTALL_ROOT/openrc/agentdock-cloudflared"
PATH="$FAKE_BIN:$PATH" \
TEST_UNAME=Linux \
AGENTDOCK_NO_SUDO=true \
AGENTDOCK_ENV_FILE="$UNINSTALL_ROOT/config/agentdock.env" \
AGENTDOCK_SOURCE_DIR="$UNINSTALL_ROOT/source" \
AGENTDOCK_DATA_DIR="$UNINSTALL_ROOT/data" \
AGENTDOCK_SYSTEMD_DIR="$UNINSTALL_ROOT/systemd" \
AGENTDOCK_OPENRC_DIR="$UNINSTALL_ROOT/openrc" \
  sh "$ENTRY" --uninstall --purge-config
[ ! -d "$UNINSTALL_ROOT/config" ]
[ -d "$UNINSTALL_ROOT/source" ]
[ -d "$UNINSTALL_ROOT/data" ]
[ ! -e "$UNINSTALL_ROOT/systemd/agentdock.service" ]
[ ! -e "$UNINSTALL_ROOT/systemd/agentdock-cloudflared.service" ]
[ ! -d "$UNINSTALL_ROOT/systemd/agentdock-cloudflared.service.d" ]

PURGE_ROOT="$TMP_ROOT/purge"
mkdir -p "$PURGE_ROOT/config" "$PURGE_ROOT/source" "$PURGE_ROOT/data" "$PURGE_ROOT/systemd" "$PURGE_ROOT/openrc"
printf 'AGENTDOCK_HOST=127.0.0.1\n' > "$PURGE_ROOT/config/agentdock.env"
PATH="$FAKE_BIN:$PATH" \
TEST_UNAME=Linux \
AGENTDOCK_NO_SUDO=true \
AGENTDOCK_ENV_FILE="$PURGE_ROOT/config/agentdock.env" \
AGENTDOCK_SOURCE_DIR="$PURGE_ROOT/source" \
AGENTDOCK_DATA_DIR="$PURGE_ROOT/data" \
AGENTDOCK_SYSTEMD_DIR="$PURGE_ROOT/systemd" \
AGENTDOCK_OPENRC_DIR="$PURGE_ROOT/openrc" \
  sh "$ENTRY" --uninstall --purge-data
[ ! -d "$PURGE_ROOT/config" ]
[ ! -d "$PURGE_ROOT/source" ]
[ ! -d "$PURGE_ROOT/data" ]

if PATH="$FAKE_BIN:$PATH" \
  TEST_UNAME=Linux \
  AGENTDOCK_NO_SUDO=true \
  AGENTDOCK_ENV_FILE=/agentdock.env \
    sh "$ENTRY" --uninstall --purge-config >"$TMP_ROOT/dangerous.out" 2>"$TMP_ROOT/dangerous.err"; then
  printf 'uninstaller accepted a dangerous config path\n' >&2
  exit 1
fi
grep -Fq '拒绝删除危险路径' "$TMP_ROOT/dangerous.err"

if PATH="$FAKE_BIN:$PATH" \
  TEST_UNAME=Linux \
  AGENTDOCK_NO_SUDO=true \
  AGENTDOCK_ENV_FILE="$TMP_ROOT/safe-config/agentdock.env" \
  AGENTDOCK_SOURCE_DIR=/opt/agentdock/../.. \
  AGENTDOCK_DATA_DIR="$TMP_ROOT/safe-data" \
    sh "$ENTRY" --uninstall --purge-data >"$TMP_ROOT/traversal.out" 2>"$TMP_ROOT/traversal.err"; then
  printf 'uninstaller accepted a traversal path\n' >&2
  exit 1
fi
grep -Fq '路径跳转' "$TMP_ROOT/traversal.err"

write_installer install-macos-platform.sh
MACOS_OUTPUT="$TMP_ROOT/macos.args"
PATH="$FAKE_BIN:$PATH" \
TEST_UNAME=Darwin \
TEST_OUTPUT="$MACOS_OUTPUT" \
AGENTDOCK_INSTALLER_BASE_URL="file://$RELEASE_DIR" \
  sh "$ENTRY" --mode "value with spaces"
assert_args "$MACOS_OUTPUT"

printf '%s\n' '0000000000000000000000000000000000000000000000000000000000000000  install-linux-platform.sh' \
  > "$RELEASE_DIR/install-linux-platform.sh.sha256"
if PATH="$FAKE_BIN:$PATH" \
  TEST_UNAME=Linux \
  TEST_OUTPUT="$TMP_ROOT/invalid.args" \
  AGENTDOCK_INSTALLER_BASE_URL="file://$RELEASE_DIR" \
  sh "$ENTRY" >/dev/null 2>&1; then
  printf 'installer accepted an invalid checksum\n' >&2
  exit 1
fi

if PATH="$FAKE_BIN:$PATH" TEST_UNAME=FreeBSD sh "$ENTRY" >/dev/null 2>&1; then
  printf 'installer accepted an unsupported operating system\n' >&2
  exit 1
fi

printf 'unified installer entry tests passed\n'
