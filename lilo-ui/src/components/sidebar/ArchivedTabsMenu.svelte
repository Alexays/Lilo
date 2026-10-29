<!-- The tabs the idle sweep or Clear archived in the last day, one click from coming back; the command bar keeps the rest. -->
<script lang="ts">
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { tabActions } from "../../lib/bridge/actions";
  import type { BridgeArchivedTab } from "../../lib/bridge/protocol";
  import { openCommandBar } from "../../stores/commandBar.svelte";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import StripPopover from "../strip/StripPopover.svelte";

  let { anchor, tabs, onclose }: { anchor: HTMLElement; tabs: BridgeArchivedTab[]; onclose: () => void } = $props();

  const now = Date.now();
  const format = new Intl.RelativeTimeFormat(getLocale(), { numeric: "auto", style: "narrow" });

  function age(archivedAt: number): string {
    const minutes = Math.round((archivedAt - now) / 60_000);
    return Math.abs(minutes) < 60 ? format.format(minutes, "minute") : format.format(Math.round(minutes / 60), "hour");
  }

  function restore(tab: BridgeArchivedTab): void {
    tabActions.restoreArchived([tab.id]);
    onclose();
  }

  function showAll(): void {
    onclose();
    openCommandBar("<");
  }
</script>

<StripPopover {anchor} {onclose} label={t("archivedTabs.title")}>
  <div class="menu-title">{t("archivedTabs.title")}</div>
  {#each tabs as tab (tab.id)}
    <button class="menu-row" role="menuitem" onclick={() => restore(tab)}>
      <SiteFavicon title={tab.title} url={tab.url} size={16} radius={4} />
      <span class="row-title">{tab.title || tab.url}</span>
      <span class="row-age">{age(tab.archivedAt)}</span>
      <span class="row-restore">{t("archivedTabs.restore")}</span>
    </button>
  {/each}
  <div class="menu-separator" role="separator"></div>
  <button class="menu-row show-all" role="menuitem" onclick={showAll}>{t("archivedTabs.showAll")}</button>
</StripPopover>

<style>
  .menu-title {
    padding: 4px 8px 2px;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }

  .menu-row {
    width: 100%;
    height: 32px;
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 0 8px;
    border: 0;
    border-radius: calc(var(--float-radius-popover) - 6px);
    background: transparent;
    color: var(--text-primary);
    font: inherit;
    font-size: var(--font-size-sm);
    text-align: left;
  }

  .menu-row:hover,
  .menu-row:focus-visible {
    background: var(--bg-hover);
  }

  .row-title {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .row-age,
  .row-restore {
    flex-shrink: 0;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }

  .row-restore,
  .menu-row:hover .row-age,
  .menu-row:focus-visible .row-age {
    display: none;
  }

  .menu-row:hover .row-restore,
  .menu-row:focus-visible .row-restore {
    display: inline;
  }

  .menu-separator {
    height: 1px;
    margin: 4px 6px;
    background: var(--separator);
  }

  .show-all {
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
  }
</style>
