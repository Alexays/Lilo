<!-- Clear Browsing Data, a modal over whatever the page area shows. -->
<script lang="ts">
  import { onMount, untrack } from "svelte";
  import { settingsActions } from "../../lib/bridge/actions";
  import type { BridgeBrowsingDataKind } from "../../lib/bridge/protocol";
  import { formatByteSize } from "../../lib/format";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { getBrowsingDataSizes, getWebsiteData } from "../../stores/settings.svelte";
  import { BROWSING_DATA_KINDS } from "./settingsPanelModel";
  import UiButton from "../ui/UiButton.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import { closeClearBrowsingData, openHistoryPage } from "../../stores/panels.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiModal from "../ui/UiModal.svelte";
  import UiSegmented from "../ui/UiSegmented.svelte";

  const TINTS: Record<BridgeBrowsingDataKind, string> = { history: "teal", cookies: "orange", cache: "blue", siteData: "purple" };

  let selected = $state<BridgeBrowsingDataKind[]>(["history", "cache"]);
  let range = $state("all");
  let clearing = $state(false);

  const sizes = $derived(getBrowsingDataSizes());
  const sites = $derived(getWebsiteData());
  // Clearing site data takes the cookies and the cache with it.
  const cleared = $derived(selected.includes("siteData") ? [...new Set<BridgeBrowsingDataKind>([...selected, "cookies", "cache"])] : selected);
  const bytes = $derived<Record<BridgeBrowsingDataKind, number | undefined>>({
    history: sizes?.history,
    cookies: sizes?.cookies,
    cache: sizes?.cache,
    siteData: sizes?.storage,
  });
  const total = $derived(BROWSING_DATA_KINDS.reduce((sum, kind) => sum + (bytes[kind] ?? 0), 0));
  const freed = $derived(cleared.reduce((sum, kind) => sum + (bytes[kind] ?? 0), 0));
  const hints = $derived<Record<BridgeBrowsingDataKind, string>>({
    history: sizes?.historyEntries === undefined ? "" : t("settings.clearData.hints.history", { count: sizes.historyEntries.toLocaleString(getLocale()) }),
    cookies: t("settings.clearData.hints.cookies", { count: sites.filter((site) => site.kinds.includes("cookies")).length }),
    cache: t("settings.clearData.hints.cache"),
    siteData: t("settings.clearData.hints.siteData", { count: sites.length }),
  });

  onMount(() => settingsActions.loadBrowsingDataSizes());

  // The sizes measured after a clear are its answer: the job is done.
  $effect(() => {
    void sizes;
    if (untrack(() => clearing)) closeClearBrowsingData();
  });

  function toggle(kind: BridgeBrowsingDataKind, checked: boolean): void {
    selected = checked ? [...selected, kind] : selected.filter((candidate) => candidate !== kind);
  }

  function clear(): void {
    if (selected.length === 0 || clearing) return;
    clearing = true;
    settingsActions.clearBrowsingData(cleared, range);
  }
</script>

<UiModal zone="clear-browsing-data" width={560} title={t("settings.clearData.title")} oncancel={closeClearBrowsingData} ondefault={clear}>
  <!-- WebKit measures in the background: the summary keeps its room meanwhile, so nothing jumps. -->
  <div class="browsing-data-summary">
    {#if sizes}
      <p class="browsing-data-total">
        <span class="browsing-data-total-value">{formatByteSize(total, getLocale())}</span>
        {t("settings.clearData.total")}
      </p>
      {#if total > 0}
        <div class="browsing-data-bar" aria-hidden="true">
          {#each BROWSING_DATA_KINDS as kind (kind)}
            {#if bytes[kind]}
              <span style:flex={bytes[kind]} style:background="var(--tile-{TINTS[kind]})" class:dimmed={!cleared.includes(kind)}></span>
            {/if}
          {/each}
        </div>
      {/if}
    {/if}
  </div>

  <UiInsetList>
    {#each BROWSING_DATA_KINDS as kind (kind)}
      {@const implied = kind !== "siteData" && kind !== "history" && selected.includes("siteData")}
      <label class="browsing-data-kind" class:implied>
        <UiListRow title={t(`settings.clearData.kinds.${kind}`)} description={hints[kind]}>
          {#snippet icon()}
            <input
              type="checkbox"
              checked={cleared.includes(kind)}
              disabled={implied}
              onchange={(event) => toggle(kind, event.currentTarget.checked)}
            />
          {/snippet}
          {#snippet action()}
            <span class="browsing-data-dot" style:background="var(--tile-{TINTS[kind]})"></span>
            <span class="browsing-data-size">{bytes[kind] === undefined ? "" : formatByteSize(bytes[kind], getLocale())}</span>
          {/snippet}
        </UiListRow>
      </label>
    {/each}
    <UiListRow title={t("settings.historyTimeRange")}>
      {#snippet action()}
        <UiSegmented
          value={range}
          options={[
            { value: "hour", label: t("settings.historyRangeHour") },
            { value: "day", label: t("settings.historyRangeDay") },
            { value: "week", label: t("settings.historyRangeWeek") },
            { value: "all", label: t("settings.historyRangeAll") },
          ]}
          ariaLabel={t("settings.historyTimeRange")}
          onchange={(value) => (range = value)}
        />
      {/snippet}
    </UiListRow>
  </UiInsetList>

  <!-- WebKit sizes a site's data as a whole, not by when it was written: only an all-time clear has a known size. -->
  <p class="browsing-data-note">
    {#if range !== "all"}
      {t("settings.clearData.rangeNote")}
    {:else if sizes && freed > 0}
      {t("settings.clearData.freed", { size: formatByteSize(freed, getLocale()) })}
    {/if}
  </p>

  {#snippet leading()}
    <UiButton onclick={() => { closeClearBrowsingData(); openHistoryPage(); }}>{t("settings.manageHistory")}</UiButton>
  {/snippet}
  {#snippet actions()}
    <UiButton onclick={closeClearBrowsingData}>{t("common.cancel")}</UiButton>
    <UiButton variant="destructive" busy={clearing} disabled={selected.length === 0} onclick={clear}>{t("common.clear")}</UiButton>
  {/snippet}
</UiModal>

<style>
  .browsing-data-summary {
    display: grid;
    align-content: start;
    gap: var(--space-12);
    min-height: 40px;
    margin-bottom: var(--space-16);
  }

  .browsing-data-total {
    margin: 0;
    color: var(--text-secondary);
  }

  .browsing-data-total-value {
    color: var(--text-primary);
    font-weight: var(--font-weight-medium);
    font-variant-numeric: tabular-nums;
  }

  .browsing-data-bar {
    display: flex;
    gap: 2px;
    height: 6px;
    border-radius: var(--radius-chip);
    overflow: hidden;
  }

  .browsing-data-bar .dimmed {
    opacity: 0.25;
  }

  .browsing-data-kind {
    display: block;
    cursor: pointer;
  }

  .browsing-data-kind.implied {
    cursor: default;
  }

  .browsing-data-kind input {
    margin: 0;
    accent-color: var(--accent);
  }

  .browsing-data-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
  }

  .browsing-data-size {
    min-width: 64px;
    color: var(--text-secondary);
    font-variant-numeric: tabular-nums;
    text-align: right;
  }

  .browsing-data-note {
    min-height: 1lh;
    margin: var(--space-12) 0 0;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }
</style>
