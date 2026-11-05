<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import SectionNavPanel from "../ui/SectionNavPanel.svelte";
  import UiSearchField from "../ui/UiSearchField.svelte";
  import {
    closePageShell,
    getProcessManagerSection,
    setProcessManagerSection,
    type ProcessManagerSectionId,
  } from "../../stores/panels.svelte";
  import { getProcessOverview, getProcessQuery, getSleepingTabs, setProcessQuery } from "../../stores/processManager.svelte";

  let { compact = false }: { compact?: boolean } = $props();

  const overview = $derived(getProcessOverview());
  const groups = $derived([
    {
      id: "sections",
      sections: [
        { id: "tabs" as const, label: t("processManager.groupTabs"), icon: "tabs" as const, count: overview.tabs.length },
        { id: "sleeping" as const, label: t("processManager.groupSleeping"), icon: "moon" as const, count: getSleepingTabs().length },
        { id: "system" as const, label: t("processManager.groupSystem"), icon: "chip" as const, count: overview.system.length },
      ],
    },
  ]);
</script>

<SectionNavPanel
  title={t("processManager.title")}
  ariaLabel={t("processManager.navLabel")}
  {groups}
  activeId={getProcessManagerSection()}
  onSelect={(id: ProcessManagerSectionId) => setProcessManagerSection(id)}
  onclose={closePageShell}
  {compact}
>
  {#snippet toolbar()}
    <UiSearchField
      value={getProcessQuery()}
      placeholder={t("processManager.searchPlaceholder")}
      ariaLabel={t("processManager.searchPlaceholder")}
      onchange={setProcessQuery}
    />
  {/snippet}
</SectionNavPanel>
