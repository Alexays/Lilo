// Seed world for the fake host. Reuses the builders from src/stores/testFixtures.ts
// so the shapes stay aligned with the unit-test fixtures.
import { tab, treeItem } from "../src/stores/testFixtures";
import type { FakeHostWorld } from "./fakeHost";

export const SPACE_1 = "space-1";
export const SPACE_2 = "space-2";

// The keys of Lilo's default bindings the chrome names, as KeyboardShortcuts.displayedKeys spells them.
export const LILO_SHORTCUT_KEYS: Record<string, string> = {
	"tab.new": "⌘T",
	"tab.close": "⌘W",
	"app.settings": "⌘,",
	"space.newPrivate": "⇧⌘N",
	"sidebar.toggle": "⇧⌘S",
	"page.save": "⌘S",
	"page.reload": "⌘R",
	"page.stop": "⌘.",
	"history.back": "⌘[",
	"history.forward": "⌘]",
	"zoom.in": "⌘+",
	"zoom.out": "⌘-",
	"zoom.reset": "⌘0",
	"page.viewSource": "⌥⌘U",
	"tab.reopenClosed": "⇧⌘T",
	"tab.clearUnpinned": "⇧⌘K",
	"tab.mute": "⇧⌘M",
	"page.copyURL": "⇧⌘C",
	"find.show": "⌘F",
	"terminal.newTab": "⌃`",
	"terminal.nextWaiting": "⌃⌘J",
	"terminal.showChanges": "⌃⌘G",
	"downloads.show": "⌥⌘L",
	...Object.fromEntries(Array.from({ length: 9 }, (_, index) => [`space.select${index + 1}`, `⌃${index + 1}`])),
};

// Space 1: 3 unpinned (alpha, beta, gamma), 1 pinned (home), 1 bookmarked (wiki).
// Space 2: 1 unpinned (zeta). Active: space-1 / tab-alpha.
export function initialWorld(): FakeHostWorld {
	return {
		spaces: [
			{
				id: SPACE_1,
				name: "Work",
				icon: "W",
				color: "#4a90d9",
				profileId: "profile-1",
				isPrivate: false,
				sortOrder: 0,
			},
			{
				id: SPACE_2,
				name: "Play",
				icon: "P",
				color: "#d94a6a",
				profileId: "profile-1",
				isPrivate: false,
				sortOrder: 1,
			},
		],
		activeSpaceId: SPACE_1,
		shortcutKeys: LILO_SHORTCUT_KEYS,
		activeTabBySpace: { [SPACE_1]: "tab-alpha", [SPACE_2]: "tab-zeta" },
		tabsBySpace: {
			[SPACE_1]: [
				tab("tab-alpha", SPACE_1, { title: "Alpha Docs" }),
				tab("tab-beta", SPACE_1, { title: "Beta Mail" }),
				tab("tab-gamma", SPACE_1, { title: "Gamma News" }),
				tab("tab-home", SPACE_1, { title: "Pinned Home", isPinned: true }),
				tab("tab-wiki", SPACE_1, { title: "Marked Wiki", isBookmarked: true }),
			],
			[SPACE_2]: [tab("tab-zeta", SPACE_2, { title: "Zeta Chat" })],
		},
		treeItemsBySpace: {
			[SPACE_1]: [
				treeItem("tab-wiki", SPACE_1, 0, "bookmarked"),
				treeItem("tab-home", SPACE_1, 1, "pinned"),
				treeItem("tab-alpha", SPACE_1, 2),
				treeItem("tab-beta", SPACE_1, 3),
				treeItem("tab-gamma", SPACE_1, 4),
			],
			[SPACE_2]: [treeItem("tab-zeta", SPACE_2, 0)],
		},
	};
}

function folderSnapshot(id: string, name: string, isCollapsed = false, color = "#4a90d9") {
	return { id, spaceId: SPACE_1, name, color, isCollapsed };
}

// Space 1 with three levels: Projects > Clients > Acme > tab-alpha, tab-beta beside Clients,
// then tab-gamma and a collapsed empty Archive at the root. Sort orders follow the tree.
export function nestedFolderWorld(): FakeHostWorld {
	const world = initialWorld();
	world.foldersBySpace = {
		[SPACE_1]: [
			folderSnapshot("folder-projects", "Projects", false, "#4a90d9"),
			folderSnapshot("folder-clients", "Clients", false, "#2fa36b"),
			folderSnapshot("folder-acme", "Acme", false, "#d97a2b"),
			folderSnapshot("folder-archive", "Archive", true, "#8a63d2"),
		],
	};
	world.treeItemsBySpace[SPACE_1] = [
		treeItem("tab-wiki", SPACE_1, 0, "bookmarked"),
		treeItem("tab-home", SPACE_1, 1, "pinned"),
		treeItem("folder-projects", SPACE_1, 2, "unpinned", "folder"),
		treeItem("folder-clients", SPACE_1, 3, "unpinned", "folder", "folder-projects"),
		treeItem("folder-acme", SPACE_1, 4, "unpinned", "folder", "folder-clients"),
		treeItem("tab-alpha", SPACE_1, 5, "unpinned", "tab", "folder-acme"),
		treeItem("tab-beta", SPACE_1, 6, "unpinned", "tab", "folder-projects"),
		treeItem("tab-gamma", SPACE_1, 7),
		treeItem("folder-archive", SPACE_1, 8, "unpinned", "folder"),
	];
	return world;
}

// Five open folders each inside the previous one, the deepest holding tab-alpha, then
// tab-beta, tab-gamma and a collapsed empty folder at the root. Long names to test ellipsis.
export function deepFolderWorld(): FakeHostWorld {
	const world = initialWorld();
	const levels = [1, 2, 3, 4, 5].map((level) =>
		folderSnapshot(`folder-level-${level}`, `Level ${level} folder with a name far too long to fit`),
	);
	world.foldersBySpace = { [SPACE_1]: [...levels, folderSnapshot("folder-loose", "Loose", true)] };
	world.tabsBySpace[SPACE_1] = world.tabsBySpace[SPACE_1].map((tab) =>
		tab.id === "tab-alpha" ? { ...tab, title: "A deeply nested tab whose title is much too long" } : tab,
	);
	world.treeItemsBySpace[SPACE_1] = [
		treeItem("tab-wiki", SPACE_1, 0, "bookmarked"),
		treeItem("tab-home", SPACE_1, 1, "pinned"),
		...levels.map((folder, index) =>
			treeItem(folder.id, SPACE_1, 2 + index, "unpinned", "folder", index === 0 ? null : levels[index - 1].id),
		),
		treeItem("tab-alpha", SPACE_1, 7, "unpinned", "tab", "folder-level-5"),
		treeItem("tab-beta", SPACE_1, 8),
		treeItem("tab-gamma", SPACE_1, 9),
		treeItem("folder-loose", SPACE_1, 10, "unpinned", "folder"),
	];
	return world;
}

// Space 1 with folders around the plain rows: an expanded one holding tab-alpha, an
// expanded empty one and a collapsed empty one.
export function folderWorld(): FakeHostWorld {
	const world = initialWorld();
	const folder = (id: string, name: string, isCollapsed: boolean) => ({
		id,
		spaceId: SPACE_1,
		name,
		color: "#4a90d9",
		isCollapsed,
	});
	world.foldersBySpace = {
		[SPACE_1]: [
			folder("folder-docs", "Docs", false),
			folder("folder-empty", "Empty", false),
			folder("folder-shut", "Shut", true),
		],
	};
	world.treeItemsBySpace[SPACE_1] = [
		treeItem("tab-wiki", SPACE_1, 0, "bookmarked"),
		treeItem("tab-home", SPACE_1, 1, "pinned"),
		treeItem("folder-docs", SPACE_1, 2, "unpinned", "folder"),
		treeItem("tab-alpha", SPACE_1, 3, "unpinned", "tab", "folder-docs"),
		treeItem("tab-beta", SPACE_1, 4),
		treeItem("tab-gamma", SPACE_1, 5),
		treeItem("folder-empty", SPACE_1, 6, "unpinned", "folder"),
		treeItem("folder-shut", SPACE_1, 7, "unpinned", "folder"),
	];
	return world;
}
