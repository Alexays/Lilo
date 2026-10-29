<script lang="ts">
  import { tick } from "svelte";
  import { SvelteSet } from "svelte/reactivity";
  import { on } from "../../lib/bridge";
  import { historyActions } from "../../lib/bridge/actions";
  import type { BridgeHistoryDayRow } from "../../lib/bridge/protocol";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { hostOf } from "../../lib/url";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import UiShellFrame from "../ui/UiShellFrame.svelte";
  import BottomConfirmSheet from "../ui/BottomConfirmSheet.svelte";
  import HistoryNav from "./HistoryNav.svelte";
  import { groupHistoryDays, rowKey, timeLabel, timeRangeLabel, type HistoryCluster } from "./historyPageModel";
  import { isHistoryShellOpen } from "../../stores/panels.svelte";
  import { isVerticalLayout } from "../../stores/tabLayout.svelte";
  import { getTabs } from "../../stores/tabs.svelte";
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
    toggleHistoryRows,
    unwindHistory,
  } from "../../stores/history.svelte";

  const shellOpen = $derived(isHistoryShellOpen());
  const filter = $derived(getHistoryFilter());
  const rows = $derived(getHistoryRows());
  const selection = $derived(getHistorySelection());
  const selecting = $derived(selection.size > 0);
  // A search or a site already narrows the list: folding by site would only hide what was asked for.
  const bySite = $derived(!filter.query.trim() && filter.host === undefined);
  const days = $derived(groupHistoryDays(rows, Date.now(), getLocale(), bySite));
  // The persisted favicons miss many sites: an open tab of the same site fills in.
  const tabFavicons = $derived.by(() => {
    // eslint-disable-next-line svelte/prefer-svelte-reactivity -- rebuilt whole by the $derived, never mutated after
    const byHost = new Map<string, string>();
    for (const tab of getTabs()) {
      const host = hostOf(tab.url);
      if (host && tab.faviconDataURL && !byHost.has(host)) byHost.set(host, tab.faviconDataURL);
    }
    return byHost;
  });
  const expanded = new SvelteSet<string>();

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
      expanded.clear();
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

  function favicon(row: BridgeHistoryDayRow): string | undefined {
    return getHistoryFavicon(row.host) ?? tabFavicons.get(row.host);
  }

  function clusterKeys(cluster: HistoryCluster): string[] {
    return cluster.rows.map(rowKey);
  }

  function rowClick(event: MouseEvent, row: BridgeHistoryDayRow): void {
    const key = rowKey(row);
    if (event.shiftKey) extendHistorySelection(key);
    else if (selecting) toggleHistoryRow(key);
    else openHistoryRow(row, event.metaKey);
  }

  function clusterClick(event: MouseEvent, cluster: HistoryCluster): void {
    if (selecting || event.shiftKey) toggleHistoryRows(clusterKeys(cluster));
    else if (expanded.has(cluster.key)) expanded.delete(cluster.key);
    else expanded.add(cluster.key);
  }

  function showMenu(event: MouseEvent, row: BridgeHistoryDayRow): void {
    event.preventDefault();
    historyActions.showRowMenu({ key: rowKey(row), url: row.url, host: row.host, x: event.clientX, y: event.clientY, width: 0, height: 0 });
  }

  /** Arrows walk the visible rows and site headers in order, whatever their nesting. */
  async function moveFocus(from: HTMLElement, step: number): Promise<void> {
    const items = [...(listEl?.querySelectorAll<HTMLElement>("[data-nav]") ?? [])];
    const next = items[Math.max(0, Math.min(items.length - 1, items.indexOf(from) + step))];
    await tick();
    next?.focus();
  }

  function itemKeydown(event: KeyboardEvent, keys: string[], open: (background: boolean) => void): void {
    const target = event.currentTarget as HTMLElement;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      void moveFocus(target, event.key === "ArrowDown" ? 1 : -1);
    } else if (event.key === "Enter") {
      event.preventDefault();
      open(event.metaKey);
    } else if (event.key === " ") {
      event.preventDefault();
      toggleHistoryRows(keys);
    } else if (event.key === "Backspace" || event.key === "Delete") {
      event.preventDefault();
      deleteHistoryRows(selecting ? selection : new Set(keys));
    } else if (event.key === "a" && event.metaKey) {
      event.preventDefault();
      selectAllHistory();
    }
  }

  function clusterKeydown(event: KeyboardEvent, cluster: HistoryCluster, open: boolean): void {
    if (event.key === "ArrowRight") {
      event.preventDefault();
      expanded.add(cluster.key);
    } else if (event.key === "ArrowLeft") {
      event.preventDefault();
      expanded.delete(cluster.key);
    } else {
      itemKeydown(event, clusterKeys(cluster), () => (open ? expanded.delete(cluster.key) : expanded.add(cluster.key)));
    }
  }

  function handleWindowKeydown(event: KeyboardEvent): void {
    if (!shellOpen || event.key !== "Escape" || event.defaultPrevented || siteToDelete) return;
    if (event.target instanceof HTMLInputElement && event.target.value) return;
    event.preventDefault();
    if (selecting) clearHistorySelection();
    else unwindHistory();
  }

  function confirmDeleteSite(): void {
    if (siteToDelete) deleteHistorySite(siteToDelete);
    siteToDelete = null;
  }
</script>

<svelte:window onkeydown={handleWindowKeydown} />

{#snippet historyNav(compact: boolean)}<HistoryNav {compact} />{/snippet}

{#snippet leading(row: BridgeHistoryDayRow, keys: string[])}
  {@const checked = keys.every((key) => selection.has(key))}
  <span class="lead" class:checked>
    <span class="lead-icon"><SiteFavicon src={favicon(row)} title={row.title} url={row.url} size={16} radius={4} /></span>
    <button
      class="check"
      class:on={checked}
      type="button"
      role="checkbox"
      aria-checked={checked}
      aria-label={t("historyPage.selectRow", { title: row.title || row.url })}
      tabindex="-1"
      onclick={(event) => {
        event.stopPropagation();
        if (event.shiftKey && keys.length === 1) extendHistorySelection(keys[0]);
        else toggleHistoryRows(keys);
      }}
    ></button>
  </span>
{/snippet}

{#snippet trailing(time: string, keys: string[], row: BridgeHistoryDayRow | null)}
  <span class="time">{time}</span>
  <span class="actions">
    {#if row}
      <button
        class="act"
        type="button"
        tabindex="-1"
        aria-label={t("historyPage.openInNewTab")}
        title={t("historyPage.openInNewTab")}
        onclick={(event) => {
          event.stopPropagation();
          openHistoryRow(row, true);
        }}
      >
        <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true"><path d="M3 8h10M8 3v10" /></svg>
      </button>
    {/if}
    <button
      class="act"
      type="button"
      tabindex="-1"
      aria-label={t("historyPage.delete")}
      title={t("historyPage.delete")}
      onclick={(event) => {
        event.stopPropagation();
        deleteHistoryRows(new Set(keys));
      }}
    >
      <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5" /></svg>
    </button>
  </span>
{/snippet}

{#snippet pageRow(row: BridgeHistoryDayRow, nested: boolean)}
  {@const key = rowKey(row)}
  <div
    class="row"
    class:nested
    class:checked={selection.has(key)}
    class:selecting
    role="option"
    aria-selected={selection.has(key)}
    tabindex="0"
    data-nav
    onclick={(event) => rowClick(event, row)}
    oncontextmenu={(event) => showMenu(event, row)}
    onkeydown={(event) => itemKeydown(event, [key], (background) => openHistoryRow(row, background))}
  >
    {#if !nested}{@render leading(row, [key])}{/if}
    <span class="label">
      <span class="title">{row.title || row.url}</span>
      {#if !nested}<span class="host">{row.host}</span>{/if}
    </span>
    {#if row.visits > 1}<span class="visits" title={t("historyPage.visits", { count: row.visits })}>{row.visits}×</span>{/if}
    {@render trailing(timeLabel(row.lastVisitAt, getLocale()), [key], row)}
  </div>
{/snippet}

<UiShellFrame
  active={shellOpen}
  ariaLabel={t("historyPage.title")}
  interactiveZoneId="history-shell"
  {title}
  nav={isVerticalLayout() ? undefined : historyNav}
>
  <div>
    {#if isHistoryLoaded() && rows.length === 0 && !hasMoreHistory()}
      <div class="empty">
        {#if filter.query.trim() || filter.period !== "all" || filter.host !== undefined || filter.openedFrom !== undefined}
          <p class="empty-title">{t("historyPage.noResultsTitle")}</p>
          <p class="empty-copy">{t("historyPage.noResultsCopy")}</p>
        {:else}
          <p class="empty-title">{t("historyPage.emptyTitle")}</p>
          <p class="empty-copy">{t("historyPage.emptyCopy")}</p>
        {/if}
      </div>
    {:else}
      <div class="days" role="listbox" aria-label={title} aria-multiselectable="true" tabindex="-1" bind:this={listEl}>
        {#each days as day (day.dayStart)}
          <section class="day" aria-label={day.labelKey ? t(day.labelKey) : day.weekday}>
            <header class="day-header">
              <span class="day-title">{day.labelKey ? t(day.labelKey) : day.weekday}</span>
              <span class="day-date">{day.date}</span>
              <span class="day-count">
                {t("historyPage.dayPages", { count: day.pages })}{#if bySite && day.sites > 1} · {t("historyPage.daySites", { count: day.sites })}{/if}
              </span>
            </header>
            <div class="card">
              {#each day.clusters as cluster (cluster.key)}
                {#if cluster.rows.length === 1}
                  {@render pageRow(cluster.rows[0], false)}
                {:else}
                  {@const keys = clusterKeys(cluster)}
                  {@const open = expanded.has(cluster.key)}
                  {@const checked = keys.every((key) => selection.has(key))}
                  <div class="cluster" class:open>
                    <div
                      class="row site"
                      class:checked
                      class:selecting
                      role="option"
                      aria-selected={checked}
                      aria-expanded={open}
                      tabindex="0"
                      data-nav
                      onclick={(event) => clusterClick(event, cluster)}
                      onkeydown={(event) => clusterKeydown(event, cluster, open)}
                    >
                      {@render leading(cluster.rows[0], keys)}
                      <span class="label">
                        <span class="title site-name">{cluster.host}</span>
                        <span class="host">{cluster.rows[0].title}</span>
                      </span>
                      <span class="badge">{t("historyPage.dayPages", { count: cluster.rows.length })}</span>
                      <svg class="chevron" width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m3.5 2 3 3-3 3" /></svg>
                      {@render trailing(timeRangeLabel(cluster.rows, getLocale()), keys, null)}
                    </div>
                    {#if open}
                      <div class="nested-rows">
                        {#each cluster.rows as row (rowKey(row))}{@render pageRow(row, true)}{/each}
                      </div>
                    {/if}
                  </div>
                {/if}
              {/each}
            </div>
          </section>
        {/each}
        <div class="sentinel" bind:this={sentinelEl}></div>
      </div>
    {/if}

    {#if selecting}
      <div class="selection-bar" role="toolbar" aria-label={t("historyPage.selected", { count: selection.size })}>
        <span class="selection-count">{t("historyPage.selected", { count: selection.size })}</span>
        <button class="pill" type="button" onclick={openSelectedHistory}>{t("historyPage.openInNewTabs")}</button>
        <button class="pill danger" type="button" onclick={() => deleteHistoryRows(selection)}>{t("historyPage.delete")}</button>
        <button class="pill quiet" type="button" aria-label={t("historyPage.clearSelection")} title={t("historyPage.clearSelection")} onclick={clearHistorySelection}>
          <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true"><path d="m2 2 6 6M8 2 2 8" /></svg>
        </button>
      </div>
    {/if}
  </div>

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
  .day {
    margin-bottom: var(--space-20);
  }

  .day-header {
    display: flex;
    align-items: baseline;
    gap: var(--space-8);
    margin: 0 var(--space-4) var(--space-6);
  }

  .day-title {
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
  }

  .day-date,
  .day-count {
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }

  .day-count {
    margin-left: auto;
    font-variant-numeric: tabular-nums;
  }

  .card {
    padding: var(--space-4);
    border-radius: var(--radius-lg);
    background: color-mix(in srgb, var(--text-primary) 3%, transparent);
    box-shadow: inset 0 0 0 1px var(--border);
  }

  .card > :global(* + *) {
    box-shadow: 0 -1px 0 var(--separator);
  }

  .row {
    display: flex;
    align-items: center;
    gap: var(--space-10);
    height: 38px;
    padding: 0 var(--space-10);
    border-radius: var(--radius-md);
    cursor: default;
    outline: none;
  }

  .row:hover {
    background: var(--bg-hover);
  }

  .row:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .row.checked {
    background: var(--accent-tint-18);
  }

  .lead {
    position: relative;
    display: grid;
    place-items: center;
    width: 16px;
    height: 16px;
    flex-shrink: 0;
  }

  .lead-icon {
    display: grid;
  }

  /* The checkbox takes the favicon's place on hover and while selecting, as in Chrome's history. */
  .check {
    position: absolute;
    inset: 0;
    padding: 0;
    border: 0;
    border-radius: var(--radius-xs);
    background: transparent;
    box-shadow: inset 0 0 0 1.5px color-mix(in srgb, var(--text-primary) 40%, transparent);
    opacity: 0;
  }

  .row:hover .check,
  .row.selecting .check,
  .lead.checked .check {
    opacity: 1;
  }

  .row:hover .lead-icon,
  .row.selecting .lead-icon,
  .lead.checked .lead-icon {
    visibility: hidden;
  }

  .check.on {
    background: var(--accent) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M4 8.3 6.8 11 12 5.5' fill='none' stroke='white' stroke-width='1.9' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") center / 16px no-repeat;
    box-shadow: none;
  }

  .label {
    display: flex;
    align-items: baseline;
    gap: var(--space-6);
    flex: 1;
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
  }

  .title {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    font-size: var(--font-size-md);
  }

  .site-name {
    flex-shrink: 0;
    font-weight: var(--font-weight-semibold);
  }

  .host {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }

  /* A page's title gives way first; its site keeps up to a third of the row. */
  .title:not(.site-name) + .host {
    flex-shrink: 0;
    max-width: 34%;
  }

  .visits {
    flex-shrink: 0;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-variant-numeric: tabular-nums;
  }

  .badge {
    flex-shrink: 0;
    padding: var(--space-2) var(--space-8);
    border-radius: var(--radius-chip);
    background: var(--text-primary-tint-10);
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
    font-variant-numeric: tabular-nums;
  }

  .chevron {
    flex-shrink: 0;
    color: var(--text-muted);
    transition: transform var(--transition-fast);
  }

  .cluster.open .chevron {
    transform: rotate(90deg);
  }

  .time {
    flex-shrink: 0;
    min-width: 64px;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    font-variant-numeric: tabular-nums;
    text-align: right;
    white-space: nowrap;
  }

  /* Hover trades the time for the row's actions; they keep its width so nothing shifts. */
  .actions {
    display: none;
    flex-shrink: 0;
    justify-content: flex-end;
    gap: var(--space-2);
    min-width: 64px;
  }

  .row:hover:not(.selecting) .time {
    display: none;
  }

  .row:hover:not(.selecting) .actions {
    display: flex;
  }

  .act {
    display: grid;
    place-items: center;
    width: var(--control-height-sm);
    height: var(--control-height-sm);
    padding: 0;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-secondary);
    cursor: pointer;
  }

  .act:hover {
    background: var(--bg-active);
    color: var(--text-primary);
  }

  .nested-rows {
    margin: 0 0 var(--space-4) 36px;
    padding-left: var(--space-6);
    border-left: 1px solid var(--separator);
  }

  .row.nested {
    height: 32px;
  }

  .row.nested .title {
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .sentinel {
    height: 1px;
  }

  .selection-bar {
    position: sticky;
    bottom: var(--space-20);
    z-index: 2;
    display: flex;
    align-items: center;
    gap: var(--space-6);
    width: fit-content;
    margin: var(--space-8) auto 0;
    padding: var(--space-6) var(--space-6) var(--space-6) var(--space-16);
    border-radius: var(--radius-chip);
    background: var(--chrome-floating-surface);
    backdrop-filter: blur(var(--chrome-floating-blur));
    box-shadow: var(--float-shadow);
    white-space: nowrap;
  }

  .selection-count {
    margin-right: var(--space-6);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
  }

  .pill {
    display: inline-flex;
    align-items: center;
    height: var(--control-height-md);
    padding: 0 var(--space-12);
    border: 0;
    border-radius: var(--radius-chip);
    background: var(--text-primary-tint-10);
    color: var(--text-primary);
    font: inherit;
    font-size: var(--font-size-md);
    cursor: pointer;
  }

  .pill:hover {
    background: var(--text-primary-tint-12);
  }

  .pill.danger {
    background: color-mix(in srgb, var(--danger) 16%, transparent);
    color: var(--danger-text);
  }

  .pill.quiet {
    padding: 0 var(--space-10);
    background: transparent;
    color: var(--text-secondary);
  }

  .pill:focus-visible,
  .act:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .empty {
    display: grid;
    justify-items: center;
    gap: var(--space-4);
    padding: var(--space-32) var(--space-16);
    text-align: center;
  }

  .empty p {
    margin: 0;
  }

  .empty-title {
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
  }

  .empty-copy {
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }
</style>
