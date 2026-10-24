import { defineConfig } from "astro/config";

export default defineConfig({
  build: { inlineStylesheets: "never" },
  output: "static",
  server: { port: 8787 },
  site: "https://getlilo.app",
  trailingSlash: "always",
  vite: { server: { fs: { allow: [".."] } } },
});
