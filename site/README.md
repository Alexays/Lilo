# getlilo.app

The Lilo landing page: plain static files in `public/`, served by a Cloudflare Worker with static assets (no Worker script). `wrangler.toml` holds the config, `public/_headers` the security and cache headers, `public/_redirects` the permanent redirects to the trailing-slash URLs.

## Generated files

The HTML pages are the source. `generate.py` (no dependencies) derives from them:

- the Markdown copy of each page (`index.md` beside each `index.html`) and `llms-full.txt`, the English pages in one file, for AI agents ([llms.txt](https://llmstxt.org); `llms.txt` itself is written by hand);
- in each page's JSON-LD, the `FAQPage`, which must match the visible FAQ word for word, and the `softwareVersion`, read from `MARKETING_VERSION` in `Xcode/Configs/Base.xcconfig`.

After editing a page, run `make site-generate` (or `python3 site/generate.py`) and commit the result. `npm run deploy` runs it too. A new page also needs its entry in `generate.py`, `sitemap.xml`, `llms.txt` and `_redirects`.

## Preview locally

```sh
make site-dev   # or: cd site && npm ci && npm run dev
```

Then open http://localhost:8787. Unknown paths serve `public/404.html`.

## Deploy

Cloudflare's Workers Builds deploys it on each push to `main`: the `lilo-site` Worker is connected to this repository with `site` as its root directory and `site/**` as its build watch path, and runs `npm run deploy`. Deploying by hand:

`getlilo.app` must be a zone in the owner's Cloudflare account: the custom domain route in `wrangler.toml` creates its DNS record and certificate on the first deploy.

```sh
cd site
npx wrangler login   # once
npm run deploy       # or, from the repository root: make site-deploy
```

`npx wrangler deploy --dry-run` checks the config without logging in.

### www

The Worker serves the apex only. To send `www.getlilo.app` to it, add a proxied DNS record for `www` (for example `AAAA www 100::`) and a Redirect Rule in the zone (Rules, Redirect Rules): when the hostname equals `www.getlilo.app`, redirect dynamically to `concat("https://getlilo.app", http.request.uri.path)` with a 301, preserving the query string. A Worker script could do it too, but it would have to run before every asset and `_headers` would stop applying.

## Assets

- `fonts/nunito-latin-wght.woff2`: Nunito (latin subset, variable weight) under the SIL Open Font License, see `fonts/OFL.txt`. It is self-hosted, so visitors' browsers contact no third party; Apple platforms use the system's SF Rounded first.
- `favicon.svg` is the app icon's flower mark; `favicon.ico`, `apple-touch-icon.png` and `og.png` were rendered from it with headless Chrome and are committed as is.
