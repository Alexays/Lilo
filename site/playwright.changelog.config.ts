import { fileURLToPath } from "node:url";

import { defineConfig } from "@playwright/test";

import config from "./playwright.config";

export default defineConfig(config, {
  testMatch: "changelog.spec.ts",
  use: { baseURL: "http://127.0.0.1:8792" },
  webServer: {
    command: "make site-preview SITE_PREVIEW_PORT=8792",
    cwd: fileURLToPath(new URL("..", import.meta.url)),
    reuseExistingServer: false,
    url: "http://127.0.0.1:8792",
  },
});
