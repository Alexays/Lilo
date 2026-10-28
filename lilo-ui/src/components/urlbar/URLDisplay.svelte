<script lang="ts">
  import { getContentPlaceholderLockedFolderId } from "../../stores/banners.svelte";
  import { onMount, untrack } from "svelte";
  import { on } from "../../lib/bridge";
  import { announce } from "../../lib/announce";
  import { tooltip } from "../../lib/tooltip";
  import { chromeActions, extensionActions, settingsActions, terminalActions } from "../../lib/bridge/actions";
  import { getActiveTab } from "../../stores/tabs.svelte";
  import { getRecoveredPage } from "../../stores/pageHang.svelte";
  import { copyText } from "../../lib/clipboard";
  import { isCommandBarOpen, openCommandBar } from "../../stores/commandBar.svelte";
  import { getExtensions } from "../../stores/extensions.svelte";
  import { getSetting } from "../../stores/settings.svelte";
  import {
    getActiveUrlBarDrawer,
    getTrackersBlocked,
    isBlockerAllowlisted,
    isSiteDrawerOpen,
    setSiteDrawerOpen,
  } from "../../stores/urlBarDrawer.svelte";
  import { restingBlur, restingFly } from "../../lib/motion/restingTransitions";
  import { cubicOut, quintOut } from "svelte/easing";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { springEase } from "../../lib/motion/spring";
  import URLHost from "./URLHost.svelte";
  import URLToast from "./URLToast.svelte";
  import URLProgress from "./URLProgress.svelte";
  import URLBarDrawer from "./URLBarDrawer.svelte";
  import URLDetailsCard, { type DetailAction, type DetailLocation, type DetailRow } from "./URLDetailsCard.svelte";
  import { formatTerminalDuration } from "../../lib/terminalTitle";
  import { startTabMemoryLiveRefresh, stopTabMemoryLiveRefresh, tabUsage } from "../../stores/tabMemory.svelte";
  import { permissionOriginFromURL } from "../../lib/sitePermissions";
  import { t } from "../../lib/i18n/state.svelte";
  import {
    computeDisplayedLoadingProgress,
    nextTrickleProgress,
    progressMoved,
    URL_PROGRESS_STALLED_DELAY_MS,
    URL_PROGRESS_TRICKLE_CAP_MS,
  } from "../../lib/urlProgress";
  import type { ToastVariant, URLVisual } from "../../lib/urlVisual";

  // With the address hidden, only the page's buttons stay, on the Space row.
  let { actionsOnly = false }: { actionsOnly?: boolean } = $props();

  const TOAST_DURATION_MS = 1440;
  const DETAILS_DELAY_MS = 400;
  const CHROME_WEB_STORE_DETAIL_PATH = /\/detail(?:\/[^/]+)?\/([a-p]{32})(?:[/?#]|$)/i;

  const COLLAPSIBLE_SUBDOMAINS = new Set([
    "www",
    "m",
    "mobile",
    "amp",
    "web",
    "app",
  ]);
  const SECOND_LEVEL_TLDS = new Set([
    "ac",
    "co",
    "com",
    "edu",
    "gov",
    "net",
    "org",
  ]);

  let displayedProgress = $state(0);
  let progressVisible = $state(false);
  let progressCompleting = $state(false);
  let progressStalled = $state(false);
  let progressStalledSince: number | null = null;
  let progressLastSeenValue: number = 0;
  let progressTrickleCapped = $state(false);
  let lastRawProgress = -1;
  let lastRealProgressAt = 0;
  let lastProgressTabId = "";
  let progressCompleteTimeout: ReturnType<typeof setTimeout> | null = null;
  let hideProgressTimeout: ReturnType<typeof setTimeout> | null = null;
  let progressTrickleInterval: ReturnType<typeof setInterval> | null = null;
  let hideToastTimeout: ReturnType<typeof setTimeout> | null = null;
  let installFeedbackTimeout: ReturnType<typeof setTimeout> | null = null;
  let hideHostShiftTimeout: ReturnType<typeof setTimeout> | null = null;
  let toastVisible = $state(false);
  let toastToken = $state(0);
  let toastMessage = $state("Copied");
  let toastVariant = $state<ToastVariant>("copied");
  let pendingInstallExtensionId = $state<string | null>(null);
  let hostShiftActive = $state(false);
  let lastHostIdentity = "";
  let lastPermissionOrigin = "";
  const blockerEnabled = $derived(getSetting("contentBlockerEnabled", "true") === "true");

  // Which devices are live is reported on the tab row; the address bar only opens the controls.
  const captureActive = $derived.by(() => {
    const tab = getActiveTab();
    if (!tab) return false;
    return Boolean(
      tab.isCameraActive || tab.isMicrophoneActive || tab.isScreenSharing,
    );
  });
  // Derived from the URL string, not the tab object, so other tab patches don't re-run URLHost's canvas measurement.
  // A selected tab whose folder is locked shows the lock placeholder, never its address.
  const activeTabURL = $derived(getContentPlaceholderLockedFolderId() ? "" : getActiveTab()?.url ?? "");
  // The address drags out as a link (Finder makes a .webloc, Mail and Notes a link).
  const draggableURL = $derived(/^https?:/.test(activeTabURL));

  function dragURL(event: DragEvent): void {
    event.dataTransfer?.setData("text/uri-list", activeTabURL);
    event.dataTransfer?.setData("text/plain", activeTabURL);
  }
  // Same for the progress effect: a patch on another tab must not re-run it.
  const activeTabId = $derived(getActiveTab()?.id ?? "");
  // A terminal or Changes tab has no address: the bar shows where it works instead.
  const activeKind = $derived(getActiveTab()?.kind ?? "web");
  const activeCwd = $derived(getActiveTab()?.cwd ?? "");
  const activeBranch = $derived(getActiveTab()?.gitBranch ?? "");
  const activeDiffAdded = $derived(getActiveTab()?.diffAdded ?? 0);
  const activeDiffRemoved = $derived(getActiveTab()?.diffRemoved ?? 0);
  const showsLocation = $derived(activeKind !== "web" && activeCwd !== "" && !getContentPlaceholderLockedFolderId());
  const locationPath = $derived(activeCwd.replace(/^\/Users\/[^/]+/, "~"));
  // The last folder reads like a URL's host, its parents like the path.
  const locationParent = $derived(locationPath.slice(0, locationPath.lastIndexOf("/") + 1));
  const locationName = $derived(locationPath.slice(locationParent.length));

  let locationLineEl: HTMLElement | undefined = $state();
  let locationLineWidth = $state(0);
  let locationMeasurer: CanvasRenderingContext2D | null = null;
  const LOCATION_MIN_FONT_PX = 11;
  const LOCATION_GAP_PX = 6;
  const LOCATION_SLACK_PX = 4;

  function locationTextWidth(text: string, style: CSSStyleDeclaration, size: number): number {
    locationMeasurer ??= document.createElement("canvas").getContext("2d");
    if (!locationMeasurer) return 0;
    locationMeasurer.font = `${style.fontWeight} ${size}px ${style.fontFamily}`;
    return locationMeasurer.measureText(text).width;
  }

  // The path shrinks to the smallest readable size, then drops middle folders whole, keeping the end that names where
  // the terminal is; the branch gets what the fitted path leaves (`branchRoom`, or its CSS share before a fit).
  const locationFit = $derived.by((): { parent: string; fontSize: number; branchRoom?: number } => {
    const line = locationLineEl;
    if (!line || locationLineWidth <= 0) return { parent: locationParent, fontSize: 0 };
    const parentEl = line.querySelector<HTMLElement>(".location-parent");
    const nameEl = line.querySelector<HTMLElement>(".location-name");
    const branchEl = line.querySelector<HTMLElement>(".location-branch");
    if (!parentEl || !nameEl) return { parent: locationParent, fontSize: 0 };
    const parentStyle = getComputedStyle(parentEl), nameStyle = getComputedStyle(nameEl);
    const base = Number.parseFloat(getComputedStyle(line).fontSize);
    // The branch at its natural width, measured from its text: on screen it may be squeezed by
    // the very path being fit. It never takes more than its share (.location-branch's max-width).
    let branch = 0;
    if (branchEl) {
      const branchStyle = getComputedStyle(branchEl);
      const counts = `${activeDiffAdded ? `+${compactCount.format(activeDiffAdded)}` : ""}${activeDiffRemoved ? `-${compactCount.format(activeDiffRemoved)}` : ""}`;
      const natural = Math.max(
        activeBranch ? locationTextWidth(`⎇ ${activeBranch}`, branchStyle, Number.parseFloat(branchStyle.fontSize)) : 0,
        locationTextWidth(counts, branchStyle, Number.parseFloat(branchStyle.fontSize)),
      );
      // The changes button pads its text by 6px a side and pulls 6px into the bar's padding.
      branch = Math.min(natural + (branchEl.classList.contains("changes-button") ? 6 : 0), locationLineWidth * 0.4) + LOCATION_GAP_PX;
    }
    const room = locationLineWidth - branch - LOCATION_SLACK_PX;
    const sizes = [base, base - 1, LOCATION_MIN_FONT_PX].filter((size, index, all) => size >= LOCATION_MIN_FONT_PX && all.indexOf(size) === index);
    const folders = locationParent.split("/").filter(Boolean);
    const root = locationParent.startsWith("/") ? "/" : `${folders.shift() ?? ""}/`;
    const candidates = [locationParent, ...folders.map((_, dropped) => `${root}…/${folders.slice(dropped + 1).map((folder) => `${folder}/`).join("")}`)];
    // The changes button's right padding sits in the bar's padding (its -6px margin): it is room too.
    const pulled = branchEl?.classList.contains("changes-button") ? 6 : 0;
    const leftFor = (width: number) => Math.max(0, locationLineWidth - width - LOCATION_GAP_PX - LOCATION_SLACK_PX + pulled);
    for (const parent of candidates) {
      for (const size of sizes) {
        const width = locationTextWidth(parent, parentStyle, size) + locationTextWidth(locationName, nameStyle, size);
        if (width <= room) return { parent, fontSize: size === base ? 0 : size, branchRoom: leftFor(width) };
      }
    }
    return { parent: candidates[candidates.length - 1], fontSize: sizes[sizes.length - 1] };
  });

  // Exact counts live in the chip's label and the tab tooltip.
  const compactCount = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });

  function showChanges(event: MouseEvent) {
    event.stopPropagation();
    terminalActions.showChanges(activeTabId);
  }

  const activeTerminalState = $derived(getActiveTab()?.terminalState ?? "");
  const activeCommand = $derived(getActiveTab()?.terminalCommand ?? "");
  const activeStartedAt = $derived(getActiveTab()?.terminalStartedAt ?? 0);
  const activeExitCode = $derived(getActiveTab()?.terminalExitCode ?? 0);

  // The details card: what the bar has no room for. Resting on the address brings it after a
  // beat; the buttons act at once, so resting on one never brings it over the tab list.
  let detailsOpen = $state(false);
  let detailsTimer: ReturnType<typeof setTimeout> | null = null;

  function cancelDetailsTimer() {
    if (detailsTimer === null) return;
    clearTimeout(detailsTimer);
    detailsTimer = null;
  }

  function closeDetails() {
    cancelDetailsTimer();
    detailsOpen = false;
  }

  function trackDetails(event: PointerEvent) {
    const target = event.target as Element;
    if (target.closest(".url-actions, .changes-button, .permissions-btn")) return closeDetails();
    if (detailsOpen || detailsTimer !== null || !target.closest(".url-trigger")) return;
    detailsTimer = setTimeout(() => {
      detailsTimer = null;
      detailsOpen = true;
    }, DETAILS_DELAY_MS);
  }

  function leaveDetailsFocus(event: FocusEvent) {
    const container = event.currentTarget as HTMLElement;
    if (!container.contains(event.relatedTarget as Node | null)) closeDetails();
  }

  // A keyboard focus opens it at once: the certificate lives there.
  function focusDetails(event: FocusEvent) {
    if ((event.currentTarget as HTMLElement).matches(":focus-visible")) detailsOpen = true;
  }

  $effect(() => {
    void activeTabId;
    untrack(closeDetails);
  });

  $effect(() => {
    if (!detailsOpen) return;
    startTabMemoryLiveRefresh(activeTabId);
    return stopTabMemoryLiveRefresh;
  });
  const activeTabLoading = $derived(getActiveTab()?.isLoading ?? false);
  const activeTabProgress = $derived(getActiveTab()?.progress ?? 0);
  const permissionOrigin = $derived(permissionOriginFromURL(activeTabURL));

  const drawerActive = $derived(getActiveUrlBarDrawer() !== null);

  // Navigating to another origin (or the capture ending) invalidates the Site drawer.
  $effect(() => {
    if (permissionOrigin !== lastPermissionOrigin) {
      lastPermissionOrigin = permissionOrigin;
      setSiteDrawerOpen(false);
    }
  });
  $effect(() => {
    if (!captureActive && isSiteDrawerOpen()) setSiteDrawerOpen(false);
  });

  // Asked once at startup so the invite can appear without opening Settings.
  onMount(() => settingsActions.loadDefaultBrowserStatus());

  function handleClick() {
    closeDetails();
    openCommandBar(activeTabURL, false, true);
  }

  function toggleSiteDrawer(e: MouseEvent) {
    e.stopPropagation();
    setSiteDrawerOpen(!isSiteDrawerOpen());
  }

  function showSecurityInfo(e: Event) {
    e.stopPropagation();
    if (!urlVisual.isSecure || urlVisual.isPlaceholder) {
      return;
    }

    chromeActions.showTabSecurityInfo();
  }

  function splitHostAndPort(host: string): { hostname: string; port: string } {
    if (host.startsWith("[")) {
      return { hostname: host, port: "" };
    }

    const colonIndex = host.lastIndexOf(":");
    if (colonIndex === -1) {
      return { hostname: host, port: "" };
    }

    const maybePort = host.slice(colonIndex + 1);
    if (!/^\d+$/.test(maybePort)) {
      return { hostname: host, port: "" };
    }

    return {
      hostname: host.slice(0, colonIndex),
      port: `:${maybePort}`,
    };
  }

  function registrableDomainSize(labels: string[]): number {
    if (labels.length < 2) {
      return labels.length;
    }

    const last = labels[labels.length - 1] ?? "";
    const secondLast = labels[labels.length - 2] ?? "";
    if (
      labels.length >= 3 &&
      last.length === 2 &&
      SECOND_LEVEL_TLDS.has(secondLast)
    ) {
      return 3;
    }

    return 2;
  }

  function shortenDisplayHost(host: string): string {
    if (
      !host ||
      host === "localhost" ||
      host.startsWith("[") ||
      /^\d{1,3}(?:\.\d{1,3}){3}$/.test(host)
    ) {
      return host;
    }

    const { hostname, port } = splitHostAndPort(host);
    let labels = hostname.split(".").filter(Boolean);
    if (labels[0] === "www" && labels.length > 2) {
      labels = labels.slice(1);
    }

    if (labels.length <= 4) {
      return `${labels.join(".")}${port}`;
    }

    const rootSize = registrableDomainSize(labels);
    const root = labels.slice(-rootSize).join(".");
    const subdomains = labels.slice(0, -rootSize);
    if (subdomains.length <= 2) {
      return `${labels.join(".")}${port}`;
    }

    const significantSubdomains = subdomains.filter((label, index) => {
      if (index === 0 || index === subdomains.length - 1) {
        return true;
      }

      return !COLLAPSIBLE_SUBDOMAINS.has(label);
    });

    const first = significantSubdomains[0] ?? subdomains[0] ?? "";
    const last =
      significantSubdomains[significantSubdomains.length - 1] ??
      subdomains[subdomains.length - 1] ??
      "";
    const collapsedSubdomains =
      first === last ? `${first}…` : `${first}…${last}`;
    return `${collapsedSubdomains}.${root}${port}`;
  }

  function buildURLVisual(url: string): URLVisual {
    if (!url) {
      return {
        key: "__empty__",
        host: t("urlBar.placeholder"),
        displayHost: t("urlBar.placeholder"),
        hostIdentity: "__empty__",
        path: "",
        isSecure: false,
        isPlaceholder: true,
      };
    }

    try {
      const parsed = new URL(url);
      if (parsed.hostname) {
        const remainder = `${parsed.pathname !== "/" ? parsed.pathname : ""}${parsed.search}${parsed.hash}`;
        const host = parsed.host || parsed.hostname;
        return {
          key: `${host}${remainder}`,
          host,
          displayHost: shortenDisplayHost(host),
          hostIdentity: parsed.hostname || host,
          path: remainder,
          isSecure: parsed.protocol === "https:",
          isPlaceholder: false,
        };
      }

      const protocol = parsed.protocol || "site:";
      const opaquePath =
        `${parsed.pathname}${parsed.search}${parsed.hash}`.replace(/^\/+/, "");
      return {
        key: `${protocol}${opaquePath}`,
        host: protocol,
        displayHost: protocol,
        hostIdentity: protocol,
        path: opaquePath,
        isSecure: false,
        isPlaceholder: false,
      };
    } catch {
      return {
        key: url,
        host: url,
        displayHost: url,
        hostIdentity: url,
        path: "",
        isSecure: false,
        isPlaceholder: false,
      };
    }
  }

  function buildFeedbackVisual(
    message: string,
    variant: ToastVariant,
    token: number,
  ): URLVisual {
    return {
      key: `feedback-${variant}-${token}`,
      host: message,
      displayHost: message,
      hostIdentity: `feedback-${variant}`,
      path: "",
      isSecure: false,
      isPlaceholder: false,
      isFeedback: true,
      feedbackVariant: variant,
    };
  }

  const urlVisual = $derived.by(() => buildURLVisual(activeTabURL));

  // The command bar edits this address: a card about it would only cover the tab list. The Site drawer
  // already shows what it would; a waiting request does not stop the user looking at the site.
  const detailsAvailable = $derived(
    getActiveUrlBarDrawer()?.kind !== "site" && !isCommandBarOpen() && (showsLocation || (activeKind === "web" && !urlVisual.isPlaceholder)),
  );
  // A terminal's folder is already the bar's bold part, so its card has no title.
  const detailsTitle = $derived(showsLocation ? "" : getActiveTab()?.title || urlVisual.displayHost);

  const detailsLocation = $derived.by((): DetailLocation => {
    if (showsLocation) return { before: locationParent, strong: locationName, after: "", code: true };
    const [, scheme = "", host = "", rest = ""] = /^([a-z][\w+.-]*:\/\/)?([^/?#]*)(.*)$/is.exec(activeTabURL) ?? [];
    return { before: scheme === "https://" ? "" : scheme, strong: host, after: rest, code: false };
  });

  const detailsRows = $derived.by((): DetailRow[] => {
    if (!detailsOpen) return [];
    const rows: DetailRow[] = [];
    if (showsLocation) {
      if (activeBranch) rows.push({ label: t("urlBar.details.branch"), value: activeBranch, look: "tag" });
      const command = activeCommand || t("tabItem.terminalCommand");
      // The elapsed time is read when the card opens, like the tab's own hover popup: nothing ticks.
      if (activeTerminalState === "busy" || activeTerminalState === "waiting") {
        rows.push({
          label: t("urlBar.details.command"),
          value: command,
          look: "code",
          note: activeStartedAt
            ? t("urlBar.details.runningFor", { duration: formatTerminalDuration((Date.now() - activeStartedAt) / 1000) })
            : t("urlBar.details.running"),
          state: activeTerminalState,
        });
      } else if (activeTerminalState === "failed" || activeTerminalState === "succeeded") {
        const failed = activeTerminalState === "failed";
        const duration = formatTerminalDuration(getActiveTab()?.terminalDuration ?? 0);
        rows.push({
          label: t("urlBar.details.lastCommand"),
          value: command,
          look: "code",
          note: failed
            ? t("urlBar.details.failedAfter", { code: String(activeExitCode), duration })
            : t("urlBar.details.finishedIn", { duration }),
          state: failed ? "failed" : undefined,
        });
      }
    } else {
      if (activeTabURL.startsWith("https:")) {
        rows.push({
          label: t("urlBar.details.connection"),
          value: t("urlBar.details.encrypted"),
          tone: "success",
          lock: true,
          action: {
            label: t("urlBar.details.certificate"),
            run: (event) => {
              closeDetails();
              showSecurityInfo(event);
            },
          },
        });
      } else if (activeTabURL.startsWith("http:")) {
        rows.push({ label: t("urlBar.details.connection"), value: t("urlBar.details.notEncrypted"), tone: "danger" });
      }
      if (blockerEnabled) {
        const allowlisted = isBlockerAllowlisted(urlVisual.host);
        const count = getTrackersBlocked();
        rows.push({
          label: t("urlBar.details.blocking"),
          value: allowlisted
            ? t("urlToast.adsAllowed")
            : count > 1
              ? t("urlToast.trackersBlockedLabel", { count })
              : count === 1
                ? t("urlToast.trackerBlockedLabel", { count })
                : t("urlToast.adsBlocked"),
          tone: allowlisted ? "muted" : undefined,
        });
      }
    }
    // The memory is an estimate when several tabs share a process, hence the "≈".
    const usage = tabUsage(activeTabId);
    if (usage) {
      rows.push({
        label: t("urlBar.details.usage"),
        value: `≈ ${usage.memory}`,
        extra: usage.cpu === undefined ? undefined : t("urlBar.details.cpu", { cpu: usage.cpu }),
      });
    }
    return rows;
  });

  const detailsActions = $derived.by((): DetailAction[] => {
    if (!detailsOpen || !showsLocation) return [];
    const actions: DetailAction[] = [];
    if (activeKind === "terminal" && (activeDiffAdded > 0 || activeDiffRemoved > 0)) {
      actions.push({
        label: t("urlBar.details.changes"),
        added: activeDiffAdded,
        removed: activeDiffRemoved,
        run: (event) => {
          closeDetails();
          showChanges(event);
        },
      });
    }
    actions.push({
      label: t("urlBar.details.copyPath"),
      run: async (event) => {
        event.stopPropagation();
        closeDetails();
        const ok = await copyText(activeCwd);
        showToast(ok ? "copied" : "failed", t(ok ? "urlToast.copied" : "urlToast.failed"));
      },
    });
    return actions;
  });
  const visibleURLVisual = $derived.by(() =>
    toastVisible
      ? buildFeedbackVisual(toastMessage, toastVariant, toastToken)
      : urlVisual,
  );

  async function copyURL(e: Event) {
    e.stopPropagation();
    const url = getActiveTab()?.url ?? "";
    if (!url) {
      return;
    }

    const ok = await copyText(url);
    showToast(ok ? "copied" : "failed", t(ok ? "urlToast.copied" : "urlToast.failed"));
  }

  const chromeWebStoreExtensionId = $derived(
    activeTabURL.match(CHROME_WEB_STORE_DETAIL_PATH)?.[1]?.toLowerCase() ?? null,
  );
  const chromeWebStoreExtensionInstalled = $derived(
    chromeWebStoreExtensionId !== null &&
      getExtensions().some(
        (extension) => extension.id === chromeWebStoreExtensionId,
      ),
  );

  function installChromeWebStoreExtension(e: MouseEvent) {
    e.stopPropagation();
    if (!activeTabURL || !chromeWebStoreExtensionId) {
      return;
    }

    pendingInstallExtensionId = chromeWebStoreExtensionId;
    scheduleInstallFeedbackTimeout(chromeWebStoreExtensionId);
    extensionActions.install(activeTabURL);
  }

  function clearProgressHideTimeout() {
    if (hideProgressTimeout !== null) clearTimeout(hideProgressTimeout);
    hideProgressTimeout = null;
  }

  function clearProgressCompleteTimeout() {
    if (progressCompleteTimeout !== null) clearTimeout(progressCompleteTimeout);
    progressCompleteTimeout = null;
  }

  function clearProgressTrickleInterval() {
    if (progressTrickleInterval !== null) clearInterval(progressTrickleInterval);
    progressTrickleInterval = null;
  }

  function startProgressTrickleInterval() {
    if (progressTrickleInterval !== null) {
      return;
    }

    progressTrickleInterval = setInterval(() => {
      const tab = getActiveTab();
      if (!tab?.isLoading) {
        clearProgressTrickleInterval();
        progressStalled = false;
        progressStalledSince = null;
        return;
      }

      // A load that stopped reporting real progress long ago will never finish on its
      // own: stop trickling and drop the sweep so the bar freezes at its current value.
      // The tab effect restarts the trickle when a real progress event arrives.
      if (Date.now() - lastRealProgressAt > URL_PROGRESS_TRICKLE_CAP_MS) {
        progressTrickleCapped = true;
        clearProgressTrickleInterval();
        progressStalled = false;
        progressStalledSince = null;
        return;
      }

      // Nobody watches the bar of an unfocused window: skip the tick and its restyle.
      if (document.documentElement.classList.contains("window-unfocused")) {
        return;
      }

      const rawProgress = Math.max(0, Math.min(1, tab.progress ?? 0));
      const next = nextTrickleProgress(displayedProgress, rawProgress);
      displayedProgress = next;

      if (progressMoved(next, progressLastSeenValue)) {
        progressLastSeenValue = next;
        progressStalledSince = null;
        progressStalled = false;
      } else {
        const now = Date.now();
        if (progressStalledSince === null) {
          progressStalledSince = now;
        } else if (
          !progressStalled &&
          now - progressStalledSince > URL_PROGRESS_STALLED_DELAY_MS
        ) {
          progressStalled = true;
        }
      }
    }, 400);
  }

  function clearToastTimeout() {
    if (hideToastTimeout !== null) clearTimeout(hideToastTimeout);
    hideToastTimeout = null;
  }

  function clearInstallFeedbackTimeout() {
    if (installFeedbackTimeout !== null) clearTimeout(installFeedbackTimeout);
    installFeedbackTimeout = null;
  }

  function clearHostShiftTimeout() {
    if (hideHostShiftTimeout !== null) clearTimeout(hideHostShiftTimeout);
    hideHostShiftTimeout = null;
  }

  function showToast(variant: ToastVariant, message: string) {
    toastVariant = variant;
    toastMessage = message;
    announce(message);
    toastToken += 1;
    toastVisible = true;
    clearToastTimeout();
    hideToastTimeout = setTimeout(() => {
      toastVisible = false;
      hideToastTimeout = null;
    }, TOAST_DURATION_MS);
  }

  function scheduleInstallFeedbackTimeout(extensionId: string) {
    clearInstallFeedbackTimeout();
    installFeedbackTimeout = setTimeout(() => {
      if (pendingInstallExtensionId === extensionId) {
        pendingInstallExtensionId = null;
        showToast("failed", t("urlToast.failed"));
      }

      installFeedbackTimeout = null;
    }, 12000);
  }

  $effect(() => {
    return () => {
      clearProgressCompleteTimeout();
      clearProgressHideTimeout();
      clearProgressTrickleInterval();
      clearToastTimeout();
      clearInstallFeedbackTimeout();
      clearHostShiftTimeout();
    };
  });

  $effect(() => {
    const offCopied = on("urlCopied", () => {
      showToast("copied", t("urlToast.copied"));
    });
    const offCopyFailed = on("urlCopyFailed", () => {
      showToast("failed", t("urlToast.failed"));
    });
    const offZoom = on("zoomChanged", (data) => {
      const level = typeof data.level === "number" ? data.level : 1;
      showToast("zoom", `${Math.round(level * 100)}%`);
    });
    return () => {
      offCopied();
      offCopyFailed();
      offZoom();
    };
  });

  // A page reloaded from the hung-page card answers again.
  let recoveredSeq = untrack(() => getRecoveredPage()?.seq ?? 0);
  $effect(() => {
    const recovered = getRecoveredPage();
    if (!recovered || recovered.seq === recoveredSeq) return;
    recoveredSeq = recovered.seq;
    if (recovered.tabId === untrack(() => getActiveTab()?.id)) showToast("recovered", t("pageHang.recovered"));
  });

  $effect(() => {
    const pendingExtensionId = pendingInstallExtensionId;
    if (!pendingExtensionId) {
      return;
    }

    if (
      !getExtensions().some((extension) => extension.id === pendingExtensionId)
    ) {
      return;
    }

    pendingInstallExtensionId = null;
    clearInstallFeedbackTimeout();
    showToast("installed", t("urlToast.installed"));
  });

  $effect(() => {
    const nextHostIdentity = urlVisual.hostIdentity;
    if (nextHostIdentity === lastHostIdentity) {
      return;
    }

    const shouldAnimate = lastHostIdentity !== "" && !urlVisual.isPlaceholder;
    lastHostIdentity = nextHostIdentity;
    clearHostShiftTimeout();
    hostShiftActive = shouldAnimate;

    if (!shouldAnimate) {
      return;
    }

    hideHostShiftTimeout = setTimeout(() => {
      hostShiftActive = false;
      hideHostShiftTimeout = null;
    }, 620);
  });

  $effect(() => {
    if (actionsOnly) return;
    const tabId = activeTabId;
    const isLoading = activeTabLoading;
    const rawProgress = Math.max(0, Math.min(1, activeTabProgress));

    // The trickle interval and the completion timers write the displayed state below; tracking
    // those reads would re-run this effect on every 400 ms tick.
    untrack(() => {
      if (tabId !== lastProgressTabId) {
        lastProgressTabId = tabId;
        displayedProgress = 0;
        progressVisible = false;
        progressCompleting = false;
        progressStalled = false;
        progressStalledSince = null;
        progressLastSeenValue = 0;
        progressTrickleCapped = false;
        lastRawProgress = -1;
        clearProgressCompleteTimeout();
        clearProgressHideTimeout();
        clearProgressTrickleInterval();
      }

      if (isLoading) {
        if (displayedProgress >= 0.999 || progressCompleting || !progressVisible) {
          displayedProgress = 0;
        }

        if (rawProgress !== lastRawProgress) {
          lastRawProgress = rawProgress;
          lastRealProgressAt = Date.now();
          progressTrickleCapped = false;
        }

        progressCompleting = false;
        clearProgressCompleteTimeout();
        clearProgressHideTimeout();
        progressVisible = true;
        if (!progressTrickleCapped) {
          startProgressTrickleInterval();
        }
        displayedProgress = computeDisplayedLoadingProgress(
          rawProgress,
          displayedProgress,
        );
        return;
      }

      clearProgressTrickleInterval();
      progressStalled = false;
      progressStalledSince = null;
      progressTrickleCapped = false;
      lastRawProgress = -1;

      if (!progressVisible) {
        displayedProgress = 0;
        progressCompleting = false;
        return;
      }

      if (progressCompleting || displayedProgress >= 0.999) {
        return;
      }

      displayedProgress = 1;
      clearProgressHideTimeout();
      clearProgressCompleteTimeout();
      progressCompleteTimeout = setTimeout(() => {
        progressCompleting = true;
        progressCompleteTimeout = null;

        clearProgressHideTimeout();
        hideProgressTimeout = setTimeout(() => {
          progressVisible = false;
          progressCompleting = false;
          displayedProgress = 0;
          hideProgressTimeout = null;
        }, 210);
      }, 220);
    });
  });
</script>

{#snippet permissionsButton()}
  {#if captureActive}
    <button
      type="button"
      class="permissions-btn"
      class:active={isSiteDrawerOpen()}
      aria-label={t("sitePermissions.manage")}
      use:tooltip={{ text: t("sitePermissions.manage"), placement: "bottom" }}
      aria-expanded={isSiteDrawerOpen()}
      onclick={toggleSiteDrawer}
    >
      <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
        <path d="M1.4 3.4h9.2M1.4 8.6h9.2" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>
        <circle cx="4.2" cy="3.4" r="1.5" fill="var(--bg-primary)" stroke="currentColor" stroke-width="1.2"/>
        <circle cx="7.8" cy="8.6" r="1.5" fill="var(--bg-primary)" stroke="currentColor" stroke-width="1.2"/>
      </svg>
    </button>
  {/if}
{/snippet}

{#snippet actions()}
  <URLToast
    {toastVisible}
    {toastVariant}
    canInstall={chromeWebStoreExtensionId !== null}
    isInstalled={chromeWebStoreExtensionInstalled}
    blockerActive={blockerEnabled && !urlVisual.isPlaceholder}
    isAllowlisted={isBlockerAllowlisted(urlVisual.host)}
    blockedCount={getTrackersBlocked()}
    onInstall={installChromeWebStoreExtension}
    onCopy={copyURL}
    onToggleBlocker={(e) => { e.stopPropagation(); settingsActions.toggleBlockerAllowlist(urlVisual.host); }}
  />
{/snippet}

{#if actionsOnly}
  <!-- Keeps the bar's class: the screenshot and extension menus hang from it. -->
  <div class="url-trigger actions-only">
    {@render permissionsButton()}
    {#if !showsLocation}
      {@render actions()}
    {/if}
  </div>
{:else}
<div
  class="url-display"
  role="search"
  onpointermove={trackDetails}
  onpointerleave={closeDetails}
  onfocusout={leaveDetailsFocus}
>
  <div class="url-surface" class:drawer-open={drawerActive}>
    <div
      class="url-trigger"
      role="button"
      tabindex="0"
      draggable={draggableURL}
      ondragstart={dragURL}
      onclick={handleClick}
      onfocus={focusDetails}
      onkeydown={(e) => {
        // Enter and Space on a button inside the bar press that button, not the bar.
        if ((e.key === "Enter" || e.key === " ") && e.target === e.currentTarget) {
          e.preventDefault();
          handleClick();
        } else if (e.key === "Escape" && detailsOpen) {
          e.stopPropagation();
          closeDetails();
        }
      }}
      aria-label={t("urlBar.addressBar", { url: showsLocation ? activeCwd : `${urlVisual.host}${urlVisual.path}` })}
    >
      {@render permissionsButton()}

      {#if showsLocation && !toastVisible}
        <span class="location-shell">
        <!-- Same motion as an address change; the intro is global so leaving a web tab plays it. -->
        {#key `${activeTabId}:${activeCwd}`}
        <span
          class="location"
          in:restingFly|global={{ x: -3, y: 8, duration: prefersReducedMotion() ? 0 : 380, easing: springEase }}
          out:restingFly={{ x: 5, y: -7, duration: prefersReducedMotion() ? 0 : 240, easing: cubicOut }}
        >
          <span
            class="location-line"
            bind:this={locationLineEl}
            bind:clientWidth={locationLineWidth}
            in:restingBlur|global={{ amount: 6, duration: prefersReducedMotion() ? 0 : 320, opacity: 0.16, easing: quintOut }}
            out:restingBlur={{ amount: 4, duration: prefersReducedMotion() ? 0 : 200, opacity: 0.08 }}
          >
          <!-- Clipped from the left: the folder name at the end is the part that matters. -->
          <span class="location-path" style={locationFit.fontSize ? `font-size: ${locationFit.fontSize}px` : ""}><span><span class="location-parent">{locationFit.parent}</span><span class="location-name">{locationName}</span></span></span>
          {#if activeKind === "terminal" && (activeDiffAdded > 0 || activeDiffRemoved > 0)}
            <button
              type="button"
              class="location-branch changes-button"
              style={locationFit.branchRoom !== undefined ? `max-width: ${locationFit.branchRoom}px` : ""}
              aria-label={t("tabItem.showChanges", { added: activeDiffAdded, removed: activeDiffRemoved })}
              onclick={showChanges}
              onkeydown={(event) => event.stopPropagation()}
            >
              {#if activeBranch}<span class="branch-name">⎇ {activeBranch}</span>{/if}
              <span class="changes-count">
                {#if activeDiffAdded}<span class="added">+{compactCount.format(activeDiffAdded)}</span>{/if}
                {#if activeDiffRemoved}<span class="removed">-{compactCount.format(activeDiffRemoved)}</span>{/if}
              </span>
            </button>
          {:else if activeBranch}
            <span class="location-branch" style={locationFit.branchRoom !== undefined ? `max-width: ${locationFit.branchRoom}px` : ""}><span class="branch-name">⎇ {activeBranch}</span></span>
          {/if}
          </span>
        </span>
        {/key}
        </span>
      {:else}
        <URLHost visual={visibleURLVisual} {hostShiftActive} />
      {/if}

      {#if !showsLocation}
        {@render actions()}
      {/if}

      <URLProgress
        progress={displayedProgress}
        visible={progressVisible}
        completing={progressCompleting}
        stalled={progressStalled}
        capped={progressTrickleCapped}
      />
    </div>

    <URLBarDrawer host={urlVisual.host} origin={permissionOrigin} />
  </div>

  {#if detailsOpen && detailsAvailable}
    <URLDetailsCard
      title={detailsTitle}
      location={detailsLocation}
      rows={detailsRows}
      actions={detailsActions}
    />
  {/if}
</div>
{/if}

<style>
  .url-display {
    position: relative;
    z-index: 20;
    padding: 4px var(--sidebar-right-pad, 10px) 4px 10px;
    flex-shrink: 0;
  }

  /* One shape for the bar and its drawer: the drawer grows inside this surface. */
  .url-surface {
    border-radius: var(--radius-md);
    background: var(--bg-hover);
    overflow: hidden;
    transition: background var(--transition-fast);
  }

  .url-surface:not(.drawer-open):hover {
    background: var(--bg-active);
  }

  .url-trigger {
    display: flex;
    align-items: center;
    gap: 6px;
    position: relative;
    isolation: isolate;
    overflow: hidden;
    width: 100%;
    min-height: 32px;
    padding: 8px;
    border-radius: var(--radius-md);
    color: var(--text-secondary);
    font-size: var(--font-size-md);
    line-height: 1.24;
    font-family: inherit;
    cursor: pointer;
    text-align: left;
    outline: none;
  }

  .url-trigger.actions-only {
    width: auto;
    min-height: 0;
    padding: 0;
    overflow: visible;
    cursor: default;
  }

  .url-trigger:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .permissions-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 18px;
    /* Taller than the 16px line: the overhang keeps the bar's height whether the button shows or not. */
    margin-block: -1px;
    flex-shrink: 0;
    padding: 0;
    border: none;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-muted);
    cursor: pointer;
    transition:
      background var(--transition-fast),
      color var(--transition-fast);
  }

  .location-shell {
    position: relative;
    flex: 1;
    min-width: 0;
    align-self: stretch;
  }

  /* Stacked so the leaving location overlaps the arriving one instead of pushing it. */
  .location {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
  }

  .location-line {
    display: flex;
    align-items: center;
    gap: 6px;
    width: 100%;
    min-width: 0;
  }

  /* The auto margin sends the branch and its changes to the right edge. */
  .location-path {
    flex: 0 1 auto;
    min-width: 3em;
    margin-right: auto;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    direction: rtl;
    text-align: left;
  }

  .location-path > span {
    direction: ltr;
    unicode-bidi: isolate;
  }

  .location-parent {
    color: color-mix(in srgb, var(--text-secondary) 86%, transparent);
  }

  .location-name {
    color: var(--text-primary);
    font-weight: var(--font-weight-semibold);
  }

  /* Gives way before the path does; the branch sits above its changes to leave the path more room. */
  .location-branch {
    flex: 0 4 auto;
    max-width: 40%;
    display: inline-flex;
    flex-direction: column;
    align-items: flex-end;
    justify-content: center;
    min-width: 0;
    white-space: nowrap;
    color: var(--text-muted);
    font-size: var(--font-size-2xs);
    line-height: 12px;
  }

  .branch-name {
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  /* Bare at rest; the negative margin keeps its text where the plain branch label sits. */
  .changes-button {
    margin-right: -6px;
    padding: 1px 6px;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    font-family: inherit;
    cursor: pointer;
    transition:
      background var(--transition-fast),
      color var(--transition-fast);
  }

  .changes-button:hover {
    background: var(--text-primary-tint-12);
    color: var(--text-primary);
  }

  .changes-button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .changes-count {
    flex: none;
    display: inline-flex;
    gap: 4px;
    font-weight: var(--font-weight-semibold);
    font-variant-numeric: tabular-nums;
  }

  /* Pulled toward the text colour so both read on any Space tint, light or dark. */
  .changes-count .added {
    color: color-mix(in srgb, var(--diff-added) 70%, var(--text-primary));
  }

  .changes-count .removed {
    color: color-mix(in srgb, var(--diff-removed) 70%, var(--text-primary));
  }

  /* The address bar paints its own surface underneath, so the button needs a tint above it. */
  .permissions-btn:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .permissions-btn:hover,
  .permissions-btn.active {
    background: var(--text-primary-tint-12);
    color: var(--text-primary);
  }
</style>
