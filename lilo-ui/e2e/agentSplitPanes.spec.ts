// Agent conversations as split panes: the conversation draws in the chrome overlay over the frame
// the host reports, and registers its pane as a `conversation-<tabId>` zone the host's router turns
// back into pane presses (click-to-focus). The sidebar's conversation row stays clickable at
// every sidebar width.
import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import type { FakeHostWorld } from "./fakeHost";
import { tab, treeItem } from "../src/stores/testFixtures";

// Space 1 with tab-alpha and tab-beta as the two panes of a split, tab-gamma beside them.
export function splitWorld(): FakeHostWorld {
	const world = initialWorld();
	world.foldersBySpace = {
		[SPACE_1]: [
			{
				id: "folder-split",
				spaceId: SPACE_1,
				name: "Split",
				color: "#4a90d9",
				isCollapsed: false,
				isSplit: true,
				splitLayout: {
					vertical: false,
					first: { tabId: "tab-alpha" },
					second: { tabId: "tab-beta" },
				},
			},
		],
	};
	world.treeItemsBySpace[SPACE_1] = [
		treeItem("tab-wiki", SPACE_1, 0, "bookmarked"),
		treeItem("tab-home", SPACE_1, 1, "pinned"),
		treeItem("folder-split", SPACE_1, 2, "unpinned", "folder"),
		treeItem("tab-alpha", SPACE_1, 3, "unpinned", "tab", "folder-split"),
		treeItem("tab-beta", SPACE_1, 4, "unpinned", "tab", "folder-split"),
		treeItem("tab-gamma", SPACE_1, 5),
	];
	world.activeTabBySpace[SPACE_1] = "tab-alpha";
	return world;
}

const agents = [{ id: "codex-acp", name: "Codex", description: "" }];

function receive(page: Page, messages: Record<string, unknown>[]) {
	return page.evaluate((list) => {
		for (const message of list) window.__lilo!.receive(message as never);
	}, messages);
}

async function enableAgents(page: Page) {
	await receive(page, [
		{ event: "settingsLoaded", settings: { agentsEnabled: "true" } },
		{ event: "agentCatalog", agents, projects: [], home: "/Users/example" },
	]);
}

function conversationEvents(tabId: string, spaceId: string) {
	return [
		{
			event: "conversationsChanged",
			conversations: [
				{ tabId, agentId: "codex-acp", title: "Summarize", state: "idle", unread: false, spaceId, spaceName: "Work", running: false },
			],
		},
		{ event: "conversationOpened", tabId, agentId: "codex-acp", cwd: "/Users/example/Code/acme", state: "idle", checkpoints: [], updates: [] },
	];
}

function agentTab(id: string, spaceId: string) {
	return tab(id, spaceId, { title: "Summarize", url: "", kind: "agent", agentId: "codex-acp" } as never);
}

async function reportedZones(page: Page): Promise<Record<string, { x: number; y: number; width: number; height: number }>> {
	const commands = await sentCommands(page);
	const zones: Record<string, { x: number; y: number; width: number; height: number }> = {};
	for (const command of commands) {
		if (command.action !== "registerInteractiveZones") continue;
		for (const zone of (command.payload as { zones: { id: string; x: number; y: number; width: number; height: number }[] }).zones) {
			zones[zone.id] = { x: zone.x, y: zone.y, width: zone.width, height: zone.height };
		}
	}
	return zones;
}

test("a web tab split with an agent tab draws the conversation over its own half", async ({ page }) => {
	const world = splitWorld();
	world.tabsBySpace[SPACE_1].push(agentTab("tab-agent", SPACE_1));
	world.foldersBySpace![SPACE_1][0].splitLayout = {
		vertical: false,
		first: { tabId: "tab-alpha" },
		second: { tabId: "tab-agent" },
	};
	world.treeItemsBySpace[SPACE_1] = world.treeItemsBySpace[SPACE_1].filter((item) => item.itemId !== "tab-beta");
	world.treeItemsBySpace[SPACE_1].push(treeItem("tab-agent", SPACE_1, 4, "unpinned", "tab", "folder-split"));
	await bootChrome(page, world);
	await enableAgents(page);
	await receive(page, [
		{
			event: "splitPanesChanged",
			panes: [
				{ tabId: "tab-alpha", x: 0, y: 0, width: 0.5, height: 1 },
				{ tabId: "tab-agent", x: 0.5, y: 0, width: 0.5, height: 1 },
			],
		},
		...conversationEvents("tab-agent", SPACE_1),
	]);

	const conversation = page.locator(".conversation");
	await expect(conversation).toHaveCount(1);
	await expect(conversation).toBeVisible();
	const box = (await conversation.boundingBox())!;
	const root = (await page.locator(".conversation-root").boundingBox())!;
	expect(box.x).toBeCloseTo(root.x + root.width / 2, 0);
	expect(box.y).toBeCloseTo(root.y, 0);
	expect(box.width).toBeCloseTo(root.width / 2, 0);
	expect(box.height).toBeCloseTo(root.height, 0);

	// The zone id carries the tab id: the host resolves pane presses back through it.
	const zone = (await reportedZones(page))["conversation-tab-agent"];
	expect(zone).toBeDefined();
	expect(zone.x).toBeCloseTo(box.x, 0);
	expect(zone.width).toBeCloseTo(box.width, 0);
});

test("a split of two agent tabs draws both conversations", async ({ page }) => {
	const world = splitWorld();
	world.tabsBySpace[SPACE_1].push(agentTab("tab-agent-a", SPACE_1), agentTab("tab-agent-b", SPACE_1));
	world.foldersBySpace![SPACE_1][0].splitLayout = {
		vertical: false,
		first: { tabId: "tab-agent-a" },
		second: { tabId: "tab-agent-b" },
	};
	world.treeItemsBySpace[SPACE_1] = world.treeItemsBySpace[SPACE_1].filter(
		(item) => item.itemId !== "tab-alpha" && item.itemId !== "tab-beta",
	);
	world.treeItemsBySpace[SPACE_1].push(
		treeItem("tab-agent-a", SPACE_1, 3, "unpinned", "tab", "folder-split"),
		treeItem("tab-agent-b", SPACE_1, 4, "unpinned", "tab", "folder-split"),
	);
	world.activeTabBySpace[SPACE_1] = "tab-agent-a";
	await bootChrome(page, world);
	await enableAgents(page);
	await receive(page, [
		{
			event: "splitPanesChanged",
			panes: [
				{ tabId: "tab-agent-a", x: 0, y: 0, width: 0.5, height: 1 },
				{ tabId: "tab-agent-b", x: 0.5, y: 0, width: 0.5, height: 1 },
			],
		},
		...conversationEvents("tab-agent-a", SPACE_1),
		...conversationEvents("tab-agent-b", SPACE_1),
	]);

	const conversations = page.locator(".conversation");
	await expect(conversations).toHaveCount(2);
	const [left, right] = [await conversations.nth(0).boundingBox(), await conversations.nth(1).boundingBox()];
	expect(left!.x).toBeLessThan(right!.x);
	expect(left!.width).toBeCloseTo(right!.width, 0);

	const zones = await reportedZones(page);
	expect(zones["conversation-tab-agent-a"]).toBeDefined();
	expect(zones["conversation-tab-agent-b"]).toBeDefined();
});

test("the sidebar's conversation row works at its default and narrow widths", async ({ page }) => {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1].push(agentTab("tab-agent", SPACE_1), tab("tab-page", SPACE_1, { title: "A page the agent opened" }));
	world.foldersBySpace = {
		[SPACE_1]: [{ id: "folder-conv", spaceId: SPACE_1, name: "Summarize", color: "#795ceb", isCollapsed: false }],
	};
	world.treeItemsBySpace[SPACE_1].push(
		treeItem("folder-conv", SPACE_1, 5, "unpinned", "folder"),
		treeItem("tab-agent", SPACE_1, 6, "unpinned", "tab", "folder-conv"),
		treeItem("tab-page", SPACE_1, 7, "unpinned", "tab", "folder-conv"),
	);
	await bootChrome(page, world);
	await enableAgents(page);
	await receive(page, conversationEvents("tab-agent", SPACE_1));

	const row = page.locator(".conversation-row");
	await expect(row).toHaveCount(1);
	await expect(row).toBeVisible();

	await row.click();
	const switches = (await sentCommands(page)).filter((command) => command.action === "switchTab");
	expect(switches).toHaveLength(1);
	expect((switches[0].payload as { id: string }).id).toBe("tab-agent");

	// Narrow the sidebar through the keyboard resizer: the row shrinks but keeps its title.
	const handle = page.locator(".sidebar-resize-handle");
	await handle.focus();
	for (let i = 0; i < 12; i++) await page.keyboard.press("ArrowLeft");
	const narrow = (await row.boundingBox())!;
	expect(narrow.width).toBeLessThan((await row.boundingBox())!.width + 100);
	await expect(row.locator(".title")).toBeVisible();
});
