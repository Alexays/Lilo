<script lang="ts">
  import { onDestroy } from "svelte";
  import { on, postMessage } from "../../lib/bridge";
  import { onSidebarApplied } from "../../stores/sidebar.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { tabActions } from "../../lib/bridge/actions";
  import { isSidebarVisible } from "../../stores/ui.svelte";

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
    class="find-bar"
    class:sidebar-hidden={!isSidebarVisible()}
    use:reportInteractiveZone={{ id: "findBar", active: visible }}
    onkeydown={handleKeydown}
  >
    <input
      bind:this={inputEl}
      bind:value={query}
      class="find-input"
      class:not-found={status === "not-found"}
      placeholder={t("findBar.placeholder")}
      aria-label={t("findBar.inputLabel")}
      oninput={scheduleSearch}
      spellcheck="false"
    />
    <!-- Always mounted: a live region only announces changes made while it is in the DOM. -->
    <span class="find-status" class:not-found={status === "not-found"} role="status"
      >{#if status === "not-found"}{t("findBar.noResults")}{:else if match}{t("findBar.matchCount", { current: match.index, total: match.count })}{/if}</span
    >
    <button
      class="find-btn case-btn"
      class:active={caseSensitive}
      onclick={toggleCaseSensitive}
      aria-label={t("findBar.matchCase")}
      aria-pressed={caseSensitive}>Aa</button
    >
    <button
      class="find-btn"
      onclick={previous}
      disabled={!canNavigate}
      aria-label={t("findBar.previousMatch")}
    >
      <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
        <path d="m2.5 7.5 3.5-3.5 3.5 3.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>
    <button
      class="find-btn"
      onclick={next}
      disabled={!canNavigate}
      aria-label={t("findBar.nextMatch")}
    >
      <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
        <path d="m2.5 4.5 3.5 3.5 3.5-3.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>
    <button
      class="find-btn close-btn"
      onclick={dismiss}
      aria-label={t("findBar.closeFindBar")}
    >
      <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
        <path d="M2 2L8 8M8 2L2 8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
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
    gap: var(--density-1);
    background: var(--chrome-floating-surface);
    border: 1px solid var(--chrome-overlay-border);
    border-radius: var(--radius-lg);
    padding: var(--density-1) 8px;
    box-shadow: var(--chrome-floating-shadow);
    backdrop-filter: blur(var(--chrome-floating-blur));
    pointer-events: auto;
    z-index: 1000;
  }

  .find-bar.sidebar-hidden {
    max-width: calc(100vw - var(--chrome-content-left-hidden) - var(--chrome-content-right) - 2 * var(--chrome-overlay-edge-gap));
  }

  .find-input {
    background: var(--bg-primary);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
    font-size: var(--font-size-md);
    padding: 4px 8px;
    width: 220px;
    min-width: 0;
  }

  .find-input:focus {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .find-input.not-found {
    border-color: color-mix(in srgb, var(--danger) 58%, var(--border));
  }

  .find-input::placeholder {
    color: var(--text-muted);
  }

  .find-status {
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
    font-variant-numeric: tabular-nums;
    line-height: 1;
    padding: 0 var(--density-1);
    white-space: nowrap;
  }

  .find-status.not-found {
    color: var(--danger-text);
    font-weight: var(--font-weight-semibold);
  }

  /* Out of the row, not out of the accessibility tree: a hidden live region announces nothing. */
  .find-status:empty {
    position: absolute;
  }

  /* Only the input gives way in a narrow window. */
  .find-btn {
    flex: none;
    width: 24px;
    height: 24px;
    border: none;
    background: none;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    cursor: pointer;
    border-radius: var(--radius-sm);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0;
  }

  .find-btn:hover:not(:disabled) {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .find-btn:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .find-btn.active {
    background: color-mix(in srgb, var(--accent) 16%, transparent);
    color: var(--text-primary);
  }

  .find-btn:disabled {
    color: var(--text-muted);
    cursor: default;
    opacity: var(--disabled-opacity);
  }

  .close-btn {
    margin-left: 2px;
  }

  .case-btn {
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
  }
</style>
