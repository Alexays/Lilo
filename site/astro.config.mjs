import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://getlilo.app',
  output: 'static',
  trailingSlash: 'always',
  build: { inlineStylesheets: 'never' },
  server: { port: 8787 },
  vite: { server: { fs: { allow: ['..'] } } },
});
