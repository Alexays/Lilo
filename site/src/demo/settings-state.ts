import type {
  BridgeCommandName,
  BridgeCommandPayloadMap,
  BridgeEventName,
  BridgeEventPayloadMap,
  BridgeShortcutGroup,
  BridgeSitePermissionSnapshot,
  BridgeTerminalOptions,
  BridgeTerminalTheme,
  BridgeWebsiteDataSnapshot,
} from "../../../lilo-ui/src/lib/bridge/protocol";
import { nativeCopy } from "./native-copy.ts";
import { demoCopy } from "./world.ts";
import type { DemoLocale } from "./world.ts";

export interface NativeShortcutAction {
  id: string;
  title: string;
  category: string;
  defaults: string[];
  args?: (string | number)[];
}

type DemoCommands = {
  [K in BridgeCommandName]?: (payload: BridgeCommandPayloadMap[K]) => void;
};

type KeyboardInput = Pick<
  KeyboardEvent,
  "key" | "metaKey" | "ctrlKey" | "altKey" | "shiftKey" | "isComposing"
> & { code?: string };

interface Options {
  locale: DemoLocale;
  version: string;
  emit: <K extends BridgeEventName>(
    event: K,
    payload: BridgeEventPayloadMap[K]
  ) => void;
  onChange: () => void;
  shortcuts: NativeShortcutAction[];
  activeURL?: () => string;
  clearHistory?: (range: string) => void;
  historyCount?: () => number;
  terminalThemes?: BridgeTerminalTheme[];
}

const ARC_SHORTCUTS = {
  "downloads.show": ["⇧⌘j"],
  "page.save": ["⇧⌘s"],
  "sidebar.toggle": ["⌘s"],
  "space.next": ["⌥⌘right", "⌃⌘right"],
  "space.previous": ["⌥⌘left", "⌃⌘left"],
  "split.close": ["⌃⇧-"],
  "split.new": ["⌃⇧="],
  "tab.next": ["⌥⌘down", "⇧⌘]"],
  "tab.pin": ["⌘d"],
  "tab.previous": ["⌥⌘up", "⇧⌘["],
  "terminal.newBeside": [],
} satisfies Record<string, string[]>;

const KEY_NAMES = new Map([
  [" ", "space"],
  ["ArrowDown", "down"],
  ["ArrowLeft", "left"],
  ["ArrowRight", "right"],
  ["ArrowUp", "up"],
  ["Backspace", "delete"],
  ["Delete", "forwarddelete"],
  ["End", "end"],
  ["Enter", "return"],
  ["Escape", "escape"],
  ["Home", "home"],
  ["PageDown", "pagedown"],
  ["PageUp", "pageup"],
  ["Tab", "tab"],
]);

const KEY_GLYPHS = new Map([
  ["delete", "⌫"],
  ["down", "↓"],
  ["end", "↘"],
  ["escape", "⎋"],
  ["forwarddelete", "⌦"],
  ["home", "↖"],
  ["left", "←"],
  ["pagedown", "⇟"],
  ["pageup", "⇞"],
  ["return", "↩"],
  ["right", "→"],
  ["space", "Space"],
  ["tab", "⇥"],
  ["up", "↑"],
]);

const hostFor = (url: string) => {
  try {
    return new URL(url).hostname;
  } catch {
    return "";
  }
};

const DATA_DURATIONS = new Map([
  ["day", 86_400_000],
  ["hour", 3_600_000],
  ["week", 604_800_000],
]);

const cutoff = (range = "all") => {
  const duration = DATA_DURATIONS.get(range);

  return duration ? Date.now() - duration : Number.NEGATIVE_INFINITY;
};

const normalizeCombo = (combo: string) => {
  const prefix = /^[⌃⌥⇧⌘]+/u.exec(combo)?.[0] ?? "";

  return (
    [..."⌃⌥⇧⌘"].filter((glyph) => prefix.includes(glyph)).join("") +
    combo.slice(prefix.length).toLowerCase()
  );
};

const displayCombo = (combo: string) => {
  const key = combo.replace(/^[⌃⌥⇧⌘]+/u, "");

  return (
    combo.slice(0, combo.length - key.length) +
    (KEY_GLYPHS.get(key) ?? key.toUpperCase())
  );
};

const keyboardCombo = (event: KeyboardInput): string | undefined => {
  if (
    event.isComposing ||
    ["Alt", "Control", "Meta", "Shift", "Unidentified"].includes(event.key)
  ) {
    return;
  }

  let key =
    event.code === "Backquote"
      ? "`"
      : (KEY_NAMES.get(event.key) ?? event.key.toLowerCase());

  if (event.shiftKey) {
    const shifted = '~!@#$%^&*()_+{}|:"<>?';
    const index = shifted.indexOf(key);

    if (index !== -1) {
      key = "`1234567890-=[]\\;',./"[index] ?? key;
    }
  }

  if (
    !event.metaKey &&
    !event.ctrlKey &&
    !event.altKey &&
    !/^f(?:[1-9]|1\d|20)$/u.test(key)
  ) {
    return;
  }

  if (
    key === "dead" ||
    (!KEY_NAMES.has(event.key) && key.length > 1 && !/^f\d+$/u.test(key))
  ) {
    return;
  }

  return `${event.ctrlKey ? "⌃" : ""}${event.altKey ? "⌥" : ""}${event.shiftKey ? "⇧" : ""}${event.metaKey ? "⌘" : ""}${key}`;
};

export const demoTerminalOptions = (
  dark: boolean,
  themes: BridgeTerminalTheme[] = []
): BridgeTerminalOptions => ({
  fonts: ["SF Mono", "Menlo", "Monaco"],
  ghosttyFont: "",
  themes: [
    {
      background: dark ? "#181923" : "#faf9f7",
      foreground: dark ? "#e6e6e6" : "#1d1d1f",
      id: "auto",
      name: "Lilo",
      palette: (dark
        ? [
            "2c2c2e",
            "ff6b6b",
            "7bd88f",
            "f4c56a",
            "6cb6ff",
            "c98bff",
            "5fd7d7",
            "d4d4d4",
            "7a7a80",
            "ff8787",
            "9be7a8",
            "ffd78a",
            "91c8ff",
            "dcaaff",
            "8be9e9",
            "f5f5f5",
          ]
        : [
            "1d1d1f",
            "c62828",
            "2e7d32",
            "8e6e00",
            "1565c0",
            "6a1b9a",
            "00796b",
            "9e9e9e",
            "616161",
            "e53935",
            "43a047",
            "a67c00",
            "1e88e5",
            "ac47bc",
            "00897b",
            "bdbdbd",
          ]
      ).map((color) => `#${color}`),
    },
    ...themes.filter((theme) => theme.id !== "auto"),
  ],
});

export const createDemoSettings = ({
  locale,
  version,
  emit,
  onChange,
  shortcuts,
  activeURL,
  clearHistory,
  historyCount,
  terminalThemes,
}: Options) => {
  const values: BridgeEventPayloadMap["settingsLoaded"]["settings"] = {
    agentControlEnabled: "false",
    appVersion: version,
    contentBlockerEnabled: "true",
    locale,
    onboardingCompleted: "true",
    searchEngine: "google",
    terminalEnabled: "true",
    theme: "system",
  };

  const text = () => nativeCopy(values.locale === "fr" ? "fr" : "en");

  const complete = (action: string, message: string) =>
    emit("settingsActionCompleted", {
      action,
      level: "info",
      message: text()(message),
    });

  const unavailable = (action: string) =>
    emit("settingsActionCompleted", {
      action,
      level: "info",
      message: demoCopy(values.locale === "fr" ? "fr" : "en").sampleOnly,
    });

  const publishValues = () => emit("settingsLoaded", { settings: values });

  const terminalOptions = () =>
    demoTerminalOptions(
      values.theme === "dark" ||
        (values.theme !== "light" &&
          typeof document !== "undefined" &&
          document.documentElement.style.colorScheme === "dark"),
      terminalThemes
    );

  const sites: (BridgeWebsiteDataSnapshot & { modified: number })[] = [
    {
      kinds: ["cache", "cookies", "storage"],
      modified: Date.now() - 172_800_000,
      name: "slowtravel.example.com",
    },
    {
      kinds: ["storage"],
      modified: Date.now() - 1_800_000,
      name: "notes.example.com",
    },
  ];

  const permissions: BridgeSitePermissionSnapshot[] = [];
  const zoom = new Map<string, number>();
  const actualSizePages = new Set<string>();
  let permissionId = 0;
  let recording: string | null = null;
  let overrides: Record<string, string[]> = {};
  const actions = new Map(shortcuts.map((action) => [action.id, action]));

  const bindings = (id: string) =>
    overrides[id] ?? actions.get(id)?.defaults ?? [];

  const owner = (combo: string) =>
    shortcuts.find((action) => bindings(action.id).includes(combo));

  const title = (action: NativeShortcutAction) =>
    text()(action.title, ...(action.args ?? []));

  const shortcutKeys = (): Record<string, string> =>
    Object.fromEntries(
      shortcuts.flatMap((action) => {
        const [first] = bindings(action.id);

        return first ? [[action.id, displayCombo(first)]] : [];
      })
    );

  const publishShortcuts = () => {
    const groups: BridgeShortcutGroup[] = [];

    for (const action of shortcuts) {
      const category = text()(action.category);
      let group = groups.at(-1);

      if (group?.title !== category) {
        group = { items: [], title: category };
        groups.push(group);
      }

      group.items.push({
        custom: overrides[action.id] !== undefined,
        id: action.id,
        keys: bindings(action.id).map(displayCombo),
        title: title(action),
      });
    }

    emit("shortcutsLoaded", {
      controlTabOrder:
        owner("⌃tab")?.id === "tab.recentNext" ? "recent" : "sidebar",
      groups,
    });
  };

  const setBindings = (id: string, combos: string[]) => {
    if (!actions.has(id)) {
      return;
    }

    for (const combo of combos) {
      const previous = owner(combo);

      if (previous && previous.id !== id) {
        overrides[previous.id] = bindings(previous.id).filter(
          (key) => key !== combo
        );
      }
    }

    overrides[id] = combos;
  };

  const saveShortcuts = () => {
    overrides = Object.fromEntries(
      Object.entries(overrides).filter(
        ([id, combos]) =>
          JSON.stringify(combos) !== JSON.stringify(actions.get(id)?.defaults)
      )
    );

    if (Object.keys(overrides).length) {
      values.keyboardShortcuts = JSON.stringify(overrides);
    } else {
      delete values.keyboardShortcuts;
    }

    recording = null;
    publishShortcuts();
    emit("shortcutKeys", { keys: shortcutKeys() });
    onChange();
  };

  const defaultZoom = () =>
    Math.min(3, Math.max(0.5, Number(values.defaultZoom ?? "1") || 1));

  const zoomFor = (url: string) =>
    actualSizePages.has(url) ? 1 : (zoom.get(hostFor(url)) ?? defaultZoom());

  const publishZoom = () =>
    emit("zoomLevelsLoaded", {
      levels: [...zoom]
        .toSorted(([first], [second]) => first.localeCompare(second))
        .map(([host, level]) => ({ host, zoom: level })),
    });

  const publishSites = () =>
    emit("websiteDataLoaded", {
      sites: sites.map(({ name, kinds }) => ({ kinds: [...kinds], name })),
    });

  // Sizes a profile plausibly stores for the demo's sites and visits.
  const sitesWith = (kind: BridgeWebsiteDataSnapshot["kinds"][number]) =>
    sites.filter((site) => site.kinds.includes(kind)).length;

  const publishSizes = () => {
    const visits = historyCount?.() ?? 0;

    emit("browsingDataSizesLoaded", {
      cache: sitesWith("cache") * 6_300_000,
      cookies: sitesWith("cookies") * 3200,
      history: visits * 1200,
      historyEntries: visits,
      storage: sitesWith("storage") * 2_400_000,
    });
  };

  const publishPermissions = () =>
    emit("sitePermissionsLoaded", {
      permissions: permissions.toSorted(
        (first, second) => second.updatedAt - first.updatedAt
      ),
    });

  const clearData = (
    kinds: BridgeWebsiteDataSnapshot["kinds"],
    range?: string
  ) => {
    const since = cutoff(range);

    for (let index = sites.length - 1; index >= 0; index -= 1) {
      const site = sites[index];

      if (site.modified >= since) {
        site.kinds = site.kinds.filter((kind) => !kinds.includes(kind));
      }

      if (!site.kinds.length) {
        sites.splice(index, 1);
      }
    }

    publishSites();
  };

  const changeZoom = (delta?: number) => {
    const url = activeURL?.() ?? "";
    const host = hostFor(url);

    if (!host) {
      return;
    }

    const level =
      delta === undefined
        ? 1
        : Math.round(Math.min(3, Math.max(0.5, zoomFor(url) + delta)) * 100) /
          100;

    if (delta === undefined) {
      zoom.delete(host);
      actualSizePages.add(url);
    } else {
      actualSizePages.delete(url);
      zoom.set(host, level);
    }

    emit("zoomChanged", { level });
    publishZoom();
    onChange();
  };

  const replies: Partial<Record<BridgeCommandName, () => void>> = {
    getBrowsingDataSizes: publishSizes,
    getContentBlockerStatus: () =>
      emit("contentBlockerStatus", { lists: 7, updating: false }),
    getDefaultBrowserStatus: () =>
      emit("defaultBrowserStatusLoaded", {
        isDefault: false,
        shouldInvite: false,
      }),
    getDeviceSetup: () => emit("deviceSetupLoaded", { label: "" }),
    getExtensionDiagnostics: () =>
      emit("extensionDiagnosticsLoaded", { entries: [] }),
    getFeatureFlags: () => emit("featureFlagsLoaded", { flags: [] }),
    getOnboardingState: () =>
      emit("onboardingState", {
        show: values.onboardingCompleted === "false",
        step: Number(values.onboardingStep ?? "0") || 0,
        usage: values.onboardingUsage ?? "browse",
      }),
    getSettings: publishValues,
    getShortcuts: publishShortcuts,
    getSitePermissions: publishPermissions,
    getStartupMetrics: () =>
      emit("startupMetricsLoaded", { marks: [], summary: {}, traces: [] }),
    getTerminalOptions: () => emit("terminalOptions", terminalOptions()),
    getUpdaterStatus: () =>
      emit("updaterStatus", {
        automatic: false,
        available: false,
        lastCheck: null,
        version,
      }),
    getWebsiteData: publishSites,
    getZoomLevels: publishZoom,
  };

  const commands: DemoCommands = {
    applyShortcutPreset: ({ preset }) => {
      overrides =
        preset === "arc"
          ? Object.fromEntries(
              Object.entries(ARC_SHORTCUTS).filter(([id]) => actions.has(id))
            )
          : {};

      saveShortcuts();
    },
    checkForUpdates: () => {
      replies.getUpdaterStatus?.();
      unavailable("checkForUpdates");
    },
    chooseDownloadsFolder: () => unavailable("chooseDownloadsFolder"),
    clearBrowsingData: ({ kinds, range }) => {
      if (kinds.includes("history")) {
        clearHistory?.(range);
      }

      clearData(
        kinds.includes("siteData")
          ? ["cookies", "cache", "storage"]
          : kinds.filter((kind) => kind === "cookies" || kind === "cache"),
        range
      );

      if (
        kinds.includes("siteData") &&
        cutoff(range) === Number.NEGATIVE_INFINITY
      ) {
        permissions.length = 0;
        publishPermissions();
      }

      publishSizes();
      complete("clearBrowsingData", "Browsing data cleared");
    },
    clearExtensionDiagnostics: () => {
      replies.getExtensionDiagnostics?.();
      complete("clearExtensionDiagnostics", "Extension diagnostics cleared");
    },
    completeOnboarding: () => {
      values.onboardingCompleted = "true";
      delete values.onboardingStep;
      values.didPromptDefaultBrowser = "true";
      onChange();
    },
    copyDiagnosticsReport: () => unavailable("copyDiagnosticsReport"),
    copyExtensionDiagnostics: () => unavailable("copyExtensionDiagnostics"),
    dismissDefaultBrowserInvite: () => {
      values.didPromptDefaultBrowser = "true";
      replies.getDefaultBrowserStatus?.();
    },
    dismissUpdate: () => emit("updateReady", { version: null }),
    forceLifecycleTrim: () => {
      replies.getStartupMetrics?.();
      unavailable("forceLifecycleTrim");
    },
    forgetDeviceSetup: () => {
      replies.getDeviceSetup?.();
      unavailable("forgetDeviceSetup");
    },
    importTerminalTheme: () => unavailable("importTerminalTheme"),
    installUpdate: () => unavailable("installUpdate"),
    recordShortcut: ({ id }) => {
      recording = id && actions.has(id) ? id : null;

      if (!recording) {
        publishShortcuts();
      }
    },
    removeWebsiteData: ({ name }) => {
      const index = sites.findIndex((site) => site.name === name);

      if (index !== -1) {
        sites.splice(index, 1);
      }

      publishSites();
    },
    resetShortcut: ({ id }) => {
      setBindings(id, actions.get(id)?.defaults ?? []);
      saveShortcuts();
    },
    resetZoomLevel: ({ host }) => {
      zoom.delete(host);

      for (const url of actualSizePages) {
        if (hostFor(url) === host) {
          actualSizePages.delete(url);
        }
      }

      publishZoom();

      if (hostFor(activeURL?.() ?? "") === host) {
        emit("zoomChanged", { level: defaultZoom() });
      }

      onChange();
    },
    revokeSitePermission: ({ id }) => {
      const index = permissions.findIndex((permission) => permission.id === id);

      if (index !== -1) {
        permissions.splice(index, 1);
      }

      publishPermissions();
      complete("revokeSitePermission", "Site permission revoked");
    },
    setAutomaticUpdates: () => {
      replies.getUpdaterStatus?.();
      unavailable("setAutomaticUpdates");
    },
    setControlTabOrder: ({ order }) => {
      for (const [combo, recentId, sidebarId] of [
        ["⌃tab", "tab.recentNext", "tab.next"],
        ["⌃⇧tab", "tab.recentPrevious", "tab.previous"],
      ]) {
        const id = order === "recent" ? recentId : sidebarId;

        if (!bindings(id).includes(combo)) {
          setBindings(id, [...bindings(id), combo]);
        }
      }

      saveShortcuts();
    },
    setDefaultBrowser: () => {
      replies.getDefaultBrowserStatus?.();
      unavailable("setDefaultBrowser");
    },
    setOnboardingStep: ({ step }) => {
      values.onboardingStep = String(Math.max(0, Math.trunc(step)));
      onChange();
    },
    setSetting: ({ key, value }) => {
      if (values[key] === value) {
        return;
      }

      values[key] = value;
      publishValues();

      if (key === "locale") {
        publishShortcuts();
      }

      if (key === "theme") {
        emit("terminalOptions", terminalOptions());
      }

      if (key === "defaultZoom") {
        emit("zoomChanged", { level: zoomFor(activeURL?.() ?? "") });
      }

      onChange();
    },
    setShortcut: ({ id, combo }) => {
      setBindings(id, combo ? [normalizeCombo(combo)] : []);
      saveShortcuts();
    },
    setSitePermission: ({ origin, type, allow }) => {
      const previous = permissions.find(
        (permission) => permission.origin === origin && permission.type === type
      );

      permissionId += 1;

      const permission = {
        decision: allow ? "allow" : "deny",
        id: previous?.id ?? `demo-permission-${permissionId}`,
        origin,
        type,
        updatedAt: Date.now() / 1000,
      };

      if (previous) {
        Object.assign(previous, permission);
      } else {
        permissions.push(permission);
      }

      publishPermissions();
    },
    toggleBlockerAllowlist: ({ host }) => {
      let list: string[] = [];

      try {
        const parsed: unknown = JSON.parse(
          values.contentBlockerAllowlist ?? "[]"
        );

        if (Array.isArray(parsed)) {
          list = parsed.filter(
            (entry): entry is string => typeof entry === "string"
          );
        }
      } catch {
        /* An invalid setting is an empty list, as in native. */
      }

      list = list.includes(host)
        ? list.filter((site) => site !== host)
        : [...list, host];
      values.contentBlockerAllowlist = JSON.stringify(list);
      emit("blockerAllowlistChanged", { allowlist: list });
      publishValues();
      onChange();
    },
    unlockDeveloperTools: () => unavailable("unlockDeveloperTools"),
    updateFilterLists: () => {
      replies.getContentBlockerStatus?.();
      unavailable("updateFilterLists");
    },
    zoomIn: () => changeZoom(0.1),
    zoomOut: () => changeZoom(-0.1),
    zoomReset: () => changeZoom(),
  };

  const recordKeyboard = (event: KeyboardInput) => {
    if (!recording) {
      return false;
    }

    const id = recording;

    const bare =
      !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey;

    if (bare && event.key === "Escape") {
      recording = null;
      publishShortcuts();

      return true;
    }

    if (bare && ["Delete", "Backspace"].includes(event.key)) {
      setBindings(id, []);
      saveShortcuts();

      return true;
    }

    const combo = keyboardCombo(event);

    if (!combo) {
      return true;
    }

    recording = null;

    const previous = owner(combo);

    if (previous && previous.id !== id) {
      emit("shortcutConflict", {
        combo,
        id,
        keys: displayCombo(combo),
        owner: title(previous),
      });
    } else {
      setBindings(id, [combo]);
      saveShortcuts();
    }

    return true;
  };

  return {
    commands,
    isDefaultShortcut: (id: string, event: KeyboardInput) => {
      const combo = keyboardCombo(event);

      return Boolean(combo && actions.get(id)?.defaults.includes(combo));
    },
    navigated: (url: string) => {
      actualSizePages.delete(url);
    },
    recordKeyboard,
    replies,
    shortcutAction: (event: KeyboardInput) => {
      const combo = keyboardCombo(event);

      return combo ? owner(combo)?.id : undefined;
    },
    shortcutKeys,
    values,
    zoomFor,
  };
};
