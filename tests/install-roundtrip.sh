#!/usr/bin/env bash
# Verify install.sh / uninstall.sh round-trip behavior in a sandboxed HOME.
# Exits non-zero on any failure. Designed to run identically in CI and locally.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK"

passes=0
failures=0
current_test=""

start_test() {
  current_test="$1"
  printf '\n--- %s ---\n' "$current_test"
}

pass() {
  passes=$((passes + 1))
  printf '  PASS: %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf '  FAIL: %s\n' "$1" >&2
}

assert_same() {
  local label=$1 a=$2 b=$3
  if cmp -s "$a" "$b"; then
    pass "$label"
  else
    fail "$label"
    {
      printf '    --- expected (hex) ---\n'
      xxd "$a" || true
      printf '    --- actual (hex) ---\n'
      xxd "$b" || true
    } >&2
  fi
}

assert_eq() {
  local label=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail "$label (expected '$expected', got '$actual')"
  fi
}

assert_nonzero() {
  local label=$1 rc=$2
  if [[ "$rc" -ne 0 ]]; then
    pass "$label"
  else
    fail "$label (expected non-zero exit, got $rc)"
  fi
}

setup_clean() {
  rm -f "$HOME/.bashrc" "$HOME/.zshrc"
  rm -rf "$HOME/.config/fish"
  mkdir -p "$HOME/.config/fish"
}

install_sh="$PROJECT_ROOT/bin/install.sh"
uninstall_sh="$PROJECT_ROOT/bin/uninstall.sh"

# --- Per-shell round-trip tests -------------------------------------------

shells_to_test=()
for s in bash zsh fish; do
  if command -v "$s" >/dev/null 2>&1; then
    shells_to_test+=("$s")
  else
    printf 'skip: %s not in PATH on this runner\n' "$s"
  fi
done

shell_rc_path() {
  case "$1" in
    bash) printf '%s\n' "$HOME/.bashrc" ;;
    zsh)  printf '%s\n' "$HOME/.zshrc" ;;
    fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
  esac
}

shell_rc_seed() {
  # The seeded rc lines should be written literally; the $PATH references are
  # for the *target* shell to expand when it later sources the file.
  # shellcheck disable=SC2016
  case "$1" in
    bash) printf 'export PATH=/foo:$PATH\nalias ll="ls -la"\n' ;;
    zsh)  printf '# my zsh config\nalias ll="ls -la"\nexport EDITOR=vim\n' ;;
    fish) printf 'set -gx PATH /foo $PATH\nalias ll "ls -la"\n' ;;
  esac
}

for shell_name in "${shells_to_test[@]}"; do
  start_test "$shell_name: standard install -> uninstall round-trip"
  setup_clean
  rc=$(shell_rc_path "$shell_name")
  shell_rc_seed "$shell_name" > "$rc.orig"
  cp "$rc.orig" "$rc"
  "$install_sh" "$shell_name" >/dev/null
  "$uninstall_sh" "$shell_name" >/dev/null
  assert_same "$shell_name round-trip is byte-identical" "$rc.orig" "$rc"
done

# --- Edge cases (run with whichever shells are available) -----------------

if [[ " ${shells_to_test[*]} " == *" zsh "* ]]; then
  start_test "empty rc file: install -> uninstall returns to size 0"
  setup_clean
  : > "$HOME/.zshrc"
  "$install_sh" zsh >/dev/null
  "$uninstall_sh" zsh >/dev/null
  size=$(wc -c < "$HOME/.zshrc" | tr -d ' ')
  assert_eq "empty rc round-trip size" "0" "$size"

  start_test "user's trailing blank line preserved"
  setup_clean
  printf 'foo\n\n' > "$HOME/.zshrc.orig"
  cp "$HOME/.zshrc.orig" "$HOME/.zshrc"
  "$install_sh" zsh >/dev/null
  "$uninstall_sh" zsh >/dev/null
  assert_same "trailing blank preserved" "$HOME/.zshrc.orig" "$HOME/.zshrc"

  start_test "double install -> single uninstall removes both blocks"
  setup_clean
  echo "alias x=y" > "$HOME/.zshrc"
  cp "$HOME/.zshrc" "$HOME/.zshrc.orig"
  "$install_sh" zsh >/dev/null
  # Append a manual second copy to simulate weird state.
  {
    printf '\n'
    printf '# cmatrix-screensaver\n'
    printf 'source "%s/zsh/cmatrix-screensaver.zsh"\n' "$PROJECT_ROOT"
  } >> "$HOME/.zshrc"
  "$uninstall_sh" zsh >/dev/null
  assert_same "double-install cleaned" "$HOME/.zshrc.orig" "$HOME/.zshrc"

  start_test "marker-only broken state: marker is removed"
  setup_clean
  {
    printf 'before\n\n'
    printf '# cmatrix-screensaver\n'
    printf 'after\n'
  } > "$HOME/.zshrc"
  "$uninstall_sh" zsh >/dev/null
  expected=$(printf 'before\nafter\n')
  actual=$(cat "$HOME/.zshrc")
  assert_eq "marker-only cleanup" "$expected" "$actual"

  start_test "source-only broken state: source line is removed"
  setup_clean
  {
    printf 'before\n'
    printf 'source "%s/zsh/cmatrix-screensaver.zsh"\n' "$PROJECT_ROOT"
    printf 'after\n'
  } > "$HOME/.zshrc"
  "$uninstall_sh" zsh >/dev/null
  expected=$(printf 'before\nafter\n')
  actual=$(cat "$HOME/.zshrc")
  assert_eq "source-only cleanup" "$expected" "$actual"

  start_test "uninstall when not installed is a no-op"
  setup_clean
  echo "alias x=y" > "$HOME/.zshrc"
  cp "$HOME/.zshrc" "$HOME/.zshrc.orig"
  "$uninstall_sh" zsh >/dev/null
  assert_same "no-op uninstall" "$HOME/.zshrc.orig" "$HOME/.zshrc"

  start_test "install is idempotent (running twice is same as once)"
  setup_clean
  echo "alias x=y" > "$HOME/.zshrc"
  "$install_sh" zsh >/dev/null
  cp "$HOME/.zshrc" "$HOME/.zshrc.first"
  "$install_sh" zsh >/dev/null
  assert_same "install idempotency" "$HOME/.zshrc.first" "$HOME/.zshrc"

  start_test "rc file permissions are preserved across uninstall"
  setup_clean
  echo "x" > "$HOME/.zshrc"
  chmod 600 "$HOME/.zshrc"
  "$install_sh" zsh >/dev/null
  "$uninstall_sh" zsh >/dev/null
  perm_octal=$(stat -c '%a' "$HOME/.zshrc" 2>/dev/null || stat -f '%Lp' "$HOME/.zshrc")
  assert_eq "permissions preserved (600)" "600" "$perm_octal"
fi

# --- 'all' mode -----------------------------------------------------------

if [[ ${#shells_to_test[@]} -gt 0 ]]; then
  start_test "all mode: install + uninstall on every available shell"
  setup_clean
  for shell_name in "${shells_to_test[@]}"; do
    rc=$(shell_rc_path "$shell_name")
    shell_rc_seed "$shell_name" > "$rc.orig"
    cp "$rc.orig" "$rc"
  done
  "$install_sh" all >/dev/null
  "$uninstall_sh" all >/dev/null
  for shell_name in "${shells_to_test[@]}"; do
    rc=$(shell_rc_path "$shell_name")
    assert_same "all-mode $shell_name round-trip" "$rc.orig" "$rc"
  done
fi

# --- Argument validation ---------------------------------------------------

start_test "uninstall.sh rejects unknown shell name"
set +e
"$uninstall_sh" not-a-shell >/dev/null 2>&1
rc=$?
set -e
assert_nonzero "unknown arg returns non-zero" "$rc"

start_test "install.sh rejects unknown shell name"
set +e
"$install_sh" not-a-shell >/dev/null 2>&1
rc=$?
set -e
assert_nonzero "unknown arg returns non-zero" "$rc"

# --- Summary ---------------------------------------------------------------

printf '\n=== summary: %d passed, %d failed ===\n' "$passes" "$failures"
if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
exit 0
