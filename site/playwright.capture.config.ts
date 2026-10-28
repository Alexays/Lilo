import { fileURLToPath } from "node:url";

import { defineConfig } from "@playwright/test";

export default defineConfig({
  forbidOnly: true,
  retries: 0,
  testDir: "./captures",
  testMatch: "*.spec.ts",
  timeout: 60_000,
  use: {
    baseURL: "http://127.0.0.1:8791",
    reducedMotion: "reduce",
  },
  webServer: {
    command: "make site-capture-server",
    cwd: fileURLToPath(new URL("..", import.meta.url)),
    reuseExistingServer: false,
    url: "http://127.0.0.1:8791/demo/",
  },
  workers: 1,
});
