#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agentdock-linux-native-test.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

mkdir -p "$TMP_ROOT/runtime" "$TMP_ROOT/bin"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -o "$TMP_ROOT/agentdock" "$ROOT_DIR/cmd/agentdock"

cat > "$TMP_ROOT/cloudflared.go" <<'GO'
package main

import (
	"fmt"
	"time"
)

func main() {
	fmt.Println("INF Quick Tunnel available at https://linux-native.trycloudflare.com")
	for {
		time.Sleep(time.Hour)
	}
}
GO
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -o "$TMP_ROOT/cloudflared" "$TMP_ROOT/cloudflared.go"

cat > "$TMP_ROOT/bin/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> /test/runtime/systemctl.log
exit 0
SH
chmod 0755 "$TMP_ROOT/bin/systemctl" "$TMP_ROOT/agentdock" "$TMP_ROOT/cloudflared"

cat > "$TMP_ROOT/runtime/agentdock.env" <<'ENV'
AGENTDOCK_HOST=127.0.0.1
AGENTDOCK_PORT=18876
AGENTDOCK_AUTH_TOKEN=linux-native-token
AGENTDOCK_LOG_LEVEL=info
AGENTDOCK_OAUTH_ENABLED=false
AGENTDOCK_OAUTH_PASSWORD=linux-native-password
AGENTDOCK_OAUTH_TOKEN_SECRET=linux-native-secret-0123456789abcdef
ENV
cat > "$TMP_ROOT/runtime/cloudflared.env" <<'ENV'
AGENTDOCK_TUNNEL_MODE=quick
AGENTDOCK_TUNNEL_TARGET=http://127.0.0.1:18876
ENV
cat > "$TMP_ROOT/runtime/desktop-runtime.json" <<'JSON'
{
  "schema_version": 1,
  "service_manager": "systemd",
  "service_name": "agentdock-native-test",
  "tunnel_service_name": "agentdock-native-test-cloudflared",
  "agentdock_binary": "/test/agentdock",
  "cloudflared_binary": "/test/cloudflared",
  "environment_file": "/test/runtime/agentdock.env",
  "tunnel_environment": "/test/runtime/cloudflared.env"
}
JSON
chmod 0600 "$TMP_ROOT/runtime/agentdock.env" "$TMP_ROOT/runtime/cloudflared.env"
chmod 0700 "$TMP_ROOT/runtime"

# shellcheck disable=SC2016
docker run --rm --platform linux/amd64 \
  -v "$TMP_ROOT:/test" \
  -e PATH=/test/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  alpine:3.22 /bin/sh -eu -c '
    cleanup() {
      [ -z "${tunnel_pid:-}" ] || kill "$tunnel_pid" 2>/dev/null || true
      [ -z "${core_pid:-}" ] || kill "$core_pid" 2>/dev/null || true
    }
    trap cleanup EXIT

    /test/agentdock service launch-core --runtime-root /test/runtime > /test/runtime/core.log 2>&1 &
    core_pid=$!
    i=0
    while [ ! -S /test/runtime/control.sock ]; do
      i=$((i + 1))
      [ "$i" -lt 100 ] || { cat /test/runtime/core.log >&2; exit 1; }
      sleep 0.1
    done

    status="$(/test/agentdock service status --runtime-root /test/runtime)"
    echo "$status" | grep -q "\"running\":true"
    echo "$status" | grep -q "\"healthy\":true"
    test "$(stat -c %a /test/runtime/control.sock)" = 600

    /test/agentdock tunnel launch --runtime-root /test/runtime > /test/runtime/tunnel.log 2>&1 &
    tunnel_pid=$!
    i=0
    while [ ! -s /test/runtime/quick-tunnel-url.txt ]; do
      i=$((i + 1))
      [ "$i" -lt 150 ] || { cat /test/runtime/tunnel.log >&2; exit 1; }
      sleep 0.1
    done

    grep -q "^https://linux-native.trycloudflare.com$" /test/runtime/quick-tunnel-url.txt
    grep -q "AGENTDOCK_SERVER_URL=.*linux-native.trycloudflare.com" /test/runtime/agentdock.env
    grep -q "^restart agentdock-native-test$" /test/runtime/systemctl.log
    test ! -e /test/runtime/start-agentdock.sh
    test ! -e /test/runtime/start-cloudflared.sh
  '

printf '%s\n' "Linux native runtime tests passed"
