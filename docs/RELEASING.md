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

A feature release (`x.y.0`) ships with its highlights: an entry in
`lilo-ui/src/components/whatsnew/releaseHighlights.json` and a story in
`site/src/content/releases/<version>.json`, both described below. `make release-version` refuses to
cut one without them and leaves the notes in place; `make release-status` warns early. Patch
releases need neither.

`make release-version` collects the pending notes into a release file, consumes the fragments, and
regenerates `CHANGELOG.md`. It updates `MARKETING_VERSION` in `Xcode/Configs/Base.xcconfig`, the UI and
extension bridge package versions and their lockfiles. It then runs `make release-media-ci` for the
prepared version: choose the native subject, capture, render and verify it. Finally `make site-generate`
builds the Astro website, including its changelog and app metadata, in the git-ignored `site/dist/` directory.
It increments `CURRENT_PROJECT_VERSION` once for each release it collects, or when the app version
differs from Changie's latest release. Sparkle compares this build number, so every release needs a
larger one. It checks the version and highlight files before consuming the fragments; running it again
without new fragments leaves both versions alone. Native media generation follows preparation of the
notes. If it fails, the prepared version remains available for diagnosis and retry, but publication is
blocked. `Lilo/Info.plist` and the About panel read the Xcode settings at build time.

### Native release media

The shared `release-media/backlog.json` gives every published version an explicit video,
screenshot or text-only decision. HyperFrames turns genuine native Lilo captures into feature
announcements; a finished visual state gets a screenshot, and routine fixes with no useful visual
story stay text-only. The website and native What's New sheet consume the same final MP4/PNG.
The source receipt records the actual captured app version, build and commit separately from the
release being illustrated; a historical story never claims that today's app is the old binary.

A feature's implementation includes its native capture scenario and literal HyperFrames recipe.
`make release-media-author` selects supported features from the exact release notes. An unknown
visual feature must gain a genuine native scenario and recipe in its feature pull request; it
fails closed rather than silently using an older feature, a fabricated interface or a static
fallback for a required video. This keeps publishing unattended after the feature is merged
without asking the release job to invent unverified browser behavior.

For a local pass:

```bash
make release-media-author
make release-media-capture RELEASE=x.y.z
make release-media-import RELEASE=x.y.z
make release-media-render RELEASE=x.y.z
make release-media-check release-media-test release-media-inspect
make release-media-publish-check RELEASE=x.y.z
```

`make release-media-ci RELEASE=x.y.z` runs that selection, fresh native capture/import, rendering
and quality gate for the selected release. Capture uses the compiled app with a disposable
profile and owned sample pages. The macOS runner needs a usable GUI session and native capture
support; failure to capture blocks the release. Historical committed captures are preserved;
archive verification does not pretend to recapture old binaries.

Isolated interface pieces use transparent PNGs and preserve their captured RGB pixels. Fonts,
MP4 players, sound, source hashes, current recipe hashes, exact frame counts, full decode,
compression, motion, visual layout and sound levels are checked before publication. The music
license permits use without attribution, so announcements have no author-credit ending. Rights
and source provenance remain in repository notices.

Publication is quality-gated. A successful result applies only to the exact checked bytes: a
missing report, changed source, stale recipe, changed output or failed required check blocks
publishing. In tag CI, the target release's fresh native receipt must also name that tag's commit.
Rendering or validation failure cannot leave an old passing report as approval for a new attempt.
See the [media guide](../release-media/README.md) for recipes, native fixtures and quality limits.

Review the generated notes and version changes, then commit them together. The initial
`.changes/v0.1.5.md` contains all earlier published entries, with their dates and compare links.
Edit a prepared release's file and run `make release-version` to regenerate the changelog.

### In-app highlights

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

The release workflow runs only in `Alexays/Lilo` (never in forks). Native capture and signing use
`xcode-27` (macOS 27, Xcode 27; `macos-26` has no Xcode 27); website deployment uses Ubuntu.
Native capture needs a visible, unlocked Retina desktop on that runner. It rejects a non-Retina
window instead of upscaling a lower-resolution capture; an unavailable desktop blocks the release.


1. A separate **Native release media** job checks `make release-tag-check TAG=vX.Y.Z`: the prepared
   notes, generated changelog, app/package versions and feature highlights must agree with the tag.
   This job has read-only repository permissions and no signing environment or signing secrets.
2. It runs `make release-media-ci RELEASE=X.Y.Z`, which authors the release's selected subject,
   captures the real app, renders HyperFrames media and runs the full quality and publication gates.
   Any failure stops the signing job. Failed capture/quality diagnostics are kept as Actions artifacts.
3. It builds the website from these exact media and runs `make release-media-package RELEASE=X.Y.Z`.
   The verified media, native receipts, recipes and static website output are uploaded as a
   same-workflow artifact. The app signing job has an explicit dependency on this job's success.
4. **Build and sign** downloads that artifact and repeats the prepared-tag and hash-based publication
   checks before importing a certificate. It rebuilds the embedded UI with the verified media;
   an earlier main build's cached UI cannot replace the new What's New assets. No checkout token
   is left in Git configuration, and UI dependencies install with scripts disabled.
5. It dates files by content, restores the last main Release build, imports the Developer ID
   certificate into a temporary keychain, and downloads checksum-pinned libghostty-vt. Then
   `make release-archive` builds and exports the app with Developer ID and hardened runtime.
6. `make dmg` packages the app with the pinned installer layout. CI signs and notarizes the DMG,
   staples its ticket, and verifies the DMG and app using `stapler` and `spctl`. A failed Gatekeeper
   assessment stops the draft release. The app itself is not stapled; Sparkle downloads the stapled DMG.
7. Checksum-pinned Sparkle tools create `appcast.xml`, signed with `SPARKLE_ED_PRIVATE_KEY`.
   `SURequireSignedFeed` requires valid EdDSA signatures on the feed and update archive.
8. CI creates a **draft** GitHub release with the DMG, appcast, debug symbols and
   `Lilo-changelog-X.Y.Z.zip`. The notes come from the tag's prepared release file. Installed copies
   discover the update only when the draft is published.
9. **Deploy verified changelog website** waits for media validation and the signed draft. It downloads
   the same run's website artifact, repeats the tag and media publication checks, and runs
   `make site-deploy-verified`. Wrangler publishes that existing `site/dist/` to `lilo-site` on
   `getlilo.app`; it does not rebuild the website. Missing Cloudflare credentials or a deployment
   error fail the workflow. Keep the GitHub release as a draft until every job succeeds.

Pull-request and main CI also re-author and render the archive from committed genuine native
captures, run the media quality gate, and exercise the compact changelog players. Their review
artifacts contain encoded output and compact-frame sheets. The native source captures in this
archive retain their recorded version and commit.

The release artifact includes the validated website output for review and recovery. Production
release deployment uses this exact artifact through GitHub Actions. Alexays must configure the
Cloudflare secrets below before the first automatic deployment can succeed; generating an artifact
alone does not publish it. Disable the earlier Cloudflare Workers Builds production branch deploy
when enabling this job, so a separate Git build cannot replace the verified release output.

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
| `CLOUDFLARE_API_TOKEN` | scoped Cloudflare Workers deployment token for `lilo-site` |
| `CLOUDFLARE_ACCOUNT_ID` | account ID owning the `lilo-site` Worker and `getlilo.app` |
| `HOMEBREW_TAP_TOKEN` | fine-grained token with `contents: write` on `Alexays/homebrew-tap`, used by `homebrew.yml` |
| `DISCORD_WEBHOOK_URL` | incoming webhook URL for Lilo's Discord release channel, used by `discord.yml` |

### Cloudflare deployment (once)

Alexays must create a token with the **Edit Cloudflare Workers** permission policy, restricted to
the account and zone used by `lilo-site` and `getlilo.app`, and find that account's ID. Follow
[Cloudflare's CI authentication instructions](https://developers.cloudflare.com/workers/ci-cd/external-cicd/github-actions/#1-authentication).
Add both values to **Alexays/Lilo > Settings > Environments > release > Environment secrets** as
`CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. Keep this environment restricted to `v*` tags.

Until both secrets are configured, **Deploy verified changelog website** deliberately fails with
setup instructions and the GitHub release remains a draft. After configuring them, rerun the failed
job to publish the same validated artifact. No token is needed in pull-request or native-media jobs.

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

1. Check every release workflow job succeeded, including verified website deployment, then publish
   the draft release. CI already checked its DMG with `stapler` and `spctl`.
2. Publishing runs `.github/workflows/homebrew.yml`, which bumps the `lilo` cask of the
   `alexays/tap` Homebrew tap to the new version and the DMG's sha256, so
   `brew install --cask alexays/tap/lilo` and `brew upgrade` pick it up.
3. Publishing also runs `.github/workflows/discord.yml`, which announces the release and its notes
   in the Discord channel configured by `DISCORD_WEBHOOK_URL`.
