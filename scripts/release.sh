#!/bin/bash
# Builds the LaunchMat distribution DMG. The steps and what to check by hand are in docs/distribution.md.
#
# Signing is explicit. Nothing is picked from the keychain automatically and nothing secret lives in the repo:
#   LAUNCHMAT_SIGNING_IDENTITY    "Developer ID Application: Name (TEAMID)" or its SHA-1 hash. Unset = ad-hoc build
#                                  (LaunchMat-<v>-adhoc.dmg, runs only on the Mac that built it; never publish it).
#   LAUNCHMAT_NOTARY_PROFILE      keychain profile made with `xcrun notarytool store-credentials`. Required for a
#                                  signed build, unless LAUNCHMAT_SKIP_NOTARIZATION=1 (-> LaunchMat-<v>-unnotarized.dmg,
#                                  for local testing only).
#   LAUNCHMAT_OUTPUT_DIR          default: build/release
#   LAUNCHMAT_SKIP_TESTS=1        skip `swift test`
#   LAUNCHMAT_ALLOW_DIRTY=1       allow a distribution build from a working tree with uncommitted changes
#   LAUNCHMAT_REBUILD=1           replace a notarized build of the same version already in the output folder
#
# Output: <out>/LaunchMat-<v>[-suffix].dmg, <out>/SHA256SUMS, <out>/release.json (the numbers the website needs).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"

identity="${LAUNCHMAT_SIGNING_IDENTITY:-}"
profile="${LAUNCHMAT_NOTARY_PROFILE:-}"
skip_notary="${LAUNCHMAT_SKIP_NOTARIZATION:-0}"
out="${LAUNCHMAT_OUTPUT_DIR:-$root/build/release}"
repo="Jimmygplus/LaunchMat"
entitlements="$root/Support/LaunchMat.entitlements"
version="$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)"
build_number="$(plutil -extract CFBundleVersion raw Support/Info.plist)"
min_os="$(plutil -extract LSMinimumSystemVersion raw Support/Info.plist)"

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------------- mode
if [ -z "$identity" ]; then
  mode=adhoc; suffix="-adhoc"
elif [ "$identity" = "-" ]; then
  die "for an ad-hoc build leave LAUNCHMAT_SIGNING_IDENTITY unset."
elif [ -n "$profile" ]; then
  mode=release; suffix=""
elif [ "$skip_notary" = "1" ]; then
  mode=signed; suffix="-unnotarized"
else
  die "LAUNCHMAT_NOTARY_PROFILE is not set. Create one with
  xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID>
or set LAUNCHMAT_SKIP_NOTARIZATION=1 for a signed, un-notarized local test build."
fi

if [ "$mode" != adhoc ]; then
  security find-identity -v -p codesigning | grep -F -- "$identity" >/dev/null \
    || die "no valid code-signing identity matching \"$identity\" in the keychain (security find-identity -v -p codesigning)."
fi

commit="$(git rev-parse HEAD)"
if [ "$mode" = release ] && [ "${LAUNCHMAT_ALLOW_DIRTY:-0}" != "1" ] && [ -n "$(git status --porcelain)" ]; then
  die "uncommitted changes; a release must match a commit (or set LAUNCHMAT_ALLOW_DIRTY=1)."
fi

# A notarized build of this version already in the output folder is probably published: don't replace it by accident.
if [ "$mode" = release ] && [ -f "$out/release.json" ] && [ "${LAUNCHMAT_REBUILD:-0}" != "1" ] \
  && [ "$(plutil -extract version raw "$out/release.json" 2>/dev/null)" = "$version" ] \
  && [ "$(plutil -extract notarized raw "$out/release.json" 2>/dev/null)" = "true" ]; then
  die "a notarized $version build is already in $out (published?). Raise the version in Support/Info.plist,
or set LAUNCHMAT_REBUILD=1 to replace it."
fi

dmg_name="LaunchMat-$version$suffix.dmg"
stage="$(mktemp -d "${TMPDIR:-/tmp}/LaunchMat-release.XXXXXX")"
mnt=""
cleanup() {
  [ -n "$mnt" ] && hdiutil detach -quiet "$mnt" 2>/dev/null || true
  rm -rf "$stage"
}
trap cleanup EXIT

printf 'LaunchMat %s (%s), mode: %s, commit %s\n' "$version" "$build_number" "$mode" "${commit:0:12}"

# ---------------------------------------------------------------------------------------------------- test + build
if [ "${LAUNCHMAT_SKIP_TESTS:-0}" != "1" ]; then
  step "swift test"
  swift test
fi

step "Universal build"
./build.sh --universal
app="$stage/LaunchMat.app"
ditto --norsrc --noextattr build/LaunchMat.app "$app"
xattr -cr "$app"
archs="$(lipo -archs "$app/Contents/MacOS/LaunchMat")"
case "$archs" in *arm64*x86_64*|*x86_64*arm64*) ;; *) die "expected a universal binary, got: $archs" ;; esac

# ---------------------------------------------------------------------------------------------------- sign + verify
# Checks a signature strictly; for Developer ID builds also the authority, team, secure timestamp and hardened runtime.
verify_signature() {
  local path="$1" info
  codesign --verify --strict --deep "$path" || die "codesign --verify --strict failed for $path"
  [ "$mode" = adhoc ] && return 0
  info="$(codesign --display --verbose=4 "$path" 2>&1)"
  case "$info" in *"Authority=Developer ID Application:"*) ;; *) die "$path: not signed with a Developer ID Application certificate." ;; esac
  case "$info" in *"Timestamp="*) ;; *) die "$path: signature has no secure timestamp." ;; esac
  if [ "${path%.app}" != "$path" ]; then
    case "$info" in *"(runtime)"*) ;; *) die "$path: signature is missing the hardened runtime." ;; esac
    case "$(codesign --display --entitlements - --xml "$path" 2>/dev/null)" in *get-task-allow*)
      die "$path: has the get-task-allow entitlement; notarization would reject it." ;;
    esac
  fi
  printf '%s\n' "$info" | grep -E '^(Authority=Developer ID Application|TeamIdentifier|Timestamp)' | sed 's/^/    /'
}

if [ "$mode" = adhoc ]; then
  step "Ad-hoc signing (NOT for distribution)"
  codesign --force --sign - --options runtime --entitlements "$entitlements" "$app"
else
  step "Signing with: $identity"
  codesign --force --sign "$identity" --options runtime --timestamp --entitlements "$entitlements" "$app"
fi
verify_signature "$app"

# Submits a file to Apple's notary service and fails unless the result is Accepted.
notarize() {
  local file="$1" result status id
  result="$stage/notary-$(basename "$file").plist"
  xcrun notarytool submit "$file" --keychain-profile "$profile" --wait --output-format plist >"$result" \
    || die "notarytool submit failed for $file"
  status="$(plutil -extract status raw "$result" 2>/dev/null || echo unknown)"
  id="$(plutil -extract id raw "$result" 2>/dev/null || echo unknown)"
  printf '    submission %s: %s\n' "$id" "$status"
  if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
    die "notarization of $(basename "$file") was not accepted ($status)."
  fi
}

# 1) Notarize and staple the app itself, so a copy dragged out of the DMG passes Gatekeeper offline.
if [ "$mode" = release ]; then
  step "Notarizing the app (profile: $profile)"
  ditto -c -k --norsrc --noextattr --keepParent "$app" "$stage/LaunchMat-notarize.zip"
  notarize "$stage/LaunchMat-notarize.zip"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  verify_signature "$app"
fi

# ---------------------------------------------------------------------------------------------------- DMG
step "Packaging $dmg_name"
mkdir -p "$stage/dmg" "$out"
ditto --norsrc --noextattr "$app" "$stage/dmg/LaunchMat.app"
ln -s /Applications "$stage/dmg/Applications"
dmg="$stage/$dmg_name"
hdiutil create -quiet -volname "LaunchMat $version" -srcfolder "$stage/dmg" -fs HFS+ -format UDZO -ov "$dmg"

if [ "$mode" != adhoc ]; then
  codesign --force --sign "$identity" --timestamp "$dmg"
  verify_signature "$dmg"
fi

# 2) Notarize and staple the DMG too, so the download itself opens without a network check.
if [ "$mode" = release ]; then
  step "Notarizing the DMG"
  notarize "$dmg"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi

# ---------------------------------------------------------------------------------------------------- check what ships
step "Checking the DMG as a user would get it"
hdiutil verify -quiet "$dmg"
mnt="$stage/mnt"
mkdir -p "$mnt"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mnt" "$dmg"
[ -L "$mnt/Applications" ] || die "DMG has no Applications link."
shipped="$mnt/LaunchMat.app"
[ "$(plutil -extract CFBundleShortVersionString raw "$shipped/Contents/Info.plist")" = "$version" ] \
  || die "version inside the DMG does not match $version."
verify_signature "$shipped"
if [ "$mode" = release ]; then
  xcrun stapler validate "$shipped"
  spctl --assess --type execute --verbose=2 "$shipped"
fi
hdiutil detach -quiet "$mnt"; mnt=""
if [ "$mode" = release ]; then
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

# ---------------------------------------------------------------------------------------------------- outputs
rm -f "$out/LaunchMat-$version"*.dmg "$out/SHA256SUMS" "$out/release.json"
mv "$dmg" "$out/$dmg_name"
(cd "$out" && shasum -a 256 "$dmg_name" >SHA256SUMS)
sha256="$(cut -d' ' -f1 "$out/SHA256SUMS")"
bytes="$(stat -f %z "$out/$dmg_name")"
signed=false; notarized=false
[ "$mode" != adhoc ] && signed=true
url=null
[ "$mode" = release ] && notarized=true && url="\"https://github.com/$repo/releases/download/v$version/$dmg_name\""
cat >"$out/release.json" <<JSON
{
  "version": "$version",
  "build": "$build_number",
  "tag": "v$version",
  "commit": "$commit",
  "file": "$dmg_name",
  "url": $url,
  "bytes": $bytes,
  "sha256": "$sha256",
  "signed": $signed,
  "notarized": $notarized,
  "minimumSystemVersion": "$min_os",
  "architectures": ["arm64", "x86_64"]
}
JSON

step "Done ($mode)"
cat "$out/SHA256SUMS"
printf '%s\n' "$out/release.json"
case "$mode" in
  adhoc) printf '\nThis DMG is ad-hoc signed. It is for checking the pipeline only; do not publish it.\n' ;;
  signed) printf '\nThis DMG is signed but NOT notarized. Do not publish it.\n' ;;
  release) printf '\nNext: create the GitHub release v%s with %s and SHA256SUMS, then run scripts/verify-release.sh %s\n' \
    "$version" "$dmg_name" "$version" ;;
esac
