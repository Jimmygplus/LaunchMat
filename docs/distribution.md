# Distribution

How a LaunchGrid release is built, checked and published. Nothing here is automatic past step 3: a person creates
the GitHub release and changes the website.

## What ships

- `LaunchGrid-<version>.dmg`: a universal (arm64 + x86_64) app, Developer ID signed with the hardened runtime and a
  secure timestamp, notarized and stapled; the DMG itself is signed, notarized and stapled too.
- `SHA256SUMS`: the DMG's SHA-256, in `shasum -c` format.
- GitHub's own source archives for the tag.

Releases live on GitHub Releases (`Jimmygplus/LaunchGrid`). The app makes no network requests and has no updater.

## One-time setup

1. A **Developer ID Application** certificate and its private key in the login keychain. Check, read-only:
   ```bash
   security find-identity -v -p codesigning
   ```
2. A **notarytool keychain profile**, with an app-specific password from appleid.apple.com:
   ```bash
   xcrun notarytool store-credentials LaunchGrid --apple-id <apple id> --team-id <TEAMID>
   ```
   The password lives only in the keychain. Never put it, or the profile, in the repository.

The script never picks an identity on its own and never changes keychain or trust settings.

## 1. Build

Start from a clean working tree at the commit you will tag, with `CFBundleShortVersionString` and `CFBundleVersion`
raised in `Support/Info.plist`.

```bash
LAUNCHGRID_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" \
LAUNCHGRID_NOTARY_PROFILE=LaunchGrid \
./scripts/release.sh
```

`scripts/release.sh` (also `./build.sh --release`):

1. Runs `swift test`.
2. Builds the universal app (`./build.sh --universal`), copies it to a private temporary directory and checks that
   the binary has both architectures. Everything after this happens in that directory, so a dev build running at the
   same time cannot replace the app being notarized.
3. Signs with `--options runtime --timestamp` and the app's entitlements, then checks strictly: `codesign --verify
   --strict --deep`, the `Developer ID Application` authority, a secure `Timestamp`, the `runtime` flag, and no
   `get-task-allow`.
4. Zips the app, `xcrun notarytool submit --wait`, and fails unless the status is `Accepted` (it prints the notary log
   otherwise). Staples and validates the ticket.
5. Builds the DMG (the app plus an `Applications` link), signs it, notarizes, staples and validates it.
6. Mounts the DMG read-only and checks what a user gets: the version, the signature again, the stapled ticket, and
   `spctl --assess` for the app (`execute`) and the DMG (`open`).
7. Writes `build/release/LaunchGrid-<version>.dmg`, `SHA256SUMS` and `release.json` (version, commit, URL, bytes,
   SHA-256: the numbers the website needs).

Without `LAUNCHGRID_SIGNING_IDENTITY` the same script makes `LaunchGrid-<version>-adhoc.dmg`, to test the pipeline on
any Mac. With an identity but `LAUNCHGRID_SKIP_NOTARIZATION=1` it makes `-unnotarized.dmg`. Neither may be published;
their `release.json` has no URL.

Apple's first submission for a new team can wait in the queue for an hour; later ones usually take minutes.

## 2. Test the DMG by hand

Open the DMG on a Mac that did not build it (or after downloading it in a browser) and run the checklist in
[TESTING.md](../TESTING.md). There must be no Gatekeeper warning beyond the usual "downloaded from the internet" prompt.

## 3. Publish (a person does this)

```bash
git tag -s v<version> -m "LaunchGrid <version>"     # or -a if you don't sign tags
git push origin v<version>
gh release create v<version> build/release/LaunchGrid-<version>.dmg build/release/SHA256SUMS \
  --title "LaunchGrid <version>" --notes-file docs/releases/v<version>.md
```

## 4. Re-download and re-verify from the public URL

```bash
./scripts/verify-release.sh <version>
```

It downloads the DMG and `SHA256SUMS` from the release URL into a temporary directory, checks the checksum (and that
it equals `build/release/release.json`, if present), marks the file as downloaded by a browser, and checks the DMG and
the app inside: Developer ID signature, timestamp, hardened runtime, stapled tickets and `spctl --assess`. Only after
it passes does the website change.

## 5. Point the website at it

In the website repository: `npm run release:sync -- <path to release.json>` copies the version, URL, size and
SHA-256 into `site.config.json` and marks the release as published; then build, test and deploy there.
