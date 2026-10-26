import type {
  BridgeInitialStatePayload,
  BridgeSpaceSnapshot,
  BridgeTabSnapshot,
  BridgeSidebarTreeItemSnapshot,
  BridgeTabFolderSnapshot,
  BridgeProfileSnapshot,
} from "../../../lilo-ui/src/lib/bridge/protocol";
import { demoMessages } from "../lib/i18n.ts";
import type { Locale } from "../lib/i18n.ts";
import { sampleFavicon } from "./assets.ts";
import type { DemoAssets } from "./assets.ts";

export type DemoLocale = Locale;

export const demoCopy = (locale: DemoLocale) => demoMessages[locale];

export type DemoTab = BridgeTabSnapshot & {
  spaceId: string;
};

export const pageNotes = new Map<string, string>();

export const pageProjects = new Map<
  string,
  { completed: boolean[]; update: string; published: boolean }
>();

const sampleColors = new Map([
  ["github.com", "#9d89cc"],
  ["notes.example.com", "#cba66f"],
  ["radio.example.com", "#b36a91"],
  ["slowtravel.example.com", "#7e9f87"],
  ["tracker.example.com", "#4e7bbf"],
]);

export const samplePageColor = (url: string) => {
  if (!URL.canParse(url)) {
    return;
  }

  return sampleColors.get(new URL(url).hostname) ?? "#7868d8";
};

interface DemoWorld extends BridgeInitialStatePayload {
  tabs: DemoTab[];
  spaces: BridgeSpaceSnapshot[];
  folders: BridgeTabFolderSnapshot[];
  profiles: BridgeProfileSnapshot[];
  activeSpaceId: string;
}

export const makeTab = (
  id: string,
  spaceId: string,
  title: string,
  url = "",
  assets?: DemoAssets
): DemoTab => ({
  canGoBack: false,
  canGoForward: false,
  faviconDataURL: sampleFavicon(url, assets),
  faviconDominantColor: samplePageColor(url),
  hasNavigationError: false,
  id,
  isAudioPlaying: false,
  isBookmarked: false,
  isCameraActive: false,
  isClosed: false,
  isLoading: false,
  isMicrophoneActive: false,
  isMicrophoneMuted: false,
  isMuted: false,
  isPinned: false,
  isScreenSharing: false,
  navigationErrorCode: 0,
  navigationErrorDescription: "",
  navigationErrorDomain: "",
  navigationErrorURL: "",
  progress: 1,
  spaceId,
  title,
  url,
});

export const makeTreeItem = (
  tab: DemoTab,
  sortOrder: number
): BridgeSidebarTreeItemSnapshot => {
  let section: BridgeSidebarTreeItemSnapshot["section"] = "unpinned";

  if (tab.isPinned) {
    section = "pinned";
  }

  if (tab.isBookmarked) {
    section = "bookmarked";
  }

  return {
    id: `item-${tab.id}`,
    itemId: tab.id,
    kind: "tab",
    parentFolderId: null,
    section,
    sortOrder,
    spaceId: tab.spaceId,
  };
};

export const sampleWorld = (
  locale: DemoLocale,
  assets?: DemoAssets
): DemoWorld => {
  const text = demoCopy(locale);

  const spaces: BridgeSpaceSnapshot[] = [
    {
      color: "#7868d8",
      icon: "🪻",
      id: "home",
      isPrivate: false,
      name: text.personal,
      profileId: "profile-personal",
      sortOrder: 0,
    },
    {
      color: "#4e7bbf",
      icon: "💼",
      id: "work",
      isPrivate: false,
      name: text.work,
      profileId: "profile-work",
      sortOrder: 1,
    },
    {
      color: "#b36a91",
      icon: "🎧",
      id: "music",
      isPrivate: false,
      name: text.music,
      profileId: "profile-personal",
      sortOrder: 2,
    },
  ];

  const tabs: DemoTab[] = [
    {
      ...makeTab(
        "lilo",
        "home",
        "Alexays / Lilo",
        "https://github.com/Alexays/Lilo"
      ),
      isPinned: true,
    },
    {
      ...makeTab(
        "travel",
        "home",
        text.article,
        "https://slowtravel.example.com/lisbon"
      ),
      isPinned: true,
    },
    makeTab("notes", "home", text.notes, "https://notes.example.com"),
    {
      ...makeTab(
        "board",
        "work",
        text.board,
        "https://tracker.example.com/project"
      ),
      isPinned: true,
    },
    makeTab("work-notes", "work", text.notes, "https://notes.example.com/work"),
    {
      ...makeTab("terminal", "work", "~/Projects/lilo"),
      customTitle: "~/Projects/lilo",
      cwd: "/Users/you/Projects/lilo",
      kind: "terminal",
      terminalState: "idle",
    },
    {
      ...makeTab(
        "playlist",
        "music",
        text.playlist,
        "https://radio.example.com/late-night"
      ),
      isPinned: true,
    },
  ];

  for (const tab of tabs) {
    tab.faviconDataURL = sampleFavicon(tab.url, assets);
  }

  const treeItems = tabs.map((tab, index) => ({
    ...makeTreeItem(tab, index),
    parentFolderId: tab.id === "travel" ? "trips" : null,
  }));

  treeItems.push({
    id: "item-trips",
    itemId: "trips",
    kind: "folder",
    parentFolderId: null,
    section: "pinned",
    sortOrder: 0.5,
    spaceId: "home",
  });

  return {
    activeSpaceId: "home",
    activeTabId: "lilo",
    folders: [
      {
        color: "#c68d54",
        id: "trips",
        isCollapsed: false,
        name: text.trips,
        spaceId: "home",
      },
    ],
    profiles: [
      {
        color: "#7868d8",
        id: "profile-personal",
        isDefault: true,
        name: text.personal,
      },
      {
        color: "#4e7bbf",
        id: "profile-work",
        isDefault: false,
        name: text.work,
      },
    ],
    sidebarVisible: true,
    sidebarWidth: 260,
    spaces,
    tabs,
    trafficLightsVisible: true,
    treeItems,
  } satisfies BridgeInitialStatePayload;
};
