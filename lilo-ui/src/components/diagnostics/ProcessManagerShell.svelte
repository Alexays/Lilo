<script lang="ts">
  import StatusBanner from "../banners/StatusBanner.svelte";
  import { formatByteSize } from "../../lib/format";
  import { getFormatLocale, getLocale, t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { hostOf } from "../../lib/url";
  import { processManagerActions } from "../../lib/bridge/actions";
  import type { BridgeProcessInfo, BridgeProcessKind, BridgeProcessTabInfo } from "../../lib/bridge/protocol";
  import { closePageShell, getProcessManagerSection, isProcessManagerVisible } from "../../stores/panels.svelte";
  import {
    getProcessOverview,
    getProcessQuery,
    getProcessSidebarTab,
    getProcessSnapshot,
    getProcessStatus,
    getSleepingTabs,
    loadProcessSnapshot,
    setProcessQuery,
    setProcessStatus,
  } from "../../stores/processManager.svelte";
  import { isVerticalLayout } from "../../stores/tabLayout.svelte";
  import { tabDisplayTitle } from "../../stores/tabs.svelte";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiConfirmModal from "../ui/UiConfirmModal.svelte";
  import UiShellFrame from "../ui/UiShellFrame.svelte";
  import ProcessManagerNav from "./ProcessManagerNav.svelte";
  import { filterTabUsages } from "./processManagerModel";

  const REFRESH_MS = 2000;

  const KIND_LABEL_KEYS: Record<BridgeProcessKind, string> = {
    webContent: "processManager.kindWebContent",
    provisionalWebContent: "processManager.kindProvisional",
    network: "processManager.kindNetwork",
    gpu: "processManager.kindGPU",
    model: "processManager.kindModel",
  };

  const SECTION_TITLE_KEYS = {
    tabs: "processManager.groupTabs",
    sleeping: "processManager.groupSleeping",
    system: "processManager.groupSystem",
  } as const;

  type PendingAction =
    | { kind: "terminate"; process: BridgeProcessInfo }
    | { kind: "closeTab"; tab: BridgeProcessTabInfo };

  const open = $derived(isProcessManagerVisible());
  const section = $derived(getProcessManagerSection());
  const snapshot = $derived(getProcessSnapshot());
  const overview = $derived(getProcessOverview());
  const query = $derived(getProcessQuery().trim().toLowerCase());
  const tabs = $derived(filterTabUsages(overview.tabs, query));
  const sleeping = $derived(
    getSleepingTabs().filter(({ tab }) => !query || tab.title.toLowerCase().includes(query) || tab.url.toLowerCase().includes(query)),
  );
  const maxTabBytes = $derived(overview.tabs.reduce((max, usage) => Math.max(max, usage.bytes), 0));
  const locale = $derived(getLocale());
  // Whole percents from 10%, one decimal below.
  const cpuFormats = $derived([0, 1].map((digits) =>
    new Intl.NumberFormat(getFormatLocale(), { style: "percent", minimumFractionDigits: digits, maximumFractionDigits: digits })));

  let expandedId = $state<string | null>(null);
  let pendingAction = $state<PendingAction | null>(null);

  // Polls only while the screen shows and the window is visible.
  $effect(() => {
    if (!open) return;
    loadProcessSnapshot();
    const timer = window.setInterval(() => {
      if (!document.hidden) processManagerActions.load();
    }, REFRESH_MS);
    return () => {
      window.clearInterval(timer);
      expandedId = null;
      setProcessQuery("");
    };
  });

  const note = $derived(
    snapshot
      ? new Intl.ListFormat(getFormatLocale(), { type: "unit" }).format([
          formatByteSize(overview.totalBytes, locale),
          t("processManager.tabsCount", { count: overview.tabs.length }),
          t("processManager.cpu", { value: formatCPU(overview.cpuPercent) }),
        ])
      : "",
  );

  // The chrome web view has no dialog delegate, so window.confirm() always returns false:
  // destructive actions go through the in-page sheet instead.
  function confirmPendingAction(): void {
    const pending = pendingAction;
    pendingAction = null;
    if (!pending) return;
    if (pending.kind === "terminate") {
      processManagerActions.terminateProcess({ processId: pending.process.id, confirmed: true });
    } else {
      processManagerActions.closeTab(pending.tab.id, pending.tab.spaceId);
    }
  }

  function pendingActionTitle(pending: PendingAction): string {
    return pending.kind === "terminate"
      ? t("processManager.confirmTerminate", { kind: t(KIND_LABEL_KEYS[pending.process.kind]), pid: pending.process.pid })
      : t("processManager.confirmCloseTab", { tab: pending.tab.title || pending.tab.url || pending.tab.id });
  }

  function handleWindowKeydown(event: KeyboardEvent): void {
    if (event.key !== "Escape" || event.defaultPrevented || !open || pendingAction) return;
    if (event.target instanceof HTMLInputElement && event.target.value) return;
    event.preventDefault();
    if (expandedId) expandedId = null;
    else closePageShell();
  }

  function formatCPU(value: number | null | undefined): string {
    if (value == null || Number.isNaN(value)) return "--";
    return cpuFormats[value >= 10 ? 0 : 1].format(value / 100);
  }

  function segmentLabel(id: string, label: string | null): string {
    if (id === "system") return t("processManager.groupSystem");
    if (id === "others") return t("processManager.others", { count: Math.max(0, overview.tabs.length - 3) });
    return tabDisplayTitle(label ?? "") || t("processManager.untitledTab");
  }

  function segmentClass(id: string, index: number): string {
    return `seg-${id === "system" || id === "others" ? id : index}`;
  }

  function reclaimCopy(): string {
    const count = overview.reclaimableTabCount;
    if (overview.reclaimableBytes <= 0) {
      return t("processManager.reclaimNoSize", { count });
    }
    const size = formatByteSize(overview.reclaimableBytes, locale);
    return t("processManager.reclaim", { count, size });
  }
</script>

<svelte:window onkeydown={handleWindowKeydown} />

{#snippet processNav(compact: boolean)}<ProcessManagerNav {compact} />{/snippet}

{#snippet toggleRow(id: string, onopen: () => void)}
  <button
    class="row-hit"
    type="button"
    aria-expanded={expandedId === id}
    aria-label={t("processManager.details")}
    onclick={() => (expandedId = expandedId === id ? null : id)}
    ondblclick={onopen}
  ></button>
{/snippet}

<UiShellFrame
  active={open}
  ariaLabel={t("processManager.title")}
  interactiveZoneId="processes-shell"
  title={t(SECTION_TITLE_KEYS[section])}
  {note}
  nav={isVerticalLayout() ? undefined : processNav}
>
  <StatusBanner bind:status={getProcessStatus, setProcessStatus} />

  {#if snapshot && section === "tabs"}
    {#if overview.totalBytes > 0}
      <section class="overview" aria-label={t("processManager.memoryAriaLabel")}>
        <div class="memory-bar" aria-hidden="true">
          {#each overview.segments as segment, index (segment.id)}
            <span class="segment {segmentClass(segment.id, index)}" style:flex-grow={segment.bytes}></span>
          {/each}
        </div>
        <ul class="memory-legend">
          {#each overview.segments as segment, index (segment.id)}
            <li>
              <span class="swatch {segmentClass(segment.id, index)}"></span>
              <span class="legend-label">{segmentLabel(segment.id, segment.label)}</span>
              <span class="legend-size">{formatByteSize(segment.bytes, locale)}</span>
            </li>
          {/each}
        </ul>
      </section>
    {/if}

    {#if overview.reclaimableTabCount > 0}
      <div class="reclaim">
        <svg width="18" height="18" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round" aria-hidden="true"><path d="M13 9.5A5.5 5.5 0 0 1 6.5 3a5.5 5.5 0 1 0 6.5 6.5z" /></svg>
        <span class="reclaim-copy">{reclaimCopy()}</span>
        <UiButton onclick={() => processManagerActions.sleepHiddenTabs()}>{t("processManager.sleep")}</UiButton>
      </div>
    {/if}

    <h3 class="section-header">{t("processManager.groupTabs")}</h3>
    {#if tabs.length === 0}
      <p class="empty-text">{t("processManager.empty")}</p>
    {/if}
    {#each tabs as usage (usage.tab.id)}
      {@const sidebarTab = getProcessSidebarTab(usage.tab.id)}
      {@const expanded = expandedId === usage.tab.id}
      {@const title = tabDisplayTitle(usage.tab.title) || t("processManager.untitledTab")}
      {@const host = hostOf(usage.tab.url)}
      <div class="object-row" class:expanded>
        {@render toggleRow(usage.tab.id, () => processManagerActions.focusTab(usage.tab.id, usage.tab.spaceId))}
        <span class="visual">
          <SiteFavicon src={sidebarTab?.faviconDataURL} {title} url={usage.tab.url} size={32} radius={8} tile />
          {#if usage.unresponsive}<span class="attention-dot" aria-hidden="true"></span>{/if}
        </span>
        <span class="copy">
          <span class="name">{title}</span>
          {#if usage.unresponsive}
            <span class="detail attention">{t("processManager.unresponsive")}</span>
          {:else if expanded}
            <span class="detail">
              {[
                host,
                t("processManager.pid", { pid: usage.process.pid }),
                t("processManager.cpu", { value: formatCPU(usage.process.metrics?.cpuPercent) }),
                usage.shared ? t("processManager.sharedWith", { count: usage.process.tabs.length - 1 }) : "",
              ].filter(Boolean).join(" · ")}
            </span>
          {:else if host}
            <span class="detail">{host}</span>
          {/if}
        </span>
        <span class="accessory">
          {#if usage.tab.isAudioPlaying}
            <svg class="flag" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" role="img" aria-label={t("processManager.audioPlaying")}><path d="M3 6.5h2.5L9 3.5v9l-3.5-3H3z" /><path d="M11.5 6a3 3 0 0 1 0 4" /></svg>
          {/if}
          {#if usage.tab.lifecycle === "frozen"}
            <svg class="flag" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" role="img" aria-label={t("processManager.frozen")}><path d="M8 2v12M2.8 5l10.4 6M2.8 11l10.4-6" /></svg>
          {/if}
          {#if !usage.unresponsive}
            <span class="usage-bar" aria-hidden="true">
              <span style:width="{maxTabBytes > 0 ? (usage.bytes / maxTabBytes) * 100 : 0}%"></span>
            </span>
          {/if}
          <span class="bytes" use:tooltip={usage.shared ? t("processManager.sharedEstimate") : ""}>
            {usage.shared ? "≈ " : ""}{formatByteSize(usage.bytes, locale)}
          </span>
        </span>
        {#if expanded}
          <div class="actions">
            <UiButton variant="danger" onclick={() => (pendingAction = { kind: "terminate", process: usage.process })}>
              {t("processManager.terminate")}
            </UiButton>
            <span class="actions-spacer"></span>
            <UiButton onclick={() => processManagerActions.reloadTab(usage.tab.id, usage.tab.spaceId)}>{t("processManager.reload")}</UiButton>
            <UiButton onclick={() => (pendingAction = { kind: "closeTab", tab: usage.tab })}>{t("common.close")}</UiButton>
            <UiButton variant="primary" onclick={() => processManagerActions.focusTab(usage.tab.id, usage.tab.spaceId)}>{t("processManager.focus")}</UiButton>
          </div>
        {/if}
      </div>
    {/each}
  {:else if snapshot && section === "sleeping"}
    {#if sleeping.length === 0}
      <p class="empty-text">{t("processManager.emptySleeping")}</p>
    {/if}
    {#each sleeping as { tab, spaceId } (tab.id)}
      {@const title = tabDisplayTitle(tab.title) || t("processManager.untitledTab")}
      <div class="object-row">
        <button
          class="row-hit"
          type="button"
          aria-label={t("processManager.wake")}
          use:tooltip={t("processManager.wake")}
          onclick={() => processManagerActions.focusTab(tab.id, spaceId)}
        ></button>
        <span class="visual">
          <SiteFavicon src={tab.faviconDataURL} {title} url={tab.url} size={32} radius={8} tile asleep />
        </span>
        <span class="copy">
          <span class="name">{title}</span>
          {#if hostOf(tab.url)}<span class="detail">{hostOf(tab.url)}</span>{/if}
        </span>
      </div>
    {/each}
  {:else if snapshot && section === "system"}
    {#each overview.system as process (process.id)}
      {@const expanded = expandedId === process.id}
      <div class="object-row" class:expanded>
        {@render toggleRow(process.id, () => (expandedId = process.id))}
        <span class="copy">
          <span class="name">{t(KIND_LABEL_KEYS[process.kind])}</span>
          <span class="detail">
            {[t("processManager.pid", { pid: process.pid }), t("processManager.cpu", { value: formatCPU(process.metrics?.cpuPercent) }), expanded ? process.webProcessStateLabel : ""].filter(Boolean).join(" · ")}
          </span>
        </span>
        <span class="accessory">
          <span class="bytes">{formatByteSize(process.metrics?.residentSizeBytes ?? 0, locale)}</span>
        </span>
        {#if expanded}
          <div class="actions">
            <UiButton variant="danger" onclick={() => (pendingAction = { kind: "terminate", process })}>
              {t("processManager.terminate")}
            </UiButton>
          </div>
        {/if}
      </div>
    {/each}
  {/if}

  <UiConfirmModal
    visible={pendingAction !== null}
    title={pendingAction ? pendingActionTitle(pendingAction) : ""}
    confirmLabel={pendingAction?.kind === "terminate" ? t("processManager.terminate") : t("common.close")}
    confirmAction={confirmPendingAction}
    cancelAction={() => (pendingAction = null)}
  />
</UiShellFrame>

<style>
  .overview {
    display: grid;
    gap: var(--space-12);
    margin-bottom: var(--space-20);
  }

  .memory-bar {
    display: flex;
    gap: 2px;
    height: 12px;
    border-radius: var(--radius-chip);
    overflow: hidden;
  }

  .segment {
    flex-basis: 0;
    min-width: 3px;
    transition: flex-grow 300ms ease;
  }

  .seg-0 { background: var(--accent); }
  .seg-1 { background: color-mix(in srgb, var(--accent) 66%, var(--bg-primary)); }
  .seg-2 { background: color-mix(in srgb, var(--accent) 42%, var(--bg-primary)); }
  .seg-others { background: color-mix(in srgb, var(--accent) 24%, var(--bg-primary)); }
  .seg-system { background: color-mix(in srgb, var(--text-primary) 22%, var(--bg-primary)); }

  .memory-legend {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-4) var(--space-20);
    margin: 0;
    padding: 0;
    list-style: none;
    font-size: var(--font-size-md);
  }

  .memory-legend li {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    min-width: 0;
  }

  .swatch {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .legend-label {
    max-width: 220px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--text-secondary);
  }

  .legend-size {
    color: var(--text-muted);
    font-variant-numeric: tabular-nums;
  }

  .reclaim {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-12);
    margin-bottom: 22px;
    padding: 11px 14px;
    border-radius: var(--radius-box);
    background: var(--group-box-bg);
    box-shadow: inset 0 0 0 1px var(--separator);
  }

  .reclaim svg {
    flex: none;
    color: var(--accent);
  }

  .reclaim-copy {
    flex: 1 1 160px;
    min-width: 0;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .section-header {
    margin: 0 0 var(--space-8);
    padding-inline: 4px;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    letter-spacing: 0.04em;
    text-transform: uppercase;
  }

  /* One object, one row: 32 px visual, name, one detail line, the accessory on the right. The whole row is
     one button under the others; its hover reaches past the content edge so the visual lines up with the title. */
  .object-row {
    position: relative;
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0 14px;
    min-height: 52px;
    margin-inline: -12px;
    padding: 8px 12px;
    border-radius: var(--radius-md);
  }

  .object-row:hover,
  .object-row.expanded {
    background: var(--bg-hover);
  }

  .object-row:has(.row-hit:focus-visible) {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .row-hit {
    position: absolute;
    inset: 0;
    padding: 0;
    border: 0;
    border-radius: inherit;
    background: none;
    outline: none;
    cursor: default;
  }

  .visual {
    position: relative;
    flex: none;
    display: grid;
    pointer-events: none;
  }

  /* The awaited-action dot, ringed in the page color. */
  .attention-dot {
    position: absolute;
    top: -3px;
    right: -3px;
    width: 10px;
    height: 10px;
    border-radius: 50%;
    background: var(--attention);
    box-shadow: 0 0 0 2px var(--bg-primary);
  }

  .copy {
    flex: 1 1 200px;
    display: grid;
    gap: 2px;
    min-width: 0;
    pointer-events: none;
  }

  .name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .detail {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  /* Orange toward the text color: plain --warning falls under 4.5:1 on the page. */
  .detail.attention {
    color: color-mix(in srgb, var(--warning) 60%, var(--text-primary));
  }

  .accessory {
    flex: none;
    display: flex;
    align-items: center;
    gap: var(--space-16);
    margin-left: auto;
    pointer-events: none;
  }

  .flag {
    color: var(--text-secondary);
  }

  .usage-bar {
    display: block;
    width: 96px;
    height: 4px;
    border-radius: var(--radius-chip);
    background: var(--text-primary-tint-10);
    overflow: hidden;
  }

  .usage-bar span {
    display: block;
    height: 100%;
    border-radius: inherit;
    background: var(--accent);
    transition: width 300ms ease;
  }

  .bytes {
    min-width: 64px;
    color: var(--text-secondary);
    font-size: var(--font-size-md);
    font-variant-numeric: tabular-nums;
    text-align: right;
    white-space: nowrap;
    pointer-events: auto;
  }

  /* Under the copy, aligned with the name; the destructive action first, apart, as red text. */
  .actions {
    position: relative;
    flex: 1 0 100%;
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-8);
    margin: var(--space-8) 0 var(--space-4) 46px;
  }

  .object-row:not(:has(.visual)) .actions {
    margin-left: 0;
  }

  .actions-spacer {
    flex: 1;
  }

  .empty-text {
    margin: 0;
    padding: var(--space-24) 4px;
    color: var(--text-muted);
    font-size: var(--font-size-md);
  }

  @media (prefers-reduced-motion: reduce) {
    .segment,
    .usage-bar span {
      transition: none;
    }
  }
</style>
