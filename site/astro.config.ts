import { readFileSync } from "node:fs";

import sitemap from "@astrojs/sitemap";
import svelte from "@astrojs/svelte";
import { defineConfig } from "astro/config";

const latestRelease = readFileSync(
  new URL("../CHANGELOG.md", import.meta.url),
  "utf-8"
).match(/^## \[[^\]]+\] - (?<date>\d{4}-\d{2}-\d{2})/mu)?.groups?.date;

export default defineConfig({
  build: { inlineStylesheets: "never" },
  integrations: [
    svelte({ compilerOptions: { discloseVersion: false, runes: true } }),
    sitemap({
      filter: (page) => !new URL(page).pathname.startsWith("/demo/"),
      i18n: { defaultLocale: "en", locales: { en: "en", fr: "fr" } },
      serialize: (item) =>
        item.url.endsWith("/changelog/")
          ? { ...item, lastmod: latestRelease }
          : item,
    }),
  ],
  output: "static",
  server: { port: 8787 },
  site: "https://getlilo.app",
  trailingSlash: "always",
  vite: {
    build: { assetsInlineLimit: 0 },
    plugins: [
      {
        enforce: "pre",
        name: "strip-native-strings",
        transform(code, id) {
          if (!/\/i18n\/locales\/[a-z]+\.json$/u.test(id)) {
            return;
          }

          const catalog = JSON.parse(code);
          delete catalog.native;

          return { code: JSON.stringify(catalog), map: null };
        },
      },
    ],
    resolve: { dedupe: ["svelte"] },
    server: { fs: { allow: [".."] } },
  },
});
