<script lang="ts">
  import { settingsActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { isClearDataSheetOpen, setClearDataSheetOpen } from "../../stores/settings.svelte";
  import BottomConfirmSheet from "../ui/BottomConfirmSheet.svelte";
  import { BROWSING_DATA_KINDS, type BrowsingDataKind } from "./settingsPanelModel";
  import UiSelect from "../ui/UiSelect.svelte";

  const CLEAR: Record<BrowsingDataKind, (range: string) => void> = {
    history: settingsActions.clearHistory,
    cookies: settingsActions.clearCookies,
    cache: settingsActions.clearCache,
    siteData: settingsActions.clearSiteData,
  };

  let selected = $state<BrowsingDataKind[]>(["history", "cache"]);
  let range = $state("all");

  function toggleKind(kind: BrowsingDataKind, checked: boolean): void {
    selected = checked ? [...selected, kind] : selected.filter((candidate) => candidate !== kind);
  }

  function confirm(): void {
    for (const kind of selected) CLEAR[kind](range);
    setClearDataSheetOpen(false);
  }
</script>

<BottomConfirmSheet
  visible={isClearDataSheetOpen()}
  title={t("settings.clearData.title")}
  confirmLabel={t("common.clear")}
  confirmDisabled={selected.length === 0}
  confirmAction={confirm}
  cancelAction={() => setClearDataSheetOpen(false)}
>
  <div class="clear-data-choices">
    {#each BROWSING_DATA_KINDS as kind (kind)}
      <label class="clear-data-choice">
        <input
          type="checkbox"
          checked={selected.includes(kind)}
          onchange={(event) => toggleKind(kind, event.currentTarget.checked)}
        />
        {t(`settings.clearData.kinds.${kind}`)}
      </label>
    {/each}
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
  </div>
</BottomConfirmSheet>

<style>
  .clear-data-choices {
    display: grid;
    gap: 8px;
    margin-top: 12px;
  }

  .clear-data-choice {
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--text-primary);
    font-size: var(--font-size-md);
    cursor: pointer;
  }

  .clear-data-choice input {
    accent-color: var(--accent);
  }
</style>
