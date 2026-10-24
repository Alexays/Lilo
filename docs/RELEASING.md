# Releasing

How a Lilo release is cut, from version bump to published DMG. Maintainer-only; day-to-day contribution flow is in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Preconditions

- `main` is green in CI and `make validate` passes locally.
- The repository secrets listed below are configured (first release only).

## Version bump

Contributors record user-visible changes with `make change`. Changie stores each note in
`.changes/unreleased/` and each prepared release in `.changes/vX.Y.Z.md`. Make downloads a pinned
native binary and verifies its SHA-256 checksum. Release tooling uses Python's standard library.
To prepare a release:

```bash
make release-status
make release-version
make validate
```

`make release-status` previews the next release and checks the changelog and app versions without
writing files. `Fixed` and `Changed` notes select a patch bump, `Added` selects minor, and `Breaking`
selects major. When notes request different bumps, the largest wins.

`make release-version` collects the pending notes into a release file, consumes the fragments, and
regenerates `CHANGELOG.md`. It updates `MARKETING_VERSION` in `Xcode/Configs/Base.xcconfig`, the UI and
extension bridge package versions and their lockfiles. `make site-generate` then builds the Astro website,
including its changelog page and app metadata, in the git-ignored `site/dist/` directory.
It increments `CURRENT_PROJECT_VERSION` once for each release it collects, or when the app version
differs from Changie's latest release. Sparkle compares this build number, so every release needs a
larger one. It reads and checks every file before consuming the fragments, and running it again
without new fragments leaves both versions alone. `Lilo/Info.plist` and the About panel read the Xcode settings at build time.

Review the generated notes and version changes, then commit them together. The initial
`.changes/v0.1.5.md` contains all earlier published entries, with their dates and compare links.
Edit a prepared release's file and run `make release-version` to regenerate the changelog.

## Tag and push

```bash
git tag vX.Y.Z
git push origin main vX.Y.Z
```

Pushing a `v*` tag triggers `.github/workflows/release.yml`.

## What CI does

The release workflow runs only in `Alexays/Lilo` (never in forks), on the GitHub-hosted `xcode-27` image (macOS 27, Xcode 27; `macos-26` has no Xcode 27):

1. Checks the tag is a prepared release: its `.changes/vX.Y.Z.md` exists, `MARKETING_VERSION` matches it, and `make release-status` passes.
2. Builds the UI bundle and the extension bridge with `npm ci --ignore-scripts`, before any secret is in reach. The checkout keeps no token.
3. Imports the Developer ID certificate into a temporary keychain.
4. Downloads libghostty-vt (`make vt-build`, checked against `VT_SHA256`), then runs `make release-notarize` (archive, export, notarize, staple).
5. Runs `make dmg`: the pinned [dmgbuild](https://github.com/dmgbuild/dmgbuild) packages `build/release/export/Lilo.app` with the installer window from `scripts/dmg/` (`settings.py` and the committed background, regenerated from `background.html` by `make dmg-background`). It then signs, notarizes and staples the DMG itself.
6. Downloads Sparkle's tools (checked against a pinned sha256) and generates `appcast.xml` with `generate_appcast`, signed with `SPARKLE_ED_PRIVATE_KEY`. The app sets `SURequireSignedFeed`, so both the feed and the update archive must carry a valid EdDSA signature.
7. Creates a **draft** GitHub release with the DMG and the appcast attached, its notes taken from the tag's `.changes/vX.Y.Z.md`. Installed copies read the appcast from the latest published release, so they see the update once the draft is published.

## Secrets

| Secret | Contents |
|--------|----------|
| `APPLE_CERT` | base64-encoded `.p12` Developer ID Application certificate |
| `APPLE_CERT_PASSWORD` | password for the `.p12` |
| `APPLE_NOTARY_TEAM_ID` | Apple Developer team ID (also used as `DEVELOPMENT_TEAM`) |
| `APPLE_NOTARY_APPLE_ID` | Apple ID for notarytool |
| `APPLE_NOTARY_PASSWORD` | app-specific password for notarytool |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle EdDSA private key that signs `appcast.xml` |

### Sparkle key (once)

Download the Sparkle release matching `project.yml`, then run `bin/generate_keys`: it stores the private key in your login keychain and prints the public key. Put the public key in `SPARKLE_PUBLIC_ED_KEY` (`Xcode/Configs/Base.xcconfig`) and commit it; export the private key with `bin/generate_keys -x sparkle.key` and store its contents as the `SPARKLE_ED_PRIVATE_KEY` secret. Builds with an empty public key never check for updates, so `make release` and `make release-notarize` refuse to build without it (`make install` does not need it).

## Local release

```bash
make release            # archive and export, no notarization
make release-notarize   # same, plus notarize and staple
```

Both wrap `scripts/build-app.sh`; signing and notarization are configured via the `LILO_*` environment variables documented at the top of that script (`LILO_TEAM_ID`, `LILO_CODE_SIGN_IDENTITY`, `LILO_NOTARY_*`, and friends).

## Browser passkey entitlement

`com.apple.developer.web-browser.public-key-credential` lets Lilo create and use passkeys for any site. It is a restricted entitlement: Apple grants it per app ID (`fr.arouillard.lilo`, team `7FCQYGT54V`), and a build carrying it must embed a Developer ID provisioning profile that includes it, or macOS refuses to launch the app. It is off by default, so ad-hoc, development and fork builds never carry it.

Once Apple grants it:

1. In the developer portal, enable the capability on the `fr.arouillard.lilo` identifier, then create and download a **Developer ID** provisioning profile for it.
2. Point `LILO_PROVISIONING_PROFILE` at that file (in `Makefile.local`, see `Makefile.local.example`). `make release` and `make release-notarize` then embed it as `Contents/embedded.provisionprofile` and re-sign the exported app with the entitlement added. Debug and development-signed builds ignore the variable.
3. Check the result before notarizing a release: `codesign -d --entitlements - build/release/export/Lilo.app` lists the entitlement, and the app launches.
4. For CI releases, store the profile as a base64 secret, decode it to a file in `release.yml` and pass its path as `LILO_PROVISIONING_PROFILE` to `make release-notarize`.

## Publish checklist

1. Verify the DMG's app on a clean mount:
   ```bash
   spctl -a -vvv /Volumes/Lilo/Lilo.app
   xcrun stapler validate /Volumes/Lilo/Lilo.app
   ```
2. Publish the draft release.
3. Update the `lilo` cask in the `alexays/tap` Homebrew tap to the new version and the DMG's
   sha256 (`shasum -a 256 Lilo.dmg`), so `brew install --cask alexays/tap/lilo` and
   `brew upgrade` pick it up.
