import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

test("a banner floats over the page, never over the sidebar of a narrow window", async ({ page }) => {
	await page.setViewportSize({ width: 600, height: 400 });
	await bootChrome(page, initialWorld());
	await page.evaluate(() => {
		document.documentElement.style.setProperty("--sidebar-width", "200px");
		window.__lilo!.receive({ event: "extensionDebuggers", debuggers: [{ id: "ext-a", name: "A debugging extension with a long name" }] });
	});

	const banner = page.locator(".notice-capsule");
	await expect(banner).toBeVisible();
	const box = (await banner.boundingBox())!;
	const sidebar = (await page.locator(".sidebar").boundingBox())!;
	expect(box.x).toBeGreaterThanOrEqual(sidebar.x + sidebar.width);
	expect(box.x + box.width).toBeLessThanOrEqual(600);

	await banner.getByRole("button", { name: "Stop Debugging" }).first().click();
	expect((await sentCommands(page)).some((command) => command.action === "cancelExtensionDebugging")).toBe(true);
});

for (const colorScheme of ["light", "dark"] as const) {
	test(`a banner is painted like the other floating cards in ${colorScheme} mode`, async ({ page }) => {
		await page.emulateMedia({ colorScheme });
		await bootChrome(page, initialWorld());
		await page.evaluate(() => window.__lilo!.receive({ event: "crashRecoveryDetected" }));

		const banner = page.locator(".notice-capsule");
		await expect(banner).toBeVisible();
		const [background, floatSurface] = await banner.evaluate((el) => {
			const probe = document.createElement("div");
			probe.style.background = "var(--float-surface)";
			document.body.appendChild(probe);
			const expected = getComputedStyle(probe).backgroundColor;
			probe.remove();
			return [getComputedStyle(el).backgroundColor, expected];
		});
		expect(background).toBe(floatSurface);
	});
}

test("one capsule shows the first notice and folds the others", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => {
		window.__lilo!.receive({ event: "crashRecoveryDetected" });
		window.__lilo!.receive({ event: "sessionRestoreDegraded", spaceName: "Example" });
		window.__lilo!.receive({ event: "extensionDebuggers", debuggers: [{ id: "ext-a", name: "Debugger" }] });
	});
	const capsule = page.locator(".notice-capsule");
	await expect(capsule).toHaveCount(1);
	await expect(capsule.locator(".notice-row")).toHaveCount(1);

	await capsule.getByRole("button", { name: "2 more notices" }).click();
	await expect(capsule.locator(".notice-row")).toHaveCount(3);
	await expect(capsule.getByRole("button", { name: "Stop Debugging" })).toBeVisible();
});
