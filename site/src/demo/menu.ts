import * as z from "zod/mini";

z.config({ jitless: true });

export interface DemoMenuRow {
  id: string;
  title: string;
  icon?: string;
  selected?: boolean;
}

export type DemoEditAction =
  | "undo"
  | "redo"
  | "cut"
  | "copy"
  | "paste"
  | "pasteMatchStyle"
  | "delete"
  | "selectAll";

export interface DemoMenuState {
  type: "lilo-demo:menu-state";
  supportedActions: string[];
  hasActiveTab: boolean;
  hasPageURL?: boolean;
  activeTabKind: "web" | "terminal" | null;
  sidebarVisible: boolean;
  sidebarLocked?: boolean;
  canGoBack: boolean;
  canGoForward: boolean;
  canReopenTab: boolean;
  canOpenAsTab?: boolean;
  canFindMatch?: boolean;
  isPinned: boolean;
  isBookmarked: boolean;
  isMuted: boolean;
  hasSplit: boolean;
  canSplit?: boolean;
  showDevelopMenu?: boolean;
  developerTools?: boolean;
  terminalEnabled?: boolean;
  editActions?: Partial<Record<DemoEditAction, boolean>>;
  shortcutKeys?: Record<string, string>;
  spaces?: DemoMenuRow[];
  tabs?: DemoMenuRow[];
  folders?: DemoMenuRow[];
  recentlyClosed?: DemoMenuRow[];
  recentlyVisited?: DemoMenuRow[];
  terminals?: DemoMenuRow[];
  extensions?: DemoMenuRow[];
}

export interface DemoMenuLabels {
  type: "lilo-demo:menu-labels";
  locale?: "en" | "fr";
  labels: Record<string, string>;
}

const menuRowSchema = z.object({
  icon: z.optional(z.string()),
  id: z.string(),
  selected: z.optional(z.boolean()),
  title: z.string(),
});

const menuMessageSchema = z.discriminatedUnion("type", [
  z.object({
    activeTabKind: z.nullable(z.enum(["web", "terminal"])),
    canFindMatch: z.optional(z.boolean()),
    canGoBack: z.boolean(),
    canGoForward: z.boolean(),
    canOpenAsTab: z.optional(z.boolean()),
    canReopenTab: z.boolean(),
    canSplit: z.optional(z.boolean()),
    developerTools: z.optional(z.boolean()),
    editActions: z.optional(z.record(z.string(), z.boolean())),
    extensions: z.optional(z.array(menuRowSchema)),
    folders: z.optional(z.array(menuRowSchema)),
    hasActiveTab: z.boolean(),
    hasPageURL: z.optional(z.boolean()),
    hasSplit: z.boolean(),
    isBookmarked: z.boolean(),
    isMuted: z.boolean(),
    isPinned: z.boolean(),
    recentlyClosed: z.optional(z.array(menuRowSchema)),
    recentlyVisited: z.optional(z.array(menuRowSchema)),
    shortcutKeys: z.optional(z.record(z.string(), z.string())),
    showDevelopMenu: z.optional(z.boolean()),
    sidebarLocked: z.optional(z.boolean()),
    sidebarVisible: z.boolean(),
    spaces: z.optional(z.array(menuRowSchema)),
    supportedActions: z.array(z.string()),
    tabs: z.optional(z.array(menuRowSchema)),
    terminalEnabled: z.optional(z.boolean()),
    terminals: z.optional(z.array(menuRowSchema)),
    type: z.literal("lilo-demo:menu-state"),
  }),
  z.object({
    labels: z.record(z.string(), z.string()),
    locale: z.optional(z.enum(["en", "fr"])),
    type: z.literal("lilo-demo:menu-labels"),
  }),
]);

export const parseMenuMessage = (
  event: Pick<MessageEvent, "data">
): DemoMenuState | DemoMenuLabels | null => {
  const result = menuMessageSchema.safeParse(event.data);

  return result.success ? result.data : null;
};

export type DemoMenuList =
  | "spaces"
  | "folders"
  | "moveSpaces"
  | "recentlyClosed"
  | "recentlyVisited"
  | "terminals"
  | "extensions";

export interface DemoMenuItem {
  label: string;
  action?: string;
  shortcutId?: string;
  keys?: string;
  macOnly?: boolean;
  alternate?: "option" | "shift";
  developerOnly?: boolean;
  children?: DemoMenuEntry[];
  dynamic?: DemoMenuList;
  emptyLabel?: string;
}

export type DemoMenuEntry =
  | DemoMenuItem
  | { separator: true; developerOnly?: boolean; terminalOnly?: boolean };

const separator = { separator: true } as const;

const command = (
  label: string,
  action: string,
  shortcutId?: string,
  keys?: string
): DemoMenuItem => ({ action, keys, label, shortcutId });

const mac = (
  label: string,
  shortcutId?: string,
  keys?: string
): DemoMenuItem => ({ keys, label, macOnly: true, shortcutId });

const submenu = (
  label: string,
  children: DemoMenuEntry[],
  dynamic?: DemoMenuList
): DemoMenuItem => ({ children, dynamic, label });

const live = (
  label: string,
  dynamic: DemoMenuList,
  empty: string
): DemoMenuItem => ({
  ...submenu(label, [{ label: empty }], dynamic),
  emptyLabel: empty,
});

// Order, labels, groups and default keys mirror App/MainMenu.swift and KeyboardShortcuts.swift.
export const demoMenus: DemoMenuItem[] = [
  submenu("Lilo", [
    mac("About Lilo"),
    mac("Check for Updates…"),
    separator,
    command("Settings…", "settings", "app.settings", "⌘,"),
    submenu("Extensions", [
      { dynamic: "extensions", label: "Extensions" },
      mac("Add Extension…"),
      separator,
      command("Manage Extensions", "extensions"),
      mac("Check for Extension Updates"),
    ]),
    separator,
    mac("Services"),
    separator,
    mac("Hide Lilo", "app.hide", "⌘H"),
    mac("Hide Others", "app.hideOthers", "⌥⌘H"),
    mac("Show All"),
    separator,
    mac("Quit Lilo", "app.quit", "⌘Q"),
  ]),
  submenu("File", [
    command("New Tab", "newTab", "tab.new", "⌘T"),
    mac("New Window", "window.new", "⌘N"),
    command("New Little Window", "newLittleWindow", "littleWindow.new", "⌥⌘N"),
    command("New Private Space", "newPrivateSpace", "space.newPrivate", "⇧⌘N"),
    { ...separator, terminalOnly: true },
    command("New Terminal Tab", "newTerminal", "terminal.newTab", "⌃`"),
    command(
      "New Terminal Beside",
      "newTerminalBeside",
      "terminal.newBeside",
      "⌘D"
    ),
    command(
      "New Terminal Below",
      "newTerminalBelow",
      "terminal.newBelow",
      "⇧⌘D"
    ),
    separator,
    command("Open Location…", "location", "location.open", "⌘L"),
    mac("Open File…", "file.open"),
    command("Open as Tab", "openAsTab", "page.openAsTab", "⌘O"),
    separator,
    command("Close Tab", "closeTab", "tab.close", "⌘W"),
    {
      ...command(
        "Close Other Tabs",
        "closeOtherTabs",
        "tab.closeOthers",
        "⌥⌘W"
      ),
      alternate: "option",
    },
    command("Close Window", "closeWindow", "window.close", "⇧⌘W"),
    separator,
    mac("Save Page As…", "page.save", "⌘S"),
    mac("Share…", "page.share"),
    mac("Create QR Code…", "page.qrCode"),
    submenu("Take Screenshot", [
      mac("Selected Area", "capture.area", "⇧⌘2"),
      mac("Visible Area", "capture.visible"),
      mac("Full Page", "capture.fullPage"),
    ]),
    mac("Print…", "page.print", "⌘P"),
  ]),
  submenu("Edit", [
    command("Undo", "undo", "edit.undo", "⌘Z"),
    command("Redo", "redo", "edit.redo", "⇧⌘Z"),
    separator,
    command("Cut", "cut", "edit.cut", "⌘X"),
    command("Copy", "copy", "edit.copy", "⌘C"),
    command("Copy Page URL", "copyURL", "page.copyURL", "⇧⌘C"),
    {
      ...command(
        "Copy Page Link as Markdown",
        "copyMarkdown",
        "page.copyMarkdown",
        "⌥⇧⌘C"
      ),
      alternate: "option",
    },
    command("Paste", "paste", "edit.paste", "⌘V"),
    command(
      "Paste and Match Style",
      "pasteMatchStyle",
      "edit.pasteMatchStyle",
      "⌥⇧⌘V"
    ),
    command("Delete", "delete"),
    command("Select All", "selectAll", "edit.selectAll", "⌘A"),
    separator,
    submenu("Find", [
      command("Find…", "find", "find.show", "⌘F"),
      command("Find Next", "findNext", "find.next", "⌘G"),
      command("Find Previous", "findPrevious", "find.previous", "⇧⌘G"),
    ]),
    submenu("Spelling and Grammar", [
      { ...mac("Show Spelling and Grammar"), keys: "⌘:" },
      mac("Check Document Now", "spelling.check", "⌘;"),
      separator,
      mac("Check Spelling While Typing"),
      mac("Check Grammar With Spelling"),
      mac("Correct Spelling Automatically"),
    ]),
    submenu("Substitutions", [
      mac("Show Substitutions"),
      separator,
      mac("Smart Quotes"),
      mac("Smart Dashes"),
      mac("Text Replacement"),
    ]),
    submenu("Transformations", [
      mac("Make Upper Case"),
      mac("Make Lower Case"),
      mac("Capitalize"),
    ]),
    submenu("Speech", [mac("Start Speaking"), mac("Stop Speaking")]),
  ]),
  submenu("View", [
    command("Hide Sidebar", "sidebar", "sidebar.toggle", "⇧⌘S"),
    command("Enter Full Screen", "fullscreen", "window.fullScreen", "⌃⌘F"),
    separator,
    command("Reload Page", "reload", "page.reload", "⌘R"),
    {
      ...command(
        "Reload Without Cache",
        "reloadFromOrigin",
        "page.reloadFromOrigin",
        "⇧⌘R"
      ),
      alternate: "shift",
    },
    command("Stop", "stop", "page.stop", "⌘."),
    separator,
    command("Zoom In", "zoomIn", "zoom.in", "⌘+"),
    command("Zoom Out", "zoomOut", "zoom.out", "⌘-"),
    command("Actual Size", "zoomReset", "zoom.reset", "⌘0"),
    separator,
    mac("Show Reader", "page.reader"),
    mac("Translate Page", "page.translate"),
    mac("Picture in Picture", "page.pictureInPicture"),
    separator,
    mac("Show Changes", "terminal.showChanges", "⌃⌘G"),
  ]),
  submenu("History", [
    command("Back", "back", "history.back", "⌘["),
    command("Forward", "forward", "history.forward", "⌘]"),
    separator,
    command("Reopen Last Closed Tab", "reopenTab", "tab.reopenClosed", "⇧⌘T"),
    live("Recently Closed", "recentlyClosed", "No Closed Tabs"),
    command("Archived Tabs…", "archivedTabs", "history.archivedTabs"),
    separator,
    live("Recently Visited", "recentlyVisited", "No History"),
    command("Show All History…", "history", "history.show", "⌘Y"),
  ]),
  submenu("Spaces", [
    command("Next Space", "nextSpace", "space.next", "⌃⌘→"),
    command("Previous Space", "previousSpace", "space.previous", "⌃⌘←"),
    separator,
    { dynamic: "spaces", label: "Spaces" },
    separator,
    command("New Space…", "newSpace", "space.new"),
    command("Edit Space…", "editSpace", "space.edit"),
  ]),
  submenu("Tab", [
    command("Show Previous Tab", "previousTab", "tab.previous", "⇧⌘["),
    command("Show Next Tab", "nextTab", "tab.next", "⇧⌘]"),
    submenu(
      "Go to Tab",
      Array.from({ length: 9 }, (_, index) =>
        command(
          index === 8 ? "Last Tab" : `Tab ${index + 1}`,
          `selectTab${index + 1}`,
          `tab.select${index + 1}`,
          `⌘${index + 1}`
        )
      )
    ),
    separator,
    command("Duplicate Tab", "duplicate", "tab.duplicate"),
    command("Pin Tab", "pin", "tab.pin"),
    command("Bookmark This Page", "bookmark", "tab.bookmark"),
    live("Move to Folder", "folders", "No Folders"),
    live("Move to Space", "moveSpaces", "No Other Spaces"),
    mac("Move to New Window", "tab.moveToNewWindow"),
    separator,
    command("New Split View", "split", "split.new"),
    command("Separate Split View", "separateSplit", "split.close"),
    separator,
    command("Mute Tab", "mute", "tab.mute", "⇧⌘M"),
    mac("Keep Awake Until Done"),
    separator,
    command("Clear Unpinned Tabs", "clearUnpinned", "tab.clearUnpinned", "⇧⌘K"),
  ]),
  submenu("Develop", [
    mac("Show Web Inspector", "devtools.inspector", "⌥⌘I"),
    mac("Inspect Element", "devtools.inspectElement", "⌥⌘C"),
    mac("Show Console", "devtools.console", "⌥⌘J"),
    mac("View Page Source", "page.viewSource", "⌥⌘U"),
    mac("Show Sources", "devtools.sources"),
    separator,
    mac("Toggle Page Profiling"),
    mac("Process Manager", "app.processManager"),
    separator,
    mac("Load Unpacked Extension…"),
    command("Feature Flags (about:config)…", "featureFlags"),
    { ...separator, developerOnly: true },
    { ...command("Design System", "designSystem"), developerOnly: true },
    { ...mac("Open Chrome Devtools"), developerOnly: true },
    { ...mac("Show Hitbox Debug Overlay"), developerOnly: true },
  ]),
  submenu("Window", [
    command("Minimize", "minimize", "window.minimize", "⌘M"),
    command("Zoom", "zoomWindow", "window.zoom"),
    separator,
    command(
      "Show Next Waiting Terminal",
      "nextWaitingTerminal",
      "terminal.nextWaiting",
      "⌃⌘J"
    ),
    live("Terminals", "terminals", "No Terminals"),
    separator,
    command("Downloads", "downloads", "downloads.show", "⌥⌘L"),
    submenu("Recent Downloads", [
      { label: "No Downloads" },
      separator,
      mac("Show Downloads Folder"),
    ]),
    separator,
    mac("Bring All to Front"),
  ]),
  submenu("Help", [
    command("Lilo Help", "help"),
    command("Keyboard Shortcuts", "shortcuts", "help.shortcuts", "⌘/"),
    command("Replay Onboarding", "onboarding"),
    separator,
    mac("Diagnostics"),
    mac("Report an Issue…"),
  ]),
];

const allItems = (entries: DemoMenuEntry[]): DemoMenuItem[] =>
  entries.flatMap((entry) =>
    "separator" in entry ? [] : [entry, ...allItems(entry.children ?? [])]
  );

export const defaultMenuShortcutKeys = Object.fromEntries(
  allItems(demoMenus).flatMap((item) =>
    item.shortcutId && item.keys ? [[item.shortcutId, item.keys]] : []
  )
);

export const menuLabelKeys = [
  ...new Set([
    ...allItems(demoMenus).map((item) =>
      /^Tab \d$/u.test(item.label) ? "Tab %d" : item.label
    ),
    "Show Sidebar",
    "Unpin Tab",
    "Unmute Tab",
  ]),
];

const editingActions = [
  "undo",
  "redo",
  "cut",
  "copy",
  "paste",
  "pasteMatchStyle",
  "delete",
  "selectAll",
] as const;

const activeTabAvailable = (state: DemoMenuState) => state.hasActiveTab;

const pageURLAvailable = (state: DemoMenuState) =>
  state.hasActiveTab && state.hasPageURL !== false;

const webPageAvailable = (state: DemoMenuState) =>
  state.hasActiveTab && state.activeTabKind === "web";

const multipleTabsAvailable = (state: DemoMenuState) =>
  (state.tabs?.length ?? 0) > 1;

const multipleSpacesAvailable = (state: DemoMenuState) =>
  (state.spaces?.length ?? 0) > 1;

const terminalAvailable = (state: DemoMenuState) =>
  state.terminalEnabled !== false;

const availability = new Map<string, (state: DemoMenuState) => boolean>([
  ["back", (state) => state.canGoBack],
  ["forward", (state) => state.canGoForward],
  ["reopenTab", (state) => state.canReopenTab],
  ["openAsTab", (state) => state.canOpenAsTab === true],
  ["sidebar", (state) => !state.sidebarLocked],
  ["findNext", (state) => state.canFindMatch === true],
  ["findPrevious", (state) => state.canFindMatch === true],
  ["previousTab", multipleTabsAvailable],
  ["nextTab", multipleTabsAvailable],
  ["closeOtherTabs", multipleTabsAvailable],
  ["nextSpace", multipleSpacesAvailable],
  ["previousSpace", multipleSpacesAvailable],
  ["separateSplit", (state) => state.hasSplit],
  ["split", (state) => state.hasActiveTab && state.canSplit !== false],
  ["reload", webPageAvailable],
  ["reloadFromOrigin", webPageAvailable],
  ["find", webPageAvailable],
  ["copyURL", pageURLAvailable],
  ["copyMarkdown", pageURLAvailable],
  ["newTerminal", terminalAvailable],
  ["newTerminalBeside", terminalAvailable],
  ["newTerminalBelow", terminalAvailable],
  ["nextWaitingTerminal", terminalAvailable],
  ["closeTab", activeTabAvailable],
  ["duplicate", pageURLAvailable],
  ["pin", activeTabAvailable],
  ["bookmark", activeTabAvailable],
  ["mute", activeTabAvailable],
]);

export const menuActionEnabled = (action: string, state: DemoMenuState) => {
  if (!state.supportedActions.includes(action)) {
    return false;
  }

  const editingAction = editingActions.find(
    (candidate) => candidate === action
  );

  if (state.editActions && editingAction) {
    return state.editActions[editingAction] === true;
  }

  if (action.startsWith("selectTab")) {
    const ordinal = Number(action.slice("selectTab".length));

    return ordinal === 9
      ? (state.tabs?.length ?? 0) > 0
      : ordinal > 0 && ordinal <= (state.tabs?.length ?? 0);
  }

  return availability.get(action)?.(state) ?? true;
};
