import { fileURLToPath } from "node:url";

import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  forbidOnly: !!process.env.CI,
  fullyParallel: true,
  retries: 0,
  testDir: "./tests",
  testMatch: "*.spec.ts",
  use: {
    ...devices["Desktop Chrome"],
    baseURL: "http://127.0.0.1:8788",
    reducedMotion: "reduce",
    trace: "retain-on-failure",
  },
  webServer: {
    command: "make site-preview",
    cwd: fileURLToPath(new URL("..", import.meta.url)),
    reuseExistingServer: !process.env.CI,
    url: "http://127.0.0.1:8788",
  },
  workers: 2,
});
