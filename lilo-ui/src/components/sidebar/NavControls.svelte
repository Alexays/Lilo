<script lang="ts">
  import { chromeActions, tabActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { getActiveTab } from "../../stores/tabs.svelte";
  import { shortcutKeys } from "../../stores/shortcutKeys.svelte";

  type HistoryDirection = "back" | "forward";

  let { collapseLocked = false }: { collapseLocked?: boolean } = $props();

  const HISTORY_MENU_PRESS_DELAY_MS = 320;
  const HISTORY_MENU_CLICK_SUPPRESSION_MS = 520;

  let historyMenuTimer: ReturnType<typeof setTimeout> | null = null;
  let lastHistoryMenuDirection: HistoryDirection | null = null;
  let lastHistoryMenuOpenedAt = 0;

  const activeTab = $derived(getActiveTab());
  const canGoBack = $derived(activeTab?.canGoBack ?? false);
  const canGoForward = $derived(activeTab?.canGoForward ?? false);
  const isLoading = $derived(activeTab?.isLoading ?? false);
  const hasReloadTarget = $derived(!!activeTab?.url || !!activeTab?.navigationErrorURL);

  function cancelHistoryMenuPress() {
    if (historyMenuTimer !== null) clearTimeout(historyMenuTimer);
    historyMenuTimer = null;
  }

  function startHistoryMenuPress(
    direction: HistoryDirection,
    event: PointerEvent,
  ) {
    if (event.button !== 0) {
      return;
    }

    if (
      (direction === "back" && !canGoBack) ||
      (direction === "forward" && !canGoForward)
    ) {
      return;
    }

    cancelHistoryMenuPress();
    const target = event.currentTarget as HTMLElement | null;
    historyMenuTimer = setTimeout(() => {
      historyMenuTimer = null;
      if (!target) return;
      const { x, y, width, height } = target.getBoundingClientRect();
      lastHistoryMenuDirection = direction;
      lastHistoryMenuOpenedAt = Date.now();
      if (direction === "back") chromeActions.showBackHistoryMenu({ x, y, width, height });
      else chromeActions.showForwardHistoryMenu({ x, y, width, height });
    }, HISTORY_MENU_PRESS_DELAY_MS);
  }

  function handleHistoryClick(direction: HistoryDirection) {
    // The release that ends a long press opening the history menu is not a click.
    if (
      lastHistoryMenuDirection === direction &&
      Date.now() - lastHistoryMenuOpenedAt < HISTORY_MENU_CLICK_SUPPRESSION_MS
    ) {
      lastHistoryMenuDirection = null;
      lastHistoryMenuOpenedAt = 0;
      return;
    }

    if (direction === "back") {
      tabActions.goBack();
      return;
    }

    tabActions.goForward();
  }

  function handleWindowDragPointerDown(event: PointerEvent) {
    if (event.button !== 0) {
      return;
    }

    const target = event.target as HTMLElement | null;
    if (
      target?.closest("button, a, input, select, textarea, [role='button']")
    ) {
      return;
    }

    chromeActions.startWindowDrag();
  }
</script>

<div
  class="nav-controls"
  role="navigation"
  aria-label={t("nav.navigationControls")}
  onpointerdown={handleWindowDragPointerDown}
>
  <button
    class="nav-btn"
    aria-label={t("nav.collapseSidebar")}
    disabled={collapseLocked}
    use:tooltip={{ text: t("nav.collapseSidebar"), shortcut: shortcutKeys("sidebar.toggle"), placement: "bottom" }}
    onclick={() => chromeActions.toggleSidebar()}
  >
    <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
      <rect
        x="1.5"
        y="2"
        width="13"
        height="12"
        rx="2"
        stroke="currentColor"
        stroke-width="1.4"
      />
      <path d="M5.5 2v12" stroke="currentColor" stroke-width="1.4" />
    </svg>
  </button>

  <div class="nav-spacer"></div>

  <button
    class="nav-btn"
    aria-label={t("nav.goBack")}
    disabled={!canGoBack}
    use:tooltip={{ text: t("nav.goBack"), shortcut: shortcutKeys("history.back"), placement: "bottom", disabled: !canGoBack }}
    onclick={() => handleHistoryClick("back")}
    onpointerdown={(event) => startHistoryMenuPress("back", event)}
    onpointerup={cancelHistoryMenuPress}
    onpointercancel={cancelHistoryMenuPress}
    onpointerleave={cancelHistoryMenuPress}
  >
    <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
      <path
        d="M10 3L5 8L10 13"
        stroke="currentColor"
        stroke-width="1.8"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
  </button>

  <button
    class="nav-btn"
    aria-label={t("nav.goForward")}
    disabled={!canGoForward}
    use:tooltip={{ text: t("nav.goForward"), shortcut: shortcutKeys("history.forward"), placement: "bottom", disabled: !canGoForward }}
    onclick={() => handleHistoryClick("forward")}
    onpointerdown={(event) => startHistoryMenuPress("forward", event)}
    onpointerup={cancelHistoryMenuPress}
    onpointercancel={cancelHistoryMenuPress}
    onpointerleave={cancelHistoryMenuPress}
  >
    <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
      <path
        d="M6 3L11 8L6 13"
        stroke="currentColor"
        stroke-width="1.8"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
  </button>

  <button
    class="nav-btn"
    class:loading={isLoading}
    aria-label={isLoading ? t("nav.stopLoading") : t("nav.reload")}
    disabled={!isLoading && !hasReloadTarget}
    use:tooltip={isLoading
      ? { text: t("nav.stopLoading"), shortcut: shortcutKeys("page.stop"), placement: "bottom" }
      : hasReloadTarget
        ? { text: t("nav.reload"), shortcut: shortcutKeys("page.reload"), placement: "bottom" }
        : { text: t("nav.reloadUnavailable"), placement: "bottom" }}
    onclick={() =>
      isLoading ? tabActions.stopLoading() : tabActions.reload()}
  >
    <span class="nav-icon-stack" aria-hidden="true">
      <svg
        class="nav-morph-icon"
        width="14"
        height="14"
        viewBox="0 0 16 16"
        fill="none"
      >
        <path
          class="nav-morph-stroke nav-reload-arc"
          pathLength="1"
          d="M13.5 8A5.5 5.5 0 1 1 8 2.5"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
        <path
          class="nav-morph-stroke nav-reload-arrow"
          pathLength="1"
          d="M13.5 2.5v3h-3"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
        <path
          class="nav-morph-stroke nav-stop-line nav-stop-line-a"
          pathLength="1"
          d="M4.2 4.2L11.8 11.8"
          stroke="currentColor"
          stroke-width="1.8"
          stroke-linecap="round"
        />
        <path
          class="nav-morph-stroke nav-stop-line nav-stop-line-b"
          pathLength="1"
          d="M11.8 4.2L4.2 11.8"
          stroke="currentColor"
          stroke-width="1.8"
          stroke-linecap="round"
        />
      </svg>
    </span>
  </button>
</div>

<style>
  .nav-controls {
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 0;
    flex: 1;
    user-select: none;
    -webkit-user-select: none;
  }

  .nav-spacer {
    flex: 1;
    align-self: stretch;
    min-height: 28px;
    cursor: default;
  }

  .nav-btn {
    width: 28px;
    height: 28px;
    border: none;
    background: none;
    color: var(--text-secondary);
    cursor: pointer;
    border-radius: var(--radius-sm);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0;
    flex-shrink: 0;
    transition:
      background var(--transition-fast),
      color var(--transition-fast);
  }

  .nav-icon-stack {
    position: relative;
    width: 14px;
    height: 14px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
  }

  .nav-morph-icon {
    width: 14px;
    height: 14px;
    overflow: visible;
  }

  .nav-morph-stroke {
    transition:
      stroke-dashoffset 220ms var(--motion-ease-spring),
      opacity var(--motion-duration-normal) ease,
      transform 220ms var(--motion-ease-spring);
    transform-origin: 50% 50%;
    vector-effect: non-scaling-stroke;
  }

  .nav-reload-arc,
  .nav-reload-arrow {
    stroke-dasharray: 1;
    stroke-dashoffset: 0;
    opacity: 1;
  }

  .nav-reload-arc {
    transform: rotate(0deg) scale(1);
  }

  .nav-reload-arrow {
    transform: translate(0px, 0px) scale(1);
  }

  .nav-stop-line {
    stroke-dasharray: 1;
    stroke-dashoffset: 1;
    opacity: 0;
  }

  .nav-stop-line-a {
    transform: rotate(-14deg) scale(0.72);
  }

  .nav-stop-line-b {
    transform: rotate(14deg) scale(0.72);
  }

  .nav-btn.loading .nav-reload-arc,
  .nav-btn.loading .nav-reload-arrow {
    stroke-dashoffset: 1;
    opacity: 0;
  }

  .nav-btn.loading .nav-reload-arc {
    transform: rotate(120deg) scale(0.82);
  }

  .nav-btn.loading .nav-reload-arrow {
    transform: translate(0.35px, -0.2px) rotate(34deg) scale(0.7);
  }

  .nav-btn.loading .nav-stop-line {
    stroke-dashoffset: 0;
    opacity: 1;
  }

  .nav-btn.loading .nav-stop-line-a,
  .nav-btn.loading .nav-stop-line-b {
    transform: rotate(0deg) scale(1);
  }

  .nav-btn:hover:not(:disabled) {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .nav-btn:disabled {
    color: var(--text-muted);
    opacity: var(--disabled-opacity);
    cursor: default;
  }
</style>
