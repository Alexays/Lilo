<script lang="ts">
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import { tabActions } from "../../lib/bridge/actions";
  import { optimisticallyActivateTab } from "../../stores/sidebar.svelte";
  import { hoverTabPreview, leaveTabPreview } from "../../stores/tabPreview.svelte";
  import { tabDisplayTitle, type TabState } from "../../stores/tabs.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { openCommandBar } from "../../stores/commandBar.svelte";
  import { closeSettingsShell } from "../../stores/panels.svelte";

  // `editsAddress`: the strip has no address bar, so a click on the active pill edits its address.
  let { tab, active = false, iconOnly = false, editsAddress = false }: { tab: TabState; active?: boolean; iconOnly?: boolean; editsAddress?: boolean } = $props();

  const title = $derived(tabDisplayTitle(tab.title) || tab.url || t("tabItem.newTab"));
  // With no address bar on screen, the active pill always says which site this is, and whether it is secure.
  const site = $derived.by(() => {
    if (!active || !editsAddress || !tab.url) return null;
    try {
      const url = new URL(tab.url);
      if (url.protocol !== "https:" && url.protocol !== "http:") return null;
      return { host: url.hostname.replace(/^www\./, ""), secure: url.protocol === "https:" };
    } catch {
      return null;
    }
  });
  function activate() {
    closeSettingsShell();
    if (active && editsAddress) {
      openCommandBar(tab.url ?? "", false, true);
      return;
    }
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
  <!-- One tab stop for the whole strip: the active pill holds it, the arrow keys move along. -->
  <button
    class="strip-tab-main"
    role="tab"
    aria-selected={active}
    aria-label={site ? `${site.host}, ${title}` : title}
    tabindex={active ? 0 : -1}
    data-roving
    onclick={activate}
  >
    <span class="strip-tab-icon">
      {#if tab.kind === "terminal"}
        <!-- The sidebar's tile: a terminal reads apart from pages at a glance. -->
        <span class="terminal-tile" class:asleep={!tab.terminalState} aria-hidden="true">
          <svg width="11" height="11" viewBox="0 0 16 16" fill="none"><path d="m3.5 4.5 3.5 3.5-3.5 3.5" /><path d="M8.5 11.5h4" /></svg>
        </span>
      {:else if tab.kind === "changes"}
        <span class="changes-tile" aria-hidden="true">
          <svg width="11" height="11" viewBox="0 0 16 16" fill="none"><path d="M5 2.5v6M2 5.5h6" /><path d="M8.5 12h5" /></svg>
        </span>
      {:else}
        <SiteFavicon src={tab.faviconDataURL} title={tab.title} url={tab.url} size={16} radius={4} />
      {/if}
      {#if tab.isCameraActive || tab.isMicrophoneActive || tab.isScreenSharing}
        <!-- The sidebar row's capture pip: red while the tab can hear or see you. -->
        <span
          class="capture-pip"
          class:live={tab.isCameraActive || tab.isScreenSharing || (tab.isMicrophoneActive && !tab.isMicrophoneMuted)}
          aria-hidden="true"
        ></span>
      {/if}
    </span>
    {#if site}
      <span class="strip-tab-site">
        {#if site.secure}
          <svg width="9" height="11" viewBox="0 0 11 12" aria-hidden="true"><rect x="1" y="5" width="9" height="6.5" rx="1.5" fill="currentColor" /><path d="M3 5V3.5a2.5 2.5 0 0 1 5 0V5" fill="none" stroke="currentColor" stroke-width="1.3" /></svg>
        {/if}
        {site.host}
      </span>
    {/if}
    {#if !iconOnly}
      <span class="strip-tab-title" class:secondary={!!site}>{title}</span>
    {/if}
  </button>
  {#if !iconOnly}
    <button class="strip-tab-close" tabindex="-1" aria-label={t("tabItem.closeTab")} onclick={() => tabActions.close(tab.id)}>
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
    height: 32px;
    display: flex;
    align-items: center;
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    transition: background-color var(--motion-duration-fast) ease;
  }

  /* Only a pill with a title queries its own width; an icon pill keeps its intrinsic width, which the strip's groups size on. */
  .strip-tab:not(.icon-only) {
    container-type: inline-size;
  }

  .strip-tab:hover {
    background: var(--bg-hover);
  }

  .strip-tab.active {
    flex: 0 0 260px;
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

  .strip-tab-icon {
    position: relative;
    flex: none;
    display: grid;
  }

  .capture-pip {
    position: absolute;
    right: -3px;
    bottom: -3px;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--text-muted);
    box-shadow: 0 0 0 1.5px var(--sidebar-bg);
  }

  .capture-pip.live {
    background: var(--danger-vivid);
  }

  /* The sidebar's tiles, in a 16px favicon's box. */
  .terminal-tile,
  .changes-tile {
    flex: none;
    width: 16px;
    height: 16px;
    border-radius: var(--radius-xs);
    display: grid;
    place-items: center;
    box-sizing: border-box;
  }

  .terminal-tile {
    background: var(--terminal-tile-bg);
    box-shadow: inset 0 0 0 1px var(--terminal-tile-border);
    stroke: var(--terminal-tile-accent);
  }

  .terminal-tile.asleep {
    opacity: 0.55;
  }

  .changes-tile {
    border: 1.5px solid var(--accent);
    stroke: var(--accent);
  }

  .terminal-tile path,
  .changes-tile path {
    stroke-width: 1.8;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  .strip-tab-site {
    flex: none;
    display: flex;
    align-items: center;
    gap: 4px;
    font-weight: var(--font-weight-semibold);
    white-space: nowrap;
  }

  .strip-tab-title.secondary {
    color: var(--text-secondary);
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

  /* Out of the way until wanted, and never in a pill too narrow for it: it would spill over its neighbor. */
  @container (min-width: 72px) {
    .strip-tab:hover .strip-tab-close,
    .strip-tab.active .strip-tab-close,
    .strip-tab:focus-within .strip-tab-close {
      display: grid;
    }
  }

  /* Squeezed to its icon, a pill shows just the icon, centered. */
  @container (max-width: 47px) {
    .strip-tab-title,
    .strip-tab-site {
      display: none;
    }

    .strip-tab-main {
      justify-content: center;
      padding: 0;
    }
  }

  .strip-tab-close:hover {
    background: var(--bg-hover);
  }
</style>
