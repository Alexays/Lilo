import type {
  BridgeCommandName,
  BridgeCommandPayloadMap,
  BridgeEventPayloadMap,
  BridgeSidebarTreeItemSnapshot,
  BridgeTabFolderSnapshot,
} from "../../../lilo-ui/src/lib/bridge/protocol";
import type { DemoSnapshot } from "./host.ts";

type ContextCommand = {
  [K in BridgeCommandName]: {
    name: K;
    payload: BridgeCommandPayloadMap[K];
  };
}[BridgeCommandName];

type ContextEventName =
  | "beginFolderUnlock"
  | "editTabFolder"
  | "openSpaceEditor"
  | "openAddSpaceEditor"
  | "extensionMenuAction";

type ContextEvent = {
  [K in ContextEventName]: {
    name: K;
    payload: BridgeEventPayloadMap[K];
  };
}[ContextEventName];

export type ContextAction =
  | { type: "command"; command: ContextCommand }
  | { type: "event"; event: ContextEvent }
  | { type: "editTab"; id: string }
  | {
      type: "host";
      method:
        | "createFolderFromTab"
        | "createSubfolder"
        | "closeOtherTabs"
        | "separateSplit"
        | "toggleSplitArrangement"
        | "toggleTabPinned"
        | "duplicateTab";
      id: string;
    }
  | { type: "newItem"; kind: "tab" | "terminal" | "folder"; spaceId: string }
  | { type: "delete"; kind: "folder" | "space"; id: string }
  | { type: "stopAgents" };

export interface ContextMenuItem {
  kind: "item";
  key: string;
  label: string;
  action?: ContextAction;
  children?: ContextMenuEntry[];
  disabled?: boolean;
  checked?: boolean;
  depth?: number;
  macOnly?: boolean;
}

export type ContextMenuEntry = ContextMenuItem | { kind: "separator" };

export type NativeCopy = (key: string, ...args: (string | number)[]) => string;

const separator: ContextMenuEntry = { kind: "separator" };

const command = <K extends BridgeCommandName>(
  name: K,
  payload: BridgeCommandPayloadMap[K]
): ContextAction => ({
  // SAFETY: K constrains the payload to the named protocol command.
  command: { name, payload } as ContextCommand,
  type: "command",
});

const event = <K extends ContextEventName>(
  name: K,
  payload: BridgeEventPayloadMap[K]
): ContextAction => ({
  // SAFETY: K constrains the payload to the named protocol event.
  event: { name, payload } as ContextEvent,
  type: "event",
});

const hostAction = (
  method: Extract<ContextAction, { type: "host" }>["method"],
  id: string
): ContextAction => ({ id, method, type: "host" });

const parentId = (snapshot: DemoSnapshot, id: string) =>
  snapshot.treeItems.find((item) => item.itemId === id)?.parentFolderId ?? null;

const lockedAncestor = (snapshot: DemoSnapshot, id: string) => {
  const visited = new Set<string>();
  let parent = parentId(snapshot, id);

  while (parent && !visited.has(parent)) {
    visited.add(parent);

    const currentId = parent;

    const folder = snapshot.folders.find(
      (candidate) => candidate.id === currentId
    );

    if (folder?.isLocked) {
      return folder;
    }

    parent = parentId(snapshot, parent);
  }
};

export const contextFolderTargets = (
  treeItems: BridgeSidebarTreeItemSnapshot[],
  folders: BridgeTabFolderSnapshot[],
  spaceId: string
) => {
  const result: {
    folder: BridgeTabFolderSnapshot;
    item: BridgeSidebarTreeItemSnapshot;
    depth: number;
  }[] = [];

  const visited = new Set<string>();

  const visit = (
    parent: string | null,
    section: "pinned" | "unpinned",
    depth: number
  ) => {
    const children = treeItems
      .filter(
        (item) =>
          item.spaceId === spaceId &&
          item.kind === "folder" &&
          (item.parentFolderId ?? null) === parent &&
          (parent !== null || item.section === section)
      )
      .toSorted((left, right) => left.sortOrder - right.sortOrder);

    for (const item of children) {
      const folder = folders.find((candidate) => candidate.id === item.itemId);

      if (
        !folder ||
        folder.isLocked ||
        folder.isSplit ||
        visited.has(folder.id)
      ) {
        continue;
      }

      visited.add(folder.id);
      result.push({ depth, folder, item });
      visit(folder.id, section, depth + 1);
    }
  };

  visit(null, "pinned", 0);
  visit(null, "unpinned", 0);

  return result;
};

export const folderTabCount = (snapshot: DemoSnapshot, id: string) => {
  const descendants = new Set([id]);
  let count = 0;

  for (const folderId of descendants) {
    for (const item of snapshot.treeItems) {
      if (item.parentFolderId !== folderId) {
        continue;
      }

      if (item.kind === "folder") {
        descendants.add(item.itemId);
      } else {
        count += 1;
      }
    }
  }

  return count;
};

export const buildContextMenu = (
  snapshot: DemoSnapshot,
  t: NativeCopy
): ContextMenuEntry[] => {
  const { menu } = snapshot;

  if (!menu) {
    return [];
  }

  const item = (
    key: string,
    label: string,
    action?: ContextAction,
    options: Partial<ContextMenuItem> = {}
  ): ContextMenuItem => ({
    action,
    key,
    kind: "item",
    label: t(label),
    ...options,
  });

  const unlock = (id: string) => [
    item("unlock", "Unlock Folder…", event("beginFolderUnlock", { id })),
  ];

  const tabMenu = () => {
    const tab = snapshot.tabs.find((candidate) => candidate.id === menu.id);

    if (!tab) {
      return [];
    }

    const locked = lockedAncestor(snapshot, tab.id);

    if (locked) {
      return unlock(locked.id);
    }

    const entries: ContextMenuEntry[] = [];
    const parent = parentId(snapshot, tab.id);

    const folder = snapshot.folders.find(
      (candidate) => candidate.id === parent
    );

    const isSplit = folder?.isSplit || snapshot.splitIds.includes(tab.id);

    const addFolderDestinations = () => {
      const targets = contextFolderTargets(
        snapshot.treeItems,
        snapshot.folders,
        tab.spaceId
      );

      const children: ContextMenuEntry[] = targets.map(
        ({ folder: target, item: treeItem, depth }) =>
          item(
            `folder-${target.id}`,
            target.name,
            command("commitSidebarDrop", {
              fallbackIndex: Number.MAX_SAFE_INTEGER,
              id: tab.id,
              kind: "tab",
              parentFolderId: target.id,
              section: treeItem.section === "pinned" ? "pinned" : "unpinned",
              type: "insert",
            }),
            {
              checked: target.id === parent,
              depth,
              disabled: target.id === parent,
              label: target.name,
            }
          )
      );

      const folderItem = snapshot.treeItems.find(
        (candidate) => candidate.itemId === parent
      );

      if (parent && folderItem) {
        if (children.length) {
          children.push(separator);
        }

        children.push(
          item(
            "removeFromFolder",
            "Remove from Folder",
            command("commitSidebarDrop", {
              fallbackIndex: Number.MAX_SAFE_INTEGER,
              id: tab.id,
              insertAfterId: parent,
              kind: "tab",
              parentFolderId: folderItem.parentFolderId ?? null,
              section: folderItem.section === "pinned" ? "pinned" : "unpinned",
              type: "insert",
            })
          )
        );
      }

      if (children.length) {
        entries.push(
          item("moveToFolder", "Move to Folder", undefined, { children })
        );
      }
    };

    const addOrganizationItems = () => {
      if (tab.isPinned || tab.isBookmarked) {
        entries.push(item("edit", "Edit...", { id: tab.id, type: "editTab" }));
      }

      if (!tab.isBookmarked) {
        entries.push(
          item(
            "createFolder",
            "Create Folder from Tab",
            hostAction("createFolderFromTab", tab.id)
          )
        );

        if (!isSplit) {
          addFolderDestinations();
        }
      }

      if (!tab.isClosed && tab.spaceId === snapshot.activeSpaceId) {
        const children = snapshot.spaces
          .filter(
            (space) =>
              space.id !== snapshot.activeSpaceId &&
              space.id !== "playground-agents"
          )
          .map((space) =>
            item(
              `space-${space.id}`,
              space.name,
              command("moveTabToSpace", {
                spaceId: space.id,
                tabId: tab.id,
              }),
              { label: `${space.icon}  ${space.name}` }
            )
          );

        if (children.length) {
          entries.push(
            item("moveToSpace", "Move to Space", undefined, { children })
          );
        }
      }

      if (entries.length) {
        entries.push(separator);
      }

      if (
        tab.kind === "terminal" &&
        ["busy", "waiting"].includes(tab.terminalState ?? "") &&
        snapshot.settings.terminalPreventSleep !== "false"
      ) {
        entries.push(
          item("keepAwake", "Keep Awake Until Done", undefined, {
            disabled: true,
            macOnly: true,
          }),
          separator
        );
      }
    };

    const addStateItems = () => {
      entries.push(
        item(
          "bookmark",
          tab.isBookmarked && !tab.isPinned ? "Unbookmark Tab" : "Bookmark Tab",
          command(tab.isBookmarked ? "unbookmarkTab" : "bookmarkTab", {
            id: tab.id,
          })
        ),
        item(
          "pin",
          tab.isPinned ? "Unpin Tab" : "Pin Tab",
          hostAction("toggleTabPinned", tab.id)
        )
      );

      if (isSplit) {
        entries.push(
          item(
            "separateSplit",
            "Separate Split View",
            hostAction("separateSplit", folder?.id ?? tab.id)
          )
        );
      } else if (
        !tab.isClosed &&
        !tab.isBookmarked &&
        snapshot.activeTabId &&
        snapshot.activeTabId !== tab.id
      ) {
        entries.push(
          item(
            "split",
            "Open in Split View",
            command("splitTab", { side: "right", tabId: tab.id })
          )
        );
      }

      if (!tab.kind || tab.kind === "web") {
        entries.push(
          item(
            "mute",
            tab.isMuted ? "Unmute Tab" : "Mute Tab",
            command(tab.isMuted ? "unmuteTab" : "muteTab", { id: tab.id })
          )
        );
      }

      entries.push(
        item("duplicate", "Duplicate Tab", hostAction("duplicateTab", tab.id), {
          disabled: !tab.url,
        })
      );

      if (!tab.isClosed && snapshot.settings.singleWindow !== "true") {
        entries.push(
          item("newWindow", "Move to New Window", undefined, {
            disabled: true,
            macOnly: true,
          })
        );
      }
    };

    addOrganizationItems();
    addStateItems();

    entries.push(separator);

    if (tab.isClosed && tab.isBookmarked) {
      entries.push(
        item(
          "close",
          "Remove Bookmark",
          command("unbookmarkTab", { id: tab.id })
        )
      );
    } else if (tab.isClosed && tab.isPinned) {
      entries.push(
        item("close", "Remove Pinned Tab", command("unpinTab", { id: tab.id }))
      );
    } else {
      entries.push(
        item("close", "Close Tab", command("closeTab", { id: tab.id }))
      );
    }

    entries.push(
      item(
        "closeOthers",
        "Close Other Tabs",
        hostAction("closeOtherTabs", tab.id),
        {
          disabled: !snapshot.tabs.some(
            (candidate) =>
              candidate.id !== tab.id &&
              !candidate.isPinned &&
              !candidate.isBookmarked
          ),
        }
      )
    );

    return entries;
  };

  const folderMenu = () => {
    const folder = snapshot.folders.find(
      (candidate) => candidate.id === menu.id
    );

    if (!folder) {
      return [];
    }

    const locked = lockedAncestor(snapshot, folder.id);

    if (locked || folder.isLocked) {
      return unlock(locked?.id ?? folder.id);
    }

    if (folder.isSplit) {
      const stacked =
        folder.splitLayout && "vertical" in folder.splitLayout
          ? folder.splitLayout.vertical
          : snapshot.splitArrangement === "vertical";

      return [
        item(
          "arrange",
          stacked ? "Arrange Side by Side" : "Arrange Top and Bottom",
          hostAction("toggleSplitArrangement", folder.id)
        ),
        item(
          "separateSplit",
          "Separate Split View",
          hostAction("separateSplit", folder.id)
        ),
      ];
    }

    const entries: ContextMenuEntry[] = [
      item(
        "collapse",
        folder.isCollapsed ? "Open Folder" : "Close Folder",
        command("setTabFolderCollapsed", {
          collapsed: !folder.isCollapsed,
          id: folder.id,
        })
      ),
      item(
        "editFolder",
        "Edit Folder",
        event("editTabFolder", { id: folder.id })
      ),
    ];

    let depth = 1;
    const visited = new Set([folder.id]);
    let parent = parentId(snapshot, folder.id);

    while (parent && !visited.has(parent)) {
      visited.add(parent);
      depth += 1;
      parent = parentId(snapshot, parent);
    }

    if (depth < 5) {
      entries.push(
        item(
          "newFolder",
          "New Folder",
          hostAction("createSubfolder", folder.id)
        )
      );
    }

    entries.push(separator);

    if (folder.lock) {
      entries.push(
        item(
          "changePassword",
          "Change Password…",
          command("changeTabFolderPassword", { id: folder.id })
        ),
        item(
          "removeLock",
          "Remove Lock",
          command("removeTabFolderLock", { id: folder.id })
        )
      );
    } else {
      entries.push(
        item(
          "lock",
          "Lock Folder…",
          command("beginTabFolderLockSetup", { id: folder.id })
        )
      );
    }

    entries.push(
      separator,
      item("deleteFolder", "Delete Folder", {
        id: folder.id,
        kind: "folder",
        type: "delete",
      })
    );

    return entries;
  };

  const extensionMenu = () => {
    if (!menu.id) {
      return [];
    }

    const entries: ContextMenuEntry[] = [];

    if (menu.pinned !== undefined) {
      entries.push(
        item(
          "togglePin",
          menu.pinned ? "Unpin from Address Bar" : "Pin to Address Bar",
          event("extensionMenuAction", { action: "togglePin", id: menu.id })
        )
      );
    }

    entries.push(
      item(
        "details",
        "Details",
        event("extensionMenuAction", { action: "details", id: menu.id })
      ),
      separator,
      item(
        "remove",
        "Remove…",
        event("extensionMenuAction", { action: "remove", id: menu.id })
      )
    );

    return entries;
  };

  const sidebarMenu = () => {
    const spaceId = menu.spaceId ?? snapshot.activeSpaceId;

    const entries: ContextMenuEntry[] = [
      item("newTab", "New Tab", { kind: "tab", spaceId, type: "newItem" }),
    ];

    if (snapshot.settings.terminalEnabled !== "false") {
      entries.push(
        item("newTerminal", "New Terminal Tab", {
          kind: "terminal",
          spaceId,
          type: "newItem",
        })
      );
    }

    entries.push(
      item("newFolder", "Create Folder", {
        kind: "folder",
        spaceId,
        type: "newItem",
      }),
      item("tabPosition", "Tab Position", undefined, {
        children: (["left", "right", "top", "bottom"] as const).map(
          (position) =>
            item(
              position,
              position[0].toUpperCase() + position.slice(1),
              command("setSetting", { key: "tabPosition", value: position }),
              {
                checked: position === snapshot.tabPosition,
              }
            )
        ),
      }),
      separator,
      item(
        "editSpace",
        "Edit Space",
        event("openSpaceEditor", { id: spaceId })
      ),
      item("newSpace", "New Space", event("openAddSpaceEditor", {}))
    );

    if (snapshot.spaces.length > 1) {
      entries.push(
        item("deleteSpace", "Delete Space…", {
          id: spaceId,
          kind: "space",
          type: "delete",
        })
      );
    }

    entries.push(
      separator,
      item("restore", "Restore Closed Tab", command("restoreClosedTab", {}), {
        disabled: !snapshot.canRestoreClosedTab,
      })
    );

    if (spaceId === "playground-agents" && snapshot.agentConnected) {
      entries.push(
        separator,
        item("stopAgents", "Stop Agents", { type: "stopAgents" })
      );
    }

    return entries;
  };

  switch (menu.kind) {
    case "tab": {
      return tabMenu();
    }

    case "folder": {
      return folderMenu();
    }

    case "extension": {
      return extensionMenu();
    }

    case "sidebar": {
      return sidebarMenu();
    }

    default: {
      return [];
    }
  }
};
