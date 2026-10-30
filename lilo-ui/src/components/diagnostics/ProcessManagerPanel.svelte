<script lang="ts">
  import StatusBanner from "../banners/StatusBanner.svelte";
  import { on } from "../../lib/bridge";
  import { formatByteSize } from "../../lib/format";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { processManagerActions } from "../../lib/bridge/actions";
  import type {
    BridgeProcessInfo,
    BridgeProcessKind,
    BridgeProcessManagerActionStatusPayload,
    BridgeProcessSnapshot,
    BridgeProcessTabInfo,
    BridgeTabSnapshot,
  } from "../../lib/bridge/protocol";
  import {
    closeActivePanel,
    isProcessManagerVisible,
  } from "../../stores/panels.svelte";
  import { getSidebarsBySpace } from "../../stores/sidebar.svelte";
  import { tabDisplayTitle } from "../../stores/tabs.svelte";
  import BottomConfirmSheet from "../ui/BottomConfirmSheet.svelte";
  import PanelHeader from "../ui/PanelHeader.svelte";
  import UiSearchField from "../ui/UiSearchField.svelte";
  import { filterTabUsages, processOverview } from "./processManagerModel";

  const REFRESH_MS = 2000;

  const KIND_LABEL_KEYS: Record<BridgeProcessKind, string> = {
    webContent: "processManager.kindWebContent",
    provisionalWebContent: "processManager.kindProvisional",
    network: "processManager.kindNetwork",
    gpu: "processManager.kindGPU",
    model: "processManager.kindModel",
  };

  type PendingAction =
    | { kind: "terminate"; process: BridgeProcessInfo }
    | { kind: "closeTab"; tab: BridgeProcessTabInfo };

  let _snapshot = $state.raw<BridgeProcessSnapshot | null>(null);
  let _status = $state<BridgeProcessManagerActionStatusPayload | null>(null);
  let _query = $state("");
  let _searchOpen = $state(false);
  let _expandedId = $state<string | null>(null);
  let _showSleeping = $state(false);
  let _showSystem = $state(false);
  let _pendingAction = $state<PendingAction | null>(null);

  const _overview = $derived(processOverview(_snapshot));
  const _tabs = $derived(filterTabUsages(_overview.tabs, _query));
  const _maxTabBytes = $derived(
    _overview.tabs.reduce((max, usage) => Math.max(max, usage.bytes), 0),
  );

  // Favicons and sleeping tabs come from the sidebar, which knows every open tab.
  const _sidebarTabs = $derived.by(() => {
    // eslint-disable-next-line svelte/prefer-svelte-reactivity -- rebuilt whole by the $derived, never mutated after
    const byId = new Map<string, { tab: BridgeTabSnapshot; spaceId: string }>();
    for (const [spaceId, state] of Object.entries(getSidebarsBySpace())) {
      for (const tab of state.tabs) {
        if (!tab.isClosed && tab.kind !== "terminal") byId.set(tab.id, { tab, spaceId });
      }
    }
    return byId;
  });

  const _sleepingTabs = $derived.by(() => {
    const live = new Set(_overview.tabs.map((usage) => usage.tab.id));
    const query = _query.trim().toLowerCase();
    return [..._sidebarTabs.values()].filter(
      ({ tab }) =>
        !live.has(tab.id) &&
        (!query || tab.title.toLowerCase().includes(query) || tab.url.toLowerCase().includes(query)),
    );
  });

  $effect(() => {
    if (!isProcessManagerVisible()) return;
    processManagerActions.load();
    const timer = window.setInterval(() => {
      if (!document.hidden) processManagerActions.load();
    }, REFRESH_MS);
    return () => window.clearInterval(timer);
  });

  $effect(() => {
    const offSnapshot = on("processSnapshotUpdated", (data) => {
      _snapshot = data;
    });
    const offStatus = on("processManagerActionCompleted", (data) => {
      _status = data;
    });
    return () => {
      offSnapshot();
      offStatus();
    };
  });

  // The chrome web view has no dialog delegate, so window.confirm() always returns false:
  // destructive actions go through the in-panel sheet instead.
  function confirmPendingAction(): void {
    const pending = _pendingAction;
    _pendingAction = null;
    if (!pending) return;
    if (pending.kind === "terminate") {
      processManagerActions.terminateProcess({ processId: pending.process.id, confirmed: true });
    } else {
      processManagerActions.closeTab(pending.tab.id, pending.tab.spaceId);
    }
  }

  function pendingActionTitle(pending: PendingAction): string {
    return pending.kind === "terminate"
      ? t("processManager.confirmTerminate", {
          kind: t(KIND_LABEL_KEYS[pending.process.kind]),
          pid: pending.process.pid,
        })
      : t("processManager.confirmCloseTab", {
          tab: pending.tab.title || pending.tab.url || pending.tab.id,
        });
  }

  function handleWindowKeydown(e: KeyboardEvent): void {
    if (e.key !== "Escape" || e.defaultPrevented || !isProcessManagerVisible()) return;
    const target = e.target;
    if (target instanceof HTMLInputElement && target.value) return;
    e.preventDefault();
    closeActivePanel();
  }

  function toggleSearch(): void {
    _searchOpen = !_searchOpen;
    if (!_searchOpen) _query = "";
  }

  function formatCPU(value: number | null | undefined): string {
    if (value == null || Number.isNaN(value)) return "--";
    return `${value >= 10 ? value.toFixed(0) : value.toFixed(1)}%`;
  }

  function segmentLabel(id: string, label: string | null): string {
    if (id === "system") return t("processManager.groupSystem");
    if (id === "others") {
      return t("processManager.others", { count: Math.max(0, _overview.tabs.length - 3) });
    }
    return label || t("processManager.untitledTab");
  }

  function reclaimCopy(): string {
    const count = _overview.reclaimableTabCount;
    if (_overview.reclaimableBytes <= 0) {
      return count === 1
        ? t("processManager.reclaimNoSizeOne")
        : t("processManager.reclaimNoSize", { count });
    }
    const size = formatByteSize(_overview.reclaimableBytes, getLocale());
    return count === 1
      ? t("processManager.reclaimOne", { size })
      : t("processManager.reclaim", { count, size });
  }
</script>

<svelte:window onkeydown={handleWindowKeydown} />

{#snippet favicon(tab: BridgeTabSnapshot | undefined, title: string)}
  {#if tab?.faviconDataURL}
    <img class="favicon" src={tab.faviconDataURL} alt="" width="16" height="16" />
  {:else}
    <span class="favicon favicon-fallback" aria-hidden="true">{(title || "?").charAt(0).toUpperCase()}</span>
  {/if}
{/snippet}

{#if isProcessManagerVisible()}
  <div
    class="panel-shell process-panel"
    role="dialog"
    aria-label={t("processManager.title")}
    {@attach (node) => node.querySelector<HTMLElement>("button:not(:disabled)")?.focus({ preventScroll: true })}
  >
    <PanelHeader title={t("processManager.title")} onclose={closeActivePanel}>
      {#snippet actions()}
        <button
          class="hdr-ctl"
          class:on={_searchOpen}
          type="button"
          onclick={toggleSearch}
          use:tooltip={{ text: t("processManager.searchPlaceholder"), placement: "bottom" }}
          aria-label={t("processManager.searchPlaceholder")}
          aria-pressed={_searchOpen}
        >
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true"><circle cx="7" cy="7" r="4.5" /><path d="m10.5 10.5 3 3" /></svg>
        </button>
      {/snippet}
    </PanelHeader>

    <div class="process-body">
      <StatusBanner bind:status={_status} />

      <section class="overview" aria-label={t("processManager.memoryAriaLabel")}>
        <div class="overview-figures">
          <span class="overview-total">{_snapshot ? formatByteSize(_overview.totalBytes, getLocale()) : "--"}</span>
          <span class="overview-meta">
            {_overview.tabs.length === 1
              ? t("processManager.tabsCountOne")
              : t("processManager.tabsCount", { count: _overview.tabs.length })}
            · {t("processManager.cpu", { value: formatCPU(_overview.cpuPercent) })}
          </span>
        </div>
        {#if _overview.totalBytes > 0}
          <div class="memory-bar" aria-hidden="true">
            {#each _overview.segments as segment, index (segment.id)}
              <span class={`segment seg-${segment.id === "system" || segment.id === "others" ? segment.id : index}`} style={`flex-grow: ${segment.bytes}`}></span>
            {/each}
          </div>
          <ul class="memory-legend">
            {#each _overview.segments as segment, index (segment.id)}
              <li>
                <span class={`swatch seg-${segment.id === "system" || segment.id === "others" ? segment.id : index}`}></span>
                <span class="legend-label">{segmentLabel(segment.id, segment.label)}</span>
              </li>
            {/each}
          </ul>
        {/if}
      </section>

      {#if _overview.reclaimableTabCount > 0}
        <div class="reclaim">
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round" aria-hidden="true"><path d="M13 9.5A5.5 5.5 0 0 1 6.5 3a5.5 5.5 0 1 0 6.5 6.5z" /></svg>
          <span class="reclaim-copy">{reclaimCopy()}</span>
          <button class="link-button" type="button" onclick={() => processManagerActions.sleepHiddenTabs()}>
            {t("processManager.sleep")}
          </button>
        </div>
      {/if}

      {#if _searchOpen}
        <UiSearchField
          placeholder={t("processManager.searchPlaceholder")}
          ariaLabel={t("processManager.searchPlaceholder")}
          value={_query}
          onchange={(value) => (_query = value)}
        />
      {/if}

      <section class="group" aria-label={t("processManager.groupTabs")}>
        <div class="group-title">{t("processManager.groupTabs")}</div>
        {#if _tabs.length === 0}
          <p class="empty-text">{t("processManager.empty")}</p>
        {/if}
        {#each _tabs as usage (usage.tab.id)}
          {@const sidebarTab = _sidebarTabs.get(usage.tab.id)?.tab}
          {@const expanded = _expandedId === usage.tab.id}
          <div class="tab-entry" class:expanded class:unresponsive={usage.unresponsive}>
            <button
              class="tab-row"
              type="button"
              aria-expanded={expanded}
              onclick={() => (_expandedId = expanded ? null : usage.tab.id)}
              ondblclick={() => processManagerActions.focusTab(usage.tab.id, usage.tab.spaceId)}
            >
              {@render favicon(sidebarTab, usage.tab.title)}
              <span class="tab-copy">
                <span class="tab-title">{tabDisplayTitle(usage.tab.title) || t("processManager.untitledTab")}</span>
                {#if usage.unresponsive}
                  <span class="tab-state">{t("processManager.unresponsive")}</span>
                {:else}
                  <span class="usage-bar" aria-hidden="true">
                    <span style={`width: ${_maxTabBytes > 0 ? (usage.bytes / _maxTabBytes) * 100 : 0}%`}></span>
                  </span>
                {/if}
              </span>
              {#if usage.tab.isAudioPlaying}
                <svg class="tab-flag" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" role="img" aria-label={t("processManager.audioPlaying")}><path d="M3 6.5h2.5L9 3.5v9l-3.5-3H3z" /><path d="M11.5 6a3 3 0 0 1 0 4" /></svg>
              {/if}
              {#if usage.tab.lifecycle === "frozen"}
                <svg class="tab-flag" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" role="img" aria-label={t("processManager.frozen")}><path d="M8 2v12M2.8 5l10.4 6M2.8 11l10.4-6" /></svg>
              {/if}
              <span class="tab-bytes" use:tooltip={usage.shared ? t("processManager.sharedEstimate") : ""}>
                {usage.shared ? "≈ " : ""}{formatByteSize(usage.bytes, getLocale())}
              </span>
            </button>
            {#if expanded}
              <div class="details">
                <div class="details-url">{usage.tab.url}</div>
                <div class="details-meta">
                  {t("processManager.pid", { pid: usage.process.pid })}
                  · {t("processManager.cpu", { value: formatCPU(usage.process.metrics?.cpuPercent) })}
                  {#if usage.shared}· {t("processManager.sharedWith", { count: usage.process.tabs.length - 1 })}{/if}
                </div>
                <div class="details-actions">
                  <button class="small-button" type="button" onclick={() => processManagerActions.focusTab(usage.tab.id, usage.tab.spaceId)}>
                    {t("processManager.focus")}
                  </button>
                  <button class="small-button" type="button" onclick={() => processManagerActions.reloadTab(usage.tab.id, usage.tab.spaceId)}>
                    {t("processManager.reload")}
                  </button>
                  <button class="small-button" type="button" onclick={() => (_pendingAction = { kind: "closeTab", tab: usage.tab })}>
                    {t("common.close")}
                  </button>
                  <button class="small-button danger" type="button" onclick={() => (_pendingAction = { kind: "terminate", process: usage.process })}>
                    {t("processManager.terminate")}
                  </button>
                </div>
              </div>
            {/if}
          </div>
        {/each}
      </section>

      {#if _sleepingTabs.length > 0}
        <section class="group" aria-label={t("processManager.groupSleeping")}>
          <button class="group-toggle" type="button" aria-expanded={_showSleeping} onclick={() => (_showSleeping = !_showSleeping)}>
            <svg class="chevron" class:open={_showSleeping} width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m3.5 2 3 3-3 3" /></svg>
            <span>{t("processManager.groupSleeping")} · {_sleepingTabs.length}</span>
          </button>
          {#if _showSleeping}
            {#each _sleepingTabs as { tab, spaceId } (tab.id)}
              <button
                class="tab-row sleeping"
                type="button"
                use:tooltip={t("processManager.wake")}
                onclick={() => processManagerActions.focusTab(tab.id, spaceId)}
              >
                {@render favicon(tab, tab.title)}
                <span class="tab-copy"><span class="tab-title">{tabDisplayTitle(tab.title) || t("processManager.untitledTab")}</span></span>
              </button>
            {/each}
          {/if}
        </section>
      {/if}

      {#if _overview.system.length > 0}
        <section class="group" aria-label={t("processManager.groupSystem")}>
          <button class="group-toggle" type="button" aria-expanded={_showSystem} onclick={() => (_showSystem = !_showSystem)}>
            <svg class="chevron" class:open={_showSystem} width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m3.5 2 3 3-3 3" /></svg>
            <span class="group-toggle-label">{t("processManager.groupSystem")} · {_overview.system.length}</span>
            <span class="tab-bytes">{formatByteSize(_overview.systemBytes, getLocale())}</span>
          </button>
          {#if _showSystem}
            {#each _overview.system as process (process.id)}
              {@const expanded = _expandedId === process.id}
              <div class="tab-entry" class:expanded>
                <button class="tab-row" type="button" aria-expanded={expanded} onclick={() => (_expandedId = expanded ? null : process.id)}>
                  <span class="tab-copy"><span class="tab-title">{t(KIND_LABEL_KEYS[process.kind])}</span></span>
                  <span class="tab-cpu">{formatCPU(process.metrics?.cpuPercent)}</span>
                  <span class="tab-bytes">{formatByteSize(process.metrics?.residentSizeBytes ?? 0, getLocale())}</span>
                </button>
                {#if expanded}
                  <div class="details">
                    <div class="details-meta">{t("processManager.pid", { pid: process.pid })} · {process.webProcessStateLabel}</div>
                    <div class="details-actions">
                      <button class="small-button danger" type="button" onclick={() => (_pendingAction = { kind: "terminate", process })}>
                        {t("processManager.terminate")}
                      </button>
                    </div>
                  </div>
                {/if}
              </div>
            {/each}
          {/if}
        </section>
      {/if}
    </div>

    <BottomConfirmSheet
      visible={_pendingAction !== null}
      title={_pendingAction ? pendingActionTitle(_pendingAction) : ""}
      confirmLabel={_pendingAction?.kind === "terminate"
        ? t("processManager.terminate")
        : t("common.close")}
      confirmAction={confirmPendingAction}
      cancelAction={() => (_pendingAction = null)}
    />
  </div>
{/if}

<style>
  .process-panel {
    position: relative;
    background: var(--sidebar-bg);
    color: var(--text-primary);
  }

  .hdr-ctl.on {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .process-body {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    padding: 0 10px 18px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .overview {
    display: grid;
    gap: 8px;
    padding: 2px 4px 0;
  }

  .overview-figures {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 8px;
  }

  .overview-total {
    font-size: var(--font-size-3xl);
    font-weight: var(--font-weight-semibold);
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }

  .overview-meta {
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    white-space: nowrap;
  }

  .memory-bar {
    display: flex;
    gap: 2px;
    height: 10px;
    border-radius: var(--radius-xs);
    overflow: hidden;
  }

  .segment {
    flex-basis: 0;
    min-width: 3px;
    transition: flex-grow 300ms ease;
  }

  .seg-0 { background: var(--accent); }
  .seg-1 { background: var(--chart-2); }
  .seg-2 { background: var(--chart-3); }
  .seg-others { background: color-mix(in srgb, var(--text-primary) 28%, transparent); }
  .seg-system { background: color-mix(in srgb, var(--text-primary) 14%, transparent); }

  .memory-legend {
    display: flex;
    flex-wrap: wrap;
    gap: 4px 10px;
    margin: 0;
    padding: 0;
    list-style: none;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }

  .memory-legend li {
    display: flex;
    align-items: center;
    gap: 4px;
    min-width: 0;
  }

  .swatch {
    width: 7px;
    height: 7px;
    border-radius: var(--radius-2xs);
    flex-shrink: 0;
  }

  .legend-label {
    max-width: 90px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* A narrow row sends the button under the text rather than squeeze the text into a column. */
  .reclaim {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px;
    padding: 8px 10px;
    border: 1px solid color-mix(in srgb, var(--text-primary) 8%, transparent);
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--bg-hover) 40%, transparent);
    color: var(--text-secondary);
  }

  .reclaim .link-button {
    margin-left: auto;
  }

  .reclaim-copy {
    flex: 1 1 80px;
    min-width: 0;
    font-size: var(--font-size-sm);
    line-height: 1.3;
  }

  .link-button {
    flex-shrink: 0;
    padding: 2px 0;
    border: none;
    background: none;
    color: color-mix(in srgb, var(--accent) 50%, var(--text-primary));
    font: inherit;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-semibold);
    cursor: pointer;
    white-space: nowrap;
  }

  .link-button:hover {
    color: var(--text-primary);
  }

  .group {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: 1px;
  }

  .group-title,
  .group-toggle {
    padding: 4px 6px;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
  }

  .group-toggle {
    display: flex;
    align-items: center;
    gap: 4px;
    border: none;
    background: none;
    font-family: inherit;
    text-align: left;
    cursor: pointer;
  }

  .group-toggle:hover {
    color: var(--text-primary);
  }

  .group-toggle-label {
    flex: 1;
  }

  .chevron {
    transition: transform 140ms ease;
  }

  .chevron.open {
    transform: rotate(90deg);
  }

  .tab-entry {
    border-radius: var(--radius-md);
  }

  .tab-entry.expanded {
    background: color-mix(in srgb, var(--bg-hover) 46%, transparent);
  }

  .tab-entry.unresponsive {
    background: color-mix(in srgb, var(--danger) 8%, transparent);
  }

  .tab-row {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    min-height: 36px;
    padding: 4px 6px;
    border: none;
    border-radius: var(--radius-md);
    background: none;
    color: var(--text-primary);
    font: inherit;
    text-align: left;
    cursor: default;
  }

  .tab-row:hover {
    background: color-mix(in srgb, var(--bg-hover) 46%, transparent);
  }

  .tab-row.sleeping {
    min-height: 30px;
    color: var(--text-secondary);
  }

  .tab-row.sleeping .favicon {
    opacity: 0.6;
  }

  .favicon {
    width: 16px;
    height: 16px;
    border-radius: var(--radius-xs);
    flex-shrink: 0;
  }

  .favicon-fallback {
    display: grid;
    place-items: center;
    background: var(--text-primary-tint-10);
    color: var(--text-primary);
    font-size: var(--font-size-3xs);
    font-weight: var(--font-weight-semibold);
  }

  .tab-copy {
    flex: 1;
    min-width: 0;
    display: grid;
    gap: 4px;
  }

  .tab-title {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: var(--font-size-sm);
  }

  /* Danger mixed toward the text color here: on the tinted rows plain danger text falls under AA. */
  .tab-state {
    color: color-mix(in srgb, var(--danger) 60%, var(--text-primary));
    font-size: var(--font-size-xs);
  }

  .usage-bar {
    display: block;
    height: 3px;
    border-radius: var(--radius-2xs);
    background: color-mix(in srgb, var(--text-primary) 8%, transparent);
    overflow: hidden;
  }

  .usage-bar span {
    display: block;
    height: 100%;
    border-radius: inherit;
    background: color-mix(in srgb, var(--text-primary) 35%, transparent);
    transition: width 300ms ease;
  }

  .unresponsive .tab-title {
    color: color-mix(in srgb, var(--danger) 60%, var(--text-primary));
  }

  .tab-flag {
    flex-shrink: 0;
    color: var(--text-muted);
  }

  .tab-bytes,
  .tab-cpu {
    flex-shrink: 0;
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }

  .tab-cpu {
    color: var(--text-muted);
  }

  .details {
    display: grid;
    gap: 6px;
    padding: 0 8px 8px 30px;
    font-size: var(--font-size-xs);
    /* Secondary, not muted: the open row's tint takes muted text under AA. */
    color: var(--text-secondary);
  }

  .details-url {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .details-actions {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
  }

  .small-button.danger {
    color: color-mix(in srgb, var(--danger) 45%, var(--text-primary));
  }

  .empty-text {
    margin: 0;
    padding: 10px 6px;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }
</style>
