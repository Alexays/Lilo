<script lang="ts">
  import { tick } from "svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import SectionNavPanel from "../ui/SectionNavPanel.svelte";
  import UiSearchField from "../ui/UiSearchField.svelte";
  import { closePageShell, isDownloadsVisible } from "../../stores/panels.svelte";
  import {
    getDownloadsQuery,
    getPageDownloads,
    setDownloadsQuery,
  } from "../../stores/downloadsPage.svelte";

  let { compact = false }: { compact?: boolean } = $props();
  let searchEl: HTMLDivElement | undefined = $state();

  $effect(() => {
    if (!isDownloadsVisible() || compact) return;
    void tick().then(() => searchEl?.querySelector("input")?.focus({ preventScroll: true }));
  });

  const groups = $derived([
    {
      id: "views",
      sections: [{ id: "all", label: t("downloadsPanel.allDownloads"), icon: "tray" as const, count: getPageDownloads().length }],
    },
  ]);

</script>

<SectionNavPanel
  title={t("downloadsPanel.title")}
  ariaLabel={t("downloadsPanel.navLabel")}
  {groups}
  activeId={getDownloadsQuery().trim() ? null : "all"}
  onSelect={() => setDownloadsQuery("")}
  onclose={closePageShell}
  {compact}
>
  {#snippet toolbar()}
    <div class="downloads-search" bind:this={searchEl}>
      <UiSearchField
        value={getDownloadsQuery()}
        placeholder={t("downloadsPanel.searchPlaceholder")}
        ariaLabel={t("downloadsPanel.searchPlaceholder")}
        onchange={setDownloadsQuery}
      />
    </div>
  {/snippet}
</SectionNavPanel>

<style>
  .downloads-search {
    display: contents;
  }
</style>
