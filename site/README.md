# getlilo.app

Lilo's website uses Astro to build static pages for Cloudflare Workers. It needs Node 22.23.4 or later and Python 3. All commands run from the repository root through Make.

Coding agents must also follow the website's [Astro project rules](AGENTS.md).

## Development

```sh
make site-dev           # Astro with live reload at http://localhost:8787
make site-dev-stop      # Stop Astro if it started a background dev server
make site-generate      # Build the complete website in site/dist/
make site-preview       # Preview the build with Cloudflare headers at http://localhost:8788
make site-check         # Check lint, formatting, Astro templates and TypeScript
make site-fix           # Fix lint and formatting with Ultracite
make site-test          # Build, then test release notes, routes, links and metadata
make site-e2e           # Test the interactive demo in Chromium with production headers
make site-release-capture RELEASE=0.7.0 # Capture missing release screenshots from the demo
make site-e2e SITE_E2E_ARGS='--browser=webkit tests/demo/links.spec.ts' # Check link actions in WebKit
make site-deploy-check  # Check Cloudflare deployment without publishing
```

`make validate` includes the website checks and tests. After changing dependencies in `site/package.json`, run `make site-lock` to update its lockfile.

The focused changelog checks use their own preview on port 8792, so they never test another worktree's running preview: `make site-e2e SITE_E2E_ARGS='--config=playwright.changelog.config.ts'`. For a separate manual preview, use `make site-preview SITE_PREVIEW_PORT=8792` after the tests finish.

The site uses [Ultracite](https://www.ultracite.ai/providers/oxlint) with Oxlint’s core, Astro and anti-slop presets and Oxfmt’s formatting preset. `oxfmt.config.ts` enables Astro formatting with `@astrojs/compiler-rs`. Oxlint checks scripts in Astro files; `astro check` checks the templates and TypeScript; `svelte-check` checks Svelte components. They run through `make site-check`, including in CI. The check command exposes the website’s packages through `NODE_PATH` so Astro’s editor integration can inspect shared Svelte sources outside `site/` without adding Astro dependencies to the native UI package. Generated output and dependencies are ignored.

The Undici override patches the HTTP clients used by Miniflare and guarded-fetch. Remove it when both dependencies use a patched version.

## Sources

- `src/pages/` holds the English and French home, moving and changelog routes, the 404 page and the sitemap endpoint.
- `src/layouts/Layout.astro` shares page metadata, language alternates, icons, the header and footer. It reads the app version from `Xcode/Configs/Base.xcconfig` at build time.
- `src/components/` holds navigation, the footer and the changelog. New shared website copy lives in `src/lib/i18n.ts`.
- `Layout.astro` owns every public page's main landmark, `PageHero.astro` and `PageEnd.astro`. Pages supply localized headings and descriptions through its `hero` and `closing` props; announcement and preview slots carry the homepage's release link and demo. `PageSection.astro` frames body content. These components own spacing, borders and typography so routes cannot drift into separate designs. The closing CTA uses a solid lavender panel, left-aligned content and the breathing pixel flower at every viewport width. `Install.astro` shares download and Homebrew controls, `Flower.astro` supplies the classic brand mark, and `PixelBloom.astro` pauses its 3.2-second breathing animation offscreen, in background tabs and with Reduce Motion.
- `src/styles/global.css` holds shared tokens and page layout styles. All public pages use a 1280px frame with 16px, 24px and 40px responsive gutters shared by their sections, text and demo windows. Component styles stay with their Astro components. Astro fingerprints the built stylesheets.
- `src/components/Demo.astro` embeds `/demo/` with macOS application menus and Browser, Terminal and MCP modes. `src/pages/demo.astro` and Astro's official Svelte integration build this page directly. `src/demo/` owns its memory-only host, window surface and interactive sample pages. The host installs the native bridge before dynamically importing the production interface from `../lilo-ui/src/`. Website copy stays in `src/lib/i18n.ts`; host and browser tests live in `tests/demo/`. The iframe loads lazily, receives appearance/visibility changes, fits the available width, and expands to fullscreen with an on-page expansion when the browser cannot use fullscreen. Reset reloads only the demo. The native UI package has no demo entry or website build configuration.
- `FeatureDemo.astro` embeds that same app in the terminal and agent sections, using `mode=terminal` or `mode=mcp`. Each frame starts loading only when visible, has its own session, receives appearance and visibility changes, and keeps only the Lilo logo, refresh and expand controls in its toolbar. When motion is enabled, walkthroughs repeat while visible, with a short pause on the finished result. Scrolling away, background tabs and Reduce Motion pause playback; returning resumes it. Interaction hands control to the visitor until refresh. Replay clears the virtual terminal or resets the sample launch page without reloading the frame.
- `src/components/Header.astro` contains one responsive navigation list, the theme toggle, scoped styles and TypeScript bundled by Astro. It selects the French equivalent of English pages when French is the browser's first supported language, preserving the path, query and fragment. Explicit French URLs stay French; other languages fall back to English. Language alternates remain in page metadata, without a footer language switch. Authored browser modules, tests and tool configs use TypeScript.
- `src/components/ExtensionStore.astro` links to the real Chrome Web Store listings. Its logos live in `src/assets/extensions/`; Astro generates WebP images at 1x and 2x density.
- `public/` holds static assets, `robots.txt`, `llms.txt`, and Cloudflare's `_headers` and `_redirects`.

The build runs `generate.py` after Astro to derive a Markdown copy of each page, `llms-full.txt`, and FAQ structured data matching the visible questions and answers. These outputs live in `dist/` and are not committed. Both `/llms.txt` and `/llms-full.txt` are included in the deployed site. Edit the Astro sources, then rebuild.

## Release stories and recordings

The changelog reads the generated root `CHANGELOG.md`. Optional stories in `src/content/releases/<version>.json` add a translated introduction and up to three highlights. Each highlight lists the exact English release notes it describes; the build rejects missing translations, unknown versions and notes from another release. Use the existing story as an example, and edit the copy with Humanizer.

Stories choose a capture `source`: `demo` (the default) or `native`. A demo capture records opening, closing and reopening a link in the website demo and checks that the source tab stays selected. It uses local sample pages, isolated language/appearance contexts and blocked external requests:

```sh
make site-release-capture RELEASE=x.y.z
```

For `source: "demo"`, the command saves four PNG posters, four animated WebP recordings and `capture.json` under `src/assets/releases/<version>/`. Its record includes the duration, source revision and UI/demo source digest. Run it from a checkout whose app version matches the story.

The 0.7.0 pilot uses `source: "native"`: actual installed Lilo 0.7.0, build 20, opening MDN's public CSS and StyleSheet pages in Peek. Public pages were inspected with Lilo MCP; the native window was captured with computer use in a separate private recording space. MCP-controlled tabs deliberately disable native Peek, and MCP screenshots capture only page contents. Keep personal tabs, history suggestions and account details out of recorded frames.

Native capture keeps the browser's actual language and appearance in one shared recording. Its manifest lists `appVersion`, `appBuild`, `capturedAt`, canonical public `pages`, a `poster` filename, and `frames` containing each image's `file` and `delay` in milliseconds. Use simple filenames beside the manifest. Review the frames, then encode them:

```sh
make site-release-import RELEASE=0.7.0 FRAMES=/tmp/lilo-capture/manifest.json RECAPTURE=1
```

The importer normalizes the frame canvas and writes `peek-native.png`, `peek-native.webp` and `capture.json`. It verifies the app version, filenames, frame timing and archive replacement flag before writing. Provenance records the installed app version/build, capture tool, public URLs and source-frame digest. It does not attribute an installed browser to the current worktree. Review and commit these outputs with the story. Astro optimizes posters and serves recordings unchanged; Sharp is a pinned direct development dependency.

The recording plays once when half the player is visible. One small icon over the image provides play, stop and replay, with translated accessible labels. Reduce Motion shows the poster until explicit playback. Scrolling away, hiding the page or changing appearance restores the poster. Reading highlights and full notes works without JavaScript.

Each highlight can define an optional `action` with translated `label` and `href` fields. It appears with the feature text, outside the recording. Highlights for installed features can omit it; no demo action is added automatically.

Existing archives stay unchanged on later builds and releases; incomplete archives require explicit replacement. For a demo story, `make site-release-capture RELEASE=x.y.z RECAPTURE=1` replaces its media using an owned server on port 8791 and Playwright's Chromium browser. For a native story, use `site-release-import` with reviewed window frames. Missing native media stops release preparation with that instruction. `make release-version` prepares missing media before the website build; normal builds and `make validate` never record or replace media.

## Demo playground

The demo uses interactive local example pages. Entered addresses stay inside the sample experience and do not load external websites. Shift-click a page link to Peek; Command-click or middle-click opens a background tab. Right-click a link for Peek, Split View, a Little window, new or background tabs, and Copy Link.

Terminal mode loads xterm.js and just-bash's browser engine on demand. Commands use a shared virtual filesystem; working directories, environment variables, history and output persist per terminal tab. Try `ls`, `cat README.md`, or `printf '# Hello from Lilo\n' > README.md` to update the workspace beside the terminal. Pipes, redirection and common text utilities work. Native executables and network commands are unavailable. Execution, memory, output and history are bounded; Ctrl+C cancels a command. Reloading or resetting discards the session.

MCP mode opens a visibly labeled local Codex session beside a project page. Run makes real MCP calls to read the current checklist, click unfinished tasks, type an update and request permission before publishing. The coral cursor and controlled-tab frame match Lilo's native presentation, and Allow Once, Always Allow and Deny use the production approval drawer. Stop, hiding the demo, closing Details and switching modes cancel pending work. Turning agent access off in Settings disables the local tools too.

The official MCP client and server SDKs connect through their in-memory transport. Visitors can still edit JSON tool calls under Tool details or run `mcp list` and `mcp call read_page '{"tabId":1}'` in the terminal. Tools read the rendered sample DOM and change the same tabs and fields visible in the demo. The separate Agents Space restricts tools to unlocked tabs owned by this session. No model, backend, native shell or connection to the visitor's installed Lilo is involved. Both playgrounds are loaded only when opened.

Explore Lilo (the compass control) covers the shipped capability groups and routes into the relevant demo or settings screen. Peek and the Little window support local navigation and preserve notes when expanded into a tab. Archive/restore, Space profiles, archive delays, folder password locks and a labeled sample import use in-memory data. Capabilities requiring macOS, a native engine or hardware are explicitly labeled as Mac capabilities; the demo does not pretend to run DRM, native executables or system integrations. Reset forgets all demo data, including passwords and remembered approvals.

The demo follows the production tab layout and agent bridge contracts. Tabs work on all four edges with the native address-placement rules; the sample content uses the same chrome geometry as settings and overlays. Saved tabs support name and home-page editing, and Spaces retain their fixed, time-of-day or sample-page color mode. Wallpaper colors and native process metrics require the Mac app.

Menus follow the native groups, submenus, availability and alternate commands. The build reads shortcut definitions and terminal presets from the native Swift sources and both native translation catalogs. Keyboard customization updates both dispatch and menu hints. Closing saved tabs returns them to their saved home; split views retain their sidebar structure with up to four panes. Settings for website data, zoom, terminal appearance, extension profiles and agent approvals operate on the same local state as the visible pages.

For a live native comparison on macOS, `make site-native-preview` builds and opens a disposable Debug session. Its preferences, WebKit storage, downloads and agent socket use a temporary directory; quitting removes that directory. It does not open personal profiles.

`src/lib/demo-assets.ts` builds the demo's asset catalog with Astro. The alternate app icons are imported directly from `Lilo/Resources/AppIcons/` and optimized for the native settings grid; the classic icon is exported from the built app's `AppIcon.icns`. The Lilo mark and interface glyphs reuse the existing website and native UI components. Extension icons use their original bundled PNG data, as required by the native bridge's image validation. The public password-manager directory links to `lilo-ui/public/password-managers/` and Astro copies its files into the demo build. Sample websites have local SVG favicons. No runtime requests go to icon services.

To refresh the classic icon and the Codex desktop icon on macOS, build the app with `make xcode-build`, then run `make site-demo-icons`. `CODEX_ICON` can select the Codex app's `.icns` file; the default is the installed desktop app. Commit the exported PNGs in `src/assets/demo/`. These exports are inputs to the normal website build, which does not need macOS or an installed app. The static and browser tests check the native icon catalog, image loading, and setup assets in both languages.

## Changelog

The changelog component reads the repository's `CHANGELOG.md`, generated by Changie. Each published version appears at `/changelog/#vX.Y.Z`, newest first. `/fr/changelog/` has French navigation and dates; the release notes keep their original English text. Release content is static; the shared header script handles the theme toggle and mobile menu.

The imported history in `.changes/v0.1.5.md` contains several earlier versions. Reading the merged changelog preserves all of them. Pending fragments in `.changes/unreleased/` appear on the website when `make release-version` collects them. That command also rebuilds the website, including the changelog and app metadata.

## Deployment

Cloudflare Workers Builds uses `site` as its root directory and `npm run deploy` as its deploy command. Astro builds the website and Svelte demo together, then deploys `dist/`; no Worker script or Astro server adapter is needed. The full repository must be available for the shared UI sources, but only the website's dependencies are needed to build it. `wrangler.toml` keeps the existing custom domain, headers, redirects and 404 behavior.

Set the build watch paths to `site/**`, `lilo-ui/**`, `Lilo/Resources/AppIcons/**`, `Lilo/App/KeyboardShortcuts.swift`, `Lilo/App/MainMenu.swift`, `Lilo/Terminal/TerminalTheme.swift`, `Makefile`, `CHANGELOG.md`, and `Xcode/Configs/Base.xcconfig` so shared interface, icon, shortcut, theme and release changes also rebuild the website. The site's `.nvmrc` selects Node 22.23.4. Workers Builds settings live in the Cloudflare dashboard.

For a manual deployment, authenticate with Cloudflare first, then run:

```sh
make site-deploy
```

`getlilo.app` must be a zone in the owner's Cloudflare account. The custom domain route creates its DNS record and certificate on the first deploy.

### www

The Worker serves the apex only. To redirect `www.getlilo.app`, add a proxied DNS record for `www` (for example `AAAA www 100::`) and a Redirect Rule in the zone: when the hostname equals `www.getlilo.app`, redirect to `concat("https://getlilo.app", http.request.uri.path)` with a 301, preserving the query string.

## Assets

- `fonts/inter-latin-wght-*.woff2` and `fonts/geist-mono-latin-wght-*.woff2`: self-hosted Latin variable fonts, including italics, matching Ultracite's Inter and Geist Mono typography. Their SIL Open Font Licenses are in `fonts/Inter-OFL.txt` and `fonts/GeistMono-OFL.txt`. The filenames include the source font hashes for immutable caching.
- `favicon.svg` is the app icon's flower mark. `favicon.ico`, `apple-touch-icon.png` and `og.png` were rendered from it with headless Chrome and are committed as is.
