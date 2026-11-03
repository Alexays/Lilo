# Lilo's WebKit fork

Lilo runs on the WebKit that ships with macOS, the engine Safari uses. On Apple silicon it can also
run its own build of WebKit, embedded in the app, to bring engine fixes before macOS does. The fork is
WebKit `main` plus a short list of patches, each one also sent upstream, and it runs only while it
holds every security fix of the installed macOS: an early delivery of fixes, never a requirement.

Lilo must work fully on the WebKit of macOS. A patch belongs in the fork only when it fixes a WebKit bug
or a performance problem; no feature of Lilo may depend on a patch, an API or a behavior only the fork
has, since any macOS security update can turn the fork off.

Settings shows which engine runs next to the Lilo version ("WebKit 627.1.7+, Lilo fork"), and so do
the About panel, performance recordings and the bug report form.

## Patches

Every patch has a WebKit bug and an upstream pull request. A patch leaves this list once it lands in
WebKit and the fork is rebased past it. The patches live on the `lilo` branch of
[Alexays/WebKit](https://github.com/Alexays/WebKit).

| Bug | What it fixes | Upstream |
|---|---|---|
| [329822](https://bugs.webkit.org/show_bug.cgi?id=329822) | Removing or changing a style sheet recomputes the style of every element (Gmail: 25 ms to 4 ms per removal) | [WebKit/WebKit#79315](https://github.com/WebKit/WebKit/pull/79315) |
| [328920](https://bugs.webkit.org/show_bug.cgi?id=328920) | `sizes=auto`: each width change queues another source selection that re-requests the image | [WebKit/WebKit#79337](https://github.com/WebKit/WebKit/pull/79337) |
| [329909](https://bugs.webkit.org/show_bug.cgi?id=329909) | Changing an inherited custom property compares every descendant's custom property maps in full (2000 root variables: 44 ms to 10 ms) | [WebKit/WebKit#79412](https://github.com/WebKit/WebKit/pull/79412) |

## Security

Apple ships WebKit security fixes in macOS updates before their source is public, so a fork built
from public source can lag the system. Running it then would undo a fix the user already has. The
rule that prevents it:

- Apple's security advisories list the WebKit bugs each macOS release fixes ("WebKit Bugzilla: N"),
  and every WebKit commit names its bug.
- When the fork is packaged, `scripts/webkit-fork-coverage.py` walks the advisories of the macOS the
  fork is built for, oldest first. A release is covered when each of its WebKit bugs, and of every
  earlier release, has a commit in the fork; a release without published CVEs is covered with the
  one before. The newest covered release goes into the app as `LiloWebKitForkCoversSafari`.
- At launch, `WebKitFork.execIfCovered()` compares the installed Safari, which follows the system's
  WebKit, with that release. The fork runs only for the same macOS major version and a Safari that is
  the same or older. A newer Safari, a Background Security Improvement ("27.0.1 (a)"), a missing
  Safari or an Intel Mac all run the WebKit of macOS.

Every doubt resolves to the WebKit of macOS: an advisory the script cannot read stops the packaging,
a bug it cannot find stops the coverage there. `LILO_SYSTEM_WEBKIT=1` runs the WebKit of macOS for one
launch.

### Keeping it current

- Each macOS release with WebKit fixes calls for a fork rebuilt on the latest `main`, then a Lilo
  release that pins it. Until both ship, users who installed the update run the WebKit that came with it, fixes included.
- Without a security release, the fork is still rebuilt about every two weeks, like Safari Technology
  Preview, so it never drifts far from `main`.
- A patch that no longer applies on `main` blocks the rebuild until it is fixed or dropped; a stale
  fork stays safe, since the coverage rule turns it off.

## How Lilo runs it

- The fork's frameworks, libraries and XPC services sit side by side in `Contents/Frameworks`, the
  layout of a WebKit build. WebKit's Release configuration builds relocatable frameworks: each XPC
  service carries a dyld environment that loads the frameworks next to it.
- `Contents/MacOS/LiloFork` is Lilo's own executable (arm64) with `DYLD_FRAMEWORK_PATH` and
  `DYLD_LIBRARY_PATH` pointing at `Contents/Frameworks`, added as load commands by
  `scripts/add-dyld-environment.py`. dyld honors them under the hardened runtime because they are part
  of the signed executable and the frameworks carry the same team's signature: no entitlement relaxes
  library validation or allows dyld environment variables.
- `Lilo` starts, runs the check above, and replaces itself with `LiloFork` (`execv`, same process). The
  process loads the fork's frameworks instead of the system's, Sparkle included.
- FairPlay streaming works on the fork as on the WebKit of macOS (tested on a DRM service). Apple Pay and
  platform passkeys depend on entitlements of the app or of Safari, not on which WebKit runs.

The cost: about 300 MB more in the app (75 MB compressed), and the fork's frameworks are not in the
system's shared cache, which adds roughly 130 ms to the first page of a cold launch.

## Building and publishing a fork

In a WebKit checkout on the `lilo` branch, with its commit history (`git fetch --filter=tree:0`):

```bash
Tools/Scripts/build-webkit --release
scripts/package-webkit-fork.sh ~/Projects/WebKit build/WebKitFork.zip
```

`package-webkit-fork.sh` (run from Lilo) checks the coverage, keeps what Lilo runs (frameworks without
headers, libraries, XPC services) and prints the zip's sha256. Publish the zip as a release of
Alexays/WebKit, then set `WEBKIT_FORK_URL` and `WEBKIT_FORK_SHA256` in the `Makefile`: `make release`
downloads it (`make webkit-fork`) and `scripts/build-app.sh` embeds and signs it as it signs the app.
With nothing pinned, releases run on the WebKit of macOS.
