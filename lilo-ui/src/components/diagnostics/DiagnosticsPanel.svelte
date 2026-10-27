<script lang="ts">
  import StatusBanner from "../banners/StatusBanner.svelte";
  import { on } from "../../lib/bridge";
  import { settingsActions } from "../../lib/bridge/actions";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import type {
    BridgeExtensionDiagnosticSnapshot,
    BridgeSettingsActionStatusPayload,
    BridgeStartupMetricMarkSnapshot,
    BridgeStartupMetricSummary,
    BridgeStartupTraceSnapshot,
    BridgeTabLifecycleDiagnostics,
  } from "../../lib/bridge/protocol";
  import PanelHeader from "../ui/PanelHeader.svelte";
  import UiSearchField from "../ui/UiSearchField.svelte";
  import UiSegmented from "../ui/UiSegmented.svelte";
  import { resolveDisplayName } from "../extensions/extensionPanelModel";
  import {
    filterLog,
    formatEventName,
    logEntries,
    startupWaterfall,
    type LogFilter,
  } from "./diagnosticsPanelModel";
  import {
    closeActivePanel,
    isDiagnosticsVisible,
    openProcessManager,
  } from "../../stores/panels.svelte";
  import { getExtensions } from "../../stores/extensions.svelte";

  type Tab = "startup" | "memory" | "log";

  const MAX_LOG_ROWS = 200;

  const DIAGNOSTIC_ACTIONS = new Set([
    "clearExtensionDiagnostics",
    "copyExtensionDiagnostics",
    "copyDiagnosticsReport",
    "forceLifecycleTrim",
    "togglePerfRecording",
  ]);

  let _extensionDiagnostics = $state.raw<BridgeExtensionDiagnosticSnapshot[]>([]);
  let _startupSummary = $state.raw<BridgeStartupMetricSummary | null>(null);
  let _startupMarks = $state.raw<BridgeStartupMetricMarkSnapshot[]>([]);
  let _startupTraces = $state.raw<BridgeStartupTraceSnapshot[]>([]);
  let _lifecycle = $state.raw<BridgeTabLifecycleDiagnostics | null>(null);
  let _status = $state<BridgeSettingsActionStatusPayload | null>(null);
  let _tab = $state<Tab>("startup");
  let _logFilter = $state<LogFilter>("all");
  let _logQuery = $state("");
  let _recordingStartedAt = $state<number | null>(null);
  let _now = $state(Date.now());

  const _recordingElapsed = $derived.by(() => {
    if (_recordingStartedAt == null) return "";
    const seconds = Math.max(0, Math.floor((_now - _recordingStartedAt) / 1000));
    return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
  });

  const _extensions = $derived(getExtensions());
  const _timeFormat = $derived(
    new Intl.DateTimeFormat(getLocale(), { hour: "2-digit", minute: "2-digit", second: "2-digit" }),
  );
  const _dateTimeFormat = $derived(
    new Intl.DateTimeFormat(getLocale(), { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }),
  );

  const _bootMs = $derived(
    _startupSummary?.bootDurationMilliseconds ??
      _startupSummary?.chromeVisualReadyMilliseconds ??
      _startupMarks.at(-1)?.totalMilliseconds ??
      null,
  );
  const _waterfall = $derived(startupWaterfall(_startupMarks));

  const _log = $derived(logEntries(_extensionDiagnostics, _startupTraces, extensionLabel));
  const _errorCount = $derived(_log.reduce((count, entry) => count + Number(entry.level === "error"), 0));
  const _filteredLog = $derived(filterLog(_log, _logFilter, _logQuery));

  const _tabOptions = $derived([
    { value: "startup", label: t("diagnostics.tabStartup"), icon: "M8 5.5V8.5l2 1.3M6.5 1.5h3M8 3.5a5 5 0 1 0 0 10 5 5 0 0 0 0-10z" },
    { value: "memory", label: t("diagnostics.tabMemory"), icon: "M4.5 4.5h7v7h-7zM6.5 2v2.5M9.5 2v2.5M6.5 11.5V14M9.5 11.5V14M2 6.5h2.5M2 9.5h2.5M11.5 6.5H14M11.5 9.5H14" },
    {
      value: "log",
      label: _errorCount > 0 ? t("diagnostics.tabLogCount", { count: _errorCount }) : t("diagnostics.tabLog"),
      icon: "M3 4h10M3 8h10M3 12h6",
    },
  ]);
  // Under this width the three labels cannot share the row (French, the narrowest sidebar).
  const COMPACT_TABS_WIDTH = 230;
  let _tabsWidth = $state(0);

  const _filterOptions = $derived<Array<{ value: LogFilter; label: string }>>([
    { value: "all", label: t("diagnostics.filterAll") },
    { value: "errors", label: t("diagnostics.filterErrors") },
    { value: "extensions", label: t("diagnostics.filterExtensions") },
    { value: "traces", label: t("diagnostics.filterTraces") },
  ]);

  const _memoryRows = $derived([
    { label: t("diagnostics.liveWebViews"), value: _lifecycle?.totalLiveEngineCount },
    { label: t("diagnostics.inActiveSpace"), value: _lifecycle?.activeSpaceEngineCount, indent: true },
    { label: t("diagnostics.inHiddenSpaces"), value: _lifecycle?.hiddenSpaceEngineCount, indent: true },
    { label: t("diagnostics.sleepingTabs"), value: _lifecycle?.discardedOpenTabCount },
    { label: t("diagnostics.restoringTabs"), value: _lifecycle?.restoringTabCount },
    { label: t("diagnostics.savedStates"), value: _lifecycle?.savedInteractionStateCount },
    { label: t("diagnostics.trackedSpaces"), value: _lifecycle?.trackedSpaceCount },
    { label: t("diagnostics.hiddenSpacesRetaining"), value: _lifecycle?.hiddenSpacesWithNormalRetainedEngines },
  ]);

  function loadPanelData(): void {
    settingsActions.loadStartupMetrics();
    settingsActions.loadExtensionDiagnostics();
  }

  $effect(() => {
    if (isDiagnosticsVisible()) loadPanelData();
  });

  $effect(() => {
    const offExtensions = on("extensionDiagnosticsLoaded", (data) => {
      _extensionDiagnostics = data.entries ?? [];
    });
    const offStartup = on("startupMetricsLoaded", (data) => {
      _startupSummary = data.summary ?? null;
      _startupMarks = data.marks ?? [];
      _startupTraces = data.traces ?? [];
      _lifecycle = data.lifecycleDiagnostics ?? null;
      _recordingStartedAt = data.perfRecordingStartedAt ?? null;
    });
    const offRecording = on("perfRecordingChanged", (data) => {
      _recordingStartedAt = data.startedAt;
    });
    const offStatus = on("settingsActionCompleted", (data) => {
      if (DIAGNOSTIC_ACTIONS.has(data.action)) _status = data;
    });
    return () => {
      offExtensions();
      offStartup();
      offRecording();
      offStatus();
    };
  });

  // The elapsed time ticks only while a recording runs and the panel shows it.
  $effect(() => {
    if (_recordingStartedAt == null || !isDiagnosticsVisible()) return;
    _now = Date.now();
    const timer = setInterval(() => (_now = Date.now()), 1000);
    return () => clearInterval(timer);
  });

  function handleWindowKeydown(e: KeyboardEvent): void {
    if (e.key !== "Escape" || e.defaultPrevented || !isDiagnosticsVisible()) return;
    if (e.target instanceof HTMLInputElement && e.target.value) return;
    e.preventDefault();
    closeActivePanel();
  }

  function formatMilliseconds(value: number | null | undefined): string {
    if (value == null || Number.isNaN(value)) return "--";
    return `${value >= 100 ? value.toFixed(0) : value.toFixed(1)} ms`;
  }

  function extensionLabel(extensionId: string): string {
    if (!extensionId) return t("diagnostics.appExtensionLabel");
    const extension = _extensions.find((ext) => ext.id === extensionId);
    return extension ? resolveDisplayName(extension) : extensionId;
  }
</script>

<svelte:window onkeydown={handleWindowKeydown} />

{#if isDiagnosticsVisible()}
  <div class="panel-shell diagnostics-panel" role="dialog" aria-label={t("diagnostics.title")}>
    <PanelHeader title={t("diagnostics.title")} onclose={closeActivePanel}>
      {#snippet actions()}
        <button
          class="hdr-ctl record-ctl"
          class:recording={_recordingStartedAt != null}
          type="button"
          onclick={() => settingsActions.togglePerfRecording()}
          use:tooltip={{ text: _recordingStartedAt == null ? t("diagnostics.recordSession") : t("diagnostics.stopRecording"), placement: "bottom" }}
          aria-label={_recordingStartedAt == null ? t("diagnostics.recordSession") : t("diagnostics.stopRecording")}
          aria-pressed={_recordingStartedAt != null}
        >
          {#if _recordingStartedAt == null}
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><circle cx="8" cy="8" r="5.5" /><circle cx="8" cy="8" r="2.5" fill="currentColor" stroke="none" /></svg>
          {:else}
            <span class="record-dot" aria-hidden="true"></span>
            <span class="record-time">{_recordingElapsed}</span>
          {/if}
        </button>
        <button
          class="hdr-ctl"
          type="button"
          onclick={() => settingsActions.copyDiagnosticsReport()}
          use:tooltip={{ text: t("diagnostics.copyReport"), placement: "bottom" }}
          aria-label={t("diagnostics.copyReport")}
        >
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" aria-hidden="true"><rect x="5.5" y="5.5" width="8" height="8" rx="1.5" /><path d="M10.5 5.5V4A1.5 1.5 0 0 0 9 2.5H4A1.5 1.5 0 0 0 2.5 4v5A1.5 1.5 0 0 0 4 10.5h1.5" /></svg>
        </button>
        <button
          class="hdr-ctl"
          type="button"
          onclick={loadPanelData}
          use:tooltip={{ text: t("diagnostics.refresh"), placement: "bottom" }}
          aria-label={t("diagnostics.refresh")}
        >
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M13 8a5 5 0 1 1-1.6-3.7" /><path d="M13 2.5v3h-3" /></svg>
        </button>
      {/snippet}
    </PanelHeader>

    <div class="diagnostics-tabs" bind:clientWidth={_tabsWidth}>
      <UiSegmented
        value={_tab}
        options={_tabOptions}
        compact={_tabsWidth > 0 && _tabsWidth < COMPACT_TABS_WIDTH}
        ariaLabel={t("diagnostics.tabsAriaLabel")}
        onchange={(value) => (_tab = value as Tab)}
      />
    </div>

    <div class="diagnostics-body">
      <StatusBanner bind:status={_status} />

      {#if _tab === "startup"}
        <section class="boot-summary">
          <div class="boot-figures">
            <span class="boot-total">{formatMilliseconds(_bootMs)}</span>
            <span class="muted">{t("diagnostics.bootLabel")}</span>
          </div>
          {#if _startupMarks.length > 0}
            <span class="muted">
              {t("diagnostics.launchedAt", { date: _dateTimeFormat.format(_startupMarks[0]!.timestamp * 1000) })}
            </span>
          {/if}
        </section>

        {#if _waterfall.length === 0}
          <p class="empty-text">{t("diagnostics.noStartupMetrics")}</p>
        {:else}
          <ol class="waterfall">
            {#each _waterfall as row, index (row.id)}
              <li
                class="waterfall-row"
                class:slowest={row.slowest}
                use:tooltip={`${row.event} · ${formatMilliseconds(row.totalMs)}`}
              >
                <span class="waterfall-name">{formatEventName(row.event)}</span>
                <span class="waterfall-track" aria-hidden="true">
                  <span class="waterfall-bar" style={`left: ${row.startPct}%; width: max(2px, ${row.widthPct}%)`}></span>
                </span>
                <span class="waterfall-value">
                  {index === 0 ? formatMilliseconds(row.totalMs) : `+${formatMilliseconds(row.deltaMs)}`}
                </span>
              </li>
            {/each}
          </ol>
          <p class="muted hint">{t("diagnostics.slowestHint")}</p>
        {/if}
      {:else if _tab === "memory"}
        <dl class="memory-list">
          {#each _memoryRows as row (row.label)}
            <div class="memory-row" class:indent={row.indent}>
              <dt>{row.label}</dt>
              <dd>{row.value ?? "--"}</dd>
            </div>
          {/each}
        </dl>

        <div class="memory-actions">
          <button class="link-button" type="button" onclick={openProcessManager}>
            {t("diagnostics.openProcessManager")}
          </button>
          <div class="trim">
            <span class="muted">{t("diagnostics.trimDescription")}</span>
            <button class="small-button" type="button" onclick={() => settingsActions.forceLifecycleTrim()}>
              {t("diagnostics.trimMemory")}
            </button>
          </div>
        </div>
      {:else}
        <div class="log-toolbar">
          <UiSearchField
            placeholder={t("diagnostics.searchPlaceholder")}
            ariaLabel={t("diagnostics.searchPlaceholder")}
            value={_logQuery}
            onchange={(value) => (_logQuery = value)}
          />
          <div class="log-filters">
            <div class="chips" role="radiogroup" aria-label={t("diagnostics.filterAriaLabel")}>
              {#each _filterOptions as option (option.value)}
                <button
                  class="chip"
                  class:on={_logFilter === option.value}
                  type="button"
                  role="radio"
                  aria-checked={_logFilter === option.value}
                  onclick={() => (_logFilter = option.value)}
                >
                  {option.label}
                </button>
              {/each}
            </div>
            <button
              class="hdr-ctl small"
              type="button"
              onclick={() => settingsActions.copyExtensionDiagnostics()}
              use:tooltip={t("diagnostics.copyLogs")}
              aria-label={t("diagnostics.copyLogs")}
            >
              <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" aria-hidden="true"><rect x="5.5" y="5.5" width="8" height="8" rx="1.5" /><path d="M10.5 5.5V4A1.5 1.5 0 0 0 9 2.5H4A1.5 1.5 0 0 0 2.5 4v5A1.5 1.5 0 0 0 4 10.5h1.5" /></svg>
            </button>
            <button
              class="hdr-ctl small"
              type="button"
              onclick={() => settingsActions.clearExtensionDiagnostics()}
              use:tooltip={t("diagnostics.clearLog")}
              aria-label={t("diagnostics.clearLog")}
            >
              <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5" /></svg>
            </button>
          </div>
        </div>

        {#if _log.length === 0}
          <p class="empty-text">{t("diagnostics.emptyLog")}</p>
        {:else if _filteredLog.length === 0}
          <p class="empty-text">{t("diagnostics.noMatches")}</p>
        {:else}
          <ol class="log">
            {#each _filteredLog.slice(0, MAX_LOG_ROWS) as entry (entry.id)}
              <li class={`log-entry level-${entry.level}`}>
                <span class="level-dot" role="img" aria-label={t(`diagnostics.level.${entry.level}`)}></span>
                <div class="log-copy">
                  <div class="log-head">
                    <span class="log-title">{entry.title}</span>
                    {#if entry.durationMs != null}<span class="muted">{formatMilliseconds(entry.durationMs)}</span>{/if}
                    <span class="muted log-time">{_timeFormat.format(entry.timestamp * 1000)}</span>
                  </div>
                  <p class="log-message">{entry.message}</p>
                  {#if entry.detail}<p class="log-detail">{entry.detail}</p>{/if}
                </div>
              </li>
            {/each}
          </ol>
          {#if _filteredLog.length > MAX_LOG_ROWS}
            <p class="muted hint">{t("diagnostics.truncated", { count: MAX_LOG_ROWS })}</p>
          {/if}
        {/if}
      {/if}
    </div>
  </div>
{/if}

<style>
  .diagnostics-panel {
    position: relative;
    background: var(--sidebar-bg);
    color: var(--text-primary);
  }

  .hdr-ctl {
    width: 26px;
    height: 26px;
  }

  .hdr-ctl.small {
    width: 24px;
    height: 24px;
  }

  .record-ctl.recording {
    display: inline-flex;
    align-items: center;
    width: auto;
    gap: 5px;
    padding: 0 7px;
    color: var(--text-primary);
  }

  .record-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--danger);
  }

  .record-time {
    font-size: var(--font-size-xs);
    font-variant-numeric: tabular-nums;
  }

  .diagnostics-tabs {
    padding: 0 10px 8px;
    flex-shrink: 0;
  }

  /* Never wider than the sidebar: the labels shrink before they push the panel aside. */
  .diagnostics-tabs :global(.ui-segmented) {
    max-width: 100%;
  }

  .diagnostics-tabs :global(.ui-segmented button) {
    flex: 0 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .diagnostics-body {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    padding: 0 10px 18px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .muted {
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }

  .hint {
    margin: 0;
    padding: 0 4px;
  }

  .empty-text {
    margin: 0;
    padding: 16px 6px;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    text-align: center;
  }

  .boot-summary {
    display: grid;
    gap: 2px;
    padding: 2px 4px 0;
  }

  .boot-figures {
    display: flex;
    align-items: baseline;
    gap: 6px;
  }

  .boot-total {
    font-size: var(--font-size-3xl);
    font-weight: var(--font-weight-semibold);
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }

  .waterfall {
    display: grid;
    gap: 1px;
    margin: 0;
    padding: 0;
    list-style: none;
  }

  .waterfall-row {
    display: grid;
    grid-template-columns: minmax(0, 92px) minmax(0, 1fr) 52px;
    align-items: center;
    gap: 8px;
    padding: 4px;
    border-radius: var(--radius-sm);
    font-size: var(--font-size-xs);
  }

  .waterfall-row:hover {
    background: color-mix(in srgb, var(--bg-hover) 46%, transparent);
  }

  .waterfall-name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .waterfall-track {
    position: relative;
    height: 8px;
  }

  .waterfall-bar {
    position: absolute;
    top: 0;
    height: 100%;
    border-radius: var(--radius-2xs);
    background: color-mix(in srgb, var(--accent) 80%, var(--text-primary));
  }

  .slowest .waterfall-bar {
    background: var(--warning);
  }

  /* Orange only on the bar: as text it cannot read on every Space color. */
  .slowest .waterfall-value {
    color: var(--text-primary);
    font-weight: var(--font-weight-semibold);
  }

  .waterfall-value {
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
    text-align: right;
    white-space: nowrap;
  }

  .memory-list {
    display: grid;
    margin: 0;
  }

  .memory-row {
    display: flex;
    justify-content: space-between;
    gap: 8px;
    padding: 8px 4px;
    border-bottom: 1px solid color-mix(in srgb, var(--text-primary) 6%, transparent);
    font-size: var(--font-size-sm);
  }

  .memory-row.indent {
    padding-left: 16px;
    color: var(--text-secondary);
  }

  .memory-row dt {
    min-width: 0;
  }

  .memory-row dd {
    margin: 0;
    font-variant-numeric: tabular-nums;
  }

  .memory-actions {
    display: grid;
    gap: 10px;
    padding: 0 4px;
  }

  .trim {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .trim .muted {
    flex: 1;
  }

  .link-button {
    justify-self: start;
    padding: 0;
    border: none;
    background: none;
    color: color-mix(in srgb, var(--accent) 50%, var(--text-primary));
    font: inherit;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-semibold);
    cursor: pointer;
  }

  .link-button:hover {
    color: var(--text-primary);
  }

  .log-toolbar {
    display: grid;
    gap: 6px;
  }

  .log-filters {
    display: flex;
    align-items: center;
    gap: 2px;
  }

  .chips {
    flex: 1;
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
  }

  .chip {
    height: 22px;
    padding: 0 8px;
    border: 1px solid var(--text-primary-tint-10);
    border-radius: var(--radius-chip);
    background: none;
    color: var(--text-secondary);
    font: inherit;
    font-size: var(--font-size-xs);
    cursor: pointer;
  }

  .chip.on {
    border-color: color-mix(in srgb, var(--text-primary) 22%, transparent);
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .log {
    display: grid;
    margin: 0;
    padding: 0;
    list-style: none;
  }

  .log-entry {
    display: grid;
    grid-template-columns: 6px minmax(0, 1fr);
    gap: 8px;
    padding: 8px 4px;
    border-bottom: 1px solid color-mix(in srgb, var(--text-primary) 6%, transparent);
  }

  .level-dot {
    width: 6px;
    height: 6px;
    margin-top: 4px;
    border-radius: 50%;
    background: color-mix(in srgb, var(--text-primary) 25%, transparent);
  }

  .level-warning .level-dot {
    background: var(--warning);
  }

  .level-error .level-dot {
    background: var(--danger);
  }

  .log-copy {
    display: grid;
    gap: 2px;
    min-width: 0;
  }

  .log-head {
    display: flex;
    align-items: baseline;
    gap: 6px;
  }

  .log-title {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-medium);
  }

  .log-time {
    flex-shrink: 0;
    font-variant-numeric: tabular-nums;
  }

  .log-message,
  .log-detail {
    margin: 0;
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: var(--font-size-xs);
    line-height: 1.4;
    overflow-wrap: anywhere;
  }

  .log-message {
    color: var(--text-secondary);
  }

  .level-error .log-message {
    color: var(--danger);
  }

  .log-detail {
    color: var(--text-muted);
  }
</style>
