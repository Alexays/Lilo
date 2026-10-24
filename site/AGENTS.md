# Astro website

These rules apply to `site/`, alongside the repository's [AGENTS.md](../AGENTS.md). Read [README.md](README.md) for the source layout and deployment details.

## Documentation and tooling

- Before changing Astro APIs or configuration, consult the Astro Docs MCP server (`https://mcp.docs.astro.build/mcp`) and check compatibility with the version in `package.json`. If MCP is unavailable, use the [official docs](https://docs.astro.build/).
- Build on the existing project. When an official integration is needed, follow the documented `astro add` workflow; install other packages with npm. Expose these operations through the root Makefile, extending it when necessary, and commit the dependency and lockfile changes together.
- Keep strict TypeScript and the existing Ultracite Astro lint/format presets enabled. Fix diagnostics without weakening the checks.

## Components, scripts and styles

- Keep the website statically rendered for Cloudflare. Use `.astro` components and build-time frontmatter for content; add framework islands only when an interaction needs them, choosing the least eager hydration directive that supports the feature.
- Define a `Props` interface for components that accept props. Keep browser APIs in client scripts; frontmatter runs at build time for this site.
- Use normal `<script>` tags so Astro handles TypeScript, bundling and deduplication. Keep small behaviors in their `.astro` component; put reusable browser modules in `src/` as `.ts`. Do not add authored JavaScript in `public/` or custom compilation endpoints. Reserve `is:inline` for cases that require unprocessed output and comply with the site's CSP.
- Use component-scoped `<style>` tags for component rules. Keep shared tokens, resets and site-wide styles in `src/styles/global.css`; use `:global()` only for selectors that intentionally cross component boundaries.
- Keep shared page structure in `src/layouts/Layout.astro` and reusable UI in `src/components/`. Navigation should render one set of links that adapts to the viewport.

## Content, assets and accessibility

- Maintain the English and French routes together. Shared website copy belongs in both locales in `src/lib/i18n.ts`; translate route content in both page files. Preserve language alternates, canonical URLs, section anchors and the footer's language switch.
- Use semantic HTML with one main landmark containing the page heading, a working skip link, and the shared footer outside main. Give icon controls accessible names and preserve keyboard operation, focus visibility and navigation without JavaScript.
- Respect Reduce Motion, support light and dark appearances, and keep Lilo's existing color tokens. Demos and animations must do no background work while unused.
- Use `astro:assets` for content images that benefit from optimization. Files needing stable URLs, such as favicons, can stay in `public/`. Give images dimensions and appropriate alt text; hide decorative SVGs from assistive technology.
- Preserve `public/_headers`, including the script CSP. Use `set:html` only with trusted repository content or sanitized HTML, and escape serialized JSON for its HTML context.
- Edit sources rather than `dist/` or `.astro/`. Markdown copies, FAQ metadata and the website's release notes are generated from their documented sources.

## Verification

- Run commands from the repository root through Make. Use `make site-fix` for formatting when needed, then `make site-check site-test`. `astro check` is required because TypeScript alone does not check `.astro` templates.
- For layout or interaction changes, check both languages at desktop and mobile widths, keyboard behavior, appearance changes and navigation without JavaScript in a browser. Add regression coverage for behavior that could break; avoid mock browser tests that reproduce the implementation.
- Run `make validate` before reporting completion, as required by the root rules. Report any failing gate accurately even when the website checks pass.

Astro references: [AI development](https://docs.astro.build/en/guides/build-with-ai/), [components](https://docs.astro.build/en/basics/astro-components/), [client scripts](https://docs.astro.build/en/guides/client-side-scripts/), [scoped styles](https://docs.astro.build/en/guides/styling/) and [TypeScript](https://docs.astro.build/en/guides/typescript/).
