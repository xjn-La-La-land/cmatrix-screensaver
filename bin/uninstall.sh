#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

print_usage() {
  printf 'Usage: %s [zsh|fish|bash|all]\n' "$0" >&2
}

shell_config_path() {
  case "$1" in
    bash) printf '%s\n' "${HOME}/.bashrc" ;;
    zsh) printf '%s\n' "${HOME}/.zshrc" ;;
    fish) printf '%s\n' "${HOME}/.config/fish/config.fish" ;;
    *)
      printf 'Unsupported shell: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

shell_script_path() {
  case "$1" in
    bash) printf '%s\n' "${PROJECT_ROOT}/bash/cmatrix-screensaver.bash" ;;
    zsh) printf '%s\n' "${PROJECT_ROOT}/zsh/cmatrix-screensaver.zsh" ;;
    fish) printf '%s\n' "${PROJECT_ROOT}/fish/cmatrix-screensaver.fish" ;;
    *)
      printf 'Unsupported shell: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

shell_source_line() {
  local script_path
  script_path="$(shell_script_path "$1")" || return 1
  printf 'source "%s"\n' "${script_path}"
}

detect_default_shell() {
  local shell_path shell_name

  shell_path="${SHELL:-}"
  if [[ -z "${shell_path}" ]]; then
    printf 'SHELL is not set; please specify one of: bash, zsh, fish\n' >&2
    return 1
  fi

  shell_name="${shell_path##*/}"
  case "${shell_name}" in
    bash|zsh|fish)
      printf '%s\n' "${shell_name}"
      ;;
    *)
      printf 'Unsupported SHELL value: %s\n' "${shell_path}" >&2
      return 1
      ;;
  esac
}

copy_mode() {
  local src=$1
  local dst=$2
  local mode

  if mode=$(stat -f '%Lp' "${src}" 2>/dev/null); then
    chmod "${mode}" "${dst}" 2>/dev/null || true
  elif mode=$(stat -c '%a' "${src}" 2>/dev/null); then
    chmod "${mode}" "${dst}" 2>/dev/null || true
  fi
}

remove_source_line() {
  local shell_name="$1"
  local target_file="$2"
  local source_line="$3"
  local marker='# cmatrix-screensaver'

  if [[ ! -f "${target_file}" ]]; then
    printf 'Skipping %s: config file not found: %s\n' "${shell_name}" "${target_file}"
    return 0
  fi

  if ! grep -Fqx "${marker}" "${target_file}" \
     && ! grep -Fqx "${source_line}" "${target_file}"; then
    printf 'Not installed in %s\n' "${target_file}"
    return 0
  fi

  local tmp_file
  tmp_file=$(mktemp "${target_file}.cmss.XXXXXX")

  awk -v marker="${marker}" -v source_line="${source_line}" '
    function flush_blank() {
      if (buffered_blank) {
        print ""
        buffered_blank = 0
      }
    }
    BEGIN { buffered_blank = 0; skip_next = 0 }
    {
      if (skip_next) {
        skip_next = 0
        if ($0 == source_line) {
          next
        }
      }
      if ($0 == marker) {
        buffered_blank = 0
        skip_next = 1
        next
      }
      if ($0 == source_line) {
        buffered_blank = 0
        next
      }
      if ($0 == "") {
        flush_blank()
        buffered_blank = 1
        next
      }
      flush_blank()
      print
    }
    END {
      flush_blank()
    }
  ' "${target_file}" > "${tmp_file}"

  copy_mode "${target_file}" "${tmp_file}"
  mv "${tmp_file}" "${target_file}"
  printf 'Removed from %s\n' "${target_file}"
}

uninstall_for_shell() {
  local shell_name="$1"
  local config_path source_line

  config_path="$(shell_config_path "${shell_name}")" || return 1
  source_line="$(shell_source_line "${shell_name}")" || return 1

  remove_source_line "${shell_name}" "${config_path}" "${source_line}"
}

TARGET_SHELL="${1:-}"
if [[ -z "${TARGET_SHELL}" ]]; then
  TARGET_SHELL="$(detect_default_shell)" || exit 1
fi

case "${TARGET_SHELL}" in
  bash | zsh | fish)
    uninstall_for_shell "${TARGET_SHELL}"
    printf 'If cmatrix-screensaver is loaded in this session, run cmss_disable or restart %s.\n' "${TARGET_SHELL}"
    ;;
  all)
    processed_count=0

    for shell_name in bash zsh fish; do
      config_path="$(shell_config_path "${shell_name}")" || exit 1
      if [[ ! -f "${config_path}" ]]; then
        printf 'Skipping %s: config file not found: %s\n' "${shell_name}" "${config_path}"
        continue
      fi
      uninstall_for_shell "${shell_name}"
      processed_count=$((processed_count + 1))
    done

    if [[ ${processed_count} -eq 0 ]]; then
      printf 'No supported shell with an existing config file was found.\n' >&2
      exit 1
    fi

    printf 'If cmatrix-screensaver is loaded in any session, run cmss_disable or restart that shell.\n'
    ;;
  *)
    print_usage
    exit 1
    ;;
esac
