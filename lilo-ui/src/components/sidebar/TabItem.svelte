<script lang="ts" module>
  import type { terminalProgramIcon } from "../../lib/terminalIcons";

  // The logos load on first need: most sessions never show a busy terminal.
  let lookupProgramIcon = $state<typeof terminalProgramIcon>();
  let programIconsRequested = false;
</script>

<script lang="ts">
  import { tooltipSide } from "../../stores/tabLayout.svelte";
  import { untrack } from "svelte";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import TabLoader from "./TabLoader.svelte";
  import { tabActions } from "../../lib/bridge/actions";
  import { optimisticallyActivateTab } from "../../stores/sidebar.svelte";
  import { DEFAULT_TAB_TITLE } from "../../lib/bridge/defaults";
  import { fallbackTabTitle, tooltipTabURL } from "../../lib/bridge/coerceHelpers";
  import { resolveTabCloseIntent } from "../../lib/tabCloseBehavior";
  import { tooltip } from "../../lib/tooltip";
  import {
    startTabMemoryLiveRefresh,
    stopTabMemoryLiveRefresh,
    tabUsageLabel,
  } from "../../stores/tabMemory.svelte";
  import {
    clearTabPreview,
    leaveTabPreview,
    getTabPreviewTabId,
    hoverTabPreview,
  } from "../../stores/tabPreview.svelte";
  import { subscribeHoverClear } from "../../lib/hoverClear";
  import { getSelectionTravelTarget } from "../../stores/selectionTravel.svelte";
  import { getRenamingTabId, setRenamingTabId } from "../../stores/tabRename.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { getActingAgentTabIds } from "../../stores/agents.svelte";
  import { getHangSeconds, getPageHang } from "../../stores/pageHang.svelte";
  import { isChromaticHex } from "../../lib/sidebarTheme";
  import { terminalFolder, terminalTitle, formatTerminalDuration } from "../../lib/terminalTitle";
  import type { TabState } from "../../stores/tabs.svelte";
  import { cubicOut } from "svelte/easing";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { springEase } from "../../lib/motion/spring";

  let {
    tab,
    isActive,
    interactive = true,
    disableTooltip = false,
    tooltipAnchor,
    previewActions = false,
    actionsInert = false,
    level = 1,
    tabStop = true,
  }: {
    tab: TabState;
    isActive: boolean;
    interactive?: boolean;
    disableTooltip?: boolean;
    /** Ancestor selector the tooltip sits beside, so it clears neighbours sharing the row. */
    tooltipAnchor?: string;
    previewActions?: boolean;
    actionsInert?: boolean;
    /** Depth in the sidebar tree, 1 at the root. */
    level?: number;
    /** The one row of its tree that Tab lands on; arrows move between the others. */
    tabStop?: boolean;
  } = $props();

  let isHovered = $state(false);
  let tabItemEl: HTMLDivElement | undefined = $state();

  // The row owns its active highlight; it is only held back while the SelectionIndicator
  // travel ghost is still flying toward this row, so both are never visible at once.
  const travelHold = $derived(isActive && getSelectionTravelTarget() === tab.id);

  $effect(() => {
    if (!isActive || !tabItemEl) return;
    const el = tabItemEl;
    const t = setTimeout(() => {
      scrollActiveTabIntoView(el);
    }, 50);
    return () => clearTimeout(t);
  });
  // Clear hover on window blur / tab hidden / sidebar drag start. Subscribes to the shared
  // module-level listeners in lib/hoverClear instead of registering its own, at 100+ tabs
  // that's the difference between 3 global listeners and 300+.
  $effect(() => {
    return subscribeHoverClear(
      () => {
        isHovered = false;
        clearTabPreview();
      },
      { reactToDndActiveChange: true },
    );
  });

  // A row closed under the pointer (Cmd+W) never gets its mouseleave.
  $effect(() => () => {
    if (isHovered) clearTabPreview();
  });

  // Live-refresh this tab's memory estimate only while it's hovered (tooltip visible).
  // The store ref-counts across tabs, so this shares one timer; cleanup covers unmount too.
  $effect(() => {
    if (!isHovered) return;
    // Untracked: every runtime patch hands this row a new `tab`, which must not restart the timer.
    startTabMemoryLiveRefresh(untrack(() => tab.id));
    return stopTabMemoryLiveRefresh;
  });

  const tooltipURL = $derived(tooltipTabURL(tab.url));

  function switchToTab() {
    if (!interactive) return;
    clearTabPreview();
    optimisticallyActivateTab(tab.id);
    tabActions.switchTo(tab.id);
  }

  function scrollActiveTabIntoView(el: HTMLElement): void {
    if (document.body.classList.contains("sidebar-dnd-active")) return;
    const container = el.closest<HTMLElement>(".space-scroll");
    if (!container) return;

    const rowRect = el.getBoundingClientRect();
    const viewRect = container.getBoundingClientRect();
    // The sticky pinned/unpinned divider overlays the first few pixels of the viewport.
    const topInset = 12;

    if (rowRect.top < viewRect.top + topInset) {
      container.scrollBy({
        top: rowRect.top - viewRect.top - topInset,
        behavior: prefersReducedMotion() ? "instant" : "smooth",
      });
      return;
    }
    if (rowRect.bottom > viewRect.bottom) {
      container.scrollBy({
        top: rowRect.bottom - viewRect.bottom,
        behavior: prefersReducedMotion() ? "instant" : "smooth",
      });
    }
  }

  function requestCloseTab() {
    if (!interactive) return;
    // The row unmounts on close, so its mouseleave never fires.
    clearTabPreview();

    const intent = resolveTabCloseIntent(tab);
    if (intent === "unpin") {
      tabActions.unpin(tab.id);
      return;
    }
    if (intent === "unbookmark") {
      tabActions.setBookmarked(tab.id, false);
      return;
    }
    tabActions.close(tab.id);
  }

  function closeTab(e: MouseEvent) {
    e.stopPropagation();
    requestCloseTab();
  }

  function toggleMute(e: MouseEvent) {
    e.stopPropagation();
    if (!interactive) return;
    tabActions.setMuted(tab.id, !tab.isMuted);
  }

  function toggleMicrophoneMute(e: MouseEvent) {
    e.stopPropagation();
    if (!interactive) return;
    tabActions.setMicrophoneMuted(tab.id, !tab.isMicrophoneMuted);
  }

  const closeButtonLabel = $derived(
    tab.isClosed && tab.isPinned ? t("tabItem.removePinnedTab") :
    tab.isClosed && tab.isBookmarked ? t("tabItem.removeBookmark") :
    t("tabItem.closeTab")
  );

  const usesPinnedRemovalIcon = $derived(tab.isClosed && tab.isPinned);
  // Action buttons are NEVER unmounted for transient states (drag in progress): they occupy
  // layout even when invisible, so unmounting them reflows the whole row on every drag start.
  // Transient disabling goes through `actionsInert` (inert attribute) instead.
  const showPreviewActions = $derived(previewActions || interactive);

  const isTerminal = $derived(tab.kind === "terminal");
  const isChanges = $derived(tab.kind === "changes");
  const pageTitle = $derived.by((): string => {
    if (tab.title && tab.title !== DEFAULT_TAB_TITLE) return tab.title;
    if (tab.url && tab.url !== "") return fallbackTabTitle(tab.url);
    return t(isTerminal ? "tabItem.terminal" : "tabItem.newTab");
  });
  // Away from its home page, a saved tab keeps the name of its home (or its own), and the page it is on follows.
  const awayTitle = $derived(tab.homeTitle ? pageTitle : "");
  const displayTitle = $derived(tab.customTitle || tab.homeTitle || pageTitle);
  const isEmptyNewTab = $derived(
    !isTerminal && !isChanges && !tab.url && (!tab.title || tab.title === "" || tab.title === DEFAULT_TAB_TITLE),
  );
  // Only states worth a glance: a running command, or how the last one ended.
  const terminalStateLabel = $derived.by((): string => {
    if (!isTerminal) return "";
    if (tab.terminalState === "busy") return t("tabItem.terminalBusy");
    if (tab.terminalState === "waiting") return t("tabItem.terminalWaiting");
    if (tab.terminalState === "failed") return t("tabItem.terminalFailed");
    if (tab.terminalState === "succeeded") return t("tabItem.terminalSucceeded");
    return "";
  });

  // A running program prints all the time (an agent's spinner): its pip already says so, and the
  // dot marks only a result not seen yet.
  const hasUnreadOutput = $derived(
    isTerminal && !!tab.hasUnreadOutput && !isActive && tab.terminalState !== "busy" && tab.terminalState !== "waiting",
  );
  // The one insistent signal: a background program (typically an agent) or page dialog waits for an answer.
  const awaitingInput = $derived(!!tab.awaitingInputSince && !isActive);
  // The shell starts on first show: until then the terminal reports no state at all.
  const isTerminalAsleep = $derived(isTerminal && !tab.terminalState);
  const terminalIconLabel = $derived(
    isTerminalAsleep
      ? t("tabItem.sleeping")
      : [
          awaitingInput ? t("tabItem.terminalAttention") : "",
          terminalStateLabel,
          hasUnreadOutput ? t("tabItem.terminalUnread") : "",
        ].filter(Boolean).join(", "),
  );

  // A running program shows its own logo; at the prompt, or for an unknown program, the glyph
  // keeps drawing the command state.
  const programIcon = $derived.by(() => {
    if (!isTerminal || (tab.terminalState !== "busy" && tab.terminalState !== "waiting")) {
      return undefined;
    }
    if (!lookupProgramIcon && !programIconsRequested) {
      programIconsRequested = true;
      void import("../../lib/terminalIcons").then((module) => {
        lookupProgramIcon = module.terminalProgramIcon;
      });
    }
    return lookupProgramIcon?.(tab.terminalCommand ?? "");
  });

  // One line like web tabs: what runs, else the folder, which then joins on the right.
  const terminalLabel = $derived(isTerminal && !tab.customTitle ? terminalTitle(tab) : "");
  const terminalHint = $derived.by((): string => {
    if (isChanges) return terminalFolder(tab.cwd ?? "");
    if (!terminalLabel) return "";
    const folder = terminalFolder(tab.cwd ?? "");
    return folder !== terminalLabel ? folder : "";
  });
  // The row's accessible name carries the states its icons only show.
  const agentActing = $derived(getActingAgentTabIds().has(tab.id));
  const hangSeconds = $derived(getHangSeconds(tab.id));
  const hangRepeat = $derived(hangSeconds !== null && !!getPageHang(tab.id)?.repeat);
  const rowLabel = $derived(
    [
      terminalLabel || displayTitle,
      agentActing ? t("tabItem.agentActing") : "",
      hangSeconds !== null ? t("tabItem.notResponding") : "",
      tab.isPinned ? t("tabItem.pinned") : "",
      tab.isLoading ? t("tabItem.loading") : "",
      tab.isMuted ? t("tabItem.muted") : tab.isAudioPlaying ? t("tabItem.playingAudio") : "",
      tab.isClosed && !isTerminal ? t("tabItem.sleeping") : "",
      awaitingInput && !isTerminal ? t("tabItem.terminalAttention") : "",
      terminalIconLabel,
    ].filter(Boolean).join(", "),
  );
  // Only work, a question or a failure draws on the tile: a quiet success needs no mark, nor does
  // a program idling at its prompt ("waiting", an agent between turns).
  const terminalPip = $derived(
    awaitingInput ? "attention"
      : tab.terminalState === "busy" || tab.terminalState === "failed" ? tab.terminalState
      : "",
  );

  const isCloseVisible = $derived(isHovered || isActive);

  // Read only while hovered, like the memory line: a running command's elapsed time is taken then.
  const terminalStatusDetail = $derived.by((): string => {
    if (!isTerminal || !isHovered || !terminalStateLabel) return "";
    const command = tab.terminalCommand || t("tabItem.terminalCommand");
    if (tab.awaitingInputSince) {
      return t("tabItem.terminalAwaitingFor", { command, duration: formatTerminalDuration((Date.now() - tab.awaitingInputSince) / 1000) });
    }
    if (tab.terminalState === "busy" || tab.terminalState === "waiting") {
      if (!tab.terminalStartedAt) return t("tabItem.terminalBusy");
      return t("tabItem.terminalRunningFor", { command, duration: formatTerminalDuration((Date.now() - tab.terminalStartedAt) / 1000) });
    }
    const duration = formatTerminalDuration(tab.terminalDuration ?? 0);
    return tab.terminalState === "failed"
      ? t("tabItem.terminalFailedDetail", { command, code: String(tab.terminalExitCode ?? 0), duration })
      : t("tabItem.terminalSucceededDetail", { command, duration });
  });

  // Read only while hovered: the shared process snapshot lands every 2s, and an ungated read
  // would rebuild the tooltip params of every mounted row on each tick.
  const tooltipMemory = $derived.by((): string => {
    if (!isHovered) return "";
    return tabUsageLabel(tab.id);
  });

  // Boolean hop: a preview opening on another row re-runs this comparison per row, but only the
  // two rows that actually flip rebuild their tooltip params.
  const isPreviewedTab = $derived(getTabPreviewTabId() === tab.id);

  const isRenaming = $derived(interactive && getRenamingTabId() === tab.id);

  const tooltipContent = $derived({
    text: awayTitle ? `${displayTitle} / ${awayTitle}` : displayTitle,
    subtitle: isTerminal
      ? terminalStatusDetail || [tab.cwd, tab.gitBranch].filter(Boolean).join(" · ")
      : tooltipURL,
    memory: tooltipMemory,
    iconSrc: tab.faviconDataURL,
    // Shown only on a deliberate dwell: sweeping across rows should not pop one per row.
    delay: 1000,
    placement: tooltipSide(),
    anchor: tooltipAnchor,
    // The floating preview card already names the tab; both at once would stack
    // to the right of the row.
    disabled: disableTooltip || isPreviewedTab || isRenaming,
  });

  let renameInput: HTMLInputElement | undefined = $state();
  let draftTitle = $state("");

  $effect(() => {
    if (!isRenaming) return;
    draftTitle = untrack(() => displayTitle);
    clearTabPreview();
    queueMicrotask(() => {
      renameInput?.focus();
      renameInput?.select();
    });
  });

  function commitRename() {
    if (!isRenaming) return;
    setRenamingTabId(null);
    const name = draftTitle.trim();
    // Confirming the name the row already shows keeps an unnamed tab following its page.
    if (name !== displayTitle) tabActions.rename(tab.id, name);
  }

  function handleRenameKeydown(e: KeyboardEvent) {
    if (e.key === "Enter") {
      e.preventDefault();
      commitRename();
      tabItemEl?.focus();
    } else if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      setRenamingTabId(null);
      tabItemEl?.focus();
    }
  }

  // Arc's cue: the favicon of a saved tab away from home takes it back there.
  function returnHome() {
    if (interactive && tab.homeTitle) tabActions.returnHome(tab.id);
  }

  function handleContextMenu(e: MouseEvent) {
    e.preventDefault();
    e.stopPropagation();
    if (!interactive) return;
    const el = e.currentTarget as HTMLElement;
    const rect = el.getBoundingClientRect();
    tabActions.showContextMenu(
      tab.id,
      rect.left,
      rect.top,
      rect.width,
      rect.height,
    );
  }

  function iconMorph(_node: Element) {
    return {
      duration: prefersReducedMotion() ? 0 : 200,
      easing: cubicOut,
      css: (t: number) => `
        opacity: ${t};
        transform: scale(${0.55 + 0.45 * t});
      `,
    };
  }

  // Pops out of the icon's corner on arrival and shrinks back into it on leaving.
  function pipPop(_node: Element, { leaving = false }: { leaving?: boolean } = {}) {
    return {
      duration: prefersReducedMotion() ? 0 : leaving ? 160 : 320,
      easing: leaving ? cubicOut : springEase,
      css: (t: number) => `opacity: ${Math.min(1, t * 2)}; transform: scale(${t});`,
    };
  }
</script>

<div
  bind:this={tabItemEl}
  data-tab-id={tab.id}
  class="tab-item"
  class:active={isActive}
  class:needs-attention={awaitingInput}
  class:travel-hold={travelHold}
  class:closed={tab.isClosed}
  class:loading={tab.isLoading}
  class:interactive
  style={`${
    tab.faviconDominantColor
      ? `--tab-glow: ${tab.faviconDominantColor};`
      : ""
  }${
    isActive && isChromaticHex(tab.faviconDominantColor)
      ? `--tab-tint: ${tab.faviconDominantColor};`
      : ""
  }`}
  role="treeitem"
  tabindex={interactive && tabStop ? 0 : -1}
  aria-level={level}
  aria-selected={isActive}
  aria-label={rowLabel}
  use:tooltip={tooltipContent}
  onclick={switchToTab}
  oncontextmenu={handleContextMenu}
  onkeydown={(e) => {
    if (!interactive) return;
    // The action buttons live inside the row; their keystrokes bubble through here.
    if (e.target !== e.currentTarget) return;
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      switchToTab();
    }
    if (e.key === "Delete" || e.key === "Backspace") {
      requestCloseTab();
    }
  }}
  onmouseenter={(e) => {
    if (document.body.classList.contains("sidebar-dnd-active")) return;
    isHovered = true;
    if (interactive) {
      const rect = e.currentTarget.getBoundingClientRect();
      hoverTabPreview(
        { id: tab.id, title: displayTitle, url: tab.url ?? "", favicon: isTerminal ? "" : tab.faviconDataURL },
        rect,
      );
    }
  }}
  onmouseleave={() => {
    isHovered = false;
    leaveTabPreview();
  }}
>
  <!-- A pointer shortcut: the keyboard reaches the home page through the row's menu. -->
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="tab-icon" class:returns-home={!!tab.homeTitle && interactive} onclick={returnHome}>
    <!-- Transitions live on each branch root so an isLoading flip swaps content without
         destroying and rebuilding the whole keyed subtree (favicon img included) -->
    {#if isTerminal}
      <div class="tab-icon-inner" in:iconMorph out:iconMorph>
        <span
          class="terminal-tile"
          class:asleep={isTerminalAsleep}
          role={terminalIconLabel ? "img" : undefined}
          aria-label={terminalIconLabel || undefined}
          aria-hidden={terminalIconLabel ? undefined : true}
        >
          {#if programIcon}
            <svg
              class="program-logo"
              style={programIcon.color ? `color: ${programIcon.color}` : undefined}
              width="10"
              height="10"
              viewBox="0 0 24 24"
            >
              <path d={programIcon.path} fill="currentColor"/>
            </svg>
          {:else}
            <svg class="terminal-prompt" width="11" height="11" viewBox="0 0 16 16" fill="none">
              <path d="m3.5 4.5 3.5 3.5-3.5 3.5"/>
              <path d="M8.5 11.5h4"/>
            </svg>
          {/if}
          {#if terminalPip}
            <span class="terminal-pip" data-state={terminalPip} in:pipPop out:pipPop={{ leaving: true }}></span>
          {/if}
        </span>
      </div>
    {:else if isChanges}
      <div class="tab-icon-inner" in:iconMorph out:iconMorph>
        <span class="changes-tile" aria-hidden="true">
          <svg width="11" height="11" viewBox="0 0 16 16" fill="none">
            <path d="M5 2.5v6M2 5.5h6"/>
            <path d="M8.5 12h5"/>
          </svg>
        </span>
      </div>
    {:else if hangSeconds !== null}
      <div class="tab-icon-inner" in:iconMorph out:iconMorph>
        <svg class="hang-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M7 3h10M7 21h10M8 3v4l4 5-4 5v4M16 3v4l-4 5 4 5v4"/>
        </svg>
      </div>
    {:else if tab.isLoading}
      <div class="tab-icon-inner" in:iconMorph out:iconMorph>
        <TabLoader />
      </div>
    {:else if isEmptyNewTab}
      <div class="tab-icon-inner" in:iconMorph out:iconMorph>
        <span class="tab-empty-icon">+</span>
      </div>
    {:else}
      <div class="tab-icon-inner" in:iconMorph out:iconMorph>
        <SiteFavicon
          src={tab.faviconDataURL}
          title={tab.title}
          url={tab.url}
          size={16}
          radius={4}
        />
      </div>
    {/if}
    {#if agentActing}
      <span class="agent-pip" aria-hidden="true" in:pipPop out:pipPop={{ leaving: true }}></span>
    {/if}
  </div>

  {#if isRenaming}
    <input
      bind:this={renameInput}
      bind:value={draftTitle}
      class="tab-title-input"
      type="text"
      spellcheck="false"
      aria-label={t("tabItem.tabName")}
      onclick={(e) => e.stopPropagation()}
      ondblclick={(e) => e.stopPropagation()}
      onkeydown={handleRenameKeydown}
      onblur={commitRename}
    />
  {:else}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <span
      class="tab-title"
      ondblclick={tab.isPinned && interactive ? () => setRenamingTabId(tab.id) : undefined}
    >{terminalLabel || displayTitle}{#if awayTitle}<span class="away-title"><span class="away-slash" aria-hidden="true">/</span>{awayTitle}</span>{/if}</span>
  {/if}
  {#if terminalHint}
    <span class="terminal-hint">{terminalHint}</span>
  {/if}
  {#if hangSeconds !== null}
    <span class="hang-timer">{hangRepeat ? t("tabItem.hangAgain") : t("tabItem.hangSeconds", { seconds: String(hangSeconds) })}</span>
  {/if}
  {#if hasUnreadOutput}
    <span class="terminal-unread" aria-hidden="true"></span>
  {/if}

  <div class="tab-actions" inert={actionsInert || undefined}>
    {#if tab.isCameraActive}
      <span
        class="status-icon"
        role="img"
        aria-label={t("tabItem.cameraInUse")}
        use:tooltip={{ text: t("tabItem.cameraInUse"), placement: tooltipSide() }}
      >
        <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
          <rect x="1.4" y="3.4" width="6" height="5.2" rx="1.1" stroke="currentColor" stroke-width="1.2"/>
          <path d="M7.8 5.2 10.6 3.9v4.2L7.8 6.8z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/>
        </svg>
      </span>
    {/if}

    {#if tab.isMicrophoneActive}
      <button
        type="button"
        class="action-btn mic-btn"
        class:muted={tab.isMicrophoneMuted}
        aria-label={tab.isMicrophoneMuted ? t("tabItem.unmuteMicrophone") : t("tabItem.muteMicrophone")}
        onclick={toggleMicrophoneMute}
      >
        {#if tab.isMicrophoneMuted}
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
            <path d="M4 2.8C4 1.8 4.8 1 5.8 1H6.2C7.2 1 8 1.8 8 2.8V5.2C8 6.2 7.2 7 6.2 7H5.8C4.8 7 4 6.2 4 5.2V2.8Z" fill="currentColor" opacity="0.5"/>
            <path d="M2.6 5.2C2.6 7 4.1 8.4 6 8.4M9.4 5.2C9.4 5.9 9.2 6.5 8.8 7" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>
            <path d="M6 8.4V10.2M4.6 10.2H7.4" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>
            <path d="M2 2L10 10" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>
          </svg>
        {:else}
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
            <path d="M4 2.8C4 1.8 4.8 1 5.8 1H6.2C7.2 1 8 1.8 8 2.8V5.2C8 6.2 7.2 7 6.2 7H5.8C4.8 7 4 6.2 4 5.2V2.8Z" fill="currentColor"/>
            <path d="M2.6 5.2C2.6 7 4.1 8.4 6 8.4C7.9 8.4 9.4 7 9.4 5.2" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>
            <path d="M6 8.4V10.2M4.6 10.2H7.4" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>
          </svg>
        {/if}
      </button>
    {/if}

    {#if tab.isScreenSharing}
      <span
        class="status-icon"
        role="img"
        aria-label={t("tabItem.sharingScreen")}
        use:tooltip={{ text: t("tabItem.sharingScreen"), placement: tooltipSide() }}
      >
        <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
          <rect x="1.4" y="2" width="9.2" height="6.4" rx="1.1" stroke="currentColor" stroke-width="1.2"/>
          <path d="M4.5 10.4h3" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>
        </svg>
      </span>
    {/if}

    {#if tab.hasPopup}
      <span
        class="status-icon"
        role="img"
        aria-label={t("tabItem.popupOpen")}
        use:tooltip={{ text: t("tabItem.popupOpen"), placement: tooltipSide() }}
      >
        <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
          <rect x="1.2" y="3.6" width="7.2" height="7.2" rx="1.2" stroke="currentColor" stroke-width="1.2"/>
          <path d="M4.4 1.2h6.4v6.4" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
      </span>
    {/if}

    {#if (tab.isAudioPlaying || tab.isMuted) && showPreviewActions}
      <button
        type="button"
        class="action-btn audio-btn"
        class:muted={tab.isMuted}
        aria-label={tab.isMuted ? t("tabItem.unmute") : t("tabItem.mute")}
        onclick={toggleMute}
      >
        {#if tab.isMuted}
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
            <path d="M2 4.5H3.5L6.5 2V10L3.5 7.5H2V4.5Z" fill="currentColor" opacity="0.5"/>
            <path d="M8.5 4.5L10.5 6.5M10.5 4.5L8.5 6.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>
          </svg>
        {:else}
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
            <path d="M2 4.5H3.5L6.5 2V10L3.5 7.5H2V4.5Z" fill="currentColor"/>
            <path d="M8 4.5C8.83 5 8.83 7 8 7.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>
            <path d="M9.5 3.5C11 4.5 11 7.5 9.5 8.5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>
          </svg>
        {/if}
      </button>
    {/if}

    {#if interactive}
      <button
        class="action-btn close-btn"
        class:visible={isCloseVisible}
        aria-label={closeButtonLabel}
        aria-hidden={!isCloseVisible}
        tabindex={isCloseVisible ? 0 : -1}
        onclick={closeTab}
      >
        {#if usesPinnedRemovalIcon}
          <svg width="10" height="10" viewBox="0 0 10 10" fill="none">
            <path
              d="M2.2 5H7.8"
              stroke="currentColor"
              stroke-width="1.3"
              stroke-linecap="round"
            />
          </svg>
        {:else}
          <svg width="10" height="10" viewBox="0 0 10 10" fill="none">
            <path
              d="M2 2L8 8M8 2L2 8"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linecap="round"
            />
          </svg>
        {/if}
      </button>
    {/if}
  </div>
</div>

<style>
  .tab-item {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    min-width: 0;
    padding: 6px;
    height: 28px;
    box-sizing: border-box;
    border-radius: var(--radius-md);
    cursor: default;
    transition:
      background var(--transition-fast),
      box-shadow var(--transition-fast),
      transform 220ms var(--motion-ease-spring),
      max-width 220ms var(--motion-ease-spring),
      padding 220ms var(--motion-ease-spring),
      gap 220ms var(--motion-ease-spring);
    contain: layout style paint;
    overflow: hidden;
    position: relative;
    max-width: 100%;
  }

  .tab-item.interactive {
    cursor: pointer;
  }

  /* A fifth of the selected row's surface: hover leans the way selection does, clearly weaker. */
  .tab-item:hover {
    background: color-mix(in srgb, var(--tab-glow, transparent) 3%, color-mix(in srgb, var(--bg-selected) 20%, transparent));
  }

  .tab-item:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  /* `.travel-hold` keeps the row's highlight back while the SelectionIndicator ghost flies here; the recipe must stay
     identical to `.selection-ghost` so landing is seamless. */
  .tab-item.active:not(.travel-hold) {
    background: color-mix(in srgb, var(--tab-tint, var(--accent)) 18%, var(--bg-selected));
  }

  /* A sleeping tab keeps full-strength text: italic and a greyed icon say it sleeps, not a fade. */
  .tab-item.closed .tab-title {
    color: var(--text-primary);
    font-style: italic;
  }

  .tab-item.closed .tab-icon {
    filter: grayscale(1);
    opacity: 0.55;
  }

  .tab-icon {
    width: 16px;
    height: 16px;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    position: relative;
  }

  .tab-icon-inner {
    position: absolute;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 16px;
    height: 16px;
  }

  .tab-empty-icon {
    width: 16px;
    height: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-primary);
    font-size: var(--font-size-xl);
    line-height: 1;
  }

  .tab-title {
    flex: 1;
    min-width: 0;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    font-size: var(--font-size-md);
    line-height: 1.3;
    color: var(--text-primary);
  }

  .away-title {
    color: var(--text-secondary);
  }

  .away-slash {
    margin: 0 5px;
    opacity: 0.6;
  }

  .tab-icon.returns-home:hover {
    opacity: 0.7;
  }

  .tab-title-input {
    flex: 1;
    min-width: 0;
    height: 22px;
    box-sizing: border-box;
    margin: 0 -7px;
    padding: 0 6px;
    border: 1px solid color-mix(in srgb, var(--accent) 50%, transparent);
    border-radius: var(--radius-sm);
    background: color-mix(in srgb, var(--bg-hover) 88%, transparent);
    color: var(--text-primary);
    font: inherit;
    font-size: var(--font-size-md);
    line-height: 1.3;
    outline: none;
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 18%, transparent);
  }

  .tab-actions {
    display: flex;
    align-items: center;
    gap: 2px;
    flex-shrink: 0;
  }

  /* During a sidebar drag the buttons stay mounted (unmounting them would reflow every row)
     but go inert: no clicks, no focus, just dimmed. `inert` suppresses pointer events itself. */
  .tab-actions[inert] {
    opacity: 0.45;
  }

  /* Base .action-btn recipe is global (styles/utilities.css). */
  .action-btn {
    font-size: var(--font-size-xs);
  }

  /* One recipe for the row's controls: no surface at rest, and a surface on hover that reads
     above the row's own hover paint, --bg-hover there would land on itself and stay invisible. */
  .audio-btn,
  .mic-btn,
  .close-btn {
    background: transparent;
    color: var(--text-muted);
  }

  /* Muted is a state, not a transient: the button keeps a surface so the row reads as muted
     at a glance, and hover still lifts it one step. */
  .audio-btn.muted,
  .mic-btn.muted {
    background: var(--text-primary-tint-10);
    color: var(--text-primary);
  }

  .audio-btn:hover,
  .mic-btn:hover,
  .close-btn:hover {
    background: var(--text-primary-tint-12);
    color: var(--text-primary);
  }

  /* Capture is reported, not operated: no button box, no hover affordance, and the only colour
     in the row so it reads as the live signal. */
  .status-icon {
    width: 16px;
    height: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    color: var(--danger-vivid);
  }

  .close-btn {
    transition:
      background var(--transition-fast),
      color var(--transition-fast),
      opacity var(--transition-fast),
      transform var(--transition-fast);
  }

  /* Collapsed, not just hidden: an always-reserved slot would shorten every title for a control
     that only appears on hover or on the active row. The slot opens instantly and the button
     fades into it; on the way out the collapse waits for the fade, so it never slides. */
  .close-btn:not(.visible) {
    width: 0;
    opacity: 0;
    transform: scale(0.8);
    overflow: hidden;
    pointer-events: none;
    transition:
      opacity var(--transition-fast),
      transform var(--transition-fast),
      width 0s var(--transition-fast);
  }

  /* Except when the row already shows audio/capture controls: there the slot stays reserved so
     opening the close button never slides them sideways. Only those rows pay the width. */
  .tab-actions > :not(.close-btn) ~ .close-btn:not(.visible) {
    width: 20px;
  }

  /* A dark tile stands in for the favicon: terminals read apart from pages at a glance, in both
     themes, without taking more room than a favicon. */
  /* Same box as a 16px favicon (SiteFavicon, radius 4) so it lines up as a square with the rest. */
  .terminal-tile {
    position: relative;
    width: 16px;
    height: 16px;
    border-radius: var(--radius-xs);
    display: grid;
    place-items: center;
    background: var(--terminal-tile-bg);
    box-shadow: inset 0 0 0 1px var(--terminal-tile-border);
    color: var(--terminal-tile-text);
  }

  .terminal-tile.asleep {
    opacity: 0.55;
  }

  .terminal-prompt {
    stroke: var(--terminal-tile-accent);
    stroke-width: 1.8;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  .program-logo {
    color: var(--terminal-tile-text);
  }

  /* Static like the terminal pip: the agent acts in bursts, and a loop would keep the display link up. */
  .agent-pip {
    position: absolute;
    right: -3px;
    bottom: -3px;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--agents);
    box-shadow: 0 0 0 1.5px var(--sidebar-bg);
  }

  .terminal-pip {
    position: absolute;
    right: -3px;
    bottom: -3px;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    box-shadow: 0 0 0 1.5px var(--sidebar-bg);
    transition: background var(--motion-duration-normal) ease;
  }

  /* Lightened so it reads on any space's sidebar colour. Still, never looping: an agent's spinner
     keeps a terminal busy for hours, and a looping animation runs WebKit's display link all along. */
  .terminal-pip[data-state="busy"] {
    background: color-mix(in srgb, var(--accent) 55%, white);
  }

  .terminal-pip[data-state="failed"] {
    background: var(--danger);
  }

  .terminal-pip[data-state="attention"] {
    background: var(--attention);
  }

  .tab-item.needs-attention {
    background: color-mix(in srgb, var(--attention) 14%, transparent);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--attention) 40%, transparent);
  }

  /* The attention amber, pulled toward the text color so it reads on light and dark sidebars. */
  .hang-icon,
  .hang-timer {
    color: color-mix(in srgb, var(--attention) 20%, var(--text-primary));
  }

  .hang-icon {
    /* A flip every 2 s, then rest: a page stuck for minutes must not keep the display link running. */
    animation: hang-flip 2s ease-in-out 15 forwards;
  }

  @keyframes hang-flip {
    0%, 70% {
      transform: rotate(0deg);
    }
    100% {
      transform: rotate(180deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .hang-icon {
      animation: none;
    }
  }

  .hang-timer {
    flex: none;
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    font-variant-numeric: tabular-nums;
  }

  .terminal-hint {
    flex: none;
    max-width: 40%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: var(--font-size-sm);
    color: var(--text-muted);
  }

  .changes-tile {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 16px;
    height: 16px;
    border-radius: var(--radius-xs);
    border: 1.5px solid var(--accent);
    color: var(--accent);
  }

  .changes-tile path {
    stroke: currentColor;
    stroke-width: 1.8;
    stroke-linecap: round;
  }

  .terminal-unread {
    flex: none;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--accent);
  }
</style>
