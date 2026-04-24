#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZSHRC="${HOME}/.zshrc"
SOURCE_LINE="source \"${PROJECT_ROOT}/zsh/cmatrix-screensaver.zsh\""

if [[ ! -f "${ZSHRC}" ]]; then
  touch "${ZSHRC}"
fi

if grep -Fqx "${SOURCE_LINE}" "${ZSHRC}"; then
  printf 'Already installed in %s\n' "${ZSHRC}"
  exit 0
fi

{
  printf '\n'
  printf '# cmatrix-screensaver\n'
  printf '%s\n' "${SOURCE_LINE}"
} >> "${ZSHRC}"

printf 'Installed. Restart zsh or run:\n'
printf '  %s\n' "${SOURCE_LINE}"
