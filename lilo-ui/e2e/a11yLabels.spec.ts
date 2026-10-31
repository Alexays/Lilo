import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, nestedFolderWorld, SPACE_1 } from "./fixtures";

// Every visible control a screen reader can reach, without a name it could announce, with a role
// that needs a container it is missing (a tree item outside a tree, an option outside a list), or
// inside a button, whose children WebKit hides from VoiceOver.
function a11yProblems(page: Page): Promise<string[]> {
	return page.evaluate(() => {
		const selector = [
			"button", "a[href]", "input:not([type=hidden])", "select", "textarea",
			"[role=button]", "[role=tab]", "[role=menuitem]", "[role=menuitemcheckbox]", "[role=menuitemradio]",
			"[role=switch]", "[role=checkbox]", "[role=radio]", "[role=option]", "[role=treeitem]",
			"[role=combobox]", "[role=slider]", "[role=link]", "[role=dialog]", "[role=tree]", "[role=listbox]",
		].join(",");
		const owners: Record<string, string> = {
			treeitem: "[role=tree]", option: "[role=listbox]", tab: "[role=tablist]",
			menuitem: "[role=menu], [role=menubar]", menuitemcheckbox: "[role=menu]", menuitemradio: "[role=menu]",
		};
		const nameOf = (el: Element): string => {
			const labelledBy = el.getAttribute("aria-labelledby");
			if (labelledBy) return labelledBy.split(/\s+/).map((id) => document.getElementById(id)?.textContent ?? "").join(" ").trim();
			const parts = [el.getAttribute("aria-label"), el.getAttribute("title"), el.getAttribute("placeholder")];
			if (el instanceof HTMLInputElement || el instanceof HTMLSelectElement || el instanceof HTMLTextAreaElement) {
				parts.push(...Array.from(el.labels ?? [], (label) => label.textContent));
			} else if (!["dialog", "tree", "listbox"].includes(el.getAttribute("role") ?? "")) {
				parts.push((el as HTMLElement).innerText);
				el.querySelectorAll("[aria-label], img[alt]").forEach((child) => parts.push(child.getAttribute("aria-label") ?? child.getAttribute("alt")));
			}
			return parts.filter(Boolean).join(" ").trim();
		};
		return Array.from(document.querySelectorAll(selector))
			.filter((el) => (el as HTMLElement).checkVisibility({ visibilityProperty: true }))
			.filter((el) => !el.closest("[aria-hidden=true], [inert]"))
			.flatMap((el) => {
				const role = el.getAttribute("role") ?? "";
				const html = el.outerHTML.slice(0, 160);
				const problems: string[] = [];
				if (!nameOf(el)) problems.push(`unnamed: ${html}`);
				if (owners[role] && !el.parentElement?.closest(owners[role])) problems.push(`no ${owners[role]}: ${html}`);
				if (el.parentElement?.closest("button, [role=button]")) problems.push(`inside a button: ${html}`);
				return problems;
			});
	});
}

async function receive(page: Page, message: Record<string, unknown>): Promise<void> {
	await page.evaluate((msg) => window.__lilo!.receive(msg), message);
}

test("the sidebar, bottom bar and URL bar name every control", async ({ page }) => {
	await bootChrome(page, nestedFolderWorld());
	await expect(page.locator(".sidebar-layout")).toBeVisible();
	expect(await a11yProblems(page)).toEqual([]);
});

test("the site drawer names every control", async ({ page }) => {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1].find((tab) => tab.id === "tab-alpha")!.isCameraActive = true;
	await bootChrome(page, world);
	await page.locator(".permissions-btn").click();
	await expect(page.locator(".url-drawer.open")).toBeVisible();
	expect(await a11yProblems(page)).toEqual([]);
});

test("the command bar names every control", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await receive(page, { event: "openCommandBar" });
	await expect(page.locator(".command-bar")).toBeVisible();
	expect(await a11yProblems(page)).toEqual([]);
});

test("the find bar names every control", async ({ page }) => {
	await bootChrome(page, initialWorld());
	// The find bar mounts with the deferred chrome, a beat after boot.
	await expect(async () => {
		await receive(page, { event: "toggleFindBar", query: "x" });
		await expect(page.locator(".find-bar")).toBeVisible({ timeout: 200 });
	}).toPass();
	expect(await a11yProblems(page)).toEqual([]);
});

test("an empty search field's hidden clear button takes no focus", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await receive(page, { event: "openSettings" });
	const field = page.locator(".section-nav-toolbar .ui-search-field");
	await field.locator("input").focus();

	await page.keyboard.press("Tab");

	await expect(field.locator(".ui-search-field-clear")).not.toBeFocused();
});

test("settings name every control, in every section and subpage", async ({ page }) => {
	test.setTimeout(90_000);
	await page.emulateMedia({ reducedMotion: "reduce" });
	await bootChrome(page, initialWorld());
	await receive(page, { event: "openSettings" });
	await expect(page.locator(".settings-section-content")).toBeVisible();
	const sections = page.locator(".section-nav-button");
	for (let i = 0; i < await sections.count(); i++) {
		await sections.nth(i).click();
		expect(await a11yProblems(page), `section ${i}`).toEqual([]);
		const subpages = page.locator(".settings-section-content .ui-link-row");
		for (let j = 0; j < await subpages.count(); j++) {
			await subpages.nth(j).click();
			expect(await a11yProblems(page), `section ${i} subpage ${j}`).toEqual([]);
			// Back to the section, whatever the subpage did with the settings.
			await receive(page, { event: "openSettings" });
			await sections.nth(i).click();
		}
	}
});

for (const usage of ["browse", "develop"] as const) {
	test(`every onboarding step names its controls (${usage})`, async ({ page }) => {
		await bootChrome(page, initialWorld());
		for (let step = 0; step < (usage === "develop" ? 9 : 8); step++) {
			await receive(page, { event: "onboardingState", show: true, step, usage });
			await page.waitForTimeout(50);
			expect(await a11yProblems(page), `step ${step}`).toEqual([]);
		}
	});
}

test("the downloads, diagnostics and process manager panels name every control", async ({ page }) => {
	await bootChrome(page, initialWorld());
	for (const event of ["openDownloads", "openDiagnostics", "openProcessManager"]) {
		await receive(page, { event });
		await expect(page.locator(".panel-shell").first()).toBeVisible();
		expect(await a11yProblems(page), event).toEqual([]);
	}
});

test("a download row nests no control in another, and its main button selects and opens it", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await receive(page, { event: "openDownloads" });
	await page.locator(".downloads-panel").waitFor();
	await receive(page, {
		event: "downloadsSnapshot",
		items: [{ id: 1, url: "https://example.com/a.zip", filename: "a.zip", bytesReceived: 2, totalBytes: 2, state: "complete", startedAt: Date.now() / 1000, fileMissing: false, source: "wk" }],
	});
	const row = page.locator(".download-row");
	await expect(row).toBeVisible();

	const nested = await row.evaluate((node) =>
		Array.from(node.querySelectorAll("button, a[href], input, [role=button], [tabindex]"))
			.filter((el) => el.parentElement?.closest("button, a[href], [role=button], [tabindex]:not([tabindex='-1'])"))
			.map((el) => el.outerHTML.slice(0, 120)),
	);
	expect(nested).toEqual([]);
	expect(await row.evaluate((node) => node.matches("button, [role], [tabindex]"))).toBe(false);
	expect(await a11yProblems(page)).toEqual([]);

	await row.locator(".row-main").click();
	await expect(row).toHaveClass(/selected/);
	await row.locator(".row-main").focus();
	await page.keyboard.press("Enter");
	await expect.poll(async () => (await sentCommands(page)).some((c) => c.action === "openDownload")).toBe(true);
});

test("the space editor names every control", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await receive(page, { event: "openSpaceEditor", id: SPACE_1 });
	await expect(page.locator(".editor-panel")).toBeVisible();
	expect(await a11yProblems(page)).toEqual([]);
	await page.locator(".space-emoji-btn").click();
	expect(await a11yProblems(page), "emoji popover").toEqual([]);
});

test("the extensions popover names every control", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const extensions = ["One", "Two", "Three", "Four"].map((name) => ({
		id: `ext-${name}`, name, version: "1.0", description: "", isEnabled: true, hasPopup: true,
		hasBackground: false, hasContentScripts: false, badgeText: "", badgeColor: "#5b5bd6",
	}));
	await receive(page, { event: "extensionsChanged", ids: extensions.map((e) => e.id), extensions });
	await page.locator(".extension-menu-btn").click();
	await expect(page.locator(".extensions-popover")).toBeVisible();
	expect(await a11yProblems(page)).toEqual([]);
});

test("the screenshot editor names every control", async ({ page }) => {
	await bootChrome(page, initialWorld());
	const image = `data:image/svg+xml,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="800" height="500"><rect width="800" height="500" fill="#ddd"/></svg>')}`;
	await receive(page, { event: "screenshotCaptured", id: "shot", url: image, filename: "shot.png" });
	await expect(page.locator(".screenshot-editor")).toBeVisible();
	expect(await a11yProblems(page)).toEqual([]);
});

test("the tab share picker names every control", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await receive(page, { event: "tabSharePickerRequested", requestId: "r", origin: "meet.example.com", shareableTabIds: ["tab-alpha"] });
	await expect(page.locator(".tab-share-panel")).toBeVisible();
	expect(await a11yProblems(page)).toEqual([]);
});

test("the page overlays name every control", async ({ page }) => {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1][0] = {
		...world.tabsBySpace[SPACE_1][0],
		hasNavigationError: true, navigationErrorCode: -1009, navigationErrorDomain: "NSURLErrorDomain",
		navigationErrorDescription: "", navigationErrorURL: "https://example.com/",
	};
	await bootChrome(page, world);
	await expect(page.locator(".error-page")).toBeVisible();
	expect(await a11yProblems(page), "error page").toEqual([]);

	await receive(page, { event: "pageResponsivenessChanged", tabId: "tab-alpha", responsive: false, host: "example.com", site: "example.com" });
	await expect(page.locator(".page-hang")).toBeVisible();
	expect(await a11yProblems(page), "hang card").toEqual([]);
});
