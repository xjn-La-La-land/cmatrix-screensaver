#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

install_source_line() {
  local target_file="$1"
  local source_line="$2"

  if [[ ! -f "${target_file}" ]]; then
    mkdir -p "$(dirname "${target_file}")"
    touch "${target_file}"
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

TARGET_SHELL="${1:-zsh}"

case "${TARGET_SHELL}" in
  zsh)
    install_source_line \
      "${HOME}/.zshrc" \
      "source \"${PROJECT_ROOT}/zsh/cmatrix-screensaver.zsh\""
    printf 'Restart zsh or run:\n'
    printf '  source "%s/zsh/cmatrix-screensaver.zsh"\n' "${PROJECT_ROOT}"
    ;;
  fish)
    install_source_line \
      "${HOME}/.config/fish/config.fish" \
      "source \"${PROJECT_ROOT}/fish/cmatrix-screensaver.fish\""
    printf 'Restart fish or run:\n'
    printf '  source "%s/fish/cmatrix-screensaver.fish"\n' "${PROJECT_ROOT}"
    ;;
  all)
    install_source_line \
      "${HOME}/.zshrc" \
      "source \"${PROJECT_ROOT}/zsh/cmatrix-screensaver.zsh\""
    install_source_line \
      "${HOME}/.config/fish/config.fish" \
      "source \"${PROJECT_ROOT}/fish/cmatrix-screensaver.fish\""
    printf 'Restart your shell or run one of:\n'
    printf '  source "%s/zsh/cmatrix-screensaver.zsh"\n' "${PROJECT_ROOT}"
    printf '  source "%s/fish/cmatrix-screensaver.fish"\n' "${PROJECT_ROOT}"
    ;;
  *)
    printf 'Usage: %s [zsh|fish|all]\n' "$0" >&2
    exit 1
    ;;
esac
