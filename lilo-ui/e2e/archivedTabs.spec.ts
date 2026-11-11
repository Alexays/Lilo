import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

for (const position of ["left", "right", "top", "bottom"] as const) {
	test(`the recently archived menu stays visible and clickable with tabs on the ${position}`, async ({ page }) => {
		await page.setViewportSize({ width: 1000, height: 600 });
		const strip = position === "top" || position === "bottom";
		await bootChrome(page, { ...initialWorld(), sidebarWidth: 200, tabPosition: position }, strip ? ".tab-strip" : undefined);
		await page.evaluate(() => window.__lilo!.receive({
			event: "archivedTabs",
			tabs: Array.from({ length: 26 }, (_, index) => ({
				id: `archived-${index}`,
				title: `Archived page ${index}`,
				url: `https://example.com/page/${index}`,
				archivedAt: Date.now() - 3_600_000,
			})),
			favicons: {},
		}));

		const button = page.getByRole("button", { name: strip ? "26 recently archived tabs" : "Downloads and archived tabs" });
		await button.click();
		const menu = page.getByRole("menu", { name: strip ? "Archived" : "Downloads and archived tabs", exact: true });
		await expect(menu).toBeVisible();
		await expect.poll(() => menu.evaluate((el) => {
			const rect = el.getBoundingClientRect();
			return rect.left >= 8 && rect.right <= innerWidth - 8
				&& rect.top >= 8 && rect.bottom <= innerHeight - 8
				&& [rect.left + 24, rect.right - 24].every((x) =>
					[rect.top + 24, rect.bottom - 24].every((y) => el.contains(document.elementFromPoint(x, y))));
		})).toBe(true);

		const row = menu.getByRole("menuitem", { name: /Archived page 0\b/ });
		const box = (await row.boundingBox())!;
		await row.click({ position: { x: box.width - 24, y: 16 } });
		expect((await sentCommands(page)).find((command) => command.action === "restoreArchivedTabs")?.payload).toEqual({ ids: ["archived-0"] });
		await expect(menu).toHaveCount(0);

		await button.click();
		await menu.getByRole("menuitem", { name: "Show all archived tabs" }).click();
		await expect(menu).toHaveCount(0);
		await expect(page.locator(".scope-token")).toHaveText("Archived");
		await expect(page.locator(".command-bar-input")).toHaveValue("");
	});
}

test("the library menu lists running downloads above the archived tabs, with their own controls", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => {
		window.__lilo!.receive({
			event: "archivedTabs",
			tabs: [{ id: "archived-0", title: "Archived page", url: "https://example.com/page", archivedAt: Date.now() - 3_600_000 }],
			favicons: {},
		});
		window.__lilo!.receive({
			event: "downloadUpdated", id: 1, url: "https://example.com/a.zip", filename: "a.zip", state: "inProgress",
			bytesReceived: 40, totalBytes: 100, startedAt: 1, fileMissing: false, source: "wk",
		});
	});

	await page.getByRole("button", { name: "Downloads, 1 active" }).click();
	const menu = page.getByRole("menu", { name: "Downloads and archived tabs", exact: true });
	await expect(menu.getByRole("menuitem")).toHaveText(["", /a\.zip\s*40%/, "", "", /Archived page/]);
	await menu.getByRole("menuitem", { name: "Pause" }).click();
	expect((await sentCommands(page)).some((command) => command.action === "pauseDownload")).toBe(true);
	await menu.getByRole("menuitem", { name: "Show all downloads" }).click();
	await expect(menu).toHaveCount(0);
	await expect(page.getByRole("region", { name: "Downloads" })).toBeVisible();
});

test("a finished download waits above the downloads button, ready to drag out or open", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const finish = (id: number, filename: string) => page.evaluate(([id, filename]) => window.__lilo!.receive({
		event: "downloadUpdated", id, url: `https://example.com/${filename}`, filename, state: "complete",
		bytesReceived: 100, totalBytes: 100, startedAt: 1, endedAt: 2, fileMissing: false, source: "wk",
	}), [id, filename] as const);

	await finish(1, "report.pdf");
	const card = page.getByRole("group", { name: "Downloads" });
	const file = card.getByRole("button", { name: /report\.pdf/ });
	const box = (await file.boundingBox())!;
	await page.mouse.move(box.x + 20, box.y + 20);
	await page.mouse.down();
	await page.mouse.move(box.x + 40, box.y + 20);
	await page.mouse.up();
	await expect(card).toHaveCount(0);
	const dragged = await sentCommands(page);
	expect(dragged.some((command) => command.action === "startDownloadDrag")).toBe(true);
	expect(dragged.some((command) => command.action === "openDownload")).toBe(false);

	await finish(2, "photo.png");
	await card.getByRole("button", { name: /photo\.png/ }).click();
	await expect(card).toHaveCount(0);
	expect((await sentCommands(page)).some((command) => command.action === "openDownload")).toBe(true);

	await page.getByRole("button", { name: "Downloads and archived tabs" }).click();
	const menu = page.getByRole("menu", { name: "Downloads and archived tabs", exact: true });
	await menu.getByRole("menuitem", { name: /report\.pdf/ }).hover();
	await menu.getByRole("menuitem", { name: "Show in Finder" }).first().click();
	expect((await sentCommands(page)).some((command) => command.action === "showDownloadInFinder")).toBe(true);
});
