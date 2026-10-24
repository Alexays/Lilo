// Echoing fake host: applies each mutating command to a minimal state model and pushes browserStateChanged back, as
// the Swift host does. Unhandled commands are recorded but not echoed.
import type { Page } from "@playwright/test";
import type {
	BridgeProfileSnapshot,
	BridgeSidebarTreeItemSnapshot,
	BridgeSpaceSnapshot,
	BridgeTabFolderSnapshot,
	BridgeTabSnapshot,
} from "../src/lib/bridge/protocol";

export interface FakeHostWorld {
	spaces: BridgeSpaceSnapshot[];
	activeSpaceId: string;
	activeTabBySpace: Record<string, string>;
	tabsBySpace: Record<string, BridgeTabSnapshot[]>;
	treeItemsBySpace: Record<string, BridgeSidebarTreeItemSnapshot[]>;
	foldersBySpace?: Record<string, BridgeTabFolderSnapshot[]>;
	profiles?: BridgeProfileSnapshot[];
	activeProfileId?: string;
	sidebarWidth?: number;
	// The native bindings' keys by action id, as the host sends them after the initial state.
	shortcutKeys?: Record<string, string>;
}

interface SentCommand {
	action: string;
	payload: Record<string, unknown>;
}

declare global {
	interface Window {
		__sentCommands?: SentCommand[];
	}
}

export async function installFakeHost(
	page: Page,
	world: FakeHostWorld,
): Promise<void> {
	await page.addInitScript((seed: FakeHostWorld) => {
		const state = structuredClone(seed);
		const sent: SentCommand[] = [];
		window.__sentCommands = sent;
		const closedStack: Array<{
			spaceId: string;
			tab: BridgeTabSnapshot;
			item: BridgeSidebarTreeItemSnapshot;
		}> = [];

		const tabsOf = (spaceId: string): BridgeTabSnapshot[] =>
			(state.tabsBySpace[spaceId] ??= []);
		const itemsOf = (spaceId: string): BridgeSidebarTreeItemSnapshot[] =>
			(state.treeItemsBySpace[spaceId] ??= []);

		const spaceState = (spaceId: string) => ({
			spaceId,
			activeTabId: state.activeTabBySpace[spaceId] ?? "",
			tabs: tabsOf(spaceId),
			folders: state.foldersBySpace?.[spaceId] ?? [],
			treeItems: itemsOf(spaceId),
		});

		// Async like the real host, so the echo never dispatches re-entrantly from postMessage.
		function echo(
			changedSpaceId: string,
			spaceIds: string[],
			transitionId?: string,
		): void {
			const event = {
				event: "browserStateChanged",
				changedSpaceId,
				activeTabId: state.activeTabBySpace[changedSpaceId] ?? "",
				...(transitionId ? { transitionId } : {}),
				states: spaceIds.map(spaceState),
			};
			setTimeout(() => window.__lilo?.receive(event), 0);
		}

		function findTabSpace(tabId: string): string | null {
			for (const [spaceId, tabs] of Object.entries(state.tabsBySpace)) {
				if (tabs.some((tab) => tab.id === tabId)) return spaceId;
			}
			return null;
		}

		// The Swift side owns the section flags: a drop that changes section flips them.
		function setTabSection(
			spaceId: string,
			tabId: string,
			section: "bookmarked" | "pinned" | "unpinned",
		): void {
			const tab = tabsOf(spaceId).find((candidate) => candidate.id === tabId);
			if (!tab) return;
			tab.isPinned = section === "pinned";
			tab.isBookmarked = section === "bookmarked";
		}

		function applySidebarInsert(payload: {
			kind: "tab" | "folder";
			id: string;
			section: "bookmarked" | "pinned" | "unpinned";
			parentFolderId: string | null;
			fallbackIndex: number;
			insertBeforeId?: string | null;
			insertAfterId?: string | null;
		}): void {
			const spaceId = state.activeSpaceId;
			const items = [...itemsOf(spaceId)].sort(
				(a, b) => a.sortOrder - b.sortOrder,
			);
			const draggedIndex = items.findIndex(
				(item) => item.itemId === payload.id,
			);
			if (draggedIndex < 0) return;
			const [dragged] = items.splice(draggedIndex, 1);
			dragged.section = payload.section;
			dragged.parentFolderId = payload.parentFolderId;

			// insertAfterId/insertBeforeId are sibling item ids from the drop projection; after
			// removing the dragged item they name adjacent positions, so either anchor works.
			let insertAt = -1;
			if (payload.insertAfterId) {
				const anchor = items.findIndex(
					(item) => item.itemId === payload.insertAfterId,
				);
				if (anchor >= 0) insertAt = anchor + 1;
			}
			if (insertAt < 0 && payload.insertBeforeId) {
				const anchor = items.findIndex(
					(item) => item.itemId === payload.insertBeforeId,
				);
				if (anchor >= 0) insertAt = anchor;
			}
			if (insertAt < 0) {
				const siblings = items.filter(
					(item) =>
						item.section === payload.section &&
						(item.parentFolderId ?? null) === payload.parentFolderId,
				);
				const anchor = siblings[Math.min(payload.fallbackIndex, siblings.length - 1)];
				insertAt = anchor
					? items.indexOf(anchor) +
						(payload.fallbackIndex >= siblings.length ? 1 : 0)
					: items.length;
			}
			items.splice(insertAt, 0, dragged);
			items.forEach((item, index) => {
				item.sortOrder = index;
			});
			state.treeItemsBySpace[spaceId] = items;
			if (payload.kind === "tab") {
				setTabSection(spaceId, payload.id, payload.section);
			}
			echo(spaceId, [spaceId]);
		}

		function closeTab(tabId: string): void {
			const spaceId = findTabSpace(tabId);
			if (!spaceId) return;
			const tabs = tabsOf(spaceId);
			const items = itemsOf(spaceId);
			const tab = tabs.find((candidate) => candidate.id === tabId);
			const item = items.find((candidate) => candidate.itemId === tabId);
			if (!tab || !item) return;
			state.tabsBySpace[spaceId] = tabs.filter((t) => t.id !== tabId);
			state.treeItemsBySpace[spaceId] = items.filter(
				(i) => i.itemId !== tabId,
			);
			closedStack.push({ spaceId, tab, item });
			if (state.activeTabBySpace[spaceId] === tabId) {
				const next =
					state.tabsBySpace[spaceId].find(
						(t) => !t.isPinned && !t.isBookmarked && !t.isClosed,
					) ?? state.tabsBySpace[spaceId][0];
				state.activeTabBySpace[spaceId] = next?.id ?? "";
			}
			echo(spaceId, [spaceId]);
		}

		function restoreClosedTab(): void {
			const entry = closedStack.pop();
			if (!entry) return;
			tabsOf(entry.spaceId).push(entry.tab);
			const items = itemsOf(entry.spaceId);
			entry.item.sortOrder = Math.max(...items.map((i) => i.sortOrder), 0) + 1;
			items.push(entry.item);
			state.activeTabBySpace[entry.spaceId] = entry.tab.id;
			echo(entry.spaceId, [entry.spaceId]);
		}

		function moveTabToSpace(tabId: string, targetSpaceId: string): void {
			const sourceSpaceId = findTabSpace(tabId);
			if (!sourceSpaceId || sourceSpaceId === targetSpaceId) return;
			const tab = tabsOf(sourceSpaceId).find((t) => t.id === tabId);
			const item = itemsOf(sourceSpaceId).find((i) => i.itemId === tabId);
			if (!tab || !item) return;
			state.tabsBySpace[sourceSpaceId] = tabsOf(sourceSpaceId).filter(
				(t) => t.id !== tabId,
			);
			state.treeItemsBySpace[sourceSpaceId] = itemsOf(sourceSpaceId).filter(
				(i) => i.itemId !== tabId,
			);
			if (state.activeTabBySpace[sourceSpaceId] === tabId) {
				state.activeTabBySpace[sourceSpaceId] =
					state.tabsBySpace[sourceSpaceId][0]?.id ?? "";
			}
			tab.spaceId = targetSpaceId;
			tabsOf(targetSpaceId).push(tab);
			const targetItems = itemsOf(targetSpaceId);
			targetItems.push({
				...item,
				id: `${targetSpaceId}-${tabId}-unpinned`,
				spaceId: targetSpaceId,
				section: "unpinned",
				parentFolderId: null,
				sortOrder: Math.max(...targetItems.map((i) => i.sortOrder), 0) + 1,
			});
			echo(sourceSpaceId, [sourceSpaceId, targetSpaceId]);
		}

		function handle(message: SentCommand): void {
			sent.push(message);
			const payload = (message.payload ?? {}) as {
				type?: string;
				id?: string;
				tabId?: string;
				spaceId?: string;
				transitionId?: string;
			};
			const id = payload.id ?? "";
			switch (message.action) {
				case "commitSidebarDrop":
					if (payload.type === "insert") {
						applySidebarInsert(
							message.payload as Parameters<typeof applySidebarInsert>[0],
						);
					}
					break;
				case "switchSpace":
					state.activeSpaceId = id;
					echo(id, [id], payload.transitionId);
					break;
				case "switchTab": {
					const spaceId = findTabSpace(id);
					if (spaceId) {
						state.activeTabBySpace[spaceId] = id;
						echo(spaceId, [spaceId]);
					}
					break;
				}
				case "closeTab":
					closeTab(id);
					break;
				case "restoreClosedTab":
					restoreClosedTab();
					break;
				// Removing a closed pinned tab, as the host does: it can be undone.
				case "unpinTab": {
					const spaceId = findTabSpace(id);
					const removed = spaceId ? tabsOf(spaceId).find((t) => t.id === id) : undefined;
					if (removed?.isClosed && removed.isPinned) {
						closeTab(id);
						setTimeout(() => window.__lilo?.receive({ event: "tabClosedUndoable", title: removed.customTitle || removed.title }), 0);
					}
					break;
				}
				case "renameTab": {
					const spaceId = findTabSpace(id);
					const renamed = spaceId ? tabsOf(spaceId).find((t) => t.id === id) : undefined;
					if (spaceId && renamed) {
						renamed.customTitle = ((message.payload as { title: string }).title ?? "").trim();
						echo(spaceId, [spaceId]);
					}
					break;
				}
				case "moveTabToSpace":
					moveTabToSpace(payload.tabId ?? "", payload.spaceId ?? "");
					break;
				case "setTabFolderCollapsed": {
					const folder = state.foldersBySpace?.[state.activeSpaceId]?.find((f) => f.id === id);
					if (folder) {
						folder.isCollapsed = (message.payload as { collapsed: boolean }).collapsed;
						echo(state.activeSpaceId, [state.activeSpaceId]);
					}
					break;
				}
			}
		}

		window.webkit = {
			messageHandlers: {
				lilo: { postMessage: handle },
			},
		};
		window.__liloBootstrapEvents = [
			{
				event: "initialState",
				tabs: tabsOf(state.activeSpaceId),
				treeItems: itemsOf(state.activeSpaceId),
				folders: state.foldersBySpace?.[state.activeSpaceId] ?? [],
				activeTabId: state.activeTabBySpace[state.activeSpaceId] ?? "",
				sidebarWidth: state.sidebarWidth ?? 260,
				sidebarVisible: true,
				spaces: state.spaces,
				profiles: state.profiles,
				activeProfileId: state.activeProfileId,
				activeSpaceId: state.activeSpaceId,
			},
			{ event: "shortcutKeys", keys: state.shortcutKeys ?? {} },
		];
	}, world);
}

export async function bootChrome(
	page: Page,
	world: FakeHostWorld,
): Promise<void> {
	await installFakeHost(page, world);
	await page.goto("/");
	await page.waitForSelector(".tab-list [data-tab-id]");
	// The overlays' chunk loads after the first frame; the dev server compiles it on first request, seconds
	// under load: a test opening the command bar or settings would spend its assertion's 5 s on that.
	await page.waitForSelector(".banner-host", { state: "attached" });
}

export function sentCommands(page: Page): Promise<SentCommand[]> {
	return page.evaluate(() => window.__sentCommands ?? []);
}

/**
 * Drive a real pointer drag: cross the 4px start threshold, then step to the target so the
 * engine resolves a drop zone (it needs several frames of movement, not one jump).
 */
export async function dragFromTo(
	page: Page,
	from: { x: number; y: number },
	to: { x: number; y: number },
): Promise<void> {
	await page.mouse.move(from.x, from.y);
	await page.mouse.down();
	await page.mouse.move(from.x + 6, from.y + 6);
	const steps = 14;
	for (let i = 1; i <= steps; i++) {
		await page.mouse.move(
			from.x + ((to.x - from.x) * i) / steps,
			from.y + ((to.y - from.y) * i) / steps,
		);
		await page.waitForTimeout(18);
	}
	// A couple of settle frames so frame-coalesced hit tests see the final position.
	await page.waitForTimeout(60);
	await page.mouse.up();
}

export async function centerOf(
	page: Page,
	selector: string,
): Promise<{ x: number; y: number }> {
	const box = await page.locator(selector).boundingBox();
	if (!box) throw new Error(`No bounding box for ${selector}`);
	return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
}

// Live-layout drags, the way a user follows the placeholder: starting a drag reveals the empty
// drop zones and every move reprojects the list, so each step re-reads its target box.
export async function pressAndLift(page: Page, selector: string): Promise<void> {
	const from = await centerOf(page, selector);
	await page.mouse.move(from.x, from.y);
	await page.mouse.down();
	await page.mouse.move(from.x + 6, from.y + 6);
	await page.waitForTimeout(40);
}

export async function glideTo(
	page: Page,
	selector: string,
	offsetFromTop?: number,
): Promise<void> {
	const box = await page.locator(selector).first().boundingBox();
	if (!box) throw new Error(`No bounding box for ${selector}`);
	const x = box.x + box.width / 2;
	const y = box.y + (offsetFromTop ?? box.height / 2);
	for (let i = 0; i < 4; i++) {
		await page.mouse.move(x, y + (i % 2 === 0 ? 1 : -1));
		await page.waitForTimeout(30);
	}
	await page.waitForTimeout(60);
}

/** A point over nothing a click focuses, outside `exclude`: where a press leaves focus on the body. */
export function blankPoint(page: Page, exclude: string): Promise<{ x: number; y: number }> {
	return page.evaluate((exclude) => {
		for (let y = 10; y < innerHeight; y += 20) {
			for (let x = 10; x < innerWidth; x += 20) {
				const el = document.elementFromPoint(x, y);
				if (el && !el.closest(`button, a[href], input, select, textarea, [tabindex], [contenteditable], ${exclude}`)) return { x, y };
			}
		}
		throw new Error("no blank point");
	}, exclude);
}
