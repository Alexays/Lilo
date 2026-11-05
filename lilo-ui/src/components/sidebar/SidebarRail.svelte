<script lang="ts">
  import { fly } from "svelte/transition";
  import NavControls from "./NavControls.svelte";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import StripPopover from "../strip/StripPopover.svelte";
  import { chromeActions, tabActions } from "../../lib/bridge/actions";
  import { tooltip } from "../../lib/tooltip";
  import { t } from "../../lib/i18n/state.svelte";
  import { getSpaceSidebar, optimisticallyActivateTab } from "../../stores/sidebar.svelte";
  import { getActiveSpaceId } from "../../stores/spaces.svelte";
  import { getActiveTab, getActiveTabId, tabDisplayTitle, type TabState } from "../../stores/tabs.svelte";
  import { getPagedSpaces, switchSpaceAnimated } from "../../stores/pager.svelte";
  import { getActingAgentTabIds } from "../../stores/agents.svelte";
  import { getConversationTab } from "../../stores/folders.svelte";
  import { openCommandBar } from "../../stores/commandBar.svelte";
  import { closePageShell } from "../../stores/panels.svelte";
  import { shortcutKeys } from "../../stores/shortcutKeys.svelte";
  import { getAddressPlacement, getTabPosition, hasPageToolbar, isAddressInRightTabs, tooltipSide } from "../../stores/tabLayout.svelte";
  import { areTrafficLightsVisible, setSidebarRail } from "../../stores/ui.svelte";
  import { getChosenAppIcon, getReadyUpdate } from "../../stores/settings.svelte";
  import { pressTabsHeader } from "../../stores/tabEdgeDrag.svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";

  // Floating: revealed from the window's edge over the page while the sidebar is hidden.
  let { floating, onenter, onleave, onresize }: {
    floating: boolean;
    onenter: () => void;
    onleave: () => void;
    onresize: (event: MouseEvent) => void;
  } = $props();

  const spaceId = $derived(getActiveSpaceId());
  const view = $derived(getSpaceSidebar(spaceId).view);
  const activeTabId = $derived(getActiveTabId(spaceId));
  const actingTabIds = $derived(getActingAgentTabIds());
  // A folder holding the active tab takes the selection: the tab itself is not on the rail.
  const activeRootId = $derived.by(() => {
    let id = activeTabId;
    for (let parent = view.treeIndex.parentFolderIdById.get(id); parent; parent = view.treeIndex.parentFolderIdById.get(id)) id = parent;
    return id;
  });
  const spaces = $derived(getPagedSpaces());
  const lights = $derived(getTabPosition() === "left" && areTrafficLightsVisible());
  // The sidebar header's height, so the lights keep their place as the sidebar unfolds from the rail.
  const lightsHeight = $derived(getAddressPlacement() === "tabs" || hasPageToolbar() ? 44 : 52);
  // Where the sidebar header holds the toggle: the page toolbar keeps it otherwise.
  const showsToggle = $derived(!(getTabPosition() === "left" && hasPageToolbar()) && !isAddressInRightTabs());
  let updateOpen = $state(false);
  let updateButton: HTMLButtonElement | undefined = $state();
  let openFolder: { id: string; anchor: HTMLElement } | null = $state(null);

  // Nested folders flatten into their tabs; a closed one stays listed, as in the sidebar, and reopens on click.
  function folderTabs(folderId: string): TabState[] {
    const tabs: TabState[] = [];
    for (const item of view.treeIndex.childrenByFolderId.get(folderId) ?? []) {
      if (item.kind === "folder") tabs.push(...folderTabs(item.itemId));
      else {
        const tab = view.tabsById.get(item.itemId);
        if (tab) tabs.push(tab);
      }
    }
    return tabs;
  }

  function tabTitle(tab: TabState): string {
    return tab.customTitle || tab.homeTitle || tabDisplayTitle(tab.title ?? "") || tab.url || t("tabItem.newTab");
  }

  function activate(tab: TabState): void {
    closePageShell();
    optimisticallyActivateTab(tab.id);
    tabActions.switchTo(tab.id);
  }

  function showMenu(event: MouseEvent, tab: TabState): void {
    event.preventDefault();
    const rect = (event.currentTarget as HTMLElement).getBoundingClientRect();
    tabActions.showContextMenu(tab.id, rect.x, rect.y, rect.width, rect.height);
  }

  // Every icon is a tab stop; the arrows walk the column as they do the sidebar's rows.
  function handleArrows(event: KeyboardEvent): void {
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
    const buttons = [...(event.currentTarget as HTMLElement).querySelectorAll<HTMLElement>("button:not(:disabled)")];
    const index = buttons.indexOf(document.activeElement as HTMLElement);
    if (index < 0) return;
    event.preventDefault();
    buttons[(index + (event.key === "ArrowDown" ? 1 : -1) + buttons.length) % buttons.length].focus();
  }
</script>

{#snippet tabIcon(tab: TabState)}
  {@const active = tab.id === activeTabId}
  {@const acting = actingTabIds.has(tab.id) || (tab.kind === "agent" && tab.terminalState === "busy")}
  {@const waiting = !!tab.awaitingInputSince && !active}
  {@const sound = tab.isMuted ? t("tabItem.muted") : tab.isAudioPlaying ? t("tabItem.playingAudio") : ""}
  {@const title = tabTitle(tab)}
  <button
    class="rail-item"
    class:active
    class:asleep={tab.isClosed}
    data-tab-id={tab.id}
    aria-current={active ? "page" : undefined}
    aria-label={[title, acting ? t("tabItem.agentActing") : "", waiting ? t("tabItem.terminalAttention") : "", sound].filter(Boolean).join(", ")}
    use:tooltip={{ text: title, placement: tooltipSide() }}
    onclick={() => activate(tab)}
    oncontextmenu={(e) => showMenu(e, tab)}
    onauxclick={(e) => e.button === 1 && tabActions.close(tab.id)}
  >
    <span class="icon" class:working={acting}>
      {#if tab.kind === "terminal"}
        <span class="terminal-tile" aria-hidden="true">
          <svg width="11" height="11" viewBox="0 0 16 16" fill="none"><path d="m3.5 4.5 3.5 3.5-3.5 3.5" /><path d="M8.5 11.5h4" /></svg>
        </span>
      {:else if tab.kind === "agent"}
        {#await import("../agents/MascotGlyph.svelte") then { default: MascotGlyph }}<MascotGlyph />{/await}
      {:else}
        <SiteFavicon src={tab.faviconDataURL} title={tab.title} url={tab.url} size={16} radius={4} asleep={tab.isClosed} />
      {/if}
      {#if waiting}
        <span class="attention" aria-hidden="true"></span>
      {:else if sound}
        <span class="sound" aria-hidden="true">
          <svg width="8" height="8" viewBox="0 0 12 12" fill="none">
            <path d="M2 4.5H3.5L6.5 2V10L3.5 7.5H2V4.5Z" fill="currentColor" />
            {#if tab.isMuted}
              <path d="M8 4.5L10.5 7M10.5 4.5L8 7" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
            {:else}
              <path d="M8.6 4C9.8 4.9 9.8 7.1 8.6 8" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
            {/if}
          </svg>
        </span>
      {/if}
    </span>
  </button>
{/snippet}

{#snippet rootItem(item: { kind: "tab" | "folder"; id: string })}
  {#if item.kind === "folder"}
    {@const folder = view.foldersById.get(item.id)}
    {@const conversation = folder ? getConversationTab(folder.id, spaceId) : undefined}
    <!-- An agent's conversation shows as its agent, as in the strip. -->
    {#if conversation}
      {@render tabIcon(conversation)}
    {:else if folder}
      <button
        class="rail-item"
        class:active={folder.id === activeRootId}
        aria-label={folder.name}
        aria-haspopup="menu"
        aria-expanded={openFolder?.id === folder.id}
        use:tooltip={{ text: folder.name, placement: tooltipSide() }}
        onclick={(e) => (openFolder = openFolder?.id === folder.id ? null : { id: folder.id, anchor: e.currentTarget })}
      >
        <svg width="16" height="16" viewBox="0 0 18 18" fill="none" style:--folder-color={folder.color} aria-hidden="true">
          <path class="folder" d="M2.65 6.05C2.65 5.38 3.16 4.88 3.83 4.88H6.7L7.98 6.08H14.16C14.82 6.08 15.32 6.59 15.32 7.25V12.42C15.32 13.09 14.82 13.6 14.16 13.6H3.83C3.16 13.6 2.65 13.09 2.65 12.42V6.05Z" />
        </svg>
      </button>
    {/if}
  {:else}
    {@const tab = view.tabsById.get(item.id)}
    {#if tab}{@render tabIcon(tab)}{/if}
  {/if}
{/snippet}

<div
  class="sidebar-rail tabs-surface"
  class:floating
  role="presentation"
  use:reportInteractiveZone={{ id: "sidebar-rail" }}
  onmouseenter={onenter}
  onmouseleave={onleave}
  transition:fly|global={{ x: getTabPosition() === "right" ? 84 : -84, opacity: 1, duration: floating && !prefersReducedMotion() ? 240 : 0 }}
>
<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<nav class="rail" aria-label={t("sidebar.ariaLabel")} onkeydown={handleArrows}>
  {#if lights}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="lights" style:height="{lightsHeight}px" onpointerdown={pressTabsHeader} ondblclick={() => chromeActions.maximizeWindow()}></div>
  {/if}
  <div class="tools" class:top={!lights}>
    {#if showsToggle}<NavControls show="toggle" />{/if}
    <!-- The command bar carries the address, the history and Agents: the rail needs none of them. -->
    <button
      class="rail-item"
      aria-label={t("common.search")}
      use:tooltip={{ text: t("common.search"), shortcut: shortcutKeys("location.open"), placement: tooltipSide() }}
      onclick={() => openCommandBar(getActiveTab()?.url ?? "", false, true)}
    >
      <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
        <circle cx="7" cy="7" r="4.5" /><path d="m10.5 10.5 3 3" />
      </svg>
    </button>
  </div>
  <span class="separator" aria-hidden="true"></span>

  <div class="items">
    {#each view.bookmarked as tab (tab.id)}
      {@render tabIcon(tab)}
    {/each}
    {#if view.bookmarked.length && view.rootItems.pinned.length + view.rootItems.unpinned.length}
      <span class="separator" aria-hidden="true"></span>
    {/if}
    {#each view.rootItems.pinned as item (item.id)}
      {@render rootItem(item)}
    {/each}
    {#if view.rootItems.pinned.length && view.rootItems.unpinned.length}
      <span class="separator" aria-hidden="true"></span>
    {/if}
    {#each view.rootItems.unpinned as item (item.id)}
      {@render rootItem(item)}
    {/each}
  </div>
  {#if openFolder}
    {@const folder = view.foldersById.get(openFolder.id)}
    {#if folder}
      <StripPopover anchor={openFolder.anchor} label={folder.name} onclose={() => (openFolder = null)}>
        {#if folder.isLocked}
          <!-- Unlocking takes the full sidebar: the rail unfolds to it. -->
          <button class="popover-row" onclick={() => setSidebarRail(false)}>{t("tabFolder.unlock")}</button>
        {:else}
          {#each folderTabs(folder.id) as tab (tab.id)}
            <button class="popover-row" class:active={tab.id === activeTabId} class:asleep={tab.isClosed} onclick={() => { openFolder = null; activate(tab); }}>
              <SiteFavicon src={tab.faviconDataURL} title={tab.title} url={tab.url} size={16} radius={4} asleep={tab.isClosed} />
              <span class="row-title">{tabTitle(tab)}</span>
            </button>
          {:else}
            <p class="popover-empty">{t("tabSection.folderEmpty")}</p>
          {/each}
        {/if}
      </StripPopover>
    {/if}
  {/if}

  <div class="footer">
    {#if getReadyUpdate()}
      <button
        bind:this={updateButton}
        class="rail-item update"
        aria-label={t("updateCard.restartLabel", { version: getReadyUpdate() ?? "" })}
        aria-expanded={updateOpen}
        use:tooltip={{ text: t("updateCard.ready"), placement: tooltipSide() }}
        onclick={() => (updateOpen = !updateOpen)}
      >
        {#if getChosenAppIcon()}<img src={getChosenAppIcon()} alt="" width="18" height="18" />{/if}
        <span class="update-dot" aria-hidden="true"></span>
      </button>
      {#if updateOpen && updateButton}
        <StripPopover anchor={updateButton} label={t("updateCard.ready")} onclose={() => (updateOpen = false)}>
          {#await import("./UpdateCard.svelte") then card}<card.default />{/await}
        </StripPopover>
      {/if}
    {/if}
    {#if spaces.length > 1}
      <div class="spaces" role="group" aria-label={t("bottomBar.spaces")}>
        {#each spaces as space (space.id)}
          <button
            class="space-dot"
            class:active={space.id === spaceId}
            aria-label={space.name}
            aria-current={space.id === spaceId ? "true" : undefined}
            use:tooltip={{ text: space.name, placement: tooltipSide() }}
            onclick={() => switchSpaceAnimated(space.id)}
          ></button>
        {/each}
      </div>
    {/if}
  </div>
</nav>
{#if !floating}
<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<div class="resize-handle" role="separator" aria-orientation="vertical" onmousedown={onresize}></div>
{/if}
</div>

<style>
  .sidebar-rail {
    position: fixed;
    top: 0;
    left: 0;
    width: calc(var(--sidebar-rail-width) + var(--content-inset));
    height: 100vh;
    background-color: var(--sidebar-bg);
    pointer-events: auto;
    z-index: 10;
  }

  :global(html[data-tab-position='right']) .sidebar-rail {
    left: auto;
    right: 0;
  }

  /* Over the page and its modal veils, as the full sidebar floats when hidden. */
  .sidebar-rail.floating {
    z-index: 63;
    box-shadow: 4px 0 24px var(--sidebar-shadow);
  }

  :global(html[data-tab-position='right']) .sidebar-rail.floating {
    box-shadow: -4px 0 24px var(--sidebar-shadow);
  }

  /* Glass and grain are drawn natively under the docked rail; floating, it has only the page under it. */
  :global(html:is([data-material='glass'], [data-material='grain'])) .sidebar-rail:not(.floating) {
    background-color: transparent;
  }

  /* The sidebar's own handle, on the rail's page edge. */
  .resize-handle {
    position: absolute;
    top: 0;
    right: 0;
    width: 7px;
    height: 100%;
    cursor: col-resize;
  }

  :global(html[data-tab-position='right']) .resize-handle {
    right: auto;
    left: 0;
  }

  .resize-handle:hover,
  .resize-handle:active {
    background: var(--accent-tint-12);
  }

  /* The column spans the rail to the page, so its icons center under the traffic lights. */
  .rail {
    display: flex;
    flex-direction: column;
    align-items: center;
    height: 100%;
  }

  .lights {
    flex: none;
    align-self: stretch;
  }

  .tools {
    flex: none;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 4px;
  }

  .tools.top {
    padding-top: var(--content-inset);
  }

  .tools :global(.nav-controls) {
    flex: none;
  }

  .separator {
    flex: none;
    width: 24px;
    height: 1px;
    margin: 8px 0;
    background: var(--separator);
  }

  .items {
    flex: 1;
    min-height: 0;
    align-self: stretch;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 4px;
    overflow-y: auto;
    scrollbar-width: none;
  }

  .items::-webkit-scrollbar {
    display: none;
  }

  .rail-item {
    position: relative;
    flex: none;
    width: 30px;
    height: 30px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-md);
    display: grid;
    place-items: center;
    background: transparent;
    color: var(--text-secondary);
    cursor: default;
    transition: background-color var(--motion-duration-fast) ease;
  }

  .rail-item:hover {
    background: var(--bg-hover);
  }

  .rail-item:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .rail-item.active {
    background: var(--sidebar-sel);
    color: var(--text-primary);
    box-shadow: inset 0 0 0 0.5px var(--sidebar-sel-ring);
  }

  .icon {
    position: relative;
    display: grid;
    place-items: center;
    width: 16px;
    height: 16px;
  }

  /* An agent at work on the tab: a still ring, as nothing loops in the chrome while a tab works for hours. */
  .icon.working::before {
    content: "";
    position: absolute;
    inset: -4px;
    border-radius: 50%;
    border: 1.5px solid var(--agents);
  }

  .attention,
  .sound {
    position: absolute;
    right: -3px;
    bottom: -3px;
    border-radius: 50%;
    box-shadow: 0 0 0 2px var(--sidebar-bg);
  }

  .attention {
    width: 6px;
    height: 6px;
    background: var(--attention);
  }

  .sound {
    right: -5px;
    bottom: -5px;
    width: 11px;
    height: 11px;
    display: grid;
    place-items: center;
    background: var(--sidebar-bg);
    color: var(--text-secondary);
  }

  .terminal-tile {
    width: 16px;
    height: 16px;
    border-radius: var(--radius-xs);
    display: grid;
    place-items: center;
    box-sizing: border-box;
    background: var(--terminal-tile-bg);
    box-shadow: inset 0 0 0 1px var(--terminal-tile-border);
    stroke: var(--terminal-tile-accent);
  }

  .terminal-tile path {
    stroke-width: 1.8;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  .popover-row {
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

  .popover-row:hover,
  .popover-row:focus-visible,
  .popover-row.active {
    background: var(--bg-hover);
  }

  .popover-row.asleep {
    color: var(--text-secondary);
  }

  .popover-empty {
    margin: 0;
    padding: 8px;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }

  .row-title {
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .folder {
    fill: color-mix(in srgb, var(--folder-color, currentColor) 35%, transparent);
    stroke: currentColor;
    stroke-width: 1.3;
  }

  .footer {
    flex: none;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
    padding: 8px 0 12px;
  }

  .update-dot {
    position: absolute;
    right: 3px;
    top: 3px;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--accent);
    box-shadow: 0 0 0 2px var(--sidebar-bg);
  }

  .spaces {
    display: flex;
    flex-direction: column;
    align-items: center;
  }

  .space-dot {
    width: 20px;
    height: 16px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-sm);
    display: grid;
    place-items: center;
    background: transparent;
    cursor: default;
  }

  .space-dot::before {
    content: "";
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--text-muted);
  }

  .space-dot.active::before {
    background: var(--text-primary);
  }

  .space-dot:hover {
    background: var(--bg-hover);
  }

  .space-dot:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }
</style>
