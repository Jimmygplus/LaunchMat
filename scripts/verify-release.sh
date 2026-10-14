#!/bin/bash
# Re-downloads a published release from its public URL and checks it the way a user's Mac will:
# checksum, Developer ID signature, notarization tickets and Gatekeeper. Run it after every release, before the
# website links to the new version.
#
#   scripts/verify-release.sh [version]     default: the version in Support/Info.plist
#
# If build/release/release.json exists for the same version, the download must also match its sha256 and size.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
version="${1:-$(plutil -extract CFBundleShortVersionString raw "$root/Support/Info.plist")}"
version="${version#v}"
repo="Jimmygplus/LaunchGrid"
base="https://github.com/$repo/releases/download/v$version"
dmg_name="LaunchGrid-$version.dmg"

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/LaunchGrid-verify.XXXXXX")"
mnt=""
cleanup() {
  [ -n "$mnt" ] && hdiutil detach -quiet "$mnt" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

curl -fsSL --retry 3 -o "$work/$dmg_name" "$base/$dmg_name" || die "could not download $base/$dmg_name"
curl -fsSL --retry 3 -o "$work/SHA256SUMS" "$base/SHA256SUMS" || die "could not download $base/SHA256SUMS"
ok "downloaded $base/$dmg_name"

(cd "$work" && shasum -a 256 -c SHA256SUMS) >/dev/null || die "checksum does not match SHA256SUMS"
sha256="$(shasum -a 256 "$work/$dmg_name" | cut -d' ' -f1)"
bytes="$(stat -f %z "$work/$dmg_name")"
ok "sha256 $sha256 ($bytes bytes)"

manifest="$root/build/release/release.json"
if [ -f "$manifest" ] && [ "$(plutil -extract version raw "$manifest")" = "$version" ]; then
  [ "$(plutil -extract sha256 raw "$manifest")" = "$sha256" ] || die "download differs from the local build (release.json)"
  [ "$(plutil -extract bytes raw "$manifest")" = "$bytes" ] || die "size differs from the local build (release.json)"
  ok "matches the local build in build/release/release.json"
fi

# Mark the file as downloaded by a browser, so Gatekeeper treats it like a real user's download.
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;" "$work/$dmg_name"

codesign --verify --strict "$work/$dmg_name" || die "DMG signature is invalid"
codesign --display --verbose=4 "$work/$dmg_name" 2>&1 | grep -q "Authority=Developer ID Application:" \
  || die "DMG is not signed with a Developer ID"
xcrun stapler validate -q "$work/$dmg_name" || die "DMG has no stapled notarization ticket"
spctl --assess --type open --context context:primary-signature "$work/$dmg_name" 2>/dev/null \
  || die "Gatekeeper rejects the DMG"
ok "DMG: Developer ID signed, notarized, stapled, accepted by Gatekeeper"

mnt="$work/mnt"
mkdir -p "$mnt"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mnt" "$work/$dmg_name"
app="$mnt/LaunchGrid.app"
[ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" = "$version" ] \
  || die "the app in the DMG is not version $version"
codesign --verify --strict --deep "$app" || die "app signature is invalid"
info="$(codesign --display --verbose=4 "$app" 2>&1)"
case "$info" in *"Authority=Developer ID Application:"*) ;; *) die "app is not signed with a Developer ID" ;; esac
case "$info" in *"Timestamp="*) ;; *) die "app signature has no secure timestamp" ;; esac
case "$info" in *"(runtime)"*) ;; *) die "app is missing the hardened runtime" ;; esac
xcrun stapler validate -q "$app" || die "app has no stapled notarization ticket"
spctl --assess --type execute "$app" 2>/dev/null || die "Gatekeeper rejects the app"
archs="$(lipo -archs "$app/Contents/MacOS/LaunchGrid")"
ok "app: $archs, $(printf '%s\n' "$info" | grep -m1 '^Authority=')"

printf '\nRelease v%s verified from the public URL.\n' "$version"
printf 'For the website (site.config.json): "bytes": %s, "sha256": "%s"\n' "$bytes" "$sha256"
