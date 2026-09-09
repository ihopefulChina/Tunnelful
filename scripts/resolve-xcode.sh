#!/usr/bin/env bash
set -euo pipefail

# Prefer an explicit DEVELOPER_DIR when it still exists. Otherwise pick the
# newest Xcode 26 toolchain so CI does not break when GitHub images move
# from 26.3 to 26.4 while still requiring major version 26.

if [[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR" ]]; then
  printf '%s\n' "$DEVELOPER_DIR"
  exit 0
fi

shopt -s nullglob
candidates=(/Applications/Xcode_26*.app/Contents/Developer)
if (( ${#candidates[@]} > 0 )); then
  printf '%s\n' "$(printf '%s\n' "${candidates[@]}" | sort -V -r | head -n 1)"
  exit 0
fi

printf '%s\n' "$(xcode-select -p)"
