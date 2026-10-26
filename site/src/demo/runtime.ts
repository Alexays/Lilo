import { mount } from "svelte";
import * as z from "zod/mini";

import type {
  BridgeCommandName,
  BridgeCommandPayloadMap,
} from "../../../lilo-ui/src/lib/bridge/protocol";
import type { SettingsSectionId } from "../../../lilo-ui/src/stores/panels.svelte";
import type { DemoFeatureId } from "../lib/i18n.ts";
import type { NativeDemoData } from "../lib/native-demo-data";
import { installDemoAppearance } from "./appearance";
import type { DemoAssets } from "./assets";
import DemoSurface from "./DemoSurface.svelte";
import { createDemoHost } from "./host.ts";
import { demoMenus, menuActionEnabled, menuLabelKeys } from "./menu.ts";
import type { DemoMenuEntry, DemoMenuState } from "./menu.ts";
import { installNativeCopy, nativeCopy } from "./native-copy.ts";

type NativeHandler = NonNullable<
  NonNullable<NonNullable<Window["webkit"]>["messageHandlers"]>["lilo"]
>;

type NativeMessage = Parameters<NativeHandler["postMessage"]>[0];

const expand = () => {
  if (window.parent !== window) {
    window.parent.postMessage("lilo-demo:fullscreen", location.origin);
  } else if (document.fullscreenElement) {
    void document.exitFullscreen();
  } else {
    void document.documentElement.requestFullscreen();
  }
};

const menuCommand = z.object({
  action: z.enum([
    "selectSpace",
    "selectTab",
    "moveToSpace",
    "moveToFolder",
    "restoreClosedTab",
    "openHistoryItem",
  ]),
  id: z.string(),
  type: z.literal("lilo-demo:menu-command"),
});

export const startDemo = async (
  version: string,
  assets: DemoAssets,
  native: NativeDemoData
) => {
  installNativeCopy(native.copy);
  const params = new URLSearchParams(location.search);
  const locale = params.get("lang") === "fr" ? "fr" : "en";
  document.documentElement.lang = locale;
  const appearance = installDemoAppearance();
  // oxlint-disable-next-line prefer-const -- The bridge is installed before its surface can mount.
  let surface: ReturnType<typeof DemoSurface> | undefined;
  let lastTheme = "system";
  // oxlint-disable-next-line prefer-const -- Host callbacks are installed before the menu can publish.
  let publishMenu: (() => void) | undefined;

  const host = createDemoHost(
    locale,
    (event) => {
      // Swift replies asynchronously; do the same so commands cannot re-enter the stores.
      queueMicrotask(() => window.__lilo?.receive(event));
    },
    () => {
      const { theme } = host.snapshot().settings;

      if (theme !== lastTheme) {
        lastTheme = theme;
        appearance.set(theme);
      }

      surface?.refresh();
      publishMenu?.();
    },
    version,
    assets,
    native
  );

  let matches: Range[] = [];
  let selectedMatch = 0;

  const selectMatch = (direction: number) => {
    CSS.highlights.delete("demo-find-current");

    if (!matches.length) {
      return;
    }

    selectedMatch =
      (selectedMatch + direction + matches.length) % matches.length;
    const range = matches[selectedMatch];
    CSS.highlights.set("demo-find-current", new Highlight(range));
    range.startContainer.parentElement?.scrollIntoView({ block: "nearest" });
  };

  const findInPage = (query: string, caseSensitive: boolean) => {
    matches = [];
    selectedMatch = 0;

    const pane = document.querySelector(
      `[data-sample-tab="${CSS.escape(host.snapshot().activeTabId)}"] .page`
    );

    if (pane && query) {
      const walker = document.createTreeWalker(pane, NodeFilter.SHOW_TEXT);
      const needle = caseSensitive ? query : query.toLocaleLowerCase();
      let node: Node | null;

      while ((node = walker.nextNode())) {
        const content = caseSensitive
          ? (node.textContent ?? "")
          : (node.textContent ?? "").toLocaleLowerCase();

        let offset = content.indexOf(needle);

        while (offset >= 0) {
          const range = document.createRange();
          range.setStart(node, offset);
          range.setEnd(node, offset + query.length);
          matches.push(range);
          offset = content.indexOf(needle, offset + query.length);
        }
      }
    }

    host.emit("findInPageResult", { matchFound: matches.length > 0, query });
    CSS.highlights.set("demo-find-results", new Highlight(...matches));
    selectMatch(0);
    publishMenu?.();
  };

  const handlePageAction = (
    action: string,
    payload: NativeMessage["payload"]
  ) => {
    if (action === "copyPageURL") {
      void navigator.clipboard
        .writeText(host.activeTab()?.url ?? "")
        .catch(() => host.showNotice());

      return true;
    }

    if (action === "peekURL") {
      const url = String(payload.url ?? "");

      if (/^https?:\/\//iu.test(url)) {
        surface?.showPreview("peek", url);
      }

      return true;
    }

    return false;
  };

  const runTerminal = (command: string, split: boolean) => {
    if (host.snapshot().settings.terminalEnabled === "false") {
      host.showNotice();

      return;
    }

    if (split) {
      host.newTerminalSplit("horizontal");
    } else {
      host.dispatch("newTerminal", {});
    }

    host.emit("closeCommandBarAfterNavigation", {});
    const tab = host.activeTab();

    if (tab?.kind === "terminal") {
      void import("./playground.ts").then(({ getPlayground }) =>
        getPlayground(host).exec(tab.id, command)
      );
    }
  };

  window.webkit = {
    messageHandlers: {
      lilo: {
        postMessage: ({ action, payload }) => {
          if (action === "deleteTabFolder") {
            surface?.requestFolderDeletion(String(payload.id ?? ""));

            return;
          }

          if (action === "runInTerminal") {
            runTerminal(String(payload.command ?? ""), Boolean(payload.split));

            return;
          }

          if (handlePageAction(action, payload)) {
            return;
          }

          if (action === "maximizeWindow") {
            expand();

            return;
          }

          if (action === "getProcessSnapshot") {
            void import("../../../lilo-ui/src/stores/panels.svelte").then(
              ({ closeActivePanel }) => {
                closeActivePanel();

                return host.showNotice();
              }
            );

            return;
          }

          if (action === "reload") {
            surface?.reload();

            return;
          }

          if (action === "findInPage") {
            findInPage(
              String(payload.query ?? ""),
              payload.caseSensitive === true
            );

            return;
          }

          if (action === "findNext" || action === "findPrevious") {
            selectMatch(action === "findNext" ? 1 : -1);

            return;
          }

          if (action === "dismissFind") {
            matches = [];
            CSS.highlights.clear();

            return;
          }

          // SAFETY: the production UI's typed bridge is the only caller of this in-memory handler.
          host.dispatch(
            action as BridgeCommandName,
            payload as BridgeCommandPayloadMap[BridgeCommandName]
          );
        },
      },
    },
  };
  window.__liloBootstrapEvents = [
    { event: "initialState", ...host.initialState() },
    { event: "settingsLoaded", settings: host.snapshot().settings },
    {
      event: "shortcutKeys",
      keys: host.shortcutKeys(),
    },
  ];

  await import("../../../lilo-ui/src/main");

  if (!document.querySelector(".banner-host")) {
    const ready = Promise.withResolvers<undefined>();

    const observer = new MutationObserver(() => {
      if (!document.querySelector(".banner-host")) {
        return;
      }

      observer.disconnect();
      ready.resolve(undefined);
    });

    observer.observe(document.body, { childList: true, subtree: true });
    await ready.promise;
  }

  const target = document.querySelector<HTMLElement>("#demo-surface");

  if (!target) {
    throw new Error("Missing demo surface");
  }

  const showFeature = async (id: DemoFeatureId) => {
    const panels = await import("../../../lilo-ui/src/stores/panels.svelte");
    panels.closeActivePanel();
    panels.closeSettingsShell();

    const settings: Partial<Record<DemoFeatureId, SettingsSectionId>> = {
      appearance: "appearance",
      build: "terminal",
      downloads: "general",
      engine: "advanced",
      extensions: "extensions",
      imports: "general",
      mac: "advanced",
      privacy: "privacy",
      web: "tabs",
    };

    const section = settings[id];

    if (section) {
      panels.openSettings(section);

      return;
    }

    if (id === "agents" || id === "terminal") {
      host.openPlayground(id === "agents" ? "mcp" : "terminal");
      window.parent.postMessage(
        `lilo-demo:mode:${id === "agents" ? "mcp" : "terminal"}`,
        location.origin
      );

      return;
    }

    host.openBrowser();
    window.parent.postMessage("lilo-demo:mode:browser", location.origin);

    switch (id) {
      case "spaces": {
        host.emit("openAddSpaceEditor", {});
        break;
      }

      case "commandbar": {
        host.emit("openCommandBar", { prefill: ":" });
        break;
      }

      case "history": {
        host.emit("openHistory", {});
        break;
      }

      case "archive": {
        host.emit("openCommandBar", { prefill: "<" });
        break;
      }

      case "shortcuts": {
        host.emit("openShortcuts", {});
        break;
      }

      case "find": {
        host.dispatch("showFindBar", {});
        break;
      }

      case "media": {
        host.dispatch("switchSpace", { id: "music" });
        break;
      }

      case "split": {
        const current = host.snapshot().activeTabId;

        const other = host
          .snapshot()
          .tabs.find((tab) => tab.kind === "web" && tab.id !== current);

        if (other) {
          host.dispatch("splitTab", { side: "right", tabId: other.id });
        }

        break;
      }

      case "peek": {
        surface?.showPreview("peek", "https://slowtravel.example.com/lisbon");
        break;
      }

      case "little": {
        surface?.showPreview("little", "https://notes.example.com/quick-note");
        break;
      }

      default: {
        break;
      }
    }
  };

  surface = mount(DemoSurface, {
    props: {
      expand,
      host,
      onfeature: (id) => {
        void showFeature(id);
      },
      onstatechange: () => publishMenu?.(),
    },
    target,
  });

  const showMode = (mode: "browser" | "terminal" | "mcp") => {
    void import("../../../lilo-ui/src/stores/panels.svelte").then(
      ({ closeActivePanel, closeSettingsShell }) => {
        closeActivePanel();
        closeSettingsShell();

        if (mode === "browser") {
          return host.openBrowser();
        }

        return host.openPlayground(mode);
      }
    );
  };

  const commands = new Map<string, () => void>([
    [
      "explore",
      () => {
        if (host.isAgentSessionActive()) {
          void import("./playground.ts").then(({ getPlayground }) =>
            getPlayground(host).agent.stop()
          );
        }

        surface?.showFeatures();
      },
    ],
    ["browser", () => showMode("browser")],
    ["mcp", () => showMode("mcp")],
    ["settings", () => host.emit("openSettings", {})],
    ["shortcuts", () => host.emit("openShortcuts", {})],
    ["newTab", () => host.dispatch("createTab", {})],
    ["terminal", () => showMode("terminal")],
    ["newTerminal", () => host.dispatch("newTerminal", {})],
    ["newSpace", () => host.emit("openAddSpaceEditor", {})],
    [
      "editSpace",
      () => host.emit("openSpaceEditor", { id: host.snapshot().activeSpaceId }),
    ],
    ["sidebar", () => host.dispatch("toggleSidebar", {})],
    ["split", () => host.dispatch("newSplitView", {})],
    ["history", () => host.emit("openHistory", {})],
    ["find", () => host.dispatch("showFindBar", {})],
    ["back", () => host.dispatch("goBack", {})],
    ["forward", () => host.dispatch("goForward", {})],
    [
      "reload",
      () => {
        host.navigated(host.activeTab()?.url ?? "");
        surface?.reload();
      },
    ],
    [
      "closeTab",
      () => host.dispatch("closeTab", { id: host.snapshot().activeTabId }),
    ],
    ["reopenTab", () => host.dispatch("restoreClosedTab", {})],
    ["reset", () => location.reload()],
    ["duplicate", () => host.dispatch("duplicateActiveTab", {})],
    ["pin", () => host.dispatch("togglePinActiveTab", {})],
    ["undo", () => document.execCommand("undo")],
    ["redo", () => document.execCommand("redo")],
    ["selectAll", () => document.execCommand("selectAll")],
    [
      "help",
      () =>
        host.dispatch("createTab", {
          url: "https://github.com/Alexays/Lilo#readme",
        }),
    ],
  ]);

  const cycle = (kind: "tabs" | "spaces", direction: number) => {
    const state = host.snapshot();

    const items =
      kind === "tabs"
        ? state.tabs.filter(
            (tab) => !tab.isClosed && !host.isItemLocked(tab.id)
          )
        : state.spaces;

    const current = kind === "tabs" ? state.activeTabId : state.activeSpaceId;
    const index = items.findIndex((item) => item.id === current);
    const next = items[(index + direction + items.length) % items.length];

    if (next) {
      host.dispatch(kind === "tabs" ? "switchTab" : "switchSpace", {
        id: next.id,
      });
    }
  };

  const clipboard = async (action: string) => {
    if (action === "paste" || action === "pasteMatchStyle") {
      try {
        document.execCommand(
          "insertText",
          false,
          await navigator.clipboard.readText()
        );
      } catch {
        host.showNotice();
      }
    } else {
      document.execCommand(action);
    }
  };

  const additions: [string, () => void][] = [
    ["fullscreen", expand],
    ["onboarding", () => host.emit("startOnboarding", {})],
    [
      "newLittleWindow",
      () =>
        surface?.showPreview("little", "https://notes.example.com/quick-note"),
    ],
    ["newPrivateSpace", () => host.openPrivateSpace()],
    ["newTerminalBeside", () => host.newTerminalSplit("horizontal")],
    ["newTerminalBelow", () => host.newTerminalSplit("vertical")],
    ["openAsTab", () => surface?.openAsTab()],
    [
      "location",
      () =>
        host.emit("openCommandBar", {
          prefill: host.activeTab()?.url ?? "",
          selectAll: true,
        }),
    ],
    ["closeOtherTabs", () => host.closeOtherTabs(host.snapshot().activeTabId)],
    ["closeWindow", () => surface?.closeWindow()],
    ["minimize", () => surface?.minimize()],
    ["zoomWindow", expand],
    [
      "copyURL",
      () => {
        void navigator.clipboard
          .writeText(host.activeTab()?.url ?? "")
          .catch(() => host.showNotice());
      },
    ],
    [
      "copyMarkdown",
      () => {
        const tab = host.activeTab();

        if (tab) {
          void navigator.clipboard
            .writeText(`[${tab.title}](${tab.url})`)
            .catch(() => host.showNotice());
        }
      },
    ],
    ...["cut", "copy", "paste", "pasteMatchStyle", "delete"].map(
      (action): [string, () => void] => [
        action,
        () => {
          void clipboard(action);
        },
      ]
    ),
    ["findNext", () => selectMatch(1)],
    ["findPrevious", () => selectMatch(-1)],
    ["reloadFromOrigin", () => surface?.reload()],
    ["zoomIn", () => host.dispatch("zoomIn", {})],
    ["zoomOut", () => host.dispatch("zoomOut", {})],
    ["zoomReset", () => host.dispatch("zoomReset", {})],
    ["archivedTabs", () => host.emit("openCommandBar", { prefill: "<" })],
    ["nextSpace", () => cycle("spaces", 1)],
    ["previousSpace", () => cycle("spaces", -1)],
    ["nextTab", () => cycle("tabs", 1)],
    ["previousTab", () => cycle("tabs", -1)],
    [
      "bookmark",
      () => {
        const tab = host.activeTab();

        if (tab) {
          host.dispatch(tab.isBookmarked ? "unbookmarkTab" : "bookmarkTab", {
            id: tab.id,
          });
        }
      },
    ],
    ["separateSplit", () => host.dispatch("closeSplitView", {})],
    [
      "mute",
      () => {
        const tab = host.activeTab();

        if (tab) {
          host.dispatch(tab.isMuted ? "unmuteTab" : "muteTab", { id: tab.id });
        }
      },
    ],
    ["clearUnpinned", () => host.dispatch("clearUnpinnedTabs", {})],
    [
      "extensions",
      () => {
        void import("../../../lilo-ui/src/stores/panels.svelte").then(
          ({ openSettings }) => openSettings("extensions")
        );
      },
    ],
    ["featureFlags", () => host.emit("openConfig", {})],
    ["downloads", () => host.emit("openDownloads", {})],
    [
      "nextWaitingTerminal",
      () => {
        const tab = host
          .snapshot()
          .tabs.find(
            (item) =>
              item.kind === "terminal" && item.terminalState === "waiting"
          );

        if (tab) {
          host.dispatch("switchTab", { id: tab.id });
        }
      },
    ],
  ];

  for (const [action, handler] of additions) {
    commands.set(action, handler);
  }

  for (let ordinal = 1; ordinal <= 9; ordinal += 1) {
    commands.set(`selectTab${ordinal}`, () => {
      const tabs = host.openTabs();

      const tab = ordinal === 9 ? tabs.at(-1) : tabs[ordinal - 1];

      if (tab) {
        host.dispatch("switchTab", { id: tab.id });
      }
    });
    commands.set(`selectSpace${ordinal}`, () => {
      const space = host.snapshot().spaces[ordinal - 1];

      if (space) {
        host.dispatch("switchSpace", { id: space.id });
      }
    });
  }

  const menuState = (): DemoMenuState => {
    const state = host.snapshot();
    const tab = host.activeTab();
    let activeTabKind: DemoMenuState["activeTabKind"] = tab ? "web" : null;

    if (tab?.kind === "terminal") {
      activeTabKind = "terminal";
    }

    const editable =
      document.activeElement instanceof HTMLInputElement ||
      document.activeElement instanceof HTMLTextAreaElement ||
      (document.activeElement instanceof HTMLElement &&
        document.activeElement.isContentEditable);

    return {
      ...host.recentMenuItems(),
      activeTabKind,
      canFindMatch: matches.length > 0,
      canGoBack: tab?.canGoBack ?? false,
      canGoForward: tab?.canGoForward ?? false,
      canOpenAsTab: surface?.hasPreview() ?? false,
      canReopenTab: state.canRestoreClosedTab,
      canSplit: state.splitIds.length < 4,
      developerTools: state.settings.developerToolsEnabled === "true",
      editActions: Object.fromEntries(
        [
          "undo",
          "redo",
          "cut",
          "copy",
          "paste",
          "pasteMatchStyle",
          "delete",
          "selectAll",
        ].map((action) => [
          action,
          action === "paste" || action === "pasteMatchStyle"
            ? editable
            : document.queryCommandEnabled(action),
        ])
      ),
      extensions: state.extensions
        .filter((extension) => extension.isEnabled)
        .map((extension) => ({ id: extension.id, title: extension.name })),
      folders: state.folders
        .filter((folder) => !folder.isSplit && !host.isItemLocked(folder.id))
        .map((folder) => ({ id: folder.id, title: folder.name })),
      hasActiveTab: Boolean(tab),
      hasPageURL: Boolean(tab?.url),
      hasSplit: state.splitIds.length > 1,
      isBookmarked: tab?.isBookmarked ?? false,
      isMuted: tab?.isMuted ?? false,
      isPinned: tab?.isPinned ?? false,
      shortcutKeys: host.shortcutKeys(),
      showDevelopMenu: state.settings.showDevelopMenu !== "false",
      sidebarVisible: state.sidebarVisible,
      spaces: state.spaces.map((space) => ({
        icon: space.icon,
        id: space.id,
        selected: space.id === state.activeSpaceId,
        title: space.name,
      })),
      supportedActions: [...commands.keys()],
      tabs: state.tabs
        .filter((item) => !item.isBookmarked && !host.isItemLocked(item.id))
        .map((item) => ({
          id: item.id,
          selected: item.id === state.activeTabId,
          title: item.customTitle || item.title,
        })),
      terminalEnabled: state.settings.terminalEnabled !== "false",
      terminals: state.tabs
        .filter(
          (item) => item.kind === "terminal" && !host.isItemLocked(item.id)
        )
        .map((item) => ({
          id: item.id,
          title: item.customTitle || item.title,
        })),
      type: "lilo-demo:menu-state",
    };
  };

  let lastMenuState = "";
  let lastMenuLocale = "";
  publishMenu = () => {
    const menuLocale = host.snapshot().settings.locale === "fr" ? "fr" : "en";

    if (menuLocale !== lastMenuLocale) {
      lastMenuLocale = menuLocale;
      const t = nativeCopy(menuLocale);
      window.parent.postMessage(
        {
          labels: Object.fromEntries(menuLabelKeys.map((key) => [key, t(key)])),
          locale: menuLocale,
          type: "lilo-demo:menu-labels",
        },
        location.origin
      );
    }

    const state = menuState();
    const serialized = JSON.stringify(state);

    if (serialized !== lastMenuState) {
      lastMenuState = serialized;
      window.parent.postMessage(state, location.origin);
    }
  };

  const command = (action: string) => {
    if (action !== "openAsTab") {
      const transient = surface?.closeTransient();

      if (action === "closeTab" && transient) {
        return;
      }

      surface?.reopen();
    }

    commands.get(action)?.();
    publishMenu?.();
  };

  const runMenuCommand = ({ id, action }: z.infer<typeof menuCommand>) => {
    const state = host.snapshot();

    if (
      action === "selectSpace" &&
      state.spaces.some((space) => space.id === id)
    ) {
      host.dispatch("switchSpace", { id });
    }

    if (
      action === "selectTab" &&
      state.tabs.some((tab) => tab.id === id) &&
      !host.isItemLocked(id)
    ) {
      host.dispatch("switchTab", { id });
    }

    if (action === "moveToSpace") {
      host.dispatch("moveTabToSpace", {
        spaceId: id,
        tabId: state.activeTabId,
      });
    }

    if (action === "moveToFolder") {
      host.moveToFolder(state.activeTabId, id);
    }

    if (action === "restoreClosedTab") {
      host.restoreClosedTab(id);
    }

    if (action === "openHistoryItem") {
      host.openHistoryItem(id);
    }

    publishMenu?.();
  };

  window.addEventListener("message", (event: MessageEvent) => {
    if (event.source !== window.parent || event.origin !== location.origin) {
      return;
    }

    const parsed = z.safeParse(menuCommand, event.data);

    if (parsed.success) {
      runMenuCommand(parsed.data);
    }

    for (const action of commands.keys()) {
      if (event.data === `lilo-demo:${action}`) {
        command(action);
      }
    }

    if (event.data === "lilo-demo:dark" || event.data === "lilo-demo:light") {
      appearance.setParent(event.data === "lilo-demo:dark");
    }

    if (
      event.data === "lilo-demo:visible" ||
      event.data === "lilo-demo:hidden"
    ) {
      const visible = event.data === "lilo-demo:visible";
      document.documentElement.classList.toggle("reduced-power", !visible);
      host.emit("windowFocusChanged", { focused: visible });
      host.emit("powerModeChanged", { constrained: !visible });
    }
  });
  document.addEventListener("pointerdown", () =>
    window.parent.postMessage("lilo-demo:interaction", location.origin)
  );

  const shortcutCommands = new Map<string, string>();
  let switchingRecent = false;
  let switcherModifiers: string[] = [];

  const closeSwitcher = (commit: boolean) => {
    switchingRecent = false;
    switcherModifiers = [];
    host.emit("tabSwitcherClosed", { commit });
  };

  const switchRecent = (direction: number, event: KeyboardEvent) => {
    if (switchingRecent) {
      host.emit("tabSwitcherMoved", { by: direction });

      return;
    }

    const tabs = host.recentTabRows();

    if (tabs.length < 2) {
      return;
    }

    switcherModifiers = ["Control", "Alt", "Meta"].filter((key) =>
      event.getModifierState(key)
    );
    switchingRecent = true;
    host.emit("tabSwitcherOpened", {
      selected: direction > 0 ? 1 : tabs.length - 1,
      tabs,
    });
  };

  const handleSwitcherKey = (event: KeyboardEvent, id: string | undefined) => {
    if (!switchingRecent) {
      return false;
    }

    if (!switcherModifiers.every((key) => event.getModifierState(key))) {
      closeSwitcher(true);

      return false;
    }

    const direction = new Map([
      ["ArrowDown", 1],
      ["ArrowUp", -1],
    ]).get(event.key);

    if (direction) {
      host.emit("tabSwitcherMoved", { by: direction });
    } else if (event.key === "Escape") {
      closeSwitcher(false);
    } else if (event.key === "Enter") {
      closeSwitcher(true);
    } else if (id === "tab.recentNext" || id === "tab.recentPrevious") {
      host.emit("tabSwitcherMoved", { by: id === "tab.recentNext" ? 1 : -1 });
    }

    event.preventDefault();
    event.stopImmediatePropagation();

    return true;
  };

  const collectShortcuts = (entries: DemoMenuEntry[]) => {
    for (const item of entries) {
      if ("separator" in item) {
        continue;
      }

      if (item.shortcutId && item.action) {
        shortcutCommands.set(item.shortcutId, item.action);
      }

      if (item.children) {
        collectShortcuts(item.children);
      }
    }
  };

  collectShortcuts(demoMenus);

  for (let ordinal = 1; ordinal <= 9; ordinal += 1) {
    shortcutCommands.set(`space.select${ordinal}`, `selectSpace${ordinal}`);
  }

  for (const edge of ["left", "right", "top", "bottom"]) {
    const action = `tabs${edge}`;
    commands.set(action, () =>
      host.dispatch("setSetting", { key: "tabPosition", value: edge })
    );
    shortcutCommands.set(
      `tabs.position${edge[0].toUpperCase()}${edge.slice(1)}`,
      action
    );
  }

  shortcutCommands.set("tab.recentNext", "nextTab");
  shortcutCommands.set("tab.recentPrevious", "previousTab");
  document.addEventListener(
    "keydown",
    (event) => {
      if (host.recordKeyboard(event)) {
        event.preventDefault();
        event.stopImmediatePropagation();

        return;
      }

      const id = host.shortcutAction(event);

      if (handleSwitcherKey(event, id)) {
        return;
      }

      if (!id) {
        return;
      }

      if (id === "tab.recentNext" || id === "tab.recentPrevious") {
        event.preventDefault();
        event.stopImmediatePropagation();
        switchRecent(id === "tab.recentNext" ? 1 : -1, event);

        return;
      }

      const action = shortcutCommands.get(id);

      if (id.startsWith("edit.") && host.isDefaultShortcut(id, event)) {
        return;
      }

      event.preventDefault();
      event.stopImmediatePropagation();

      if (action && menuActionEnabled(action, menuState())) {
        command(action);
      } else if (!action) {
        host.showNotice();
      }
    },
    true
  );
  document.addEventListener("keyup", (event) => {
    if (
      switchingRecent &&
      !switcherModifiers.every((key) => event.getModifierState(key))
    ) {
      closeSwitcher(true);
    }
  });
  window.addEventListener("blur", () => {
    if (switchingRecent) {
      closeSwitcher(false);
    }
  });

  for (const event of ["focusin", "input", "selectionchange"]) {
    document.addEventListener(event, () => publishMenu?.());
  }

  window.parent.postMessage("lilo-demo:ready", location.origin);
  publishMenu?.();
};
