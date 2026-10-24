import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
	testDir: "./e2e",
	fullyParallel: true,
	forbidOnly: !!process.env.CI,
	retries: process.env.CI ? 1 : 0,
	// CI lists the tests that passed only on their retry from the JSON report (scripts/retried_tests.py).
	reporter: process.env.CI ? [["list"], ["github"], ["json", { outputFile: "test-results/report.json" }]] : "list",
	use: {
		baseURL: "http://localhost:5173",
		trace: "on-first-retry",
	},
	projects: [
		{
			name: "chromium",
			use: { ...devices["Desktop Chrome"] },
		},
	],
	webServer: {
		command: "npm run dev",
		port: 5173,
		reuseExistingServer: !process.env.CI,
	},
});
