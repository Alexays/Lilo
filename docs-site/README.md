# docs.getlilo.app

Lilo's user documentation, built with [Blume](https://useblume.dev) as static pages for a Cloudflare Worker, separate from the marketing site in `site/`. It needs Node 22.23.4 or later. All commands run from the repository root through Make.

Coding agents must also follow the [documentation site rules](AGENTS.md).

## Development

```sh
make docs-dev           # Blume with live reload
make docs-build         # Generate the reference partials, build to docs-site/dist/, add the headers
make docs-check         # Check links and anchors, then the French translation gate
make docs-test          # Build, then test headers, routes and metadata and run blume audit
make docs-preview       # Preview the build with Cloudflare headers at http://localhost:8789
make docs-translate     # Translate new or changed pages into French with Claude Code
make docs-eval          # Ask an agent the questions in evals.yaml (manual, costs model time)
make docs-deploy-check  # Check the Cloudflare deployment without publishing
```

`make validate` includes `docs-check` and `docs-test`. After changing `package.json`, run `make docs-lock` to update the lockfile.

## Layout

- `content/` holds the English pages and a `meta.ts` per folder; `content/fr/` the French ones.
- `content/reference/_generated/` is written by `scripts/generate.mjs` from the app's sources and git-ignored.
- `blume.config.ts` holds the site settings; `theme.css` maps Lilo's color tokens onto Blume's. Fonts, the flower mark and icons are copies of the marketing site's.
- `scripts/headers.mjs` adds the Content-Security-Policy after the build; `scripts/translations.mjs` is the translation gate.
- `blume.translations.json` records which French files are current. It is committed and written only by `make docs-translate`.

## Deployment

The site is the `lilo-docs` Worker on `docs.getlilo.app` (`wrangler.toml`), deployed by Cloudflare Workers Builds with root directory `docs-site` and deploy command `npm run deploy`. Its watch paths are the files the build reads:

- `docs-site/**`
- `Lilo/App/KeyboardShortcuts.swift`
- `Lilo/Agent/*.swift`
- `Lilo/Import/BrowserImportScanner.swift`
- `lilo-ui/src/components/settings/settingsPanelModel.ts`
- `lilo-ui/src/lib/i18n/locales/en.json`
- `lilo-ui/src/lib/i18n/locales/fr.json`
- `COMPATIBILITY.md`
- `Xcode/Configs/Base.xcconfig`
- `Makefile`
