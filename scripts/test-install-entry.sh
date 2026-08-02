#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agentdock-install-entry-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

RELEASE_DIR="$TMP_ROOT/release"
FAKE_BIN="$TMP_ROOT/bin"
ENTRY="$TMP_ROOT/install.sh"
mkdir -p "$RELEASE_DIR" "$FAKE_BIN"
cp "$ROOT_DIR/scripts/install.sh" "$ENTRY"
chmod +x "$ENTRY"

cat > "$FAKE_BIN/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "${TEST_UNAME:?}"
EOF
chmod +x "$FAKE_BIN/uname"

cat > "$FAKE_BIN/zsh" <<'EOF'
#!/bin/sh
exec /bin/sh "$@"
EOF
chmod +x "$FAKE_BIN/zsh"

write_installer() {
  asset="$1"
  cat > "$RELEASE_DIR/$asset" <<'EOF'
#!/bin/sh
: "${TEST_OUTPUT:?}"
printf '%s\n' "$@" > "$TEST_OUTPUT"
EOF
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

write_installer install-linux-platform.sh
LINUX_OUTPUT="$TMP_ROOT/linux.args"
PATH="$FAKE_BIN:$PATH" \
TEST_UNAME=Linux \
TEST_OUTPUT="$LINUX_OUTPUT" \
AGENTDOCK_INSTALLER_BASE_URL="file://$RELEASE_DIR" \
  sh "$ENTRY" --mode "value with spaces"
assert_args "$LINUX_OUTPUT"

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
