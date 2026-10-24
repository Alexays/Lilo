import assert from "node:assert/strict";
import test from "node:test";

type PostedMessage = {
	action: string;
	payload?: Record<string, unknown>;
};

const postedMessages: PostedMessage[] = [];

function installBridgeWindow() {
	(globalThis as { window?: unknown }).window = {
		__liloBootstrapEvents: [],
		webkit: {
			messageHandlers: {
				lilo: {
					postMessage(message: PostedMessage) {
						postedMessages.push(message);
					},
				},
			},
		},
	};
}

test("folderActions.update forwards updateTabFolder", async () => {
	postedMessages.length = 0;
	installBridgeWindow();

	const { folderActions } = await import("./bridge/actions");

	folderActions.update({
		id: "folder-1",
		name: "Renamed",
		color: "#92a8ff",
	});

	assert.deepEqual(postedMessages.at(-1), {
		action: "updateTabFolder",
		payload: { id: "folder-1", name: "Renamed", color: "#92a8ff" },
	});
});

test("folderActions.showContextMenu forwards showFolderContextMenu", async () => {
	postedMessages.length = 0;
	installBridgeWindow();

	const { folderActions } = await import("./bridge/actions");

	folderActions.showContextMenu("folder-1", 10, 20, 30, 40);

	assert.deepEqual(postedMessages.at(-1), {
		action: "showFolderContextMenu",
		payload: { id: "folder-1", x: 10, y: 20, width: 30, height: 40 },
	});
});

test("chromeActions.showSidebarContextMenu forwards native sidebar menu request", async () => {
	postedMessages.length = 0;
	installBridgeWindow();

	const { chromeActions } = await import("./bridge/actions");

	chromeActions.showSidebarContextMenu({ x: 10, y: 20, width: 1, height: 1, spaceId: "space-1" });

	assert.deepEqual(postedMessages.at(-1), {
		action: "showSidebarContextMenu",
		payload: { x: 10, y: 20, width: 1, height: 1, spaceId: "space-1" },
	});
});

test("tabActions.restoreClosed forwards restoreClosedTab", async () => {
	postedMessages.length = 0;
	installBridgeWindow();

	const { tabActions } = await import("./bridge/actions");

	tabActions.restoreClosed();

	assert.deepEqual(postedMessages.at(-1), {
		action: "restoreClosedTab",
		payload: {},
	});
});

test("coerceTabFolderSnapshot keeps folder identity and presentation fields only", async () => {
	const { coerceTabFolderSnapshot } = await import("./bridge/coerce");

	const folder = coerceTabFolderSnapshot({
		id: "folder-1",
		spaceId: "space-1",
		name: "Folder",
		color: "#92a8ff",
	});

	assert.deepEqual(folder, {
		id: "folder-1",
		spaceId: "space-1",
		name: "Folder",
		color: "#92a8ff",
		isCollapsed: false,
		isSplit: false,
		isLocked: false,
		lock: null,
	});
});

test("sidebarActions.commitDrop forwards commitSidebarDrop", async () => {
	postedMessages.length = 0;
	installBridgeWindow();

	const { sidebarActions } = await import("./bridge/actions");

	sidebarActions.commitDrop({
		type: "insert",
		kind: "tab",
		id: "tab-1",
		section: "bookmarked",
		parentFolderId: null,
		fallbackIndex: 0,
		insertBeforeId: "tab-2",
	});

	assert.deepEqual(postedMessages.at(-1), {
		action: "commitSidebarDrop",
		payload: {
			type: "insert",
			kind: "tab",
			id: "tab-1",
			section: "bookmarked",
			parentFolderId: null,
			fallbackIndex: 0,
			insertBeforeId: "tab-2",
		},
	});
});

test("tabActions.openPasswordsApp posts an empty payload", async () => {
	postedMessages.length = 0;
	installBridgeWindow();

	const { tabActions } = await import("./bridge/actions");
	tabActions.openPasswordsApp();

	assert.deepEqual(
		postedMessages.map((m) => [m.action, m.payload]),
		[
			["openPasswordsApp", {}],
		],
	);
});
