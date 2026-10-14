#!/bin/zsh
# Usage:
#   ./build.sh            dev build for this Mac          -> build/LaunchGrid.app (ad-hoc signed)
#   ./build.sh --release  universal, Developer ID signed,  -> build/LaunchGrid-<version>.dmg
#                         notarized and stapled
#
# Release signing is read from the environment, nothing secret lives in the repo:
#   SIGN_IDENTITY   e.g. "Developer ID Application: Your Name (TEAMID)"; auto-detected when unset
#   NOTARY_PROFILE  keychain profile made with `xcrun notarytool store-credentials` (default: LaunchGrid)
set -euo pipefail
cd "$(dirname "$0")"

RELEASE=0
[[ "${1:-}" == "--release" ]] && RELEASE=1
VERSION=$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)
APP=build/LaunchGrid.app

if (( RELEASE )); then
  swift build -c release --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/LaunchGrid"
else
  swift build -c release
  BIN=.build/release/LaunchGrid
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LaunchGrid"
cp Support/Info.plist "$APP/Contents/Info.plist"

# App icon is drawn by the app itself (no binary assets in the repo).
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
"$BIN" --render-icon "$ICONSET/icon_512x512@2x.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  [[ $s != 512 ]] && sips -z $((s * 2)) $((s * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

if (( ! RELEASE )); then
  codesign --force --sign - "$APP" >/dev/null
  echo "Built $PWD/$APP (ad-hoc signed, this Mac only)"
  exit 0
fi

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}
if [[ -z "$IDENTITY" ]]; then
  echo "error: no 'Developer ID Application' certificate in the keychain (set SIGN_IDENTITY)." >&2
  exit 1
fi
PROFILE=${NOTARY_PROFILE:-LaunchGrid}

echo "Signing with: $IDENTITY"
codesign --force --timestamp --options runtime \
  --entitlements Support/LaunchGrid.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

# 1) Notarize + staple the app itself, so a copy dragged out of the DMG passes Gatekeeper offline.
echo "Notarizing app (profile: $PROFILE)…"
ditto -c -k --keepParent "$APP" build/LaunchGrid-notarize.zip
xcrun notarytool submit build/LaunchGrid-notarize.zip --keychain-profile "$PROFILE" --wait
rm build/LaunchGrid-notarize.zip
xcrun stapler staple "$APP"

# 2) DMG containing the stapled app; sign, notarize and staple the DMG too.
DMG=build/LaunchGrid-$VERSION.dmg
STAGE=build/dmg
rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "LaunchGrid $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "Notarizing DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
spctl --assess --type execute -v "$APP"

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Release ready: $PWD/$DMG"
