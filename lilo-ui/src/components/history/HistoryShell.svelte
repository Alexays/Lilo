<script lang="ts">
  import { tick } from "svelte";
  import { on } from "../../lib/bridge";
  import { historyActions } from "../../lib/bridge/actions";
  import type { BridgeHistoryDayRow } from "../../lib/bridge/protocol";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiShellFrame from "../ui/UiShellFrame.svelte";
  import BottomConfirmSheet from "../ui/BottomConfirmSheet.svelte";
  import HistoryNav from "./HistoryNav.svelte";
  import { groupHistoryDays, rowKey, timeLabel } from "./historyPageModel";
  import { isHistoryShellOpen, openSettings, openSettingsSubpage } from "../../stores/panels.svelte";
  import { isVerticalLayout } from "../../stores/tabLayout.svelte";
  import {
    clearHistorySelection,
    deleteHistoryRows,
    deleteHistorySite,
    extendHistorySelection,
    getHistoryFavicon,
    getHistoryFilter,
    getHistoryRows,
    getHistorySelection,
    hasMoreHistory,
    isHistoryLoaded,
    loadMoreHistory,
    openHistoryRow,
    openHistoryRowInNewTab,
    openSelectedHistory,
    selectAllHistory,
    toggleHistoryRow,
    unwindHistory,
  } from "../../stores/history.svelte";

  const shellOpen = $derived(isHistoryShellOpen());
  const filter = $derived(getHistoryFilter());
  const rows = $derived(getHistoryRows());
  const selection = $derived(getHistorySelection());
  const days = $derived(groupHistoryDays(rows, Date.now(), getLocale()));

  let focusedKey = $state<string | null>(null);
  let siteToDelete = $state<string | null>(null);
  let listEl: HTMLDivElement | undefined = $state();
  let sentinelEl: HTMLDivElement | undefined = $state();

  const title = $derived.by(() => {
    if (filter.query.trim()) return t("historyPage.searchResults");
    if (filter.host !== undefined) return filter.host;
    if (filter.openedFrom !== undefined) return filter.openedFrom;
    const periodKeys = {
      all: "historyPage.periodAll",
      today: "historyPage.periodToday",
      yesterday: "historyPage.periodYesterday",
      last7Days: "historyPage.periodLast7Days",
      older: "historyPage.periodOlder",
    } as const;
    return t(periodKeys[filter.period]);
  });

  // Another surface may take the shell's place without closing the page: native stops reporting changes either way.
  let wasOpen = false;
  $effect(() => {
    if (shellOpen) wasOpen = true;
    else if (wasOpen) {
      wasOpen = false;
      historyActions.close();
    }
  });

  // The last rows in view ask for the next batch.
  $effect(() => {
    if (!sentinelEl) return;
    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) loadMoreHistory();
    }, { rootMargin: "400px" });
    observer.observe(sentinelEl);
    return () => observer.disconnect();
  });

  $effect(() =>
    on("historyRowMenuAction", (data) => {
      const row = rows.find((candidate) => rowKey(candidate) === data.key);
      if (!row) return;
      switch (data.action) {
        case "open":
          openHistoryRow(row, false);
          break;
        case "openInNewTab":
          openHistoryRowInNewTab(row);
          break;
        case "delete":
          // A selected row stands for the whole selection, as in Finder.
          deleteHistoryRows(selection.has(data.key) ? selection : new Set([data.key]));
          break;
        case "deleteSite":
          siteToDelete = row.host;
          break;
      }
    }),
  );

  function rowClick(event: MouseEvent, row: BridgeHistoryDayRow): void {
    const key = rowKey(row);
    focusedKey = key;
    if (event.shiftKey) extendHistorySelection(key);
    else if (selection.size > 0) toggleHistoryRow(key);
    else openHistoryRow(row, event.metaKey);
  }

  function showMenu(event: MouseEvent, row: BridgeHistoryDayRow): void {
    event.preventDefault();
    historyActions.showRowMenu({ key: rowKey(row), url: row.url, host: row.host, x: event.clientX, y: event.clientY, width: 0, height: 0 });
  }

  async function moveFocus(step: number): Promise<void> {
    const keys = rows.map(rowKey);
    const index = focusedKey ? keys.indexOf(focusedKey) : -1;
    const next = keys[Math.max(0, Math.min(keys.length - 1, index + step))];
    if (!next) return;
    focusedKey = next;
    await tick();
    listEl?.querySelector<HTMLElement>(`[data-key="${CSS.escape(next)}"]`)?.focus();
  }

  function handleListKeydown(event: KeyboardEvent): void {
    const row = rows.find((candidate) => rowKey(candidate) === focusedKey);
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      void moveFocus(event.key === "ArrowDown" ? 1 : -1);
      if (event.shiftKey && focusedKey) extendHistorySelection(focusedKey);
    } else if (event.key === "Enter" && row) {
      event.preventDefault();
      openHistoryRow(row, event.metaKey);
    } else if (event.key === " " && row) {
      event.preventDefault();
      toggleHistoryRow(rowKey(row));
    } else if ((event.key === "Backspace" || event.key === "Delete") && (selection.size || row)) {
      event.preventDefault();
      deleteHistoryRows(selection.size ? selection : new Set([rowKey(row!)]));
    } else if (event.key === "a" && event.metaKey) {
      event.preventDefault();
      selectAllHistory();
    }
  }

  function handleWindowKeydown(event: KeyboardEvent): void {
    if (!shellOpen || event.key !== "Escape" || event.defaultPrevented || siteToDelete) return;
    if (event.target instanceof HTMLInputElement && event.target.value) return;
    event.preventDefault();
    if (selection.size) clearHistorySelection();
    else unwindHistory();
  }

  function clearBrowsingData(): void {
    openSettings("privacy");
    openSettingsSubpage("privacy", "browsingData");
  }

  function confirmDeleteSite(): void {
    if (siteToDelete) deleteHistorySite(siteToDelete);
    siteToDelete = null;
  }
</script>

<svelte:window onkeydown={handleWindowKeydown} />

{#snippet historyNav(compact: boolean)}<HistoryNav {compact} />{/snippet}

<UiShellFrame
  active={shellOpen}
  ariaLabel={t("historyPage.title")}
  interactiveZoneId="history-shell"
  {title}
  nav={isVerticalLayout() ? undefined : historyNav}
>
  <div class="history-toolbar">
    {#if selection.size}
      <span class="history-selected">{t("historyPage.selected", { count: selection.size })}</span>
      <span class="history-toolbar-spacer"></span>
      <UiButton variant="ghost" onclick={clearHistorySelection}>{t("historyPage.clearSelection")}</UiButton>
      <UiButton variant="secondary" onclick={openSelectedHistory}>{t("historyPage.openInNewTabs")}</UiButton>
      <UiButton variant="danger" onclick={() => deleteHistoryRows(selection)}>{t("historyPage.delete")}</UiButton>
    {:else}
      <span class="history-toolbar-spacer"></span>
      {#if filter.host}
        <UiButton variant="ghost" onclick={() => (siteToDelete = filter.host ?? null)}>
          {t("historyPage.deleteSite", { host: filter.host })}
        </UiButton>
      {/if}
      <UiButton variant="secondary" onclick={clearBrowsingData}>{t("historyPage.clearBrowsingData")}</UiButton>
    {/if}
  </div>

  {#if isHistoryLoaded() && rows.length === 0 && !hasMoreHistory()}
    <div class="history-empty">
      {#if filter.query.trim() || filter.period !== "all" || filter.host !== undefined || filter.openedFrom !== undefined}
        <p class="history-empty-title">{t("historyPage.noResultsTitle")}</p>
        <p class="history-empty-copy">{t("historyPage.noResultsCopy")}</p>
      {:else}
        <p class="history-empty-title">{t("historyPage.emptyTitle")}</p>
        <p class="history-empty-copy">{t("historyPage.emptyCopy")}</p>
      {/if}
    </div>
  {:else}
    <!-- svelte-ignore a11y_interactive_supports_focus -->
    <div
      class="history-list"
      role="listbox"
      aria-label={title}
      aria-multiselectable="true"
      bind:this={listEl}
      onkeydown={handleListKeydown}
    >
      {#each days as day (day.dayStart)}
        <div class="history-day" role="group" aria-label={day.labelKey ? t(day.labelKey, { date: day.date }) : day.date}>
          <div class="history-day-header">
            <span>{day.labelKey ? t(day.labelKey, { date: day.date }) : day.date}</span>
            <span>{t("historyPage.dayPages", { count: day.rows.length })}</span>
          </div>
          {#each day.rows as row (rowKey(row))}
            {@const key = rowKey(row)}
            {@const checked = selection.has(key)}
            {@const favicon = getHistoryFavicon(row.host)}
            <!-- svelte-ignore a11y_click_events_have_key_events (the listbox handles the keys) -->
            <div
              class="history-row"
              class:checked
              class:selecting={selection.size > 0}
              role="option"
              aria-selected={checked}
              tabindex={focusedKey === key || (focusedKey === null && key === rowKey(rows[0])) ? 0 : -1}
              data-key={key}
              onclick={(event) => rowClick(event, row)}
              oncontextmenu={(event) => showMenu(event, row)}
              onfocus={() => (focusedKey = key)}
            >
              <button
                class="history-check"
                class:on={checked}
                type="button"
                role="checkbox"
                aria-checked={checked}
                aria-label={t("historyPage.selectRow", { title: row.title || row.url })}
                tabindex="-1"
                onclick={(event) => {
                  event.stopPropagation();
                  if (event.shiftKey) extendHistorySelection(key);
                  else toggleHistoryRow(key);
                }}
              ></button>
              <span class="history-time">{timeLabel(row.lastVisitAt, getLocale())}</span>
              <span class="history-favicon" aria-hidden="true">
                {#if favicon}
                  <img src={favicon} alt="" draggable="false" />
                {:else}
                  {(row.host || "?").charAt(0).toUpperCase()}
                {/if}
              </span>
              <span class="history-title">{row.title || row.url}</span>
              <span class="history-host">{row.host}</span>
              <span class="history-visits" title={t("historyPage.visits", { count: row.visits })}>
                {row.visits > 1 ? `×${row.visits}` : ""}
              </span>
            </div>
          {/each}
        </div>
      {/each}
      <div class="history-sentinel" bind:this={sentinelEl}></div>
    </div>
  {/if}

  <BottomConfirmSheet
    visible={siteToDelete !== null}
    title={t("historyPage.deleteSiteTitle", { host: siteToDelete ?? "" })}
    message={t("historyPage.deleteSiteMessage")}
    confirmLabel={t("historyPage.delete")}
    confirmAction={confirmDeleteSite}
    cancelAction={() => (siteToDelete = null)}
  />
</UiShellFrame>

<style>
  .history-toolbar {
    position: sticky;
    top: 24px;
    z-index: 1;
    display: flex;
    align-items: center;
    gap: var(--space-8);
    min-height: 36px;
    margin-bottom: var(--space-8);
    padding: var(--space-4) var(--space-4) var(--space-4) var(--space-12);
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--bg-primary) 96%, var(--sidebar-bg));
  }

  .history-selected {
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
  }

  .history-toolbar-spacer {
    flex: 1;
  }

  .history-list {
    outline: none;
  }

  .history-day {
    margin-bottom: var(--space-16);
  }

  .history-day-header {
    display: flex;
    justify-content: space-between;
    gap: var(--space-12);
    margin-bottom: var(--space-2);
    padding: var(--space-8) var(--space-8) var(--space-4);
    border-bottom: 1px solid var(--separator);
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
  }

  .history-row {
    display: grid;
    grid-template-columns: 16px 52px 16px minmax(0, 1fr) minmax(0, 170px) 36px;
    align-items: center;
    gap: var(--space-10);
    height: 32px;
    padding: 0 var(--space-8);
    border-radius: var(--radius-md);
    font-size: var(--font-size-md);
    cursor: default;
    outline: none;
  }

  .history-row:hover {
    background: var(--bg-hover);
  }

  .history-row:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .history-row.checked {
    background: var(--accent-tint-10);
  }

  .history-check {
    width: 14px;
    height: 14px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-xs);
    background: var(--bg-elevated);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--text-primary) 28%, transparent);
    opacity: 0;
    transition: opacity var(--transition-fast);
  }

  .history-row:hover .history-check,
  .history-row.selecting .history-check,
  .history-row:focus-visible .history-check {
    opacity: 1;
  }

  .history-check.on {
    background: var(--accent) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 14 14'%3E%3Cpath d='M3.5 7.2 6 9.6l4.5-5' fill='none' stroke='white' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") center / 14px no-repeat;
    box-shadow: none;
  }

  .history-time {
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    font-variant-numeric: tabular-nums;
  }

  .history-favicon {
    display: grid;
    place-items: center;
    width: 16px;
    height: 16px;
    border-radius: var(--radius-xs);
    background: var(--text-primary-tint-10);
    color: var(--text-secondary);
    font-size: var(--font-size-3xs);
    font-weight: var(--font-weight-bold);
    overflow: hidden;
  }

  .history-favicon:has(img) {
    background: none;
  }

  .history-favicon img {
    width: 16px;
    height: 16px;
  }

  .history-title,
  .history-host {
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .history-host {
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .history-visits {
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-variant-numeric: tabular-nums;
    text-align: right;
  }

  .history-sentinel {
    height: 1px;
  }

  .history-empty {
    display: grid;
    justify-items: center;
    gap: var(--space-4);
    padding: var(--space-32) var(--space-16);
    text-align: center;
  }

  .history-empty p {
    margin: 0;
  }

  .history-empty-title {
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
  }

  .history-empty-copy {
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }
</style>
