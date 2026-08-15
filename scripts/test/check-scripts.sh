#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"

macos=false
case "${1:-}" in
  --macos) macos=true ;;
  "") ;;
  *)
    printf 'usage: %s [--macos]\n' "$0" >&2
    exit 2
    ;;
esac

posix_files=
bash_files=
zsh_files=

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  line=$(sed -n '1p' "$rel")
  case "$line" in
    *zsh*) zsh_files="$zsh_files $rel" ;;
    *bash*) bash_files="$bash_files $rel" ;;
    *) posix_files="$posix_files $rel" ;;
  esac
done <<EOF
$(git ls-files '*.sh')
EOF

syntax() {
  checker=$1
  shift
  [ "$#" -gt 0 ] || return 0
  command -v "$checker" >/dev/null 2>&1 || return 0
  # shellcheck disable=SC2086
  "$checker" -n "$@"
}

if [ "$macos" = true ]; then
  [ "$(uname -s)" = Darwin ] || {
    printf 'macOS script checks require Darwin\n' >&2
    exit 1
  }
  syntax zsh $zsh_files
  ./scripts/test/test-install-macos.sh
  ./scripts/test/test-macos-app.sh
  exit 0
fi

run_python() {
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 &&
      PYTHONDONTWRITEBYTECODE=1 "$candidate" -c 'import sys' >/dev/null 2>&1; then
      PYTHONDONTWRITEBYTECODE=1 "$candidate" "$@"
      return $?
    fi
  done
  printf 'python3 or python is required\n' >&2
  return 1
}

run_python ./scripts/test/test_shell_variable_boundaries.py
syntax sh $posix_files
syntax dash $posix_files
syntax bash $bash_files

if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  shellcheck $posix_files $bash_files
fi

./scripts/test/test-install-entry.sh
