# Documentation site

These rules apply to `docs-site/`, the user documentation at docs.getlilo.app, alongside the repository's [AGENTS.md](../AGENTS.md). Read [README.md](README.md) for the layout and deployment. The site is built with [Blume](https://useblume.dev), pinned in `package.json`; its full documentation ships in `node_modules/blume/docs/` and its agent skill in `node_modules/blume/skills/blume/SKILL.md`. Read them for the version installed here, not from memory.

## Content

- Pages are Markdown or MDX under `content/`, English at the root and French in `content/fr/` with the same tree. Organize by what the reader is trying to do: `start/` (tutorials), `guides/` (how-to), `reference/`, `about/` (explanation).
- Every page has a `title` and a `description` of 110 to 160 characters. A page's URL comes from its file name, and its place in the sidebar from `sidebar.order`; folder titles and order live in each folder's `meta.ts`. URLs are stable: never rename or move a page without the owner's agreement.
- Every statement is true of the current app and found in its source: shortcuts in `Lilo/App/KeyboardShortcuts.swift`, menu and setting names as `lilo-ui/src/lib/i18n/locales/en.json` and `fr.json` spell them, terms as the glossary in [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md#glossary) defines them.
- Link other pages root-relative in their English form (`/guides/split-view`); Blume moves them into the reader's locale. URLs have no trailing slash.
- Use Blume's built-in components with no imports; add no custom components or layout overrides.
- No real user data in text or examples: `example.com` hosts and made-up names. No screenshots.

## Generated reference

- `scripts/generate.mjs` writes the partials under `content/reference/_generated/` (and the French shortcut and settings tables) from the app's sources before every Blume command. They are git-ignored build outputs: change the source they come from, never the partial. A reference page includes its partial with `<include>./_generated/<name>.md</include>`, which resolves to the French partial on the French page.
- The generator must be deterministic (no dates, stable order) and fail loudly on input it does not understand.

## Translation

- French is produced by `make docs-translate`, which runs `blume translate` with Claude Code, then review the diff against the French interface strings and commit the pages, partials and `blume.translations.json` together. Never edit the ledger by hand.
- `make docs-check` fails when a French page is missing or out of date, and when a translated reference partial is missing; a stale translated partial only warns.

## Headers and deployment

- `scripts/headers.mjs` prepends the Content-Security-Policy and security headers to the `_headers` file Blume writes, hashing each inline script. Do not add `public/_headers`: it would replace Blume's rules.
- The site deploys as its own Cloudflare Worker with static assets (`wrangler.toml`). Only `make docs-deploy-check` (a dry run) is part of the work; deploying is the owner's.

## Verification

Run commands from the repository root through Make: `make docs-check docs-test` for any change here (validation, translation gate, build, tests and `blume audit`), `make docs-preview` to see the build with its real headers. For layout or theme changes, check both languages at desktop and 390 px width, light and dark, keyboard focus, Reduce Motion, and the browser console for CSP violations.
