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

The site is the `lilo-docs` Worker on `docs.getlilo.app` (`wrangler.toml`), deployed by Cloudflare Workers Builds with root directory `docs-site` and deploy command `npm run deploy`.

**docs.getlilo.app must answer before any link to it is published on getlilo.app.** The marketing site's Documentation and Privacy links, its feature pages and its `llms.txt` point there; merged first, they would send every visitor and crawler to a dead host. The first deployment, in order:

1. In Cloudflare, create the `lilo-docs` Worker through **Workers Builds**, connected to this repository: root directory `docs-site`, build command `npm ci --ignore-scripts` (as `make` installs), deploy command `npm run deploy`, production branch `main`, a `NODE_VERSION` build variable of 22.23.4 or later if the image's default Node is older, and the watch paths below.
2. Let the first build deploy, then check that the custom domain `docs.getlilo.app` from `wrangler.toml` is attached to the Worker (**Settings > Domains & Routes**); attach it there if the deploy did not.
3. Check that these answer 200, in English and French (`/fr` before the path): `/`, `/start/install`, `/start/import`, `/guides/ai-agents`, `/reference/mcp-tools`, `/reference/extension-compatibility`, `/about/privacy`, `/llms.txt` and `/llms-full.txt`, plus `/sitemap.xml`. Those are the pages getlilo.app links to.
4. Only then merge the marketing-site changes that link to docs.getlilo.app.

`make docs-deploy-check` runs the same build and a `wrangler deploy --dry-run` locally; it needs no Cloudflare account. The watch paths are the files the build reads:

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

## Known limits

- A request for a missing file under `/_astro/` gets the 404 page with the year-long `immutable` cache of that folder, a rule copied from the marketing site. Asset names carry their content hash, so only a mistyped or retired name hits it.
- The 404 page served for a missing French URL shows French text but keeps `lang="en"` on its `<html>`, as Blume writes it. This is an upstream issue, not something to patch here.
- `make docs-eval` runs two Claude Code sessions per question in `evals.yaml` and costs model time, so it is run by hand, not by `make validate` or CI.
