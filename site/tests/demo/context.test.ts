import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import type {
  BridgeSidebarTreeItemSnapshot,
  BridgeTabFolderSnapshot,
} from "../../../lilo-ui/src/lib/bridge/protocol";
import {
  buildContextMenu,
  contextFolderTargets,
  folderTabCount,
} from "../../src/demo/context-menu.ts";
import type {
  ContextMenuEntry,
  ContextMenuItem,
} from "../../src/demo/context-menu.ts";
import { createDemoHost } from "../../src/demo/host.ts";

const english = (key: string) => key;

const items = (entries: ContextMenuEntry[]): ContextMenuItem[] =>
  entries.filter((entry) => entry.kind === "item");

const find = (entries: ContextMenuEntry[], key: string) => {
  const entry = items(entries).find((candidate) => candidate.key === key);
  assert.ok(entry, `Missing menu item: ${key}`);

  return entry;
};

const folder = (
  id: string,
  extra: Partial<BridgeTabFolderSnapshot> = {}
): BridgeTabFolderSnapshot => ({
  color: "#7868d8",
  id,
  isCollapsed: false,
  name: id,
  spaceId: "home",
  ...extra,
});

const treeItem = (
  id: string,
  sortOrder: number,
  parentFolderId: string | null = null,
  extra: Partial<BridgeSidebarTreeItemSnapshot> = {}
): BridgeSidebarTreeItemSnapshot => ({
  id: `item-${id}`,
  itemId: id,
  kind: "folder",
  parentFolderId,
  section: "unpinned",
  sortOrder,
  spaceId: "home",
  ...extra,
});

test("folder destinations follow sidebar order and never reveal locked or split subtrees", () => {
  const folders = [
    folder("later"),
    folder("pinned"),
    folder("nested"),
    folder("locked", { isLocked: true }),
    folder("hidden"),
    folder("split", { isSplit: true }),
    folder("split-child"),
    folder("other-space", { spaceId: "work" }),
  ];

  const tree = [
    treeItem("later", 3),
    treeItem("hidden", 0, "locked"),
    treeItem("pinned", 9, null, { section: "pinned" }),
    treeItem("nested", 0, "pinned", { section: "pinned" }),
    treeItem("locked", 0),
    treeItem("split", 1),
    treeItem("split-child", 0, "split"),
    treeItem("other-space", 0, null, { spaceId: "work" }),
  ];

  assert.deepEqual(
    contextFolderTargets(tree, folders, "home").map(
      ({ folder: target, depth }) => [target.id, depth]
    ),
    [
      ["pinned", 0],
      ["nested", 1],
      ["later", 0],
    ]
  );
});

test("tab destinations carry the native pinned section and Remove from Folder goes beside its parent", () => {
  const snapshot = createDemoHost("en").snapshot();
  snapshot.menu = { id: "travel", kind: "tab", x: 0, y: 0 };
  const menu = buildContextMenu(snapshot, english);
  const destinations = find(menu, "moveToFolder").children ?? [];
  const current = find(destinations, "folder-trips");
  assert.equal(current.checked, true);
  assert.equal(current.disabled, true);
  assert.deepEqual(current.action, {
    command: {
      name: "commitSidebarDrop",
      payload: {
        fallbackIndex: Number.MAX_SAFE_INTEGER,
        id: "travel",
        kind: "tab",
        parentFolderId: "trips",
        section: "pinned",
        type: "insert",
      },
    },
    type: "command",
  });
  assert.deepEqual(find(destinations, "removeFromFolder").action, {
    command: {
      name: "commitSidebarDrop",
      payload: {
        fallbackIndex: Number.MAX_SAFE_INTEGER,
        id: "travel",
        insertAfterId: "trips",
        kind: "tab",
        parentFolderId: null,
        section: "pinned",
        type: "insert",
      },
    },
    type: "command",
  });
});

test("saved, closed, active and terminal tabs expose only their native actions", () => {
  const snapshot = createDemoHost("en").snapshot();
  snapshot.menu = { id: "notes", kind: "tab", x: 0, y: 0 };
  assert.ok(
    items(buildContextMenu(snapshot, english)).some(
      (entry) => entry.key === "split"
    )
  );
  snapshot.activeTabId = "notes";
  assert.equal(
    items(buildContextMenu(snapshot, english)).some(
      (entry) => entry.key === "split"
    ),
    false
  );
  const tab = snapshot.tabs.find((candidate) => candidate.id === "notes");
  assert.ok(tab);
  Object.assign(tab, { isBookmarked: true, isClosed: true });
  const closed = buildContextMenu(snapshot, english);
  assert.equal(items(closed)[0].label, "Edit...");
  assert.equal(find(closed, "bookmark").label, "Unbookmark Tab");
  assert.equal(find(closed, "close").label, "Remove Bookmark");
  assert.equal(
    items(closed).some((entry) =>
      [
        "createFolder",
        "moveToFolder",
        "moveToSpace",
        "split",
        "newWindow",
      ].includes(entry.key)
    ),
    false
  );
  Object.assign(tab, {
    isBookmarked: false,
    isClosed: false,
    kind: "terminal",
    url: "",
  });
  const terminal = buildContextMenu(snapshot, english);
  assert.equal(find(terminal, "duplicate").disabled, true);
  assert.equal(
    items(terminal).some((entry) => entry.key === "mute"),
    false
  );
  assert.equal(find(terminal, "newWindow").macOnly, true);
  assert.equal(find(terminal, "newWindow").disabled, true);
});

test("locked folders and their descendants offer only authentication, and unlocked locks offer password actions", () => {
  const snapshot = createDemoHost("en").snapshot();
  const [trips] = snapshot.folders;
  trips.isLocked = true;
  trips.lock = { allowsBiometrics: false, biometricsAvailable: false };
  snapshot.menu = { id: "trips", kind: "folder", x: 0, y: 0 };
  assert.deepEqual(
    items(buildContextMenu(snapshot, english)).map((entry) => entry.key),
    ["unlock"]
  );
  snapshot.menu = { id: "travel", kind: "tab", x: 0, y: 0 };
  assert.deepEqual(find(buildContextMenu(snapshot, english), "unlock").action, {
    event: { name: "beginFolderUnlock", payload: { id: "trips" } },
    type: "event",
  });
  trips.isLocked = false;
  snapshot.menu = { id: "trips", kind: "folder", x: 0, y: 0 };
  const unlocked = items(buildContextMenu(snapshot, english));
  assert.ok(unlocked.some((entry) => entry.key === "changePassword"));
  assert.ok(unlocked.some((entry) => entry.key === "removeLock"));
  assert.equal(
    unlocked.some((entry) => entry.key === "lock"),
    false
  );
});

test("split menus only arrange or separate, and folder creation stops at the native depth limit", () => {
  const snapshot = createDemoHost("en").snapshot();
  snapshot.folders = Array.from({ length: 5 }, (_, index) =>
    folder(`level-${index + 1}`)
  );
  snapshot.treeItems = snapshot.folders.map((entry, index) =>
    treeItem(entry.id, 0, index ? `level-${index}` : null)
  );
  snapshot.menu = { id: "level-5", kind: "folder", x: 0, y: 0 };
  assert.equal(
    items(buildContextMenu(snapshot, english)).some(
      (entry) => entry.key === "newFolder"
    ),
    false
  );
  snapshot.menu.id = "level-4";
  assert.ok(
    items(buildContextMenu(snapshot, english)).some(
      (entry) => entry.key === "newFolder"
    )
  );
  snapshot.folders[3].isSplit = true;
  snapshot.splitArrangement = "vertical";
  assert.deepEqual(
    items(buildContextMenu(snapshot, english)).map((entry) => entry.label),
    ["Arrange Side by Side", "Separate Split View"]
  );
});

test("folder deletion counts all nested tabs while sidebar menus target the requested Space", () => {
  const snapshot = createDemoHost("en").snapshot();
  snapshot.folders.push(folder("inner", { isLocked: true }));
  snapshot.treeItems.push(treeItem("inner", 0, "trips"));

  const notesItem = snapshot.treeItems.find(
    (entry) => entry.itemId === "notes"
  );

  assert.ok(notesItem);
  notesItem.parentFolderId = "inner";
  assert.equal(folderTabCount(snapshot, "trips"), 2);
  snapshot.menu = { id: "", kind: "sidebar", spaceId: "work", x: 0, y: 0 };
  snapshot.settings.terminalEnabled = "false";
  const sidebar = buildContextMenu(snapshot, english);
  assert.deepEqual(find(sidebar, "newTab").action, {
    kind: "tab",
    spaceId: "work",
    type: "newItem",
  });
  assert.deepEqual(find(sidebar, "editSpace").action, {
    event: { name: "openSpaceEditor", payload: { id: "work" } },
    type: "event",
  });
  assert.equal(
    items(sidebar).some((entry) => entry.key === "newTerminal"),
    false
  );
  assert.equal(find(sidebar, "restore").disabled, true);
});

test("extension menus preserve context pinning and use the native French catalog", () => {
  const snapshot = createDemoHost("fr").snapshot();

  // SAFETY: the repository's native locale namespace maps source phrases to translated strings.
  const catalog = JSON.parse(
    readFileSync(
      new URL("../../../lilo-ui/src/lib/i18n/locales/fr.json", import.meta.url),
      "utf-8"
    )
  ).native as Record<string, string>;

  snapshot.menu = {
    id: snapshot.extensions[0].id,
    kind: "extension",
    pinned: true,
    x: 0,
    y: 0,
  };
  const menu = buildContextMenu(snapshot, (key) => catalog[key] ?? key);
  assert.deepEqual(
    items(menu).map((entry) => entry.label),
    [catalog["Unpin from Address Bar"], catalog.Details, catalog["Remove…"]]
  );
  assert.deepEqual(find(menu, "togglePin").action, {
    event: {
      name: "extensionMenuAction",
      payload: { action: "togglePin", id: snapshot.menu.id },
    },
    type: "event",
  });
  snapshot.menu.pinned = undefined;
  snapshot.menu.profileId = "profile-work";
  snapshot.extensions = [];
  assert.equal(
    items(buildContextMenu(snapshot, english)).some(
      (entry) => entry.key === "togglePin"
    ),
    false
  );
  assert.equal(
    find(buildContextMenu(snapshot, english), "details").label,
    "Details"
  );
});
