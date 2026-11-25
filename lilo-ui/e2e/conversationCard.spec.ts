// A conversation started from the Ask bar shows as a mini card over the page it was asked from: the
// thread fills the card, expands to its own tab, and Esc closes the card.
import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import { tab, treeItem } from "../src/stores/testFixtures";

function receive(page: Page, messages: Record<string, unknown>[]) {
	return page.evaluate((list) => {
		for (const message of list) window.__lilo!.receive(message as never);
	}, messages);
}

async function openCard(page: Page) {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1].push(tab("tab-agent", SPACE_1, { title: "Summarize this page", url: "", kind: "agent", agentId: "codex-acp" } as never));
	world.treeItemsBySpace[SPACE_1].push(treeItem("tab-agent", SPACE_1, 9));
	await bootChrome(page, world);
	await receive(page, [
		{ event: "settingsLoaded", settings: { agentsEnabled: "true" } },
		{ event: "agentCatalog", agents: [{ id: "codex-acp", name: "Codex", description: "" }], projects: [], home: "/Users/example" },
		{ event: "openConversationCard", tabId: "tab-agent", sourceTabId: "tab-alpha" },
		{
			event: "conversationOpened",
			tabId: "tab-agent",
			agentId: "codex-acp",
			cwd: "/Users/example/Code/acme",
			state: "idle",
			checkpoints: [],
			updates: [
				{ sessionUpdate: "lilo_user", text: "Summarize this page" },
				{ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "The page describes the Acme release." } },
				{ sessionUpdate: "lilo_turn_end", stopReason: "end_turn" },
			],
		},
	]);
	const card = page.locator(".conversation-card");
	await expect(card).toBeVisible();
	await card.evaluate((node) => Promise.all(node.getAnimations({ subtree: true }).map((animation) => animation.finished.catch(() => {}))));
	return card;
}

test("the thread fills the card at the bottom center of the page", async ({ page }) => {
	const card = await openCard(page);
	await expect(card).toContainText("The page describes the Acme release.");
	const box = (await card.boundingBox())!;
	const root = (await page.locator(".conversation-card-root").boundingBox())!;
	expect(box.width).toBeCloseTo(Math.min(700, root.width - 32), 0);
	expect(box.x + box.width / 2).toBeCloseTo(root.x + root.width / 2, 0);
	expect(box.y + box.height + 24).toBeCloseTo(root.y + root.height, 0);
	const thread = (await card.locator(".conversation").boundingBox())!;
	expect(thread).toEqual(box);
});

test("the expand button opens the conversation's tab and closes the card", async ({ page }) => {
	const card = await openCard(page);
	await card.getByRole("button", { name: "Open in a tab" }).click();
	await expect
		.poll(async () => (await sentCommands(page)).filter((command) => command.action === "switchTab").map((command) => command.payload.id))
		.toContain("tab-agent");
	await expect(card).toHaveCount(0);
});

test("Esc closes the card", async ({ page }) => {
	const card = await openCard(page);
	await card.getByRole("button", { name: "Close" }).focus();
	await page.keyboard.press("Escape");
	await expect(card).toHaveCount(0);
});
