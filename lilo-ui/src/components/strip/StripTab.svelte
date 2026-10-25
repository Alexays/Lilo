<script lang="ts">
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import { tabActions } from "../../lib/bridge/actions";
  import { optimisticallyActivateTab } from "../../stores/sidebar.svelte";
  import { hoverTabPreview, leaveTabPreview } from "../../stores/tabPreview.svelte";
  import { tabDisplayTitle, type TabState } from "../../stores/tabs.svelte";
  import { t } from "../../lib/i18n/state.svelte";

  let { tab, active = false, iconOnly = false }: { tab: TabState; active?: boolean; iconOnly?: boolean } = $props();

  const title = $derived(tabDisplayTitle(tab.title) || tab.url || t("tabItem.newTab"));

  function activate() {
    optimisticallyActivateTab(tab.id);
    tabActions.switchTo(tab.id);
  }

  function showMenu(event: MouseEvent) {
    event.preventDefault();
    const rect = (event.currentTarget as HTMLElement).getBoundingClientRect();
    tabActions.showContextMenu(tab.id, rect.x, rect.y, rect.width, rect.height);
  }
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="strip-tab"
  class:active
  class:icon-only={iconOnly}
  data-tab-id={tab.id}
  onmouseenter={(e) => hoverTabPreview({ id: tab.id, title, url: tab.url ?? "", favicon: tab.faviconDataURL }, e.currentTarget.getBoundingClientRect())}
  onmouseleave={leaveTabPreview}
  oncontextmenu={showMenu}
  onauxclick={(e) => e.button === 1 && tabActions.close(tab.id)}
>
  <button class="strip-tab-main" aria-label={title} aria-current={active ? "page" : undefined} onclick={activate}>
    <SiteFavicon src={tab.faviconDataURL} title={tab.title} url={tab.url} size={16} radius={4} />
    {#if !iconOnly}
      <span class="strip-tab-title">{title}</span>
    {/if}
  </button>
  {#if !iconOnly}
    <button class="strip-tab-close" aria-label={t("tabItem.closeTab")} onclick={() => tabActions.close(tab.id)}>
      <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
        <path d="M2 2l6 6M8 2l-6 6" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
      </svg>
    </button>
  {/if}
</div>

<style>
  .strip-tab {
    position: relative;
    flex: 0 1 170px;
    min-width: 32px;
    height: 30px;
    display: flex;
    align-items: center;
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    transition: background-color var(--motion-duration-fast) ease;
  }

  .strip-tab:hover {
    background: var(--bg-hover);
  }

  .strip-tab.active {
    flex: 0 0 220px;
    background: var(--bg-selected);
    color: var(--text-primary);
    box-shadow: var(--shadow-control);
  }

  .strip-tab.icon-only {
    flex: 0 0 32px;
  }

  .strip-tab-main {
    flex: 1;
    min-width: 0;
    height: 100%;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0 8px;
    border: 0;
    background: transparent;
    color: inherit;
    font: inherit;
    font-size: var(--font-size-sm);
    cursor: default;
  }

  .icon-only .strip-tab-main {
    justify-content: center;
    padding: 0;
  }

  .strip-tab-title {
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .strip-tab-close {
    flex: none;
    width: 20px;
    height: 20px;
    margin-right: 5px;
    border: 0;
    border-radius: var(--radius-xs);
    display: grid;
    place-items: center;
    background: transparent;
    color: var(--text-secondary);
    display: none;
  }

  /* Out of the way until wanted: a narrow pill keeps its room for the title. */
  .strip-tab:hover .strip-tab-close,
  .strip-tab.active .strip-tab-close,
  .strip-tab:focus-within .strip-tab-close {
    display: grid;
  }

  .strip-tab-close:hover {
    background: var(--bg-hover);
  }
</style>
