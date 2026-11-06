<script lang="ts">
  import StatusBanner from "../banners/StatusBanner.svelte";
  import { settingsActions } from "../../lib/bridge/actions";
  import { getFormatLocale, t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import UiButton from "../ui/UiButton.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiSearchField from "../ui/UiSearchField.svelte";
  import UiSegmented from "../ui/UiSegmented.svelte";
  import UiShellFrame from "../ui/UiShellFrame.svelte";
  import DiagnosticsNav from "./DiagnosticsNav.svelte";
  import { resolveDisplayName } from "../extensions/extensionPanelModel";
  import { filterLog, formatEventName, logEntries, startupWaterfall, type LogFilter } from "./diagnosticsPanelModel";
  import { closePageShell, getDiagnosticsSection, isDiagnosticsVisible, openProcessManager } from "../../stores/panels.svelte";
  import {
    getDiagnosticsStatus,
    getExtensionDiagnostics,
    getLifecycleDiagnostics,
    getStartupMarks,
    getStartupSummary,
    getStartupTraces,
    loadDiagnostics,
    setDiagnosticsStatus,
  } from "../../stores/diagnostics.svelte";
  import { getExtensions } from "../../stores/extensions.svelte";
  import { isVerticalLayout } from "../../stores/tabLayout.svelte";

  const MAX_LOG_ROWS = 200;

  const SECTION_TITLE_KEYS = {
    startup: "diagnostics.tabStartup",
    memory: "diagnostics.tabMemory",
    log: "diagnostics.tabLog",
  } as const;

  const open = $derived(isDiagnosticsVisible());
  const section = $derived(getDiagnosticsSection());
  const marks = $derived(getStartupMarks());
  const summary = $derived(getStartupSummary());
  const lifecycle = $derived(getLifecycleDiagnostics());

  let logFilter = $state<LogFilter>("all");
  let logQuery = $state("");

  const extensions = $derived(getExtensions());
  const timeFormat = $derived(new Intl.DateTimeFormat(getFormatLocale(), { hour: "2-digit", minute: "2-digit", second: "2-digit" }));
  const dateTimeFormat = $derived(new Intl.DateTimeFormat(getFormatLocale(), { day: "numeric", month: "short", hour: "numeric", minute: "2-digit" }));

  const bootMs = $derived(
    summary?.bootDurationMilliseconds ?? summary?.chromeVisualReadyMilliseconds ?? marks.at(-1)?.totalMilliseconds ?? null,
  );
  const waterfall = $derived(startupWaterfall(marks));

  const log = $derived(logEntries(getExtensionDiagnostics(), getStartupTraces(), extensionLabel));
  const errorCount = $derived(log.reduce((count, entry) => count + Number(entry.level === "error"), 0));
  const filteredLog = $derived(filterLog(log, logFilter, logQuery));

  const filterOptions = $derived<Array<{ value: LogFilter; label: string }>>([
    { value: "all", label: t("diagnostics.filterAll") },
    { value: "errors", label: t("diagnostics.filterErrors") },
    { value: "extensions", label: t("diagnostics.filterExtensions") },
    { value: "traces", label: t("diagnostics.filterTraces") },
  ]);

  const memoryRows = $derived([
    { label: t("diagnostics.liveWebViews"), value: lifecycle?.totalLiveEngineCount },
    { label: t("diagnostics.inActiveSpace"), value: lifecycle?.activeSpaceEngineCount, indent: true },
    { label: t("diagnostics.inHiddenSpaces"), value: lifecycle?.hiddenSpaceEngineCount, indent: true },
    { label: t("diagnostics.sleepingTabs"), value: lifecycle?.discardedOpenTabCount },
    { label: t("diagnostics.restoringTabs"), value: lifecycle?.restoringTabCount },
    { label: t("diagnostics.savedStates"), value: lifecycle?.savedInteractionStateCount },
    { label: t("diagnostics.trackedSpaces"), value: lifecycle?.trackedSpaceCount },
    { label: t("diagnostics.hiddenSpacesRetaining"), value: lifecycle?.hiddenSpacesWithNormalRetainedEngines },
  ]);

  const note = $derived.by(() => {
    if (section === "startup") return marks.length > 0 ? t("diagnostics.launchedAt", { date: dateTimeFormat.format(marks[0]!.timestamp * 1000) }) : "";
    if (section === "log") return errorCount > 0 ? t("diagnostics.errorCount", { count: errorCount }) : "";
    return "";
  });

  $effect(() => {
    if (open) loadDiagnostics();
  });

  function handleWindowKeydown(event: KeyboardEvent): void {
    if (event.key !== "Escape" || event.defaultPrevented || !open) return;
    if (event.target instanceof HTMLInputElement && event.target.value) return;
    event.preventDefault();
    closePageShell();
  }

  function formatMilliseconds(value: number | null | undefined): string {
    if (value == null || Number.isNaN(value)) return "--";
    return `${value >= 100 ? value.toFixed(0) : value.toFixed(1)} ms`;
  }

  function extensionLabel(extensionId: string): string {
    if (!extensionId) return t("diagnostics.appExtensionLabel");
    const extension = extensions.find((ext) => ext.id === extensionId);
    return extension ? resolveDisplayName(extension) : extensionId;
  }
</script>

<svelte:window onkeydown={handleWindowKeydown} />

{#snippet diagnosticsNav(compact: boolean)}<DiagnosticsNav {compact} />{/snippet}

<UiShellFrame
  active={open}
  ariaLabel={t("diagnostics.title")}
  interactiveZoneId="diagnostics-shell"
  title={t(SECTION_TITLE_KEYS[section])}
  {note}
  nav={isVerticalLayout() ? undefined : diagnosticsNav}
>
  <div class="diagnostics">
    <StatusBanner bind:status={getDiagnosticsStatus, setDiagnosticsStatus} />

    {#if section === "startup"}
      <p class="boot">
        <span class="boot-total">{formatMilliseconds(bootMs)}</span>
        <span class="boot-label">{t("diagnostics.bootLabel")}</span>
      </p>

      {#if waterfall.length === 0}
        <p class="empty-text">{t("diagnostics.noStartupMetrics")}</p>
      {:else}
        <div>
          <UiInsetList>
            {#each waterfall as row, index (row.id)}
              <div class="waterfall-row" class:slowest={row.slowest} use:tooltip={`${row.event} · ${formatMilliseconds(row.totalMs)}`}>
                <span class="waterfall-name">{formatEventName(row.event)}</span>
                <span class="waterfall-track" aria-hidden="true">
                  <span class="waterfall-bar" style:left="{row.startPct}%" style:width="max(2px, {row.widthPct}%)"></span>
                </span>
                <span class="waterfall-value">
                  {index === 0 ? formatMilliseconds(row.totalMs) : `+${formatMilliseconds(row.deltaMs)}`}
                </span>
              </div>
            {/each}
          </UiInsetList>
          <p class="hint">{t("diagnostics.slowestHint")}</p>
        </div>
      {/if}
    {:else if section === "memory"}
      <UiInsetList>
        {#each memoryRows as row (row.label)}
          <div class="memory-row" class:indent={row.indent}>
            <span>{row.label}</span>
            <span class="memory-value">{row.value ?? "--"}</span>
          </div>
        {/each}
      </UiInsetList>
      <UiInsetList>
        <UiListRow title={t("diagnostics.trimTitle")} description={t("diagnostics.trimDescription")}>
          {#snippet action()}
            <UiButton onclick={() => settingsActions.forceLifecycleTrim()}>{t("diagnostics.trimMemory")}</UiButton>
          {/snippet}
        </UiListRow>
        <UiListRow title={t("processManager.title")} description={t("diagnostics.processManagerDescription")}>
          {#snippet action()}
            <UiButton onclick={openProcessManager}>{t("common.open")}</UiButton>
          {/snippet}
        </UiListRow>
      </UiInsetList>
    {:else}
      <div class="log-toolbar">
        <div class="log-search">
          <UiSearchField
            placeholder={t("diagnostics.searchPlaceholder")}
            ariaLabel={t("diagnostics.searchPlaceholder")}
            value={logQuery}
            onchange={(value) => (logQuery = value)}
          />
        </div>
        <UiSegmented
          value={logFilter}
          options={filterOptions}
          ariaLabel={t("diagnostics.filterAriaLabel")}
          onchange={(value) => (logFilter = value as LogFilter)}
        />
        <UiButton onclick={() => settingsActions.copyExtensionDiagnostics()}>{t("common.copy")}</UiButton>
        <UiButton onclick={() => settingsActions.clearExtensionDiagnostics()}>{t("common.clear")}</UiButton>
      </div>

      {#if log.length === 0}
        <p class="empty-text">{t("diagnostics.emptyLog")}</p>
      {:else if filteredLog.length === 0}
        <p class="empty-text">{t("diagnostics.noMatches")}</p>
      {:else}
        <UiInsetList>
          {#each filteredLog.slice(0, MAX_LOG_ROWS) as entry (entry.id)}
            <div class="log-entry level-{entry.level}">
              <span class="level-dot" role="img" aria-label={t(`diagnostics.level.${entry.level}`)}></span>
              <div class="log-copy">
                <div class="log-head">
                  <span class="log-title">{entry.title}</span>
                  {#if entry.durationMs != null}<span class="muted">{formatMilliseconds(entry.durationMs)}</span>{/if}
                  <span class="muted">{timeFormat.format(entry.timestamp * 1000)}</span>
                </div>
                <p class="log-message">{entry.message}</p>
                {#if entry.detail}<p class="log-detail">{entry.detail}</p>{/if}
              </div>
            </div>
          {/each}
        </UiInsetList>
        {#if filteredLog.length > MAX_LOG_ROWS}
          <p class="hint">{t("diagnostics.truncated", { count: MAX_LOG_ROWS })}</p>
        {/if}
      {/if}
    {/if}
  </div>
</UiShellFrame>

<style>
  .diagnostics {
    display: grid;
    gap: 22px;
  }

  .boot {
    display: flex;
    align-items: baseline;
    gap: var(--space-8);
    margin: 0;
  }

  .boot-total {
    font-size: var(--font-size-2xl);
    font-weight: var(--font-weight-semibold);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }

  .boot-label,
  .muted {
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }

  .hint {
    margin: var(--space-8) 0 0;
    padding-inline: 14px;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }

  .empty-text {
    margin: 0;
    color: var(--text-muted);
    font-size: var(--font-size-md);
  }

  .waterfall-row {
    display: grid;
    grid-template-columns: minmax(0, 0.7fr) minmax(0, 1fr) 72px;
    align-items: center;
    gap: var(--space-24);
    padding: 11px 14px;
    font-size: var(--font-size-md);
  }

  .waterfall-name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-weight: var(--font-weight-medium);
  }

  .waterfall-track {
    position: relative;
    height: 8px;
    border-radius: var(--radius-chip);
    background: var(--text-primary-tint-10);
  }

  .waterfall-bar {
    position: absolute;
    top: 0;
    height: 100%;
    border-radius: inherit;
    background: color-mix(in srgb, var(--accent) 40%, var(--bg-primary));
  }

  .slowest .waterfall-bar {
    background: var(--accent);
  }

  .waterfall-value {
    color: var(--text-muted);
    font-variant-numeric: tabular-nums;
    text-align: right;
    white-space: nowrap;
  }

  .slowest .waterfall-value {
    color: var(--text-primary);
    font-weight: var(--font-weight-semibold);
  }

  .memory-row {
    display: flex;
    justify-content: space-between;
    gap: var(--space-8);
    padding: 11px 14px;
    font-size: var(--font-size-md);
  }

  /* A detail of the row above: indented as a nested row. */
  .memory-row.indent {
    padding-left: 38px;
    color: var(--text-secondary);
  }

  .memory-value {
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
  }

  .log-toolbar {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-8);
  }

  .log-search {
    flex: 1 1 200px;
    min-width: 0;
  }

  .log-entry {
    display: grid;
    grid-template-columns: 8px minmax(0, 1fr);
    gap: var(--space-12);
    padding: 11px 14px;
  }

  .level-dot {
    width: 8px;
    height: 8px;
    margin-top: 5px;
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
    gap: var(--space-8);
  }

  .log-title {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .log-message,
  .log-detail {
    margin: 0;
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: var(--font-size-sm);
    line-height: 1.4;
    overflow-wrap: anywhere;
  }

  .log-message {
    color: var(--text-secondary);
  }

  .level-error .log-message {
    color: var(--danger-text);
  }

  .log-detail {
    color: var(--text-muted);
  }
</style>
