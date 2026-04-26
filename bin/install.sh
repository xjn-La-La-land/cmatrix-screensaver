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

shell_exists() {
  command -v "$1" >/dev/null 2>&1
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

install_source_line() {
  local shell_name="$1"
  local target_file="$2"
  local source_line="$3"
  local script_path="$4"

  if ! shell_exists "${shell_name}"; then
    printf 'Shell not found in PATH: %s\n' "${shell_name}" >&2
    return 1
  fi

  if [[ ! -f "${script_path}" ]]; then
    printf 'Script not found for %s: %s\n' "${shell_name}" "${script_path}" >&2
    return 1
  fi

  if [[ ! -f "${target_file}" ]]; then
    printf 'Config file not found for %s: %s\n' "${shell_name}" "${target_file}" >&2
    return 1
  fi

  if grep -Fqx "${source_line}" "${target_file}"; then
    printf 'Already installed in %s\n' "${target_file}"
    return 0
  fi

  {
    printf '\n'
    printf '# cmatrix-screensaver\n'
    printf '%s\n' "${source_line}"
  } >> "${target_file}"

  printf 'Installed in %s\n' "${target_file}"
}

install_for_shell() {
  local shell_name="$1"
  local config_path script_path source_line

  config_path="$(shell_config_path "${shell_name}")" || return 1
  script_path="$(shell_script_path "${shell_name}")" || return 1
  source_line="$(shell_source_line "${shell_name}")" || return 1

  install_source_line "${shell_name}" "${config_path}" "${source_line}" "${script_path}"
}

TARGET_SHELL="${1:-}"
if [[ -z "${TARGET_SHELL}" ]]; then
  TARGET_SHELL="$(detect_default_shell)" || exit 1
fi

case "${TARGET_SHELL}" in
  zsh)
    install_for_shell zsh
    printf 'Restart zsh or run:\n'
    printf '  source "%s/zsh/cmatrix-screensaver.zsh"\n' "${PROJECT_ROOT}"
    ;;
  fish)
    install_for_shell fish
    printf 'Restart fish or run:\n'
    printf '  source "%s/fish/cmatrix-screensaver.fish"\n' "${PROJECT_ROOT}"
    ;;
  bash)
    install_for_shell bash
    printf 'Restart bash or run:\n'
    printf '  source "%s/bash/cmatrix-screensaver.bash"\n' "${PROJECT_ROOT}"
    ;;
  all) 
    installed_count=0
    installed_shells=()

    for shell_name in bash zsh fish; do
      if ! shell_exists "${shell_name}"; then
        printf 'Skipping %s: shell not found in PATH\n' "${shell_name}"
        continue
      fi

      config_path="$(shell_config_path "${shell_name}")" || exit 1
      if [[ ! -f "${config_path}" ]]; then
        printf 'Skipping %s: config file not found: %s\n' "${shell_name}" "${config_path}"
        continue
      fi

      install_for_shell "${shell_name}"
      installed_count=$((installed_count + 1))
      installed_shells+=("${shell_name}")
    done

    if [[ ${installed_count} -eq 0 ]]; then
      printf 'No supported shell with an existing config file was found.\n' >&2
      exit 1
    fi

    printf 'Restart your shell or run one of:\n'
    for shell_name in "${installed_shells[@]}"; do
      case "${shell_name}" in
        bash)
          printf '  source "%s/bash/cmatrix-screensaver.bash"\n' "${PROJECT_ROOT}"
          ;;
        zsh)
          printf '  source "%s/zsh/cmatrix-screensaver.zsh"\n' "${PROJECT_ROOT}"
          ;;
        fish)
          printf '  source "%s/fish/cmatrix-screensaver.fish"\n' "${PROJECT_ROOT}"
          ;;
      esac
    done
    ;;
  *)
    print_usage
    exit 1
    ;;
esac
