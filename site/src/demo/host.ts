import type {
  AnyBridgeEventEnvelope,
  BridgeRecentTab,
  BridgeCommandName,
  BridgeCommandPayloadMap,
  BridgeEventName,
  BridgeEventPayloadMap,
  BridgeExtensionSnapshot,
  BridgeArchivedTab,
  BridgeSidebarDropPayload,
  BridgeAgentAction,
  TabPosition,
  ImportSourceInfo,
  ImportSummaryItem,
  BridgeSplitLayout,
  SplitDropSide,
  BridgeTerminalTheme,
} from "../../../lilo-ui/src/lib/bridge/protocol";
import { sampleFavicon } from "./assets.ts";
import type { DemoAssets } from "./assets.ts";
import { nativeCopy } from "./native-copy.ts";
import { createDemoSettings } from "./settings-state.ts";
import type { NativeShortcutAction } from "./settings-state.ts";
import {
  insertPane,
  removePane,
  splitFrames,
  swapPanes,
} from "./split-layout.ts";
import {
  demoCopy,
  makeTab,
  makeTreeItem,
  samplePageColor,
  sampleWorld,
} from "./world.ts";
import type { DemoLocale, DemoTab } from "./world.ts";

type DemoCommands = {
  [K in BridgeCommandName]?: (payload: BridgeCommandPayloadMap[K]) => void;
};

export interface DemoMenu {
  kind: "tab" | "folder" | "sidebar" | "extension";
  id: string;
  x: number;
  y: number;
  spaceId?: string;
  pinned?: boolean;
  profileId?: string;
}

export interface DemoAgentPointer {
  x: number;
  y: number;
  pressed: boolean;
}

const address = (value: string): string | null => {
  if (!value) {
    return "";
  }

  if (!/^https?:\/\//iu.test(value)) {
    return null;
  }

  try {
    return new URL(value).href;
  } catch {
    return null;
  }
};

const agentAddress = (url: string) => {
  const normalized = address(url);

  if (normalized === null) {
    throw new Error("Only http and https sample addresses are supported.");
  }

  if (normalized && new URL(normalized).hostname === "mcp.example.com") {
    throw new Error("The MCP client is outside the agent's page controls.");
  }

  return normalized;
};

export const createDemoHost = (
  locale: DemoLocale,
  onEvent?: (event: AnyBridgeEventEnvelope) => void,
  onChange?: () => void,
  version = "0.0.0",
  assets?: DemoAssets,
  native?: {
    shortcuts: NativeShortcutAction[];
    terminalThemes: BridgeTerminalTheme[];
  }
) => {
  const world: ReturnType<typeof sampleWorld> = sampleWorld(locale, assets);

  const selections = new Map([
    ["home", "lilo"],
    ["work", "board"],
    ["music", "playlist"],
  ]);

  let recent = ["lilo", "board", "playlist"];

  const history = new Map<
    string,
    {
      urls: string[];
      index: number;
    }
  >();

  const homeTitles = new Map(world.tabs.map((tab) => [tab.id, tab.title]));

  const tabHomes = new Map(
    world.tabs
      .filter((tab) => tab.isPinned || tab.isBookmarked)
      .map((tab) => [tab.id, tab.url])
  );

  const closed: {
    tab: DemoTab;
    index: number;
  }[] = [];

  const visited = world.tabs
    .filter((tab) => tab.url)
    .map((tab) => ({
      id: tab.url,
      title: tab.title,
      url: tab.url,
      visitedAt: Date.now(),
    }));

  const archived: (BridgeArchivedTab & { spaceId: string; index: number })[] =
    [];

  // The demo keeps passwords only in memory and never uses Keychain or device authentication.
  const folderPasswords = new Map<string, string>();

  const sampleSettings: BridgeEventPayloadMap["settingsLoaded"]["settings"] = {
    agentControlEnabled: "true",
    appVersion: version,
    contentBlockerEnabled: "true",
    downloadsFolder: "~/Downloads",
    locale,
    pinnedExtensions:
      "eimadpbcbfnmbkopoojfekhnkhdbieeh,nngceckbapebfimnlniiiahkandclblb",
    searchEngine: "google",
    terminalEnabled: "true",
    theme: "system",
  };

  let importSources: ImportSourceInfo[] = [];
  let menu: DemoMenu | null = null;
  let notice = "";
  let splitIds: string[] = [];
  let playgroundSplit = false;
  let splitArrangement: "horizontal" | "vertical" = "horizontal";
  let nextId = 0;
  const agentOwned = new Set<string>();
  let playgroundMode: "terminal" | "mcp" = "mcp";
  let agentConnected = false;
  let agentAuthorized = true;
  let agentBusy = false;
  let agentSessionActive = false;
  const stopListeners = new Set<() => void>();
  let agentGeneration = 0;

  let agentControl: { tabId: string; pointer: DemoAgentPointer | null } | null =
    null;

  const agentApprovals = new Map<
    string,
    { site: string; settle: (granted: boolean) => void }
  >();

  const idFor = (kind: string) => {
    nextId += 1;

    return `demo-${kind}-${nextId}`;
  };

  const sampleExtensions: BridgeExtensionSnapshot[] = [
    {
      badgeColor: "#e4a735",
      badgeText: "",
      description: "Dark Reader",
      hasBackground: true,
      hasContentScripts: true,
      hasPopup: true,
      iconDataURL: assets?.images.darkReader ?? "",
      id: "eimadpbcbfnmbkopoojfekhnkhdbieeh",
      isEnabled: true,
      name: "Dark Reader",
      version: "4.9",
    },
    {
      badgeColor: "#175ddc",
      badgeText: "",
      description: "Bitwarden",
      hasBackground: true,
      hasContentScripts: true,
      hasPopup: true,
      iconDataURL: assets?.images.bitwarden ?? "",
      id: "nngceckbapebfimnlniiiahkandclblb",
      isEnabled: true,
      name: "Bitwarden",
      version: "2026.10",
    },
  ];

  const emit = <K extends BridgeEventName>(
    event: K,
    payload: BridgeEventPayloadMap[K]
  ) => {
    // SAFETY: the protocol key K pairs this event with its payload.
    onEvent?.({ event, ...structuredClone(payload) } as AnyBridgeEventEnvelope);
  };

  const activeTab = () =>
    world.tabs.find((tab) => tab.id === world.activeTabId);

  const preferences = createDemoSettings({
    activeURL: () => activeTab()?.url ?? "",
    clearHistory: (range) => {
      const duration = new Map([
        ["hour", 3_600_000],
        ["day", 86_400_000],
        ["week", 604_800_000],
      ]).get(range);

      const cutoff = duration ? Date.now() - duration : 0;

      for (let index = visited.length - 1; index >= 0; index -= 1) {
        if (visited[index].visitedAt >= cutoff) {
          visited.splice(index, 1);
        }
      }
    },
    emit,
    historyCount: () => visited.length,
    locale,
    onChange: () => onChange?.(),
    shortcuts: native?.shortcuts ?? [],
    terminalThemes: native?.terminalThemes,
    version,
  });

  const settings = preferences.values;
  Object.assign(settings, sampleSettings);

  const tabLayout = () => {
    const positions: TabPosition[] = ["left", "right", "top", "bottom"];
    const position = positions.find((value) => value === settings.tabPosition);
    const edge = position ?? "left";
    const stored = settings.addressPlacement;

    const placement =
      stored === "page" || stored === "tabs" ? stored : undefined;

    return {
      address:
        edge === "right"
          ? "page"
          : (placement ?? (edge === "bottom" ? "page" : "tabs")),
      position: edge,
    } satisfies BridgeEventPayloadMap["tabLayoutChanged"];
  };

  const text = () => demoCopy(settings.locale === "fr" ? "fr" : "en");

  const profileExtensions = new Map(
    world.profiles.map((profile) => [
      profile.id,
      structuredClone(sampleExtensions),
    ])
  );

  const activeProfileId = () =>
    world.spaces.find((space) => space.id === world.activeSpaceId)?.profileId ??
    "";

  const extensionsFor = (profileId = activeProfileId()) => {
    let extensions = profileExtensions.get(profileId);

    if (!extensions) {
      extensions = [];
      profileExtensions.set(profileId, extensions);
    }

    return extensions;
  };

  const tabsIn = (spaceId = world.activeSpaceId) =>
    world.tabs.filter((tab) => tab.spaceId === spaceId);

  const orderedTabs = (spaceId = world.activeSpaceId) => {
    const walk = (
      parentId: string | null,
      section: "bookmarked" | "pinned" | "unpinned"
    ): DemoTab[] =>
      world.treeItems
        .filter(
          (item) =>
            item.spaceId === spaceId &&
            item.section === section &&
            (item.parentFolderId ?? null) === parentId
        )
        .toSorted((first, second) => first.sortOrder - second.sortOrder)
        .flatMap((item) =>
          item.kind === "folder"
            ? walk(item.itemId, section)
            : world.tabs.filter((tab) => tab.id === item.itemId)
        );

    return [
      ...walk(null, "bookmarked"),
      ...walk(null, "pinned"),
      ...walk(null, "unpinned"),
    ];
  };

  let publishedProfile = activeProfileId();

  const publishActiveExtensions = () => {
    const profileId = activeProfileId();

    if (publishedProfile === profileId) {
      return;
    }

    publishedProfile = profileId;
    const extensions = extensionsFor();
    emit("extensionsChanged", {
      extensions,
      ids: extensions.map((extension) => extension.id),
    });
  };

  const parentFolders = (id: string) => {
    const parents: string[] = [];

    let parent = world.treeItems.find(
      (item) => item.itemId === id
    )?.parentFolderId;

    while (parent) {
      parents.push(parent);
      const parentId = parent;
      parent = world.treeItems.find(
        (item) => item.itemId === parentId
      )?.parentFolderId;
    }

    return parents;
  };

  const lockedFolderFor = (id: string) =>
    parentFolders(id)
      .map((folderId) => world.folders.find((folder) => folder.id === folderId))
      .find((folder) => folder?.isLocked);

  const lockedItem = (id: string) =>
    world.folders.find((folder) => folder.id === id && folder.isLocked) ??
    lockedFolderFor(id);

  const splitFolderFor = (id: string) =>
    world.folders.find(
      (folder) =>
        folder.splitLayout &&
        splitFrames(folder.splitLayout).some((pane) => pane.tabId === id)
    );

  const splitPaneFrames = () => {
    const layout = splitFolderFor(world.activeTabId)?.splitLayout;

    if (layout && splitIds.length > 1) {
      return splitFrames(layout);
    }

    return splitIds.map((tabId, index) => ({
      height: splitArrangement === "vertical" ? 1 / splitIds.length : 1,
      tabId,
      width: splitArrangement === "horizontal" ? 1 / splitIds.length : 1,
      x: splitArrangement === "horizontal" ? index / splitIds.length : 0,
      y: splitArrangement === "vertical" ? index / splitIds.length : 0,
    }));
  };

  const spaceState = (spaceId: string) => ({
    activeTabId: selections.get(spaceId) ?? "",
    folders: (world.folders ?? []).filter(
      (folder) => folder.spaceId === spaceId
    ),
    spaceId,
    tabs: orderedTabs(spaceId).map((tab) => {
      const home = tabHomes.get(tab.id);
      let homeTitle = "";

      if (home && tab.url) {
        const here = new URL(tab.url);
        const there = new URL(home);
        here.hash = "";
        there.hash = "";

        if (here.href !== there.href) {
          homeTitle = homeTitles.get(tab.id) ?? there.hostname;
        }
      }

      return { ...tab, homeTitle };
    }),
    treeItems: world.treeItems.filter((item) => item.spaceId === spaceId),
  });

  const publish = (transitionId?: string, spaceIds = [world.activeSpaceId]) => {
    const spaceId = world.activeSpaceId;
    world.activeTabId = selections.get(spaceId) ?? "";
    const group = splitFolderFor(world.activeTabId);

    if (group?.splitLayout) {
      playgroundSplit = false;
      splitIds = splitFrames(group.splitLayout).map((pane) => pane.tabId);
      splitArrangement =
        "vertical" in group.splitLayout && group.splitLayout.vertical
          ? "vertical"
          : "horizontal";
    } else if (
      !playgroundSplit ||
      !splitIds.includes(world.activeTabId) ||
      splitIds.some((id) => !tabsIn(spaceId).some((tab) => tab.id === id))
    ) {
      splitIds = [];
    }

    publishActiveExtensions();
    emit("browserStateChanged", {
      changedSpaceId: spaceId,
      profileId: world.spaces?.find((space) => space.id === spaceId)?.profileId,
      states: spaceIds.map(spaceState),
      transitionId,
    });
    emit("splitPanesChanged", {
      panes: splitPaneFrames(),
    });
    onChange?.();
  };

  const select = (tab: DemoTab) => {
    const locked = lockedFolderFor(tab.id);

    if (locked) {
      emit("beginFolderUnlock", { id: locked.id });

      return;
    }

    world.activeSpaceId = tab.spaceId;
    tab.isClosed = false;
    selections.set(tab.spaceId, tab.id);
    recent = [tab.id, ...recent.filter((id) => id !== tab.id)];

    const group = splitFolderFor(tab.id);

    if (group?.splitLayout) {
      splitIds = splitFrames(group.splitLayout).map((pane) => pane.tabId);
      splitArrangement =
        "vertical" in group.splitLayout && group.splitLayout.vertical
          ? "vertical"
          : "horizontal";
    } else if (!splitIds.includes(tab.id)) {
      splitIds = [];
    }
  };

  const titleFor = (url: string) => {
    if (url.includes("studio.example.com")) {
      return text().agentProject;
    }

    if (url.includes("github.com")) {
      return "Alexays / Lilo";
    }

    if (url.includes("slowtravel.")) {
      return text().article;
    }

    if (url.includes("notes.")) {
      return text().notes;
    }

    if (url.includes("radio.")) {
      return text().playlist;
    }

    if (url.includes("tracker.")) {
      return text().board;
    }

    return new URL(url).hostname;
  };

  const addTab = (
    url = "",
    title = text().newTab,
    kind: "web" | "terminal" = "web"
  ) => {
    const tab = makeTab(idFor("tab"), world.activeSpaceId, title, url, assets);
    tab.kind = kind;

    if (kind === "terminal") {
      Object.assign(tab, {
        customTitle: title,
        cwd: "/Users/you/Projects/lilo",
        terminalState: "idle",
      });
    }

    if (url) {
      tab.title = title === text().newTab ? titleFor(url) : title;
    }

    world.tabs.push(tab);
    world.treeItems.push(makeTreeItem(tab, world.treeItems.length));
    select(tab);

    return tab;
  };

  const syncHome = (tab: DemoTab) => {
    if (!(tab.isPinned || tab.isBookmarked)) {
      tabHomes.delete(tab.id);
      homeTitles.delete(tab.id);

      return;
    }

    if (tab.url && !tabHomes.get(tab.id)) {
      tabHomes.set(tab.id, tab.url);
      homeTitles.set(tab.id, tab.title);
    }
  };

  const navigate = (url: string, tab = activeTab()) => {
    const normalized = address(url);

    if (normalized === null || !tab) {
      return;
    }

    preferences.navigated(normalized);

    const past = history.get(tab.id) ?? { index: 0, urls: [tab.url] };
    past.urls = [...past.urls.slice(0, past.index + 1), normalized];
    past.index += 1;
    history.set(tab.id, past);
    Object.assign(tab, {
      canGoBack: true,
      canGoForward: false,
      faviconDataURL: sampleFavicon(normalized, assets),
      faviconDominantColor: samplePageColor(normalized),
      kind: "web",
      title: normalized ? titleFor(normalized) : text().newTab,
      url: normalized,
    });

    syncHome(tab);

    if (normalized) {
      const previous = visited.findIndex((entry) => entry.url === normalized);

      if (previous !== -1) {
        visited.splice(previous, 1);
      }

      visited.push({
        id: normalized,
        title: tab.title,
        url: normalized,
        visitedAt: Date.now(),
      });

      if (visited.length > 100) {
        visited.shift();
      }
    }
  };

  const navigateTab = (id: string, url: string) => {
    const tab = world.tabs.find((item) => item.id === id);

    if (!tab || lockedFolderFor(id)) {
      return;
    }

    navigate(agentOwned.has(id) ? agentAddress(url) : url, tab);
    publish();
  };

  const removeFromSplit = (id: string) => {
    const group = splitFolderFor(id);

    if (group?.splitLayout) {
      const layout = removePane(group.splitLayout, id);

      if (layout && !("tabId" in layout)) {
        group.splitLayout = layout;
      } else {
        for (const item of world.treeItems) {
          if (item.parentFolderId === group.id) {
            item.parentFolderId = null;
          }
        }

        for (const child of world.tabs) {
          if (child.groupId === group.id) {
            child.groupId = undefined;
          }
        }

        world.treeItems = world.treeItems.filter(
          (item) => item.itemId !== group.id
        );
        world.folders = world.folders.filter(
          (folder) => folder.id !== group.id
        );
        splitIds = [];
      }
    }
  };

  const closeTab = (id: string, undoable = true) => {
    if (lockedFolderFor(id)) {
      return;
    }

    const index = world.tabs.findIndex((tab) => tab.id === id);

    if (index === -1) {
      return;
    }

    const tab = world.tabs[index];

    if (tab.isClosed) {
      return;
    }

    agentOwned.delete(id);

    if (undoable) {
      closed.push({ index, tab: structuredClone(tab) });
    }

    if (tab.isPinned || tab.isBookmarked) {
      tab.isClosed = true;
      const home = tabHomes.get(id);

      if (home) {
        Object.assign(tab, {
          canGoBack: false,
          canGoForward: false,
          faviconDataURL: sampleFavicon(home, assets),
          faviconDominantColor: samplePageColor(home),
          homeTitle: "",
          title: homeTitles.get(id) ?? titleFor(home),
          url: home,
        });
        history.delete(id);
      }
    } else {
      world.tabs.splice(index, 1);
      world.treeItems = world.treeItems.filter((item) => item.itemId !== id);
    }

    splitIds = splitIds.filter((tabId) => tabId !== id);
    removeFromSplit(id);

    if (selections.get(tab.spaceId) === id) {
      const available = tabsIn(tab.spaceId).filter(
        (candidate) => !candidate.isClosed && !lockedFolderFor(candidate.id)
      );

      selections.set(
        tab.spaceId,
        recent.find((recentId) =>
          available.some((candidate) => candidate.id === recentId)
        ) ??
          available.at(-1)?.id ??
          ""
      );
    }

    if (!selections.get(tab.spaceId)) {
      const current = world.activeSpaceId;
      world.activeSpaceId = tab.spaceId;
      addTab();
      world.activeSpaceId = current;
    }

    if (undoable) {
      emit("tabClosedUndoable", { title: tab.customTitle || tab.title });
    }
  };

  const addProfile = (name: string, color = "#7868d8") => {
    const profile = { color, id: idFor("profile"), isDefault: false, name };
    world.profiles.push(profile);
    emit("profileCreated", profile);

    return profile;
  };

  const requestedProfile = (
    payload: Pick<
      BridgeCommandPayloadMap["createSpace"],
      "profileId" | "newProfileName" | "newProfileColor"
    >
  ) => {
    const name = payload.newProfileName?.trim();

    return name
      ? addProfile(name, payload.newProfileColor).id
      : world.profiles.find((profile) => profile.id === payload.profileId)?.id;
  };

  const publishArchive = () =>
    emit("archivedTabs", {
      tabs: archived
        .filter((entry) => entry.spaceId === world.activeSpaceId)
        .toReversed()
        .map(({ id, url, title, archivedAt }) => ({
          archivedAt,
          id,
          title,
          url,
        })),
    });

  const lockFolder = (id: string) => {
    const folder = world.folders.find((candidate) => candidate.id === id);

    if (!folder?.lock) {
      return;
    }

    folder.isLocked = true;
    splitIds = splitIds.filter((tabId) => !parentFolders(tabId).includes(id));
    const selected = selections.get(folder.spaceId);

    if (selected && parentFolders(selected).includes(id)) {
      const replacement = tabsIn(folder.spaceId).find(
        (tab) => !lockedFolderFor(tab.id)
      );

      if (replacement) {
        selections.set(folder.spaceId, replacement.id);
      } else {
        const current = world.activeSpaceId;
        world.activeSpaceId = folder.spaceId;
        addTab();
        world.activeSpaceId = current;
      }
    }

    publish(undefined, [folder.spaceId]);
  };

  const changeSection = (
    id: string,
    section: "bookmarked" | "pinned" | "unpinned"
  ) => {
    const tab = world.tabs.find((candidate) => candidate.id === id);
    const item = world.treeItems.find((candidate) => candidate.itemId === id);

    if (!tab || !item || lockedFolderFor(id)) {
      return;
    }

    tab.isPinned = section === "pinned";
    tab.isBookmarked = section === "bookmarked";

    syncHome(tab);

    removeFromSplit(id);
    item.section = section;
    item.parentFolderId = null;

    if (section === "unpinned" && tab.isClosed) {
      world.tabs = world.tabs.filter((candidate) => candidate.id !== id);
      world.treeItems = world.treeItems.filter(
        (candidate) => candidate.itemId !== id
      );
    }
  };

  const addFolder = (name = text().newFolder) => {
    const id = idFor("folder");
    world.folders.push({
      color: "#9384ce",
      id,
      isCollapsed: false,
      name,
      spaceId: world.activeSpaceId,
    });
    world.treeItems.push({
      id: `item-${id}`,
      itemId: id,
      kind: "folder",
      parentFolderId: null,
      section: "unpinned",
      sortOrder: world.treeItems.length,
      spaceId: world.activeSpaceId,
    });

    return id;
  };

  const groupTabs = (sourceId: string, targetId: string) => {
    if (lockedFolderFor(sourceId) || lockedFolderFor(targetId)) {
      return;
    }

    const folderId = addFolder();
    const target = world.tabs.find((tab) => tab.id === targetId);
    const section = target?.isPinned ? "pinned" : "unpinned";

    const folderItem = world.treeItems.find((item) => item.itemId === folderId);

    if (folderItem) {
      folderItem.section = section;
    }

    for (const id of [sourceId, targetId]) {
      changeSection(id, section);

      const item = world.treeItems.find((candidate) => candidate.itemId === id);

      if (item) {
        item.parentFolderId = folderId;
      }
    }
  };

  const drop = (payload: BridgeSidebarDropPayload) => {
    if (payload.type === "group") {
      groupTabs(payload.sourceTabId, payload.targetTabId);

      return;
    }

    const item = world.treeItems.find(
      (candidate) => candidate.itemId === payload.id
    );

    if (
      !item ||
      item.itemId === payload.parentFolderId ||
      lockedItem(item.itemId) ||
      (payload.parentFolderId && lockedItem(payload.parentFolderId))
    ) {
      return;
    }

    // A folder cannot become a child of one of its descendants.
    let parent = payload.parentFolderId;

    while (parent) {
      if (parent === item.itemId) {
        return;
      }

      const parentId = parent;
      parent =
        world.treeItems.find((candidate) => candidate.itemId === parentId)
          ?.parentFolderId ?? null;
    }

    if (item.kind === "tab") {
      changeSection(item.itemId, payload.section);
    }

    item.section = payload.section;
    item.parentFolderId = payload.parentFolderId;

    const siblings = world.treeItems
      .filter(
        (candidate) =>
          candidate !== item &&
          candidate.spaceId === item.spaceId &&
          candidate.section === item.section &&
          candidate.parentFolderId === item.parentFolderId
      )
      .toSorted((a, b) => a.sortOrder - b.sortOrder);

    const before = siblings.findIndex(
      (candidate) => candidate.itemId === payload.insertBeforeId
    );

    const after = siblings.findIndex(
      (candidate) => candidate.itemId === payload.insertAfterId
    );

    let position = payload.fallbackIndex;

    if (after !== -1) {
      position = after + 1;
    }

    if (before !== -1) {
      position = before;
    }

    siblings.splice(position, 0, item);

    for (const [index, candidate] of siblings.entries()) {
      candidate.sortOrder = index;
    }
  };

  const showNotice = (message = text().sampleOnly) => {
    notice = message;
    onChange?.();
  };

  const recentRank = (id: string) =>
    recent.includes(id) ? recent.indexOf(id) : recent.length;

  const initialState = () =>
    structuredClone({
      ...world,
      ...spaceState(world.activeSpaceId),
      activeProfileId: world.spaces.find(
        (space) => space.id === world.activeSpaceId
      )?.profileId,
      addressPlacement: tabLayout().address,
      extensions: extensionsFor(),
      tabPosition: tabLayout().position,
    });

  const snapshot = () =>
    structuredClone({
      ...initialState(),
      activeSpaceId: world.activeSpaceId,
      agentConnected,
      agentControl,
      canRestoreClosedTab: closed.length > 0,
      menu,
      notice,
      profiles: world.profiles,
      settings,
      spaces: world.spaces,
      splitArrangement,
      splitIds,
      splitPaneFrames: splitPaneFrames(),
    });

  const publishAgentActivity = () =>
    emit("agentActivity", {
      agentsProfileId: agentConnected ? "profile-agents" : "",
      agentsSpaceIds: world.spaces.some(
        (space) => space.id === "playground-agents"
      )
        ? ["playground-agents"]
        : [],
      clients: agentConnected
        ? [
            {
              actingTabIds:
                agentBusy || agentSessionActive
                  ? (agentControl
                      ? [agentControl.tabId]
                      : [...agentOwned]
                    ).filter((id) => world.tabs.some((tab) => tab.id === id))
                  : [],
              busy: agentBusy || agentSessionActive,
              name: text().playgroundClient,
              spaceIds: ["playground-agents"],
            },
          ]
        : [],
      hiddenAgentsSpaceIds: [],
      moods:
        agentConnected && agentBusy ? { "playground-agents": "working" } : {},
    });

  const ensureAgentWorkspace = () => {
    if (world.spaces.some((space) => space.id === "playground-agents")) {
      return;
    }

    const profile = {
      color: "#d38d64",
      id: "profile-agents",
      isDefault: false,
      name: text().agents,
    };

    if (!world.profiles.some((item) => item.id === profile.id)) {
      world.profiles.push(profile);
      emit("profileCreated", profile);
    }

    const space = {
      color: "#d38d64",
      icon: "🤖",
      id: "playground-agents",
      isPrivate: false,
      name: text().agents,
      profileId: profile.id,
      sortOrder: world.spaces.length,
    };

    world.spaces.push(space);
    world.folders.push({
      color: "#d38d64",
      id: "playground-client",
      isCollapsed: false,
      name: text().playgroundClient,
      spaceId: space.id,
    });
    world.treeItems.push({
      id: "item-playground-client",
      itemId: "playground-client",
      kind: "folder",
      parentFolderId: null,
      section: "unpinned",
      sortOrder: 0,
      spaceId: space.id,
    });
    emit("spaceCreated", space);
    publishAgentActivity();
  };

  const agentTabs = () =>
    world.tabs.filter(
      (tab) =>
        agentOwned.has(tab.id) &&
        tab.spaceId === "playground-agents" &&
        !lockedFolderFor(tab.id)
    );

  const makeAgentTab = (url = "") => {
    ensureAgentWorkspace();
    const normalized = agentAddress(url);

    if (lockedItem("playground-client")) {
      throw new Error("Unlock the agent folder before using its pages.");
    }

    if (
      world.tabs.filter(
        (tab) => agentOwned.has(tab.id) && tab.spaceId === "playground-agents"
      ).length >= 12
    ) {
      throw new Error("This playground supports up to twelve agent tabs.");
    }

    const tab = makeTab(
      idFor("agent"),
      "playground-agents",
      normalized ? titleFor(normalized) : text().newTab,
      normalized,
      assets
    );

    world.tabs.push(tab);
    world.treeItems.push({
      ...makeTreeItem(tab, world.treeItems.length),
      parentFolderId: "playground-client",
    });
    agentOwned.add(tab.id);

    return tab;
  };

  const openPlayground = (mode: "terminal" | "mcp", targetId?: string) => {
    if (mode === "terminal" && settings.terminalEnabled === "false") {
      showNotice(text().terminalDisabled);

      return;
    }

    ensureAgentWorkspace();
    const locked = lockedItem("playground-client");

    if (locked) {
      emit("beginFolderUnlock", { id: locked.id });

      return;
    }

    playgroundMode = mode;
    const leftId = `playground-${mode}`;
    let left = world.tabs.find((tab) => tab.id === leftId);

    const lockedLeft = left && lockedFolderFor(left.id);

    if (lockedLeft) {
      emit("beginFolderUnlock", { id: lockedLeft.id });

      return;
    }

    if (!left) {
      left = makeTab(
        leftId,
        "playground-agents",
        mode === "terminal" ? "~/Projects/lilo" : text().inspector,
        mode === "mcp" ? "https://mcp.example.com" : "",
        assets
      );
      left.kind = mode === "terminal" ? "terminal" : "web";
      left.isPinned = true;

      if (mode === "terminal") {
        Object.assign(left, {
          customTitle: "~/Projects/lilo",
          cwd: "/Users/you/Projects/lilo",
          terminalState: "idle",
        });
      }

      world.tabs.push(left);
      world.treeItems.push(makeTreeItem(left, world.treeItems.length));
    }

    const target =
      agentTabs().find((tab) => tab.id === targetId) ??
      agentTabs().at(-1) ??
      makeAgentTab(
        mode === "terminal"
          ? "https://project.example.com"
          : "https://studio.example.com/launch"
      );

    if (
      world.activeSpaceId === "playground-agents" &&
      splitIds[0] === left.id &&
      splitIds[1] === target.id &&
      selections.get("playground-agents") === left.id
    ) {
      return target;
    }

    select(left);
    playgroundSplit = true;
    splitIds = [left.id, target.id];
    publish();
    publishAgentActivity();

    return target;
  };

  const openBrowser = () => {
    const space = world.spaces.find((item) => item.id !== "playground-agents");

    if (!space) {
      return;
    }

    world.activeSpaceId = space.id;
    splitIds = [];
    publish();
  };

  const createAgentTab = (url = "") => {
    const tab = makeAgentTab(url);
    openPlayground(playgroundMode, tab.id);

    return structuredClone(tab);
  };

  const showAgentTab = (id: string) => {
    const tab = agentTabs().find((item) => item.id === id);

    if (!tab) {
      throw new Error("This tab does not belong to the playground agent.");
    }

    openPlayground(playgroundMode, id);

    return tab;
  };

  const navigateAgentTab = (id: string, url: string) => {
    const normalized = agentAddress(url);
    const tab = showAgentTab(id);
    navigate(normalized, tab);
    publish();

    return structuredClone(tab);
  };

  const closeAgentTab = (id: string) => {
    if (!agentTabs().some((tab) => tab.id === id)) {
      throw new Error("This tab does not belong to the playground agent.");
    }

    closeTab(id);
    publish();
  };

  const setAgentBusy = (busy: boolean) => {
    if (agentConnected && agentBusy === busy) {
      return;
    }

    agentConnected = true;
    agentBusy = busy;
    publishAgentActivity();
  };

  const setAgentSession = (active: boolean) => {
    agentSessionActive = active;

    if (!active) {
      agentControl = null;
    }

    publishAgentActivity();
    onChange?.();
  };

  const presentAgent = (id: string, pointer?: DemoAgentPointer) => {
    if (!agentSessionActive || !agentTabs().some((tab) => tab.id === id)) {
      return;
    }

    if (agentControl?.tabId === id && !pointer) {
      return;
    }

    agentControl = { pointer: pointer ?? null, tabId: id };
    publishAgentActivity();
    onChange?.();
  };

  const requestAgentApproval = (
    action: BridgeAgentAction,
    signal: AbortSignal
  ) => {
    signal.throwIfAborted();

    let allowedSites: string[] = [];

    try {
      const parsed: unknown = JSON.parse(
        settings.agentAlwaysAllowedSites ?? "[]"
      );

      if (Array.isArray(parsed)) {
        allowedSites = parsed.filter(
          (site): site is string => typeof site === "string"
        );
      }
    } catch {
      /* Invalid settings have no remembered approvals. */
    }

    if (
      settings.agentAskBeforeActions === "false" ||
      allowedSites.some(
        (site) => action.site === site || action.site.endsWith(`.${site}`)
      )
    ) {
      return Promise.resolve(true);
    }

    const requestId = idFor("approval");
    const pending = Promise.withResolvers<boolean>();
    const cleanup = new AbortController();

    const settle = (granted: boolean) => {
      cleanup.abort();
      agentApprovals.delete(requestId);
      emit("permissionRequestClosed", { requestId });
      pending.resolve(granted);
    };

    agentApprovals.set(requestId, { settle, site: action.site });
    signal.addEventListener("abort", () => settle(false), {
      once: true,
      signal: cleanup.signal,
    });
    emit("agentControlRequested", {
      action,
      clientName: text().playgroundClient,
      executable: "",
      profileName: "",
      requestId,
    });

    return pending.promise;
  };

  const nameAgentGroup = (name: string) => {
    const folder = world.folders.find(
      (item) => item.id === "playground-client"
    );

    if (folder && name.trim() && folder.name !== name.trim()) {
      folder.name = name.trim();
      publish();
    }
  };

  const replies: Partial<Record<BridgeCommandName, () => void>> = {
    getAgentActivity: publishAgentActivity,
    getAgentClients: () =>
      emit("agentClientsLoaded", {
        allowed: agentConnected
          ? [
              {
                client: "codex",
                displayName: "Codex",
                lastSeen: null,
                name: text().playgroundClient,
              },
            ]
          : [],
        clients: ["claudeCode", "claudeDesktop", "codex", "cursor"].map(
          (id) => ({
            configured: id === "codex" && agentAuthorized,
            icon: id === "codex" ? (assets?.images.codex ?? null) : null,
            id,
          })
        ),
      }),
    getAppIcons: () =>
      emit("appIconsLoaded", {
        icons: assets?.appIcons ?? [],
      }),
    getContentBlockerStatus: () =>
      emit("contentBlockerStatus", {
        lists: 7,
        updated: 1_793_012_400,
        updating: false,
      }),
    getDefaultBrowserStatus: () =>
      emit("defaultBrowserStatusLoaded", {
        isDefault: false,
        shouldInvite: false,
      }),
    getDeviceSetup: () => emit("deviceSetupLoaded", { label: "" }),
    getExtensionDebuggers: () => emit("extensionDebuggers", { debuggers: [] }),
    getFeatureFlags: () => emit("featureFlagsLoaded", { flags: [] }),
    getKeepAwakeState: () =>
      emit("keepAwakeChanged", {
        agents: [],
        helperStatus: "unsigned",
        holdsLidClosed: false,
        keepsAwake: false,
        tabIds: [],
      }),
    getMediaActivity: () => emit("mediaActivity", { calls: [], tabs: [] }),
    getOnboardingState: () =>
      emit("onboardingState", { show: false, step: 0, usage: "browse" }),
    getProfileStats: () =>
      emit("profileStats", {
        extensionCounts: Object.fromEntries(
          world.profiles.map((profile) => [
            profile.id,
            extensionsFor(profile.id).length,
          ])
        ),
      }),
    getRunningApps: () => emit("runningApps", { apps: [] }),
    getUpdaterStatus: () =>
      emit("updaterStatus", {
        automatic: settings.automaticUpdates !== "false",
        available: false,
        lastCheck: null,
        version,
      }),
    requestDownloadsSnapshot: () => emit("downloadsSnapshot", { items: [] }),
    scanImportSources: () => {
      importSources = [
        {
          family: "chromium",
          iconDataURL: assets?.images.browser ?? "",
          id: "demo-arc",
          name: `Arc · ${text().importSample}`,
          needsFullDiskAccess: false,
          profiles: [
            {
              extensions: [],
              id: "personal",
              kinds: ["bookmarks", "tabs"],
              name: text().personal,
            },
            {
              extensions: [],
              id: "work",
              kinds: ["bookmarks", "tabs"],
              name: text().work,
            },
          ],
        },
      ];
      emit("importSourcesLoaded", { sources: importSources });
    },
  };

  const switchTab = ({ id }: BridgeCommandPayloadMap["switchTab"]) => {
    const tab = world.tabs.find((candidate) => candidate.id === id);

    if (!tab) {
      return;
    }

    select(tab);
    publish();
  };

  const go = (direction: number) => {
    const tab = activeTab();
    const past = tab && history.get(tab.id);

    if (!tab || !past) {
      return;
    }

    past.index = Math.max(
      0,
      Math.min(past.urls.length - 1, past.index + direction)
    );
    tab.url = past.urls[past.index];
    preferences.navigated(tab.url);
    tab.title = tab.url ? titleFor(tab.url) : text().newTab;
    tab.faviconDominantColor = samplePageColor(tab.url);
    tab.faviconDataURL = sampleFavicon(tab.url, assets);
    tab.canGoBack = past.index > 0;
    tab.canGoForward = past.index < past.urls.length - 1;
    publish();
  };

  const separateSplit = (id: string) => {
    const folder = world.folders.find(
      (candidate) => candidate.id === id && candidate.isSplit
    );

    if (folder) {
      const parent =
        world.treeItems.find((item) => item.itemId === id)?.parentFolderId ??
        null;

      for (const item of world.treeItems) {
        if (item.parentFolderId === id) {
          item.parentFolderId = parent;
        }
      }

      for (const tab of world.tabs) {
        if (tab.groupId === id) {
          tab.groupId = undefined;
        }
      }

      world.folders = world.folders.filter((candidate) => candidate.id !== id);
      world.treeItems = world.treeItems.filter((item) => item.itemId !== id);
    }

    splitIds = [];
    publish();
  };

  const splitContainer = (first: DemoTab, section: "pinned" | "unpinned") => {
    const firstItem = world.treeItems.find((item) => item.itemId === first.id);

    if (!firstItem) {
      return;
    }

    let folder = splitFolderFor(first.id);

    if (!folder) {
      const id = addFolder("");
      folder = world.folders.find((candidate) => candidate.id === id);
      const item = world.treeItems.find((candidate) => candidate.itemId === id);

      const anchor =
        world.treeItems.find(
          (candidate) => candidate.itemId === firstItem.parentFolderId
        ) ?? firstItem;

      if (item) {
        Object.assign(item, {
          section,
          sortOrder: anchor.sortOrder + (firstItem.parentFolderId ? 0.01 : 0),
        });
      }
    }

    return folder;
  };

  const normalizeSplit = (
    folderId: string,
    ids: string[],
    section: "pinned" | "unpinned"
  ) => {
    for (const [index, id] of ids.entries()) {
      const tab = world.tabs.find((candidate) => candidate.id === id);
      const item = world.treeItems.find((candidate) => candidate.itemId === id);

      if (tab) {
        tab.isPinned = section === "pinned";
        tab.isBookmarked = false;
        tab.groupId = folderId;

        syncHome(tab);
      }

      if (item) {
        Object.assign(item, {
          parentFolderId: folderId,
          section,
          sortOrder: index,
        });
      }
    }
  };

  const swapExistingPanes = (
    first: DemoTab,
    other: DemoTab,
    side: SplitDropSide
  ) => {
    const existing = splitFolderFor(first.id);

    if (
      side === "replace" &&
      existing?.splitLayout &&
      splitFrames(existing.splitLayout).some((pane) => pane.tabId === other.id)
    ) {
      existing.splitLayout = swapPanes(
        existing.splitLayout,
        first.id,
        other.id
      );
      const ids = splitFrames(existing.splitLayout).map((pane) => pane.tabId);
      normalizeSplit(existing.id, ids, first.isPinned ? "pinned" : "unpinned");
      select(other);
      publish();

      return true;
    }

    return false;
  };

  const splitFull = (id: string) => {
    const layout = splitFolderFor(id)?.splitLayout;

    return Boolean(layout && splitFrames(layout).length >= 4);
  };

  const applySplit = (first: DemoTab, other: DemoTab, side: SplitDropSide) => {
    const existing = splitFolderFor(first.id);

    if (swapExistingPanes(first, other, side)) {
      return true;
    }

    const vertical = side === "top" || side === "bottom";
    const before = side === "left" || side === "top";

    if (
      existing?.splitLayout &&
      splitFrames(existing.splitLayout).length >= 4 &&
      !splitFrames(existing.splitLayout).some(
        (pane) => pane.tabId === other.id
      ) &&
      side !== "replace"
    ) {
      return;
    }

    const section = first.isPinned ? "pinned" : "unpinned";
    const folder = splitContainer(first, section);

    if (!folder) {
      return;
    }

    const old = splitFolderFor(other.id);

    if (old && old.id !== folder.id) {
      removeFromSplit(other.id);
    }

    const layout: BridgeSplitLayout = removePane(
      folder.splitLayout ?? { tabId: first.id },
      other.id
    ) ?? { tabId: first.id };

    if (side === "replace") {
      const firstItem = world.treeItems.find(
        (item) => item.itemId === first.id
      );

      if (firstItem) {
        firstItem.parentFolderId = null;
      }

      first.groupId = undefined;
    }

    folder.isSplit = true;
    folder.color = "#5865f2";
    folder.splitLayout = insertPane(
      layout,
      first.id,
      other.id,
      vertical,
      before,
      side === "replace"
    );
    const ids = splitFrames(folder.splitLayout).map((pane) => pane.tabId);

    normalizeSplit(folder.id, ids, section);

    select(other);
    splitIds = ids;
    splitArrangement = vertical ? "vertical" : "horizontal";
    publish();

    return true;
  };

  const openSplit = (
    otherId?: string,
    url?: string,
    side: SplitDropSide = "right",
    targetId = world.activeTabId
  ) => {
    let first = world.tabs.find((tab) => tab.id === targetId);

    if (!first || lockedFolderFor(first.id)) {
      return;
    }

    if (!otherId && splitFull(first.id)) {
      return;
    }

    if (url && !address(url)) {
      return;
    }

    if (first.isBookmarked) {
      first = addTab(first.url, first.title);
    }

    const other = otherId
      ? world.tabs.find((tab) => tab.id === otherId)
      : addTab(url ?? "");

    if (
      !other ||
      other.id === first.id ||
      other.isBookmarked ||
      lockedFolderFor(other.id) ||
      other.spaceId !== first.spaceId
    ) {
      return;
    }

    const opened = applySplit(first, other, side);

    if (opened && !otherId && !url) {
      emit("openCommandBar", {});
    }
  };

  const publishExtensions = (profileId = activeProfileId()) => {
    const extensions = extensionsFor(profileId);

    if (profileId === activeProfileId()) {
      emit("extensionsChanged", {
        extensions,
        ids: extensions.map((extension) => extension.id),
      });
    }

    emit("profileExtensionsLoaded", { extensions, live: true, profileId });
  };

  const changeExtension = (
    id: string,
    action: "enable" | "disable" | "uninstall",
    profileId = activeProfileId()
  ) => {
    const extensions = extensionsFor(profileId);
    const extension = extensions.find((candidate) => candidate.id === id);

    if (!extension) {
      return;
    }

    if (action === "uninstall") {
      extensions.splice(extensions.indexOf(extension), 1);
    } else {
      extension.isEnabled = action === "enable";
    }

    publishExtensions(profileId);
    emit("extensionActionCompleted", { action, id, success: true });
    onChange?.();
  };

  const updateExtension = (
    id: string,
    update: Partial<BridgeExtensionSnapshot>,
    profileId = activeProfileId()
  ) => {
    const extension = extensionsFor(profileId).find(
      (candidate) => candidate.id === id
    );

    if (extension) {
      Object.assign(extension, update);
      publishExtensions(profileId);
      onChange?.();
    }
  };

  const stopAgents = () => {
    agentGeneration += 1;

    for (const listener of stopListeners) {
      listener();
    }

    for (const approval of agentApprovals.values()) {
      approval.settle(false);
    }

    agentSessionActive = false;
    agentBusy = false;
    agentConnected = false;
    agentControl = null;
    publishAgentActivity();
    onChange?.();
  };

  const duplicateTab = (id: string) => {
    const tab = world.tabs.find((candidate) => candidate.id === id);

    if (!tab || !tab.url || lockedFolderFor(id)) {
      return;
    }

    world.activeSpaceId = tab.spaceId;
    const original = world.treeItems.find((item) => item.itemId === id);

    const parent = world.folders.find(
      (folder) => folder.id === original?.parentFolderId
    );

    const copy = addTab(tab.url, tab.title);
    const copied = world.treeItems.find((item) => item.itemId === copy.id);

    if (
      copied &&
      original &&
      !tab.isPinned &&
      !tab.isBookmarked &&
      !parent?.isSplit
    ) {
      copied.parentFolderId = original.parentFolderId;
      copied.sortOrder = original.sortOrder + 0.01;
    }

    publish();
  };

  const toggleTabPinned = (id: string) => {
    const tab = world.tabs.find((candidate) => candidate.id === id);

    if (!tab) {
      return;
    }

    changeSection(id, tab.isPinned ? "unpinned" : "pinned");
    publish(undefined, [tab.spaceId]);
  };

  const closeOtherTabs = (id: string) => {
    const tab = world.tabs.find((candidate) => candidate.id === id);

    if (!tab || lockedFolderFor(id)) {
      return;
    }

    for (const other of tabsIn(tab.spaceId)) {
      if (
        other.id !== id &&
        !other.isPinned &&
        !other.isBookmarked &&
        !lockedFolderFor(other.id)
      ) {
        closeTab(other.id);
      }
    }

    publish(undefined, [tab.spaceId]);
  };

  const createFolderFromTab = (id: string) => {
    const tab = world.tabs.find((candidate) => candidate.id === id);
    const item = world.treeItems.find((candidate) => candidate.itemId === id);

    if (!tab || !item || lockedFolderFor(id)) {
      return;
    }

    const current = world.activeSpaceId;
    world.activeSpaceId = tab.spaceId;
    const fromSplit = Boolean(splitFolderFor(id));

    if (fromSplit) {
      removeFromSplit(id);
    }

    const folderId = addFolder();

    const folderItem = world.treeItems.find(
      (candidate) => candidate.itemId === folderId
    );

    if (folderItem) {
      Object.assign(folderItem, {
        parentFolderId:
          !fromSplit && parentFolders(id).length < 5
            ? item.parentFolderId
            : null,
        section: item.section,
        sortOrder: item.sortOrder,
      });
    }

    item.parentFolderId = folderId;
    tab.groupId = undefined;
    world.activeSpaceId = current;
    publish(undefined, [tab.spaceId]);
  };

  const createSubfolder = (id: string) => {
    const parent = world.folders.find((candidate) => candidate.id === id);

    if (
      !parent ||
      parent.isSplit ||
      lockedItem(id) ||
      parentFolders(id).length >= 4
    ) {
      return;
    }

    const current = world.activeSpaceId;
    world.activeSpaceId = parent.spaceId;
    const folderId = addFolder();

    const created = world.folders.find(
      (candidate) => candidate.id === folderId
    );

    if (created) {
      created.color = parent.color;
    }

    parent.isCollapsed = false;

    const folderItem = world.treeItems.find(
      (candidate) => candidate.itemId === folderId
    );

    const parentItem = world.treeItems.find(
      (candidate) => candidate.itemId === id
    );

    if (folderItem) {
      Object.assign(folderItem, {
        parentFolderId: id,
        section: parentItem?.section ?? "unpinned",
      });
    }

    world.activeSpaceId = current;
    publish(undefined, [parent.spaceId]);
    emit("editTabFolder", { id: folderId });
  };

  const openMenu = (
    kind: DemoMenu["kind"],
    position: {
      id?: string;
      x: number;
      y: number;
      height: number;
      spaceId?: string;
      pinned?: boolean;
      profileId?: string;
    }
  ) => {
    menu = {
      id: position.id ?? "",
      kind,
      pinned: position.pinned,
      profileId: position.profileId,
      spaceId: position.spaceId,
      x: position.x,
      y: position.y + position.height,
    };
    onChange?.();
  };

  const searchHistory = (query = "") =>
    emit("historyResults", {
      query,
      results: visited
        .toReversed()
        .filter(
          (tab) =>
            tab.url &&
            `${tab.title} ${tab.url}`
              .toLowerCase()
              .includes(query.toLowerCase())
        )
        .map(({ url, title }) => ({ title, url })),
    });

  const commands: DemoCommands = {
    agentControlResponse: ({ requestId, granted, alwaysAllowSite }) => {
      const pending = agentApprovals.get(requestId);

      if (
        pending &&
        granted &&
        alwaysAllowSite &&
        alwaysAllowSite === pending.site
      ) {
        let sites: string[] = [];

        try {
          const parsed: unknown = JSON.parse(
            settings.agentAlwaysAllowedSites ?? "[]"
          );

          if (Array.isArray(parsed)) {
            sites = parsed.filter(
              (site): site is string => typeof site === "string"
            );
          }
        } catch {
          /* Invalid settings have no remembered approvals. */
        }

        preferences.commands.setSetting?.({
          key: "agentAlwaysAllowedSites",
          value: JSON.stringify([...new Set([...sites, alwaysAllowSite])]),
        });
      }

      pending?.settle(granted);
    },
    beginTabFolderLockSetup: ({ id }) => {
      const folder = world.folders.find((candidate) => candidate.id === id);

      if (folder && !folder.isSplit && !folder.isLocked) {
        emit("beginFolderLockSetup", { biometricsAvailable: false, id });
      }
    },
    bookmarkTab: ({ id }) => {
      changeSection(id, "bookmarked");
      publish();
    },
    changeTabFolderPassword: ({ id }) => {
      const folder = world.folders.find((candidate) => candidate.id === id);

      if (folder?.lock && !folder.isLocked) {
        emit("beginFolderLockSetup", { biometricsAvailable: false, id });
      }
    },
    checkExtensionUpdates: () => {
      const extensions = extensionsFor();
      emit("extensionsChanged", {
        extensions,
        ids: extensions.map((extension) => extension.id),
        updateCheck: {
          available: 0,
          checking: false,
          failed: 0,
          lastCheck: Date.now() / 1000,
          updated: 0,
        },
      });
      showNotice(text().extensionInfo);
    },
    clearArchivedTabs: () => {
      for (let index = archived.length - 1; index >= 0; index -= 1) {
        if (archived[index].spaceId === world.activeSpaceId) {
          archived.splice(index, 1);
        }
      }

      publishArchive();
    },
    clearUnpinnedTabs: () => {
      const roots = world.treeItems
        .filter(
          (item) =>
            item.spaceId === world.activeSpaceId &&
            item.section === "unpinned" &&
            !item.parentFolderId
        )
        .toSorted((first, second) => first.sortOrder - second.sortOrder);

      const archivedIds: string[] = [];
      let title = "";

      for (const [index, item] of roots.entries()) {
        const tab =
          item.kind === "tab"
            ? world.tabs.find((candidate) => candidate.id === item.itemId)
            : undefined;

        if (
          !tab?.url ||
          (tab.kind && tab.kind !== "web") ||
          tab.id === world.activeTabId ||
          splitIds.includes(tab.id) ||
          tab.isAudioPlaying ||
          tab.isCameraActive ||
          tab.isMicrophoneActive ||
          tab.isScreenSharing ||
          agentOwned.has(tab.id)
        ) {
          continue;
        }

        const entry = {
          archivedAt: Date.now(),
          id: idFor("archive"),
          index,
          spaceId: tab.spaceId,
          title: tab.customTitle || tab.title,
          url: tab.url,
        };

        archived.push(entry);
        archivedIds.push(entry.id);
        ({ title } = entry);
        closeTab(tab.id, false);
      }

      if (archivedIds.length) {
        emit("tabClosedUndoable", {
          archivedIds,
          count: archivedIds.length,
          title,
        });
        publishArchive();
        publish();
      }
    },
    closeImport: () => {
      importSources = [];
    },
    closeSplitView: () =>
      separateSplit(splitFolderFor(world.activeTabId)?.id ?? world.activeTabId),
    closeTab: ({ id }) => {
      const spaceId = world.tabs.find((tab) => tab.id === id)?.spaceId;
      closeTab(id);
      publish(undefined, [spaceId ?? world.activeSpaceId]);
    },
    commitSidebarDrop: (payload) => {
      drop(payload);
      publish();
    },
    connectAgentClient: ({ client }) => {
      if (client === "codex") {
        agentAuthorized = true;
        replies.getAgentClients?.();
      }

      emit("settingsActionCompleted", {
        action: "connectAgentClient",
        level: "info",
        message: client === "codex" ? text().agentDemo : text().sampleOnly,
      });
    },
    createProfile: ({ name, color }) => {
      addProfile(name, color);
      publish();
    },
    createSpace: (payload) => {
      const space = {
        archiveAfterHours: 12,
        color: payload.color || "#7868d8",
        colorMode: payload.colorMode ?? "fixed",
        icon: payload.icon || (payload.name || text().newSpace)[0],
        id: idFor("space"),
        isPrivate: payload.isPrivate === true,
        name: payload.name || text().newSpace,
        profileId:
          requestedProfile(payload) ||
          world.spaces.find((candidate) => candidate.id === world.activeSpaceId)
            ?.profileId ||
          world.profiles.find((profile) => profile.isDefault)?.id ||
          world.profiles[0].id,
        sortOrder: world.spaces.length,
      };

      world.spaces.push(space);
      world.activeSpaceId = space.id;
      addTab();
      emit("spaceCreated", space);
      publish();
    },
    createTab: ({ url = "" }) => {
      const normalized = address(url);

      if (normalized === null) {
        return;
      }

      addTab(normalized);

      if (!normalized) {
        emit("openCommandBar", { newTab: true });
      }

      publish();
    },
    deleteProfile: ({ id, moveTo }) => {
      const profile = world.profiles.find((candidate) => candidate.id === id);

      const targets = world.profiles.filter(
        (candidate) => candidate.id !== id && candidate.id !== "profile-agents"
      );

      const target = moveTo
        ? targets.find((candidate) => candidate.id === moveTo)
        : (targets.find((candidate) => candidate.isDefault) ?? targets[0]);

      if (!profile || id === "profile-agents" || !target) {
        return;
      }

      for (const space of world.spaces.filter(
        (candidate) => candidate.profileId === id
      )) {
        space.profileId =
          space.id === "playground-agents" ? "profile-agents" : target.id;
        emit("spaceUpdated", space);
      }

      if (profile.isDefault) {
        target.isDefault = true;
        emit("profileUpdated", target);
      }

      world.profiles = world.profiles.filter(
        (candidate) => candidate.id !== id
      );
      emit("profileDeleted", { id });
      publish();
    },
    deleteSpace: ({ id }) => {
      if (world.spaces.length < 2) {
        return;
      }

      world.spaces = world.spaces.filter((space) => space.id !== id);
      world.tabs = world.tabs.filter((tab) => tab.spaceId !== id);
      world.treeItems = world.treeItems.filter((item) => item.spaceId !== id);

      for (const folder of world.folders.filter(
        (candidate) => candidate.spaceId === id
      )) {
        folderPasswords.delete(folder.id);
      }

      world.folders = world.folders.filter((folder) => folder.spaceId !== id);

      for (let index = archived.length - 1; index >= 0; index -= 1) {
        if (archived[index].spaceId === id) {
          archived.splice(index, 1);
        }
      }

      if (world.activeSpaceId === id) {
        world.activeSpaceId = world.spaces[0].id;
      }

      emit("spaceDeleted", {
        activeSpaceId: world.activeSpaceId,
        id,
        spaces: world.spaces,
      });
      publish();
    },
    deleteTabFolder: ({ id }) => {
      if (lockedItem(id)) {
        return;
      }

      const folder = world.folders.find((candidate) => candidate.id === id);

      if (folder?.isSplit) {
        separateSplit(id);

        return;
      }

      const descendants = new Set(
        world.treeItems
          .filter(
            (item) =>
              item.itemId === id || parentFolders(item.itemId).includes(id)
          )
          .map((item) => item.itemId)
      );

      // A protected descendant must be unlocked before deleting its containing folder.
      if ([...descendants].some((childId) => lockedItem(childId))) {
        return;
      }

      for (const tab of world.tabs.filter((candidate) =>
        descendants.has(candidate.id)
      )) {
        tab.isPinned = false;
        tab.isBookmarked = false;
        tab.isClosed = false;
        closeTab(tab.id, false);
      }

      for (const childId of descendants) {
        folderPasswords.delete(childId);
      }

      world.folders = world.folders.filter(
        (candidate) => !descendants.has(candidate.id)
      );
      world.treeItems = world.treeItems.filter(
        (item) => !descendants.has(item.itemId)
      );
      publish();
    },
    disableExtension: ({ id, profileId }) =>
      changeExtension(id, "disable", profileId),
    duplicateActiveTab: () => duplicateTab(world.activeTabId),
    enableExtension: ({ id, profileId }) =>
      changeExtension(id, "enable", profileId),
    getProfileExtensions: ({ profileId }) =>
      emit("profileExtensionsLoaded", {
        extensions: extensionsFor(profileId),
        live: true,
        profileId,
      }),
    getRecentHistory: () => searchHistory(),
    goBack: () => go(-1),
    goForward: () => go(1),
    installExtension: ({ path }) => {
      const id =
        path.match(/\/(?<id>[a-p]{32})(?:\?.*)?$/u)?.groups?.id ?? path;

      emit("extensionActionCompleted", {
        action: "install",
        error: text().extensionInfo,
        id,
        success: false,
      });
    },
    loadArchivedTabs: publishArchive,
    // The demo's visits all happened today: one batch, nothing older.
    loadHistoryPage: ({
      before,
      host,
      openedFrom,
      period,
      query,
      requestId,
    }) => {
      const dayStart = new Date().setHours(0, 0, 0, 0);

      const rows =
        before || openedFrom || period === "yesterday" || period === "older"
          ? []
          : visited
              .toReversed()
              .filter((page) =>
                `${page.title} ${page.url}`
                  .toLowerCase()
                  .includes(query.toLowerCase())
              )
              .map((page) => ({
                dayStart,
                host: new URL(page.url).host.replace(/^www\./u, ""),
                lastVisitAt: page.visitedAt,
                pageId: page.id,
                title: page.title,
                url: page.url,
                visits: 1,
              }))
              .filter((row) => !host || row.host === host);

      emit("historyPage", { favicons: {}, requestId, rows });
    },
    loadHistorySidebar: () =>
      emit("historySidebar", {
        last7Days: visited.length,
        sites: [],
        terminals: [],
        today: visited.length,
        yesterday: 0,
      }),
    lockTabFolder: ({ id }) => lockFolder(id),
    moveSpace: ({ id, toIndex }) => {
      const index = world.spaces.findIndex((space) => space.id === id);

      if (index === -1) {
        return;
      }

      world.spaces.splice(toIndex, 0, ...world.spaces.splice(index, 1));

      for (const [sortOrder, space] of world.spaces.entries()) {
        space.sortOrder = sortOrder;
      }

      emit("spacesReordered", { spaces: world.spaces });
      publish();
    },
    moveTabToSpace: ({ tabId, spaceId }) => {
      const tab = world.tabs.find((candidate) => candidate.id === tabId);
      const target = world.spaces.find((space) => space.id === spaceId);

      const item = world.treeItems.find(
        (candidate) => candidate.itemId === tabId
      );

      if (
        !tab ||
        !target ||
        target.id === "playground-agents" ||
        !item ||
        lockedFolderFor(tabId)
      ) {
        return;
      }

      const sourceId = tab.spaceId;
      removeFromSplit(tab.id);
      tab.groupId = undefined;
      tab.spaceId = target.id;
      Object.assign(item, {
        parentFolderId: null,
        sortOrder: world.treeItems.length,
        spaceId: target.id,
      });

      if (selections.get(sourceId) === tab.id) {
        selections.set(
          sourceId,
          tabsIn(sourceId).find((candidate) => !lockedFolderFor(candidate.id))
            ?.id ?? ""
        );
      }

      selections.set(target.id, tab.id);

      if (!selections.get(sourceId)) {
        const current = world.activeSpaceId;
        world.activeSpaceId = sourceId;
        addTab();
        world.activeSpaceId = current;
      }

      publish(undefined, [sourceId, target.id]);
    },
    muteTab: ({ id }) => {
      const tab = world.tabs.find((candidate) => candidate.id === id);

      if (tab && tab.kind !== "terminal" && !lockedFolderFor(id)) {
        tab.isMuted = true;
        publish();
      }
    },
    navigate: ({ url }) => {
      navigate(url);
      emit("closeCommandBarAfterNavigation", {});
      publish();
    },
    newSplitView: () => openSplit(),
    newTerminal: () => {
      if (settings.terminalEnabled === "false") {
        showNotice(text().terminalDisabled);

        return;
      }

      addTab("", "~/Projects/lilo", "terminal");
      publish();
    },
    openExtensionPopup: () => showNotice(text().extensionInfo),
    removeTabFolderLock: ({ id }) => {
      const folder = world.folders.find((candidate) => candidate.id === id);

      if (folder?.lock && !folder.isLocked) {
        folderPasswords.delete(id);
        folder.lock = null;
        publish(undefined, [folder.spaceId]);
      }
    },
    renameTab: ({ id, title }) => {
      const tab = world.tabs.find((candidate) => candidate.id === id);

      if (tab && !lockedFolderFor(id)) {
        tab.customTitle = title.trim();
        publish();
      }
    },
    requestTabPreview: ({ tabId }) => emit("tabPreviewReady", { tabId }),
    restoreArchivedTabs: ({ ids }) => {
      const entries = archived
        .filter(
          (entry) =>
            ids.includes(entry.id) &&
            world.spaces.some((space) => space.id === entry.spaceId)
        )
        .toSorted((first, second) => first.index - second.index);

      const [first] = entries;

      if (!first) {
        return;
      }

      const { spaceId } = first;

      const previous = world.tabs.find(
        (tab) => tab.id === selections.get(spaceId)
      );

      world.activeSpaceId = spaceId;

      const restoring = entries.filter((entry) => entry.spaceId === spaceId);

      for (const entry of restoring) {
        const tab = addTab(entry.url, entry.title);

        const item = world.treeItems.find(
          (candidate) => candidate.itemId === tab.id
        );

        if (item) {
          const siblings = world.treeItems
            .filter(
              (candidate) =>
                candidate !== item &&
                candidate.spaceId === spaceId &&
                candidate.section === "unpinned" &&
                !candidate.parentFolderId
            )
            .toSorted((left, right) => left.sortOrder - right.sortOrder);

          siblings.splice(entry.index, 0, item);

          for (const [index, sibling] of siblings.entries()) {
            sibling.sortOrder = index;
          }
        }

        archived.splice(archived.indexOf(entry), 1);
      }

      if (restoring.length > 1 && previous) {
        select(previous);
      }

      publishArchive();
      publish();
    },
    restoreClosedTab: () => {
      const restored = closed.pop();

      if (
        !restored ||
        !world.spaces.some((space) => space.id === restored.tab.spaceId)
      ) {
        return;
      }

      const existing = world.tabs.find((tab) => tab.id === restored.tab.id);

      if (!existing) {
        world.tabs.splice(restored.index, 0, restored.tab);
        world.treeItems.push(makeTreeItem(restored.tab, restored.index));
      }

      select(existing ?? restored.tab);
      publish();
    },
    returnTabHome: ({ id }) => {
      const tab = world.tabs.find((candidate) => candidate.id === id);
      const home = tabHomes.get(id);

      if (tab && home && !lockedFolderFor(id)) {
        navigate(home, tab);
        publish();
      }
    },
    revealTerminal: ({ tabId }) => switchTab({ id: tabId }),
    revokeAgentClient: () => {
      agentAuthorized = false;
      stopAgents();
      replies.getAgentClients?.();
    },
    runImport: ({ selections: chosen }) => {
      const summary: ImportSummaryItem[] = [];
      const changedSpaces = new Set<string>();

      const currentSpace = world.spaces.find(
        (space) => space.id === world.activeSpaceId
      );

      let first = true;

      for (const selection of chosen) {
        const source = importSources.find(
          (candidate) => candidate.id === selection.sourceId
        );

        const profile = source?.profiles.find(
          (candidate) => candidate.id === selection.profileId
        );

        if (!source || !profile || !currentSpace) {
          continue;
        }

        const kinds = profile.kinds.filter((kind) =>
          selection.kinds.includes(kind)
        );

        if (!kinds.length) {
          continue;
        }

        let target = currentSpace;

        if (!first) {
          const name = `${source.name} ${profile.name}`;

          const targetProfile =
            world.profiles.find((candidate) => candidate.name === name) ??
            addProfile(name);

          const existing = world.spaces.find(
            (space) =>
              space.profileId === targetProfile.id &&
              space.name === profile.name
          );

          target = existing ?? {
            archiveAfterHours: 12,
            color: targetProfile.color,
            icon: profile.name[0],
            id: idFor("space"),
            isPrivate: false,
            name: profile.name,
            profileId: targetProfile.id,
            sortOrder: world.spaces.length,
          };

          if (!existing) {
            world.spaces.push(target);
            emit("spaceCreated", target);
          }
        }

        first = false;

        for (const kind of kinds) {
          const pages =
            kind === "tabs"
              ? [
                  {
                    title: text().notes,
                    url: `https://notes.example.com/imported/${profile.id}`,
                  },
                  {
                    title: text().board,
                    url: `https://tracker.example.com/imported/${profile.id}`,
                  },
                ]
              : [
                  {
                    title: text().article,
                    url: `https://slowtravel.example.com/imported/${profile.id}`,
                  },
                  {
                    title: "Alexays / Lilo",
                    url: `https://github.com/Alexays/Lilo?imported=${profile.id}`,
                  },
                ];

          const progress = {
            kind,
            profileId: profile.id,
            sourceId: source.id,
            total: pages.length,
          };

          let imported = 0;
          emit("importProgress", { ...progress, done: 0 });

          for (const page of pages) {
            if (
              world.tabs.some(
                (tab) => tab.spaceId === target.id && tab.url === page.url
              )
            ) {
              continue;
            }

            const tab = makeTab(
              idFor("tab"),
              target.id,
              page.title,
              page.url,
              assets
            );

            tab.isPinned = kind === "bookmarks";
            world.tabs.push(tab);
            world.treeItems.push(makeTreeItem(tab, world.treeItems.length));

            if (!selections.has(target.id)) {
              selections.set(target.id, tab.id);
            }

            imported += 1;
            changedSpaces.add(target.id);
          }

          summary.push({
            imported,
            kind,
            profileId: profile.id,
            sourceId: source.id,
          });
          emit("importProgress", { ...progress, done: pages.length });
        }
      }

      importSources = [];

      if (changedSpaces.size) {
        publish(undefined, [...changedSpaces]);
      }

      emit("importFinished", { summary });
    },
    searchHistory: ({ query }) => searchHistory(query),
    searchSuggestions: ({ query }) =>
      emit("searchSuggestions", { query, suggestions: [] }),
    setExtensionPrivateAccess: ({ id, allowed, profileId }) =>
      updateExtension(id, { allowsPrivateAccess: allowed }, profileId),
    setExtensionSiteAccess: ({ id, hosts, profileId }) =>
      updateExtension(id, { siteAccess: hosts }, profileId),
    setExtensionUserScripts: ({ id, allowed, profileId }) =>
      updateExtension(id, { allowsUserScripts: allowed }, profileId),
    setSetting: ({ key, value }) => {
      const previous = settings[key];
      preferences.commands.setSetting?.({ key, value });

      if (previous === value) {
        return;
      }

      if (key === "tabPosition" || key === "addressPlacement") {
        emit("tabLayoutChanged", tabLayout());
      }

      if (key === "agentControlEnabled" && value !== "true") {
        stopAgents();
      }
    },
    setTabFolderBiometrics: ({ id, allowsBiometrics }) => {
      const folder = world.folders.find((candidate) => candidate.id === id);

      if (!folder?.lock || folder.isLocked) {
        return;
      }

      if (allowsBiometrics) {
        emit("folderPasswordRejected", { id });
      } else {
        folder.lock.allowsBiometrics = false;
        publish(undefined, [folder.spaceId]);
      }
    },
    setTabFolderCollapsed: ({ id, collapsed }) => {
      const folder = world.folders.find((candidate) => candidate.id === id);

      if (folder && !lockedItem(id)) {
        folder.isCollapsed = collapsed;
        publish();
      }
    },
    setTabFolderLock: ({ id, password }) => {
      const folder = world.folders.find((candidate) => candidate.id === id);

      if (!folder || folder.isSplit || folder.isLocked || !password) {
        return;
      }

      folderPasswords.set(id, password);
      folder.lock = { allowsBiometrics: false, biometricsAvailable: false };
      lockFolder(id);
    },
    setTabHomeURL: ({ id, url }) => {
      const tab = world.tabs.find((candidate) => candidate.id === id);
      const normalized = address(url);

      if (
        !tab ||
        !(tab.isPinned || tab.isBookmarked) ||
        !normalized ||
        lockedFolderFor(id)
      ) {
        return;
      }

      const wasHome = tab.url === (tabHomes.get(id) ?? tab.url);
      tabHomes.set(id, normalized);
      homeTitles.set(id, titleFor(normalized));

      if (wasHome) {
        navigate(normalized, tab);
      }

      publish();
    },
    setWallpaperColorWatch: ({ enabled }) => {
      if (enabled) {
        emit("wallpaperColorChanged", { color: "" });
      }
    },
    showExtensionContextMenu: (position) => openMenu("extension", position),
    showFindBar: () => emit("toggleFindBar", {}),
    showFolderContextMenu: (position) => openMenu("folder", position),
    showSidebarContextMenu: (position) => openMenu("sidebar", position),
    showTabContextMenu: (position) => openMenu("tab", position),
    sidebarResized: ({ width }) => {
      world.sidebarWidth = Math.max(200, Math.min(480, width));
      onChange?.();
    },
    splitTab: ({ tabId, side, targetTabId }) =>
      openSplit(tabId, undefined, side, targetTabId),
    splitURL: ({ url, side, targetTabId }) =>
      openSplit(undefined, url, side, targetTabId),
    switchSpace: ({ id, transitionId }) => {
      if (!world.spaces.some((space) => space.id === id)) {
        return;
      }

      world.activeSpaceId = id;
      splitIds = [];
      publish(transitionId);
      publishExtensions();
    },
    switchTab,
    switchToRecentTab: switchTab,
    terminalCompletions: ({ query }) =>
      emit("terminalCompletionResults", {
        closedTerminals: [],
        items: [],
        query,
        terminals: [],
      }),
    togglePinActiveTab: () => {
      const tab = activeTab();

      if (tab) {
        changeSection(tab.id, tab.isPinned ? "unpinned" : "pinned");
        publish();
      }
    },
    toggleSidebar: () => {
      world.sidebarVisible = !world.sidebarVisible;
      emit("sidebarVisibilityChanged", {
        visible: world.sidebarVisible,
        width: world.sidebarWidth,
      });
      onChange?.();
    },
    unbookmarkTab: ({ id }) => {
      changeSection(id, "unpinned");
      publish();
    },
    uninstallExtension: ({ id, profileId }) =>
      changeExtension(id, "uninstall", profileId),
    unlockTabFolder: ({ id, password, method }) => {
      const folder = world.folders.find((candidate) => candidate.id === id);

      if (!folder?.lock || !folder.isLocked) {
        return;
      }

      if (method || folderPasswords.get(id) !== password) {
        emit("folderUnlockFailed", { id });

        return;
      }

      folder.isLocked = false;
      publish(undefined, [folder.spaceId]);
    },
    unmuteTab: ({ id }) => {
      const tab = world.tabs.find((candidate) => candidate.id === id);

      if (tab && tab.kind !== "terminal" && !lockedFolderFor(id)) {
        tab.isMuted = false;
        publish();
      }
    },
    unpinTab: ({ id }) => {
      changeSection(id, "unpinned");
      publish();
    },
    updateExtension: ({ id }) =>
      emit("extensionActionCompleted", {
        action: "update",
        error: text().extensionInfo,
        id,
        success: false,
      }),
    updateProfile: ({ id, name, color }) => {
      const profile = world.profiles.find((candidate) => candidate.id === id);

      if (!profile) {
        return;
      }

      if (name !== undefined) {
        profile.name = name;
      }

      if (color !== undefined) {
        profile.color = color;
      }

      emit("profileUpdated", profile);
      publish();
    },
    updateSpace: (payload) => {
      const { id, name, icon, color, colorMode, archiveAfterHours } = payload;

      const space = world.spaces.find((candidate) => candidate.id === id);

      if (!space) {
        return;
      }

      if (name !== undefined) {
        space.name = name;
      }

      if (icon !== undefined) {
        space.icon = icon;
      }

      if (color !== undefined) {
        space.color = color;
      }

      if (colorMode !== undefined) {
        space.colorMode = colorMode;
      }

      const profileId = requestedProfile(payload);

      if (profileId) {
        space.profileId = profileId;
      }

      if (archiveAfterHours !== undefined) {
        space.archiveAfterHours = archiveAfterHours;
      }

      emit("spaceUpdated", space);
      publish();
    },
    updateTabFolder: ({ id, name, color }) => {
      const folder = world.folders.find((candidate) => candidate.id === id);

      if (folder && !lockedItem(id)) {
        Object.assign(folder, { color, name });
        publish();
      }
    },
  };

  const passive = new Set<BridgeCommandName>([
    "getTabMemory",
    "reload",
    "stopLoading",
    "updateExtensionPopupAnchor",
    "updateWindowBackground",
    "ready",
    "requestWhatsNew",
    "initialStateApplied",
    "startupMark",
    "chromeVisualReady",
    "registerInteractiveZones",
    "removeInteractiveZone",
    "setSidebarCollapseLocked",
    "sidebarOverlayChanged",
    "startWindowDrag",
    "traceSpaceSwipe",
    "traceSpaceDnd",
    "dismissFind",
    "omniboxInputCancelled",
  ]);

  const dispatch = <K extends BridgeCommandName>(
    action: K,
    payload: BridgeCommandPayloadMap[K]
  ): void => {
    const handler = commands[action] ?? preferences.commands[action];

    if (handler) {
      handler(payload);

      return;
    }

    const reply = preferences.replies[action] ?? replies[action];

    if (reply) {
      reply();

      return;
    }

    if (passive.has(action)) {
      return;
    }

    emit("settingsActionCompleted", {
      action,
      level: "info",
      message: text().sampleOnly,
    });
    showNotice();
  };

  return {
    activeTab,
    agentGeneration: () => agentGeneration,
    agentTabs: () => structuredClone(agentTabs()),
    assets,
    clearNotice: () => {
      notice = "";
      onChange?.();
    },
    closeAgentTab,
    closeMenu: () => {
      menu = null;
      onChange?.();
    },
    closeOtherTabs,
    createAgentTab,
    createFolder: (name: string) => {
      const id = addFolder(name);
      publish();

      return id;
    },
    createFolderFromTab,
    createSubfolder,
    deleteFolderConfirmed: (id: string) => {
      if (lockedFolderFor(id)) {
        return;
      }

      for (const folder of world.folders) {
        if (folder.id === id || parentFolders(folder.id).includes(id)) {
          folder.isLocked = false;
        }
      }

      commands.deleteTabFolder?.({ id });
    },
    dispatch,
    duplicateTab,
    emit,
    faviconFor: (url: string) => sampleFavicon(url, assets),
    getTabHomeURL: (id: string) =>
      tabHomes.get(id) ?? world.tabs.find((tab) => tab.id === id)?.url ?? "",
    initialState,
    isAgentControlEnabled: () =>
      settings.agentControlEnabled === "true" && agentAuthorized,
    isAgentSessionActive: () => agentSessionActive,
    isDefaultShortcut: preferences.isDefaultShortcut,
    isItemLocked: (id: string) => Boolean(lockedItem(id)),
    moveToFolder: (id: string, folderId: string) => {
      const tab = world.tabs.find((candidate) => candidate.id === id);

      const folder = world.folders.find(
        (candidate) => candidate.id === folderId
      );

      const item = world.treeItems.find((candidate) => candidate.itemId === id);

      const parentItem = world.treeItems.find(
        (candidate) => candidate.itemId === folderId
      );

      if (
        !tab ||
        !item ||
        lockedItem(id) ||
        (folderId &&
          (!folder ||
            folder.spaceId !== tab.spaceId ||
            folder.isSplit ||
            lockedItem(folderId)))
      ) {
        return;
      }

      if (splitFolderFor(id)) {
        separateSplit(splitFolderFor(id)?.id ?? id);
      }

      const section = parentItem?.section ?? item.section;
      changeSection(id, section);
      item.parentFolderId = folderId || null;
      item.sortOrder = world.treeItems.length;
      publish();
    },
    nameAgentGroup,
    navigateAgentTab,
    navigateTab,
    navigated: preferences.navigated,
    newTerminalSplit: (direction: "horizontal" | "vertical") => {
      if (settings.terminalEnabled === "false") {
        showNotice(text().terminalDisabled);

        return;
      }

      const first = activeTab();

      if (first && splitFull(first.id)) {
        return;
      }

      const terminal = addTab("", "~/Projects/lilo", "terminal");

      if (first) {
        openSplit(
          terminal.id,
          undefined,
          direction === "vertical" ? "bottom" : "right",
          first.id
        );
      } else {
        publish();
      }
    },
    onStopAgents: (listener: () => void) => {
      stopListeners.add(listener);

      return () => stopListeners.delete(listener);
    },
    openBrowser,
    openHistoryItem: (id: string) => {
      const entry = visited.find((item) => item.id === id);

      if (!entry) {
        return;
      }

      addTab(entry.url, entry.title);
      publish();
    },
    openLinkTab: (url: string, background = false) => {
      const normalized = address(url);

      if (!normalized) {
        return;
      }

      const original = activeTab();
      const previousRecent = recent;
      addTab(normalized);

      if (background && original) {
        select(original);
        recent = previousRecent;
      }

      publish();
    },
    openPlayground,
    openPrivateSpace: () => {
      const existing = world.spaces.find(
        (space) => space.isPrivate && space.id !== "playground-agents"
      );

      if (existing) {
        world.activeSpaceId = existing.id;
        addTab();
        publish();
      } else {
        commands.createSpace?.({
          color: "#3f4656",
          icon: "P",
          isPrivate: true,
          name: nativeCopy(settings.locale === "fr" ? "fr" : "en")("Private"),
        });
      }

      emit("openCommandBar", { newTab: true });
    },
    openTabs: () =>
      orderedTabs().filter((tab) => !tab.isClosed && !lockedFolderFor(tab.id)),
    presentAgent,
    recentMenuItems: () => ({
      recentlyClosed: closed
        .toReversed()
        .flatMap(({ tab }) =>
          lockedFolderFor(tab.id)
            ? []
            : [{ id: tab.id, title: tab.customTitle || tab.title }]
        ),
      recentlyVisited: visited
        .toReversed()
        .map(({ id, title }) => ({ id, title })),
    }),
    recentTabRows: () =>
      world.tabs
        .filter((tab) => !tab.isClosed && !lockedFolderFor(tab.id))
        .toSorted(
          (first, second) => recentRank(first.id) - recentRank(second.id)
        )
        .map((tab): BridgeRecentTab => ({
          cwd: tab.cwd ?? "",
          faviconDataURL: tab.faviconDataURL ?? "",
          id: tab.id,
          kind: tab.kind === "terminal" ? "terminal" : "web",
          leftAt: 0,
          spaceName:
            world.spaces.find((space) => space.id === tab.spaceId)?.name ?? "",
          terminalCommand: tab.terminalCommand ?? "",
          terminalState: tab.terminalState ?? "",
          title: tab.customTitle || tab.title,
          url: tab.url,
        })),
    recordKeyboard: preferences.recordKeyboard,
    requestAgentApproval,
    restoreClosedTab: (id: string) => {
      const index = closed.findIndex((entry) => entry.tab.id === id);

      if (index === -1) {
        return;
      }

      closed.push(...closed.splice(index, 1));
      commands.restoreClosedTab?.({});
    },
    separateSplit,
    setAgentBusy,
    setAgentSession,
    shortcutAction: preferences.shortcutAction,
    shortcutKeys: preferences.shortcutKeys,
    showAgentTab,
    showNotice,
    snapshot,
    stopAgents,
    toggleSplitArrangement: (id: string) => {
      const folder = world.folders.find((candidate) => candidate.id === id);

      if (folder?.splitLayout && "vertical" in folder.splitLayout) {
        folder.splitLayout.vertical = !folder.splitLayout.vertical;
      }

      publish();
    },
    toggleTabPinned,
    zoomFor: preferences.zoomFor,
  };
};

export type DemoHost = ReturnType<typeof createDemoHost>;

export type DemoSnapshot = ReturnType<DemoHost["snapshot"]>;
