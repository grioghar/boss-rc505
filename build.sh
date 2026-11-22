#!/bin/bash
# Release build of the Swift bridge.
#   dist/rc505        command-line bridge (all platforms; dist/rc505.exe on Windows)
#   dist/RC-505.app   macOS app, with the web pages and memory snapshot bundled
# On macOS both are signed with the identity in CODESIGN_IDENTITY (set it in the
# environment or in an untracked .signing.env).   ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
out=".build/release"
mkdir -p dist

if [[ "$(uname)" != "Darwin" ]]; then
  bin="$out/rc505"; [[ -f "$bin.exe" ]] && bin="$bin.exe"
  cp "$bin" dist/
  echo "Built dist/$(basename "$bin")"
  exit 0
fi

[[ -f .signing.env ]] && source .signing.env
sign() {
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$1"
    codesign --verify --strict "$1"
  else
    echo "CODESIGN_IDENTITY is not set: $1 keeps an ad-hoc signature." >&2
  fi
}

cp "$out/rc505" dist/rc505
sign dist/rc505

app="dist/RC-505.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/data"
cp macos/Info.plist "$app/Contents/Info.plist"
cp "$out/RC505App" "$app/Contents/MacOS/RC505App"
cp -R public config.json "$app/Contents/Resources/"
[[ -f data/memories.json ]] && cp -p data/memories.json "$app/Contents/Resources/data/"

icon_tmp="$(mktemp -d)"
swift macos/make-icon.swift "$icon_tmp/icon.png"
mkdir "$icon_tmp/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$icon_tmp/icon.png" --out "$icon_tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$icon_tmp/icon.png" --out "$icon_tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$icon_tmp/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$icon_tmp"

sign "$app"
echo "Built dist/rc505 and $app"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/RC-505.app"
  cp -R "$app" /Applications/
  echo "Installed /Applications/RC-505.app"
fi
