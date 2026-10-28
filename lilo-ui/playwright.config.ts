import { defineConfig, devices } from "@playwright/test";

// Its own port, so make ui-dev on 5173 runs beside it; never reused, a server on it may be another checkout's.
const port = 5174;

export default defineConfig({
	testDir: "./e2e",
	fullyParallel: true,
	forbidOnly: !!process.env.CI,
	retries: process.env.CI ? 1 : 0,
	// Playwright's default, half the cores, leaves two of the CI runner's four idle; locally it keeps the Mac usable.
	workers: process.env.CI ? "100%" : undefined,
	// CI lists the tests that passed only on their retry from the JSON report (scripts/retried_tests.py).
	reporter: process.env.CI ? [["list"], ["github"], ["json", { outputFile: "test-results/report.json" }]] : "list",
	use: {
		baseURL: `http://localhost:${port}`,
		trace: "on-first-retry",
	},
	projects: [
		{
			name: "chromium",
			// Headless Chromium hides scrollbars; the app's WebKit keeps their gutter, which the sidebar's layout counts on.
			use: { ...devices["Desktop Chrome"], launchOptions: { ignoreDefaultArgs: ["--hide-scrollbars"] } },
		},
	],
	webServer: {
		command: `npx vite dev --host localhost --port ${port} --strictPort`,
		port,
		reuseExistingServer: false,
	},
});
