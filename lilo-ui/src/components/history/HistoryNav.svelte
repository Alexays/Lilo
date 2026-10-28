<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import type { BridgeHistoryPeriod } from "../../lib/bridge/protocol";
  import { tick } from "svelte";
  import SectionNavPanel from "../ui/SectionNavPanel.svelte";
  import UiSearchField from "../ui/UiSearchField.svelte";
  import {
    closeHistory,
    getHistoryFilter,
    getHistorySidebar,
    setHistoryQuery,
    showHistoryPeriod,
    showHistorySite,
    showHistoryTerminal,
  } from "../../stores/history.svelte";
  import { isHistoryShellOpen, openSettings, openSettingsSubpage } from "../../stores/panels.svelte";

  let { compact = false }: { compact?: boolean } = $props();
  let searchEl: HTMLDivElement | undefined = $state();

  // Cmd+Y then typing searches: the field takes the focus each time the page opens.
  $effect(() => {
    if (!isHistoryShellOpen() || compact) return;
    void tick().then(() => searchEl?.querySelector("input")?.focus({ preventScroll: true }));
  });

  const filter = $derived(getHistoryFilter());
  const sidebar = $derived(getHistorySidebar());
  const activeId = $derived(
    filter.host !== undefined
      ? `site:${filter.host}`
      : filter.openedFrom !== undefined
        ? `terminal:${filter.openedFrom}`
        : filter.period,
  );

  const groups = $derived([
    {
      id: "periods",
      sections: [
        { id: "all", label: t("historyPage.periodAll"), icon: "clock" as const },
        { id: "today", label: t("historyPage.periodToday"), icon: "page" as const, count: sidebar?.today },
        { id: "yesterday", label: t("historyPage.periodYesterday"), icon: "halfCircle" as const, count: sidebar?.yesterday },
        { id: "last7Days", label: t("historyPage.periodLast7Days"), icon: "grid" as const, count: sidebar?.last7Days },
        { id: "older", label: t("historyPage.periodOlder"), icon: "stack" as const },
      ],
    },
    ...(sidebar?.sites.length
      ? [{
          id: "sites",
          label: t("historyPage.sectionSites"),
          sections: sidebar.sites.map((site) => ({ id: `site:${site.host}`, label: site.host, icon: "globe" as const })),
        }]
      : []),
    ...(sidebar?.terminals.length
      ? [{
          id: "terminals",
          label: t("historyPage.sectionTerminals"),
          sections: sidebar.terminals.map((terminal) => ({
            id: `terminal:${terminal.openedFrom}`,
            label: terminal.openedFrom,
            icon: "terminal" as const,
          })),
        }]
      : []),
    {
      id: "manage",
      sections: [{ id: "clearBrowsingData", label: t("historyPage.clearBrowsingData"), icon: "privacy" as const }],
    },
  ]);

  function select(id: string): void {
    if (id === "clearBrowsingData") {
      openSettings("privacy");
      openSettingsSubpage("privacy", "browsingData");
    } else if (id.startsWith("site:")) showHistorySite(id.slice("site:".length));
    else if (id.startsWith("terminal:")) showHistoryTerminal(id.slice("terminal:".length));
    else showHistoryPeriod(id as BridgeHistoryPeriod);
  }
</script>

<SectionNavPanel
  title={t("historyPage.title")}
  ariaLabel={t("historyPage.navLabel")}
  {groups}
  {activeId}
  onSelect={select}
  onclose={closeHistory}
  {compact}
>
  {#snippet toolbar()}
    <div class="history-search" bind:this={searchEl}>
      <UiSearchField
        value={filter.query}
        placeholder={t("historyPage.searchPlaceholder")}
        ariaLabel={t("historyPage.searchPlaceholder")}
        onchange={setHistoryQuery}
      />
    </div>
  {/snippet}
</SectionNavPanel>

<style>
  .history-search {
    display: contents;
  }
</style>
