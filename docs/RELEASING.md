# Releasing

How a Lilo release is cut, from version bump to published DMG. Maintainer-only; day-to-day contribution flow is in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Preconditions

- `main` is green in CI and `make validate` passes locally.
- The `release` environment secrets listed below are configured (first release only).

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

For a release with visual highlights, add its translated story to
`site/src/content/releases/<version>.json`. Each highlight names the release notes
it describes. A story may omit its `capture` and show no recording. Otherwise
`make release-version` runs the story's capture scenario when its media is missing, then builds the website. Demo stories record local sample pages
in English and French and both appearances. Native stories run `make release-media-proof`
to capture the current build and require automated quality approval. The historical
0.7.0 pilot retains its manually imported Peek recording. Optional actions appear
with the feature text. Commit the
versioned assets and their `capture.json` source record together. Existing captures
are preserved; normal website builds and `make validate` do not recapture them.
See [the website guide](../site/README.md#release-stories-and-recordings) for
capture and replacement commands.

Review the generated notes and version changes, then commit them together. The initial
`.changes/v0.1.5.md` contains all earlier published entries, with their dates and compare links.
Edit a prepared release's file and run `make release-version` to regenerate the changelog.

### In-app highlights

Native release media is generated with `make release-media-proof RELEASE=x.y.z` before tagging. The first proof covers Peek and 0.8.0's sharing/address features; unsupported future selections fail until their native runner exists. Generation uses the local authenticated Codex CLI and an isolated GUI test host. See [native media tooling](../site/README.md#automated-native-proof).

Required media must pass native assertions, encoding checks, digest checks, and independent visual review. A failed check blocks preparation and final packaging instead of substituting a poster. Generation stays outside `make validate`; signing jobs only verify previously generated artifacts. Current-release media ships locally in the app and is shared with the website's archive.

The app bundles the prepared notes matching its marketing version during `make ui-build` and
shows them once after an update. **Help > What’s New** reopens them. New installations finish
onboarding without an additional update introduction.

To add visual highlights, add the exact version to
`lilo-ui/src/components/whatsnew/releaseHighlights.json`. Its headline, introduction and up to
three highlights reference keys under `whatsNew.releases` in **every** shared language
catalog. Use a benefit-led heading and one or two sentences per highlight. The static local
illustrations live in `WhatsNewArt.svelte`; a new illustration also needs a recognized identifier
in `releaseNotes.ts`. Keep illustrations decorative and communicate the change in the copy.

Without an entry for that version, the sheet opens the complete notes in a compact maintenance
layout. An older version's highlights are never reused. The complete notes retain their original
English text, labelled as such in the other languages. The sheet reads its bundled `release-notes.json` on
opening; it makes no request to the public website or update feed.

Run `make ui-preview`, then open `/preview/?open=whatsnew` to inspect the installed release.
Add `&theme=dark` or `&tabs=top` to check another appearance or tab layout.

## Tag and push

```bash
git tag vX.Y.Z
git push origin main vX.Y.Z
```

Pushing a `v*` tag triggers `.github/workflows/release.yml`.

## What CI does

The release workflow runs only in `Alexays/Lilo` (never in forks), on the GitHub-hosted `xcode-27` image (macOS 27, Xcode 27; `macos-26` has no Xcode 27):

1. Checks the tag is a prepared release: its `.changes/vX.Y.Z.md` exists, `MARKETING_VERSION` matches it, and `make release-status` passes.
2. Verifies required native media and its visual approval before any signing credentials are imported. Restores the UI build CI cached for the same sources, or builds it with `npm ci --ignore-scripts`. The extension bridge bundles are committed and checked against `bridge-src` by CI. The checkout keeps no token.
3. Dates every file by its content and restores the Release build of the last `main` push (CI's `release-build` job builds the same thing on every push and caches it from `main`), so only what changed since compiles: a version bump alone compiles nothing.
4. Imports the Developer ID certificate into a temporary keychain.
5. Downloads libghostty-vt (`make vt-build`, checked against `VT_SHA256`), then runs `make release-archive` (build, export signed with Developer ID, hardened runtime and a secure timestamp).
6. Runs `make dmg`: the pinned [dmgbuild](https://github.com/dmgbuild/dmgbuild) packages `build/release/export/Lilo.app` with the installer window from `scripts/dmg/` (`settings.py` and the committed background, regenerated from `background.html` by `make dmg-background`). It then signs the DMG and notarizes it, a single submission whose ticket also covers the app inside, and staples the DMG. The app itself is not stapled: a copy taken out of the DMG and first opened offline relies on Gatekeeper's online check, and Sparkle updates download the stapled DMG. The job then checks the staple and has Gatekeeper (`spctl`) assess the DMG and the app on its read-only mount, so a release users would be refused never reaches the draft.
7. Downloads Sparkle's tools (checked against a pinned sha256) and generates `appcast.xml` with `generate_appcast`, signed with `SPARKLE_ED_PRIVATE_KEY`. The app sets `SURequireSignedFeed`, so both the feed and the update archive must carry a valid EdDSA signature.
8. Creates a **draft** GitHub release with the DMG and the appcast attached, its notes taken from the tag's `.changes/vX.Y.Z.md`. Installed copies read the appcast from the latest published release, so they see the update once the draft is published.

## Secrets

They are secrets of the `release` environment, which only `v*` tags may deploy to, so no workflow pushed on another branch can read them.

| Secret | Contents |
|--------|----------|
| `APPLE_CERT` | base64-encoded `.p12` Developer ID Application certificate |
| `APPLE_CERT_PASSWORD` | password for the `.p12` |
| `APPLE_NOTARY_TEAM_ID` | Apple Developer team ID (also used as `DEVELOPMENT_TEAM`) |
| `APPLE_NOTARY_APPLE_ID` | Apple ID for notarytool |
| `APPLE_NOTARY_PASSWORD` | app-specific password for notarytool |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle EdDSA private key that signs `appcast.xml` |
| `HOMEBREW_TAP_TOKEN` | fine-grained token with `contents: write` on `Alexays/homebrew-tap`, used by `homebrew.yml` |
| `DISCORD_WEBHOOK_URL` | incoming webhook URL for Lilo's Discord release channel, used by `discord.yml` |

### Discord announcements (once)

In the Discord channel that should receive release notes, open **Edit Channel > Integrations >
Webhooks**, create a webhook named **Lilo Releases**, and copy its URL. In `Alexays/Lilo`, add it as
the `DISCORD_WEBHOOK_URL` Actions secret under **Settings > Environments > release**.

Publishing a stable `vX.Y.Z` GitHub release runs `.github/workflows/discord.yml`. It posts the published
release's notes and a link to that release, so edits made to the draft are included. GitHub's
reference-style compare links are converted for Discord. Notes longer than Discord's 4,096-character
embed limit end with a link to the full changelog. Mentions in release notes do not ping members.
Drafts, prereleases and the `ghostty-vt-*` tooling releases are skipped.

The job fails if the secret is missing or Discord rejects the message. Rerunning it sends another
announcement; editing the GitHub release does not send one. `make release-test` checks the formatting,
release filtering and error handling without contacting Discord.

### Sparkle key (once)

Download the Sparkle release matching `project.yml`, then run `bin/generate_keys`: it stores the private key in your login keychain and prints the public key. Put the public key in `SPARKLE_PUBLIC_ED_KEY` (`Xcode/Configs/Base.xcconfig`) and commit it; export the private key with `bin/generate_keys -x sparkle.key` and store its contents as the `SPARKLE_ED_PRIVATE_KEY` secret. Builds with an empty public key never check for updates, so `make release` and `make release-notarize` refuse to build without it (`make install` does not need it).

## Local release

```bash
make release            # archive and export, no notarization
make release-notarize   # same, plus notarize and staple the app
```

`scripts/build-app.sh` runs `xcodebuild build` with an archive's postprocessing, then wraps the app in the `.xcarchive` that `-exportArchive` signs: `xcodebuild archive` would start from an empty build folder every time.

Both wrap `scripts/build-app.sh`; signing and notarization are configured via the `LILO_*` environment variables documented at the top of that script (`LILO_TEAM_ID`, `LILO_CODE_SIGN_IDENTITY`, `LILO_NOTARY_*`, and friends).

## Browser passkey entitlement

`com.apple.developer.web-browser.public-key-credential` lets Lilo create and use passkeys for any site. It is a restricted entitlement: Apple grants it per app ID (`fr.arouillard.lilo`, team `7FCQYGT54V`), and a build carrying it must embed a Developer ID provisioning profile that includes it, or macOS refuses to launch the app. It is off by default, so ad-hoc, development and fork builds never carry it.

Once Apple grants it:

1. In the developer portal, enable the capability on the `fr.arouillard.lilo` identifier, then create and download a **Developer ID** provisioning profile for it.
2. Point `LILO_PROVISIONING_PROFILE` at that file (in `Makefile.local`, see `Makefile.local.example`). `make release` and `make release-notarize` then embed it as `Contents/embedded.provisionprofile` and re-sign the exported app with the entitlement added. Debug and development-signed builds ignore the variable.
3. Check the result before notarizing a release: `codesign -d --entitlements - build/release/export/Lilo.app` lists the entitlement, and the app launches.
4. For CI releases, store the profile as a base64 secret, decode it to a file in `release.yml` and pass its path as `LILO_PROVISIONING_PROFILE` to `make release-archive`.

## Publish checklist

1. Publish the draft release. CI already checked its DMG with `stapler` and `spctl`.
2. Publishing runs `.github/workflows/homebrew.yml`, which bumps the `lilo` cask of the
   `alexays/tap` Homebrew tap to the new version and the DMG's sha256, so
   `brew install --cask alexays/tap/lilo` and `brew upgrade` pick it up.
3. Publishing also runs `.github/workflows/discord.yml`, which announces the release and its notes
   in the Discord channel configured by `DISCORD_WEBHOOK_URL`.
