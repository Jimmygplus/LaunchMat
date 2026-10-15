#!/bin/zsh
# Usage:
#   ./build.sh              dev build for this Mac -> build/LaunchMat.app (ad-hoc signed)
#   ./build.sh --universal  same, but arm64 + x86_64 (used by scripts/release.sh)
#   ./build.sh --release    the distribution DMG; runs scripts/release.sh (see docs/distribution.md)
set -euo pipefail
cd "$(dirname "$0")"

[[ "${1:-}" == "--release" ]] && exec ./scripts/release.sh
UNIVERSAL=0
[[ "${1:-}" == "--universal" ]] && UNIVERSAL=1
APP=build/LaunchMat.app

if (( UNIVERSAL )); then
  swift build -c release --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/LaunchMat"
else
  swift build -c release
  BIN=.build/release/LaunchMat
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LaunchMat"
cp Support/Info.plist "$APP/Contents/Info.plist"
# Test builds name their commit in About (a trailing + means uncommitted changes); release.sh removes it again.
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
[[ -n "$(git status --porcelain 2>/dev/null)" ]] && COMMIT="$COMMIT+"
plutil -insert LaunchMatCommit -string "$COMMIT" "$APP/Contents/Info.plist"

# App icon is drawn by the app itself (no binary assets in the repo).
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
"$BIN" --render-icon "$ICONSET/icon_512x512@2x.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  [[ $s != 512 ]] && sips -z $((s * 2)) $((s * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null
echo "Built $PWD/$APP (ad-hoc signed, this Mac only)"
