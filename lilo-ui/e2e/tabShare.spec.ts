import { expect, test } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, nestedFolderWorld, SPACE_1 } from "./fixtures";
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
	// Tabs native cannot resolve to a live engine are not offered.
	await expect(picker.locator('[data-share-tab-id="tab-gamma"]')).toHaveCount(0);

	// A click selects a card; Share sends it.
	const beta = picker.locator('[data-share-tab-id="tab-beta"]');
	await beta.click();
	await expect(beta).toHaveAttribute("aria-pressed", "true");
	await expect(picker).toBeVisible();
	await picker.locator(".tab-share-btn.primary").click();

	await expect(picker).toHaveCount(0);
	const commands = await sentCommands(page);
	expect(commands.find((c) => c.action === "tabShare.resolve")?.payload).toEqual(
		{ requestId: "req-1", choice: "tab", tabId: "tab-beta" },
	);
});

test("the first card is selected from the start, so Return shares it", async ({
	page,
}) => {
	await bootChrome(page, initialWorld());

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		{ ...requestPicker("req-1", "meet.example.com"), suggestedTabIds: ["tab-beta"] },
	);
	const picker = page.locator(".tab-share-backdrop");
	await expect(picker.locator(".tab-share-search input")).toBeFocused();
	await expect(picker.locator('[data-share-tab-id="tab-beta"]')).toHaveAttribute("aria-pressed", "true");

	await page.keyboard.press("Enter");

	await expect(picker).toHaveCount(0);
	const commands = await sentCommands(page);
	expect(commands.find((c) => c.action === "tabShare.resolve")?.payload).toEqual(
		{ requestId: "req-1", choice: "tab", tabId: "tab-beta" },
	);
});

test("tabs are grouped by folder, and suggestions name where they live", async ({ page }) => {
	await bootChrome(page, nestedFolderWorld());

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		{
			...requestPicker("req-1", "meet.example.com"),
			shareableTabIds: ["tab-alpha", "tab-beta", "tab-gamma", "tab-home"],
			suggestedTabIds: ["tab-beta"],
		},
	);
	const picker = page.locator(".tab-share-backdrop");
	const [suggested, work] = [0, 1].map((index) => picker.locator(".tab-share-section").nth(index));

	await expect(suggested.locator(".tab-share-placement")).toHaveText(["Projects"]);
	await expect(work.locator(".tab-share-group")).toContainText("Work");
	await expect(work.locator(".tab-share-current-space")).toBeVisible();
	// Loose tabs first, in sidebar order; folders emptied by the suggestions are left out.
	await expect(work.locator(".tab-share-grid").first().locator(".tab-share-card-title")).toHaveText([
		"Pinned Home",
		"Gamma News",
	]);
	await expect(work.locator(".tab-share-folder")).toHaveCount(1);
	await expect(work.locator(".tab-share-folder .parents")).toHaveText("Projects / Clients /");
	await expect(work.locator(".tab-share-folder .name")).toHaveText("Acme");
	await expect(work.locator(".tab-share-placement")).toHaveCount(0);

	// A folder name finds its tabs.
	await picker.locator(".tab-share-search input").fill("acme");
	await expect(picker.locator("[data-share-tab-id]")).toHaveCount(1);
	await expect(picker.locator('[data-share-tab-id="tab-alpha"] .tab-share-placement')).toHaveText("Acme");
});

test("a folder collapsed in the sidebar opens on demand, its subfolders with it", async ({ page }) => {
	const world = nestedFolderWorld();
	world.foldersBySpace![SPACE_1] = world.foldersBySpace![SPACE_1].map((folder) =>
		folder.id === "folder-clients" ? { ...folder, isCollapsed: true } : folder,
	);
	await bootChrome(page, world);

	await page.evaluate(
		(msg) => window.__lilo!.receive(msg),
		{ ...requestPicker("req-1", "meet.example.com"), shareableTabIds: ["tab-alpha", "tab-beta", "tab-gamma"] },
	);
	const picker = page.locator(".tab-share-backdrop");
	const folders = picker.locator(".tab-share-folder");
	const clients = folders.filter({ hasText: "Clients" }).locator(".toggle");

	// Clients counts Acme's tab; Acme and the empty Archive stay out.
	await expect(folders.locator(".name")).toHaveText(["Projects", "Clients"]);
	await expect(clients).toHaveAttribute("aria-expanded", "false");
	await expect(clients.locator(".count")).toHaveText("1");
	await expect(picker.locator('[data-share-tab-id="tab-alpha"]')).toHaveCount(0);

	await clients.click();
	await expect(folders.locator(".name")).toHaveText(["Projects", "Clients", "Acme"]);
	await expect(picker.locator('[data-share-tab-id="tab-alpha"]')).toBeVisible();

	await clients.click();
	await picker.locator(".tab-share-search input").fill("alpha");
	await expect(picker.locator('[data-share-tab-id="tab-alpha"]')).toBeVisible();
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
	await expect(picker.locator(".tab-share-search input")).toBeFocused();

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

		await expect(page.locator('[data-share-tab-id="tab-blank"] .tab-share-card-title')).toHaveText("Nouvel onglet");
	});
});
