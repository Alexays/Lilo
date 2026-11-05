<script lang="ts">
  import { onDestroy } from "svelte";
  import { on, postMessage } from "../../lib/bridge";
  import { onSidebarApplied } from "../../stores/sidebar.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { tabActions } from "../../lib/bridge/actions";
  import { isSidebarVisible } from "../../stores/ui.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { shortcutKeys } from "../../stores/shortcutKeys.svelte";

  type FindStatus = "idle" | "found" | "not-found";

  let visible = $state(false);
  let query = $state("");
  let status = $state<FindStatus>("idle");
  let hasSearched = $state(false);
  let caseSensitive = $state(false);
  let match = $state<{ index: number; count: number }>();
  let inputEl: HTMLInputElement | undefined = $state();
  let lastSearchedQuery = "";
  let currentActiveSpaceId = "";
  let currentActiveTabId = "";
  let searchTimer: ReturnType<typeof setTimeout> | undefined;

  const canNavigate = $derived(
    hasSearched && status === "found" && query.trim().length > 0,
  );

  $effect(() => {
    const offToggle = on("toggleFindBar", (data) => {
      visible = true;
      if (typeof data.query === "string" && data.query.trim()) {
        query = data.query;
        search();
      }
      focusInput();
    });
    const offResult = on("findInPageResult", (data) => {
      if (!visible || typeof data.query !== "string" || data.query !== lastSearchedQuery) return;
      status = data.matchFound ? "found" : "not-found";
      match = data.matchFound && data.matchIndex && data.matchCount ? { index: data.matchIndex, count: data.matchCount } : undefined;
      hasSearched = true;
    });
    // As in Chrome, a new document ends the search of the old one, which a find bar opened during the load only forgets.
    const offCommitted = on("findPageCommitted", (data) => {
      if (!visible) return;
      if (data.closeFindBar) {
        dismiss();
      } else {
        clearResult();
        lastSearchedQuery = "";
      }
    });
    const offInitialState = on("initialState", (data) => {
      updateContext(data.activeSpaceId, data.activeTabId);
    });
    // Structural sidebar changes (full replace or sidebarChanged patch) move the active
    // tab/space context; dismiss when it actually changed.
    const offSidebar = onSidebarApplied((event) => {
      applyContextChange(event.spaceId, event.activeTabId);
    });
    return () => {
      offToggle();
      offResult();
      offCommitted();
      offInitialState();
      offSidebar();
    };
  });

  function applyContextChange(spaceId?: string, tabId?: string) {
    const nextSpaceId = typeof spaceId === "string" && spaceId ? spaceId : currentActiveSpaceId;
    const nextTabId = typeof tabId === "string" ? tabId : currentActiveTabId;
    const changedContext =
      (currentActiveSpaceId && nextSpaceId !== currentActiveSpaceId) ||
      (currentActiveTabId && nextTabId !== currentActiveTabId);

    updateContext(nextSpaceId, nextTabId);
    if (visible && changedContext) {
      dismiss();
    }
  }

  function updateContext(spaceId?: string, tabId?: string) {
    currentActiveSpaceId = spaceId || "";
    currentActiveTabId = tabId || "";
  }

  function focusInput() {
    requestAnimationFrame(() => {
      inputEl?.focus();
      inputEl?.select();
    });
  }

  function clearResult() {
    status = "idle";
    hasSearched = false;
    match = undefined;
  }

  // The query stays for the next opening, selected; the engine keeps it for Find Next with the bar closed.
  function dismiss() {
    clearTimeout(searchTimer);
    searchTimer = undefined;
    visible = false;
    clearResult();
    lastSearchedQuery = "";
    tabActions.dismissFind();
    postMessage("focusPage");
  }

  // Spaces are part of the query, as in Chrome: "cat " skips "category". Only a blank query searches nothing.
  function search() {
    clearTimeout(searchTimer);
    searchTimer = undefined;
    if (query.trim()) {
      if (query !== lastSearchedQuery) clearResult();
      lastSearchedQuery = query;
      tabActions.findInPage(query, { caseSensitive });
    } else {
      clearResult();
      lastSearchedQuery = "";
      tabActions.dismissFind();
    }
  }

  // Each search scans the whole page: typing waits for a pause, while any explicit action
  // runs the pending search at once so it never navigates the matches of a stale query.
  function scheduleSearch() {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(search, 100);
  }

  function next() {
    if (searchTimer !== undefined) {
      search();
      return;
    }
    if (!canNavigate) return;
    tabActions.findNext();
  }

  function previous() {
    if (searchTimer !== undefined) {
      search();
      return;
    }
    if (!canNavigate) return;
    tabActions.findPrevious();
  }

  function toggleCaseSensitive() {
    caseSensitive = !caseSensitive;
    if (query.trim()) {
      search();
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === "Escape") {
      dismiss();
      e.preventDefault();
      return;
    }
    // Enter on a focused button is its click; only the input drives search.
    if (e.target !== inputEl) return;
    if (e.key === "Enter" && e.shiftKey) {
      previous();
      e.preventDefault();
      return;
    }
    if (e.key === "Enter") {
      if (!query.trim()) return;
      if (hasSearched) {
        next();
      } else {
        search();
      }
      e.preventDefault();
    }
  }

  onDestroy(() => clearTimeout(searchTimer));
</script>

{#if visible}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="find-bar float-surface"
    class:sidebar-hidden={!isSidebarVisible()}
    use:reportInteractiveZone={{ id: "findBar", active: visible }}
    onkeydown={handleKeydown}
  >
    <div class="find-field" class:not-found={status === "not-found"}>
      <svg class="find-icon" width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true">
        <circle cx="7" cy="7" r="4.75" stroke="currentColor" stroke-width="1.5" />
        <path d="M10.5 10.5 14 14" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
      </svg>
      <input
        bind:this={inputEl}
        bind:value={query}
        class="find-input"
        placeholder={t("findBar.placeholder")}
        aria-label={t("findBar.inputLabel")}
        oninput={scheduleSearch}
        spellcheck="false"
      />
      <!-- Always mounted: a live region only announces changes made while it is in the DOM. -->
      <span class="find-status" class:not-found={status === "not-found"} role="status"
        >{#if status === "not-found"}{t("findBar.noResults")}{:else if match}{t("findBar.matchCount", { current: match.index, total: match.count })}{/if}</span
      >
    </div>
    <button
      class="find-btn case-btn"
      class:active={caseSensitive}
      onclick={toggleCaseSensitive}
      aria-label={t("findBar.matchCase")}
      aria-pressed={caseSensitive}
      use:tooltip={{ text: t("findBar.matchCase"), placement: "bottom" }}>Aa</button
    >
    <div class="find-steps">
      <button
        class="find-btn"
        onclick={previous}
        disabled={!canNavigate}
        aria-label={t("findBar.previousMatch")}
        use:tooltip={{ text: t("findBar.previousMatch"), shortcut: shortcutKeys("find.previous"), placement: "bottom", disabled: !canNavigate }}
      >
        <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
          <path class="step-glyph up" d="m2.5 7.5 3.5-3.5 3.5 3.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
      </button>
      <button
        class="find-btn"
        onclick={next}
        disabled={!canNavigate}
        aria-label={t("findBar.nextMatch")}
        use:tooltip={{ text: t("findBar.nextMatch"), shortcut: shortcutKeys("find.next"), placement: "bottom", disabled: !canNavigate }}
      >
        <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
          <path class="step-glyph down" d="m2.5 4.5 3.5 3.5 3.5-3.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
      </button>
    </div>
    <button
      class="find-btn close-btn"
      onclick={dismiss}
      aria-label={t("findBar.closeFindBar")}
      use:tooltip={{ text: t("findBar.closeFindBar"), placement: "bottom" }}
    >
      <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
        <path class="close-glyph" d="M2 2L8 8M8 2L2 8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
      </svg>
    </button>
  </div>
{/if}

<style>
  .find-bar {
    position: fixed;
    top: calc(var(--chrome-content-top) + var(--chrome-overlay-edge-gap));
    right: calc(var(--chrome-content-right) + var(--chrome-overlay-edge-gap));
    max-width: calc(100vw - var(--chrome-content-left-visible) - var(--chrome-content-right) - 2 * var(--chrome-overlay-edge-gap));
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px;
    border-radius: var(--radius-lg);
    pointer-events: auto;
    z-index: 1000;
    animation: find-bar-in var(--motion-duration-overlay) var(--motion-ease-spring);
    transform-origin: 100% 0;
  }

  .find-bar.sidebar-hidden {
    max-width: calc(100vw - var(--chrome-content-left-hidden) - var(--chrome-content-right) - 2 * var(--chrome-overlay-edge-gap));
  }

  /* Only the field gives way in a narrow window. */
  .find-field {
    display: flex;
    align-items: center;
    gap: 6px;
    width: 240px;
    min-width: 0;
    height: 28px;
    padding: 0 8px;
    border-radius: var(--radius-sm);
    background: var(--bg-hover);
  }

  .find-field:focus-within {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .find-icon {
    flex: none;
    color: var(--text-secondary);
  }

  .find-input {
    flex: 1;
    min-width: 0;
    padding: 0;
    border: none;
    background: transparent;
    color: var(--text-primary);
    font-size: var(--font-size-md);
    outline: none;
  }

  .find-input::placeholder {
    color: var(--text-muted);
  }

  .find-status {
    flex: none;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }

  /* Darkened toward the text: the danger color alone falls short of AA on the field's tint. */
  .find-status.not-found {
    color: color-mix(in srgb, var(--danger-text) 75%, var(--text-primary));
  }

  /* Out of the row, not out of the accessibility tree: a hidden live region announces nothing. */
  .find-status:empty {
    position: absolute;
  }

  .find-steps {
    display: flex;
    flex: none;
    border-radius: var(--radius-sm);
    background: var(--bg-hover);
  }

  .find-btn {
    display: flex;
    flex: none;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    padding: 0;
    border: none;
    border-radius: var(--radius-sm);
    background: none;
    color: var(--text-primary);
    font-size: var(--font-size-sm);
    cursor: pointer;
  }

  .find-steps .find-btn {
    width: 28px;
  }

  .find-btn:hover:not(:disabled) {
    background: var(--bg-hover);
  }

  .find-btn:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -1px;
  }

  .find-btn.active {
    background: var(--accent-tint-14);
    color: var(--accent-ink);
  }

  .step-glyph,
  .close-glyph {
    transform-box: fill-box;
    transform-origin: center;
    transition: transform 320ms var(--motion-ease-spring);
  }

  .find-btn:hover:not(:disabled) .step-glyph.up {
    transform: translateY(-1.5px);
  }

  .find-btn:hover:not(:disabled) .step-glyph.down {
    transform: translateY(1.5px);
  }

  .find-btn:hover:not(:disabled) .close-glyph {
    transform: rotate(90deg);
  }

  .find-btn:disabled {
    cursor: default;
    opacity: var(--disabled-opacity);
  }

  .case-btn {
    width: 28px;
    font-weight: var(--font-weight-medium);
  }

  @keyframes find-bar-in {
    from {
      opacity: 0;
      transform: scale(0.96);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .find-bar {
      animation: find-bar-fade 150ms ease;
    }

    @keyframes find-bar-fade {
      from {
        opacity: 0;
      }
    }
  }
</style>
