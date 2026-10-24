import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import { tab, treeItem } from "../src/stores/testFixtures";

function requestPicker(requestId: string, origin: string) {
	return {
		event: "tabSharePickerRequested",
		requestId,
		origin,
		shareableTabIds: ["tab-alpha", "tab-beta"],
	};
}

test("picking a tab resolves the request with that tab's id", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		requestPicker("req-1", "meet.example.com"),
	);

	const picker = page.locator(".tab-share-backdrop");
	await expect(picker).toBeVisible();
	await expect(picker.locator(".tab-share-title")).toContainText(
		"meet.example.com",
	);
	// The active tab row carries the localized current-tab hint.
	await expect(
		picker.locator('[data-share-tab-id="tab-alpha"] .tab-share-current'),
	).toBeVisible();

	// Tabs native cannot resolve to a live engine are not offered.
	await expect(picker.locator('[data-share-tab-id="tab-gamma"]')).toHaveCount(0);

	await picker.locator('[data-share-tab-id="tab-beta"]').click();

	await expect(picker).toHaveCount(0);
	const commands = await sentCommands(page);
	expect(commands.find((c) => c.action === "tabShare.resolve")?.payload).toEqual(
		{ requestId: "req-1", choice: "tab", tabId: "tab-beta" },
	);
});

test("the system picker button resolves with choice system", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		requestPicker("req-1", "meet.example.com"),
	);

	const picker = page.locator(".tab-share-backdrop");
	await picker.locator(".tab-share-btn").first().click();

	await expect(picker).toHaveCount(0);
	const commands = await sentCommands(page);
	expect(commands.find((c) => c.action === "tabShare.resolve")?.payload).toEqual(
		{ requestId: "req-1", choice: "system" },
	);
});

test("Tab keeps focus inside the picker", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		{ ...requestPicker("req-1", "meet.example.com"), allowsSystem: true },
	);
	const picker = page.locator(".tab-share-panel");
	await expect(picker).toBeFocused();

	for (let i = 0; i < 5; i++) {
		await page.keyboard.press("Tab");
		await expect(picker.locator(":focus")).toHaveCount(1);
	}
	await page.keyboard.press("Shift+Tab");
	await expect(picker.locator(":focus")).toHaveCount(1);
});

test("Escape cancels the request", async ({ page }) => {
	await bootChrome(page, initialWorld());

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		requestPicker("req-1", "meet.example.com"),
	);
	await expect(page.locator(".tab-share-backdrop")).toBeVisible();

	await page.keyboard.press("Escape");

	await expect(page.locator(".tab-share-backdrop")).toHaveCount(0);
	const commands = await sentCommands(page);
	expect(commands.find((c) => c.action === "tabShare.resolve")?.payload).toEqual(
		{ requestId: "req-1", choice: "cancel" },
	);
});

test("a second request is auto-cancelled while the first stays open", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		requestPicker("req-1", "meet.example.com"),
	);
	await expect(page.locator(".tab-share-backdrop")).toBeVisible();

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		requestPicker("req-2", "call.example.org"),
	);

	// The newcomer is cancelled immediately; the first picker keeps showing.
	await expect
		.poll(async () =>
			(await sentCommands(page)).find((c) => c.action === "tabShare.resolve")
				?.payload,
		)
		.toEqual({ requestId: "req-2", choice: "cancel" });
	await expect(page.locator(".tab-share-title")).toContainText(
		"meet.example.com",
	);
});

test.describe("in French", () => {
	test.use({ locale: "fr-FR" });

	test("a blank tab's row reads Nouvel onglet", async ({ page }) => {
		const world = initialWorld();
		world.tabsBySpace[SPACE_1].push(tab("tab-blank", SPACE_1, { url: "", title: "" }));
		world.treeItemsBySpace[SPACE_1].push(treeItem("tab-blank", SPACE_1, 5));
		await bootChrome(page, world);

		await page.evaluate(
			(msg) => window.__lilo!.receive(msg),
			{ ...requestPicker("req-1", "meet.example.com"), shareableTabIds: ["tab-alpha", "tab-blank"] },
		);

		await expect(page.locator('[data-share-tab-id="tab-blank"] .tab-share-row-title')).toHaveText("Nouvel onglet");
	});
});
