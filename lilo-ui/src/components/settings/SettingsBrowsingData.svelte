<script lang="ts">
  import { onMount } from "svelte";
  import { settingsActions } from "../../lib/bridge/actions";
  import type { BridgeBrowsingDataKind } from "../../lib/bridge/protocol";
  import { formatByteSize } from "../../lib/format";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { getBrowsingDataSizes, getWebsiteData } from "../../stores/settings.svelte";
  import SettingsGroupIcon from "./SettingsGroupIcon.svelte";
  import { BROWSING_DATA_KINDS } from "./settingsPanelModel";
  import UiButton from "../ui/UiButton.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiSelect from "../ui/UiSelect.svelte";

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

  // The sizes measured after a clear are its answer.
  $effect(() => {
    void sizes;
    clearing = false;
  });

  function toggle(kind: BridgeBrowsingDataKind, checked: boolean): void {
    selected = checked ? [...selected, kind] : selected.filter((candidate) => candidate !== kind);
  }

  function clear(): void {
    clearing = true;
    settingsActions.clearBrowsingData(cleared, range);
  }
</script>

<div class="browsing-data-summary">
  <p class="browsing-data-total">
    {#if sizes}
      <span class="browsing-data-total-value">{formatByteSize(total, getLocale())}</span>
      {t("settings.clearData.total")}
    {:else}
      {t("settings.clearData.measuring")}
    {/if}
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
</div>

<UiInsetList title={t("settings.groups.browsingData")}>
  {#snippet icon()}<SettingsGroupIcon group="settings.groups.browsingData" />{/snippet}
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
      <UiSelect
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

<div class="browsing-data-footer">
  <!-- WebKit sizes a site's data as a whole, not by when it was written: only an all-time clear has a known size. -->
  <span>
    {#if range !== "all"}
      {t("settings.clearData.rangeNote")}
    {:else if sizes && freed > 0}
      {t("settings.clearData.freed", { size: formatByteSize(freed, getLocale()) })}
    {/if}
  </span>
  <UiButton variant="danger" busy={clearing} disabled={selected.length === 0} onclick={clear}>{t("common.clear")}</UiButton>
</div>

<style>
  .browsing-data-summary {
    display: grid;
    gap: var(--space-10);
    margin-bottom: var(--space-24);
  }

  .browsing-data-total {
    display: flex;
    align-items: baseline;
    gap: var(--space-8);
    margin: 0;
    color: var(--text-secondary);
    font-size: var(--font-size-md);
  }

  .browsing-data-total-value {
    color: var(--text-primary);
    font-size: var(--font-size-2xl);
    font-weight: var(--font-weight-semibold);
    font-variant-numeric: tabular-nums;
  }

  .browsing-data-bar {
    display: flex;
    gap: 2px;
    height: 8px;
    border-radius: var(--radius-xs);
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
    font-size: var(--font-size-md);
    font-variant-numeric: tabular-nums;
    text-align: right;
  }

  .browsing-data-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-12);
    margin-top: var(--space-16);
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }
</style>
