#!/bin/bash
# Release build of the Swift bridge. On macOS it is signed with the identity in
# CODESIGN_IDENTITY (set it in the environment or in an untracked .signing.env).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
bin=".build/release/rc505"
[[ -f "$bin.exe" ]] && bin="$bin.exe"

if [[ "$(uname)" == "Darwin" ]]; then
  [[ -f .signing.env ]] && source .signing.env
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$bin"
    codesign --verify --strict "$bin"
  else
    echo "CODESIGN_IDENTITY is not set: the binary keeps the linker's ad-hoc signature." >&2
  fi
fi

mkdir -p dist
cp "$bin" dist/
echo "Built dist/$(basename "$bin")"
