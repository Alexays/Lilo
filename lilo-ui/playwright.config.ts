import { defineConfig, devices } from "@playwright/test";

// Its own port, so make ui-dev on 5173 runs beside it; never reused, a server on it may be another checkout's.
const port = 5174;

export default defineConfig({
	testDir: "./e2e",
	fullyParallel: true,
	forbidOnly: !!process.env.CI,
	retries: process.env.CI ? 1 : 0,
	// CI lists the tests that passed only on their retry from the JSON report (scripts/retried_tests.py).
	reporter: process.env.CI ? [["list"], ["github"], ["json", { outputFile: "test-results/report.json" }]] : "list",
	use: {
		baseURL: `http://localhost:${port}`,
		trace: "on-first-retry",
	},
	projects: [
		{
			name: "chromium",
			use: { ...devices["Desktop Chrome"] },
		},
	],
	webServer: {
		command: `npx vite dev --host localhost --port ${port} --strictPort`,
		port,
		reuseExistingServer: false,
	},
});
