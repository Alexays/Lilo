import { expect, test, type Page } from "@playwright/test";
import { blankPoint, bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

function extension(id: string, name: string, badgeText = "") {
	return {
		id,
		name,
		version: "1.0",
		description: "",
		isEnabled: true,
		hasPopup: true,
		hasBackground: false,
		hasContentScripts: false,
		badgeText,
		badgeColor: "#5b5bd6",
	};
}

async function bootWithExtensions(page: Page) {
	await bootChrome(page, initialWorld());
	await page.evaluate(
		(extensions) => window.__lilo!.receive({ event: "extensionsChanged", ids: extensions.map((e) => e.id), extensions }),
		[
			extension("ext-blocker", "uBlock Origin", "9"),
			extension("ext-vault", "Bitwarden"),
			extension("ext-marks", "Raindrop"),
		],
	);
	await page.locator(".extension-cluster").waitFor();
}

test("the cluster stays visible while the URL actions stay hidden", async ({
	page,
}) => {
	await bootWithExtensions(page);

	await expect(page.locator(".extension-menu-btn")).toBeVisible();
	await expect(page.locator(".url-actions-reveal")).toHaveCSS("opacity", "0");
	// Only the trigger shows until something is pinned.
	await expect(page.locator(".extension-cluster .extension-icon")).toHaveCount(1);
	// A badge on a folded-away extension surfaces as a dot on the trigger.
	await expect(page.locator(".cluster-dot")).toBeVisible();
});

test("the popover lists every enabled extension and opens its popup", async ({
	page,
}) => {
	await bootWithExtensions(page);

	await page.locator(".extension-menu-btn").click();
	const popover = page.locator(".extensions-popover");
	await expect(popover.locator(".extensions-popover-row")).toHaveCount(3);

	await popover.getByRole("menuitem", { name: "Bitwarden" }).click();

	await expect(popover).toHaveCount(0);
	const commands = await sentCommands(page);
	const opened = commands.find((c) => c.action === "openExtensionPopup");
	expect(opened?.payload.id).toBe("ext-vault");
});

test("pinning moves an extension into the address bar and persists it", async ({
	page,
}) => {
	await bootWithExtensions(page);

	await page.locator(".extension-menu-btn").click();
	const row = page
		.locator(".extensions-popover-row")
		.filter({ hasText: "uBlock Origin" });
	await row.hover();
	await row.locator(".row-pin").click();

	await expect(page.locator(".extension-cluster .extension-icon")).toHaveCount(2);
	await expect(page.locator(".extension-cluster").getByRole("button", { name: "uBlock Origin" })).toBeVisible();
	await expect(page.locator(".extension-cluster .badge")).toHaveText("9");
	await expect(page.locator(".cluster-dot")).toHaveCount(0);

	const commands = await sentCommands(page);
	expect(commands.filter((c) => c.action === "setSetting")).toEqual([
		{
			action: "setSetting",
			payload: { key: "pinnedExtensions", value: "ext-blocker" },
		},
	]);
});

test("a fourth, fifth and sixth pin are taken, with no limit message", async ({ page }) => {
	await page.setViewportSize({ width: 1280, height: 720 });
	await bootChrome(page, { ...initialWorld(), sidebarWidth: 400 });
	const names = ["uBlock Origin", "Bitwarden", "Raindrop", "Dark Reader", "Wappalyzer", "Grammarly"];
	const extensions = names.map((name, i) => extension(`ext-${i}`, name));
	await page.evaluate(
		(list) => window.__lilo!.receive({ event: "extensionsChanged", ids: list.map((e) => e.id), extensions: list }),
		extensions,
	);

	await page.locator(".extension-menu-btn").click();
	for (const name of names) {
		const pin = page.locator(".extensions-popover-row").filter({ hasText: name }).locator(".row-pin");
		await expect(pin).toBeEnabled();
		await expect(pin).toHaveAttribute("aria-label", "Pin to the address bar");
		await pin.click();
		await expect(pin).toHaveAttribute("aria-pressed", "true");
	}

	await expect(page.locator(".extension-cluster .extension-icon:not(.extension-menu-btn)")).toHaveCount(6);
	await expect(page.locator(".extensions-popover")).not.toContainText(/up to|can be pinned| of /i);
	const writes = (await sentCommands(page)).filter((c) => c.action === "setSetting");
	expect(writes.at(-1)?.payload.value).toBe("ext-0,ext-1,ext-2,ext-3,ext-4,ext-5");
});

test.describe("pinned extensions beyond the address bar's room", () => {
	const names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "Unpinned"];

	async function bootPinned(page: Page, sidebarWidth: number) {
		await bootChrome(page, { ...initialWorld(), sidebarWidth });
		const list = names.map((name, i) => extension(`ext-${i}`, name, i === 7 ? "3" : ""));
		await page.evaluate((extensions) => {
			window.__lilo!.receive({ event: "extensionsChanged", ids: extensions.map((e) => e.id), extensions });
			window.__lilo!.receive({
				event: "settingsLoaded",
				settings: { pinnedExtensions: extensions.slice(0, 8).map((e) => e.id).join(",") },
			});
		}, list);
	}

	// The pinned names shown in the address bar, then those listed in the popover's pinned section.
	async function split(page: Page) {
		const inline = await page.locator(".extension-cluster .extension-icon:not(.extension-menu-btn)").evaluateAll((icons) =>
			icons.map((icon) => icon.getAttribute("aria-label")),
		);
		await page.locator(".extension-menu-btn").click();
		const popover = page.locator(".extensions-popover");
		await expect(popover).toBeVisible();
		const rows = await popover.locator(".section-label, .section-separator, .extensions-popover-row .row-name").allTextContents();
		await page.keyboard.press("Escape");
		await expect(popover).toHaveCount(0);
		const sectionEnd = rows.indexOf("");
		return { inline, rows, overflow: rows[0] === "Pinned" ? rows.slice(1, sectionEnd) : [] };
	}

	async function expectNothingClipped(page: Page) {
		const bar = (await page.locator(".url-trigger").boundingBox())!;
		const boxes = await page.locator(".extension-cluster .extension-icon").evaluateAll((icons) =>
			icons.map((icon) => icon.getBoundingClientRect().toJSON() as DOMRect),
		);
		for (const [i, box] of boxes.entries()) {
			expect(box.left).toBeGreaterThanOrEqual(bar.x);
			expect(box.right).toBeLessThanOrEqual(bar.x + bar.width);
			expect(box.top).toBeGreaterThanOrEqual(bar.y);
			expect(box.bottom).toBeLessThanOrEqual(bar.y + bar.height);
			if (i > 0) expect(box.left).toBeGreaterThanOrEqual(boxes[i - 1].right);
		}
		// The address keeps readable room beside the icons.
		const address = (await page.locator(".url-text-shell").boundingBox())!;
		expect(address.width).toBeGreaterThanOrEqual(70);
		expect(address.x + address.width).toBeLessThanOrEqual(boxes[0].left);
	}

	test("a narrow sidebar shows fewer icons and lists the rest in pin order, a wide one brings them back", async ({ page }) => {
		await bootPinned(page, 220);
		const icons = page.locator(".extension-cluster .extension-icon:not(.extension-menu-btn)");
		await expect(icons).toHaveCount(3);
		await expect(page.locator(".url-text-shell")).toHaveCSS("margin-right", "96px");

		const narrow = await split(page);
		expect(narrow.inline).toEqual(["Alpha", "Bravo", "Charlie"]);
		expect(narrow.overflow).toEqual(["Delta", "Echo", "Foxtrot", "Golf", "Hotel"]);
		// The inline pins and the unpinned extension follow, below a separator.
		expect(narrow.rows.slice(7)).toEqual(["Alpha", "Bravo", "Charlie", "Unpinned"]);
		await expectNothingClipped(page);
		// Hotel's badge stays visible: in its row, and as the menu button's dot.
		await expect(page.locator(".cluster-dot")).toBeVisible();

		await page.evaluate(() => document.documentElement.style.setProperty("--sidebar-width", "320px"));
		await expect(icons).toHaveCount(7);
		const wide = await split(page);
		expect(wide.inline).toEqual(["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf"]);
		expect(wide.overflow).toEqual(["Hotel"]);
		await expect(page.locator(".url-text-shell")).toHaveCSS("margin-right", "192px");
		await expectNothingClipped(page);
	});

	test("an overflowed pin opens its popup from the popover", async ({ page }) => {
		await bootPinned(page, 220);
		await page.locator(".extension-menu-btn").click();
		const row = page.locator(".extensions-popover-row").filter({ hasText: "Hotel" });
		await expect(row.locator(".row-badge")).toHaveText("3");
		await row.getByRole("menuitem").click();

		const opened = (await sentCommands(page)).find((c) => c.action === "openExtensionPopup");
		expect(opened?.payload.id).toBe("ext-7");
	});
});

test("Escape closes the popover and gives focus back to its button", async ({ page }) => {
	await bootWithExtensions(page);
	await page.locator(".extension-menu-btn").focus();
	await page.keyboard.press("Enter");
	await expect(page.locator(".extensions-popover")).toBeVisible();

	await page.keyboard.press("Escape");

	await expect(page.locator(".extensions-popover")).toHaveCount(0);
	await expect(page.locator(".extension-menu-btn")).toBeFocused();
});

test("a click outside the popover closes it and gives focus back to its button", async ({ page }) => {
	await bootWithExtensions(page);
	await page.locator(".extension-menu-btn").focus();
	await page.keyboard.press("Enter");
	await expect(page.locator(".extensions-popover :focus")).toHaveCount(1);

	const point = await blankPoint(page, ".extensions-popover");
	await page.mouse.click(point.x, point.y);

	await expect(page.locator(".extensions-popover")).toHaveCount(0);
	await expect(page.locator(".extension-menu-btn")).toBeFocused();
});

test("a long list in a short window keeps the popover's footer on screen", async ({ page }) => {
	await page.setViewportSize({ width: 600, height: 400 });
	await bootChrome(page, initialWorld());
	const extensions = Array.from({ length: 20 }, (_, i) => extension(`ext-${i}`, `Extension ${i}`));
	await page.evaluate(
		(list) => window.__lilo!.receive({ event: "extensionsChanged", ids: list.map((e) => e.id), extensions: list }),
		extensions,
	);
	await page.locator(".extension-menu-btn").click();

	const box = (await page.locator(".extensions-popover").boundingBox())!;
	expect(box.y + box.height).toBeLessThanOrEqual(400);
	await page.getByRole("menuitem", { name: "Add extensions" }).click();
	expect((await sentCommands(page)).some((c) => c.action === "createTab")).toBe(true);
});

test.describe("in French", () => {
	test.use({ locale: "fr-FR" });

	test("each footer action of the popover holds on one line", async ({ page }) => {
		await bootWithExtensions(page);
		await page.locator(".extension-menu-btn").click();

		const lines = await page.locator(".extensions-popover .footer-action").evaluateAll((buttons) =>
			buttons.map((button) => {
				const range = document.createRange();
				range.selectNodeContents(button);
				return new Set([...range.getClientRects()].map((rect) => Math.round(rect.top))).size;
			}),
		);
		expect(lines).toEqual([1, 1]);
	});
});

test("the Extensions settings page opens the Chrome Web Store in a new tab", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.locator(".section-nav-button").filter({ hasText: "Extensions" }).click();
	await page.getByRole("button", { name: "Add extensions" }).click();
	await expect.poll(async () => (await sentCommands(page)).find((c) => c.action === "createTab")?.payload.url)
		.toBe("https://chromewebstore.google.com");
});
