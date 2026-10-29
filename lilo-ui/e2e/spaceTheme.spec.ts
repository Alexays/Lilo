import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

const sidebarBackground = (page: Page) =>
	page.evaluate(() => document.documentElement.style.getPropertyValue("--sidebar-bg").trim());

const reportedBackground = async (page: Page) =>
	(await sentCommands(page)).filter((command) => command.action === "updateWindowBackground").at(-1)?.payload.color;

test("the shared tints mix the sidebar's own palette on a dark Space", async ({ page }) => {
	const world = initialWorld();
	world.spaces[0].color = "#20242e";
	// Dark, so the sidebar's text color differs from the document's and the tint checks below mean something.
	await page.emulateMedia({ colorScheme: "dark" });
	await bootChrome(page, world);

	const colors = await page.evaluate(() => {
		const probe = document.createElement("div");
		const read = (value: string) => {
			probe.style.color = value;
			return getComputedStyle(probe).color;
		};
		document.body.append(probe);
		const rootText = read("var(--text-primary)");
		document.querySelector(".sidebar-layout")!.append(probe);
		const result = {
			rootText,
			sidebarText: read("var(--text-primary)"),
			tint: read("var(--text-primary-tint-10)"),
			mixed: read("color-mix(in srgb, var(--text-primary) 10%, transparent)"),
			accentTint: read("var(--accent-tint-12)"),
			accentMixed: read("color-mix(in srgb, var(--accent) 12%, transparent)"),
		};
		probe.remove();
		return result;
	});

	expect(colors.sidebarText).not.toBe(colors.rootText);
	expect(colors.tint).toBe(colors.mixed);
	expect(colors.accentTint).toBe(colors.accentMixed);
});

test("a new private space behind the hidden Agents space tints the sidebar and the window frame alike", async ({ page }) => {
	const world = initialWorld();
	// Same color as the space the window leaves: a theme read from the wrong space would not change.
	world.spaces.push({ ...world.spaces[0], id: "agents", name: "Agents", sortOrder: 2 });
	await bootChrome(page, world);
	await page.evaluate(() => window.__lilo!.receive({
		event: "agentActivity", moods: {}, clients: [], agentsSpaceIds: ["agents"], agentsProfileId: "profile-1", hiddenAgentsSpaceIds: ["agents"],
	}));
	await expect.poll(() => reportedBackground(page)).toBe(await sidebarBackground(page));
	const workBackground = await sidebarBackground(page);

	await page.evaluate(() => window.__lilo!.receiveBatch([
		{ event: "spaceCreated", id: "private", name: "Private", icon: "P", color: "#3f4656", profileId: "profile-1", isPrivate: true, sortOrder: 3 },
		{
			event: "browserStateChanged",
			changedSpaceId: "private",
			profileId: "profile-1",
			states: [{ spaceId: "private", activeTabId: "", tabs: [], folders: [], treeItems: [] }],
		},
	]));

	await expect.poll(() => sidebarBackground(page)).not.toBe(workBackground);
	await expect.poll(() => reportedBackground(page)).toBe(await sidebarBackground(page));
});
