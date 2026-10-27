<script lang="ts">
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import StripPopover from "./StripPopover.svelte";
  import { folderActions, sidebarActions, tabActions } from "../../lib/bridge/actions";
  import type { BridgeTabFolderSnapshot } from "../../lib/bridge/protocol";
  import { optimisticallyActivateTab } from "../../stores/sidebar.svelte";
  import { tabDisplayTitle, type TabState } from "../../stores/tabs.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { dndZone } from "../../lib/dndEngine/action";
  import type { SidebarDndItem } from "../../lib/dndEngine/adapters/sidebar";
  import { commitSidebarDrop, getSidebarDrag, resetSidebarDrag, type SidebarZoneRef } from "../../stores/sidebarDnd.svelte";
  import { getLockPanel, openLockPanel } from "../../stores/folderLock.svelte";
  import { closeSettingsShell } from "../../stores/panels.svelte";

  let {
    folder,
    tabs,
    activeTabId,
    spaceId,
    section,
    childItems,
  }: {
    folder: BridgeTabFolderSnapshot;
    tabs: TabState[];
    activeTabId: string;
    spaceId: string;
    section: "pinned" | "unpinned";
    childItems: SidebarDndItem[];
  } = $props();

  // A tab dropped on the chip goes into the folder; its edges still reorder the row around it.
  const zone: SidebarZoneRef = $derived({ id: `strip-folder-${folder.id}`, section, parentFolderId: folder.id });
  const dropTarget = $derived(getSidebarDrag()?.target?.id === zone.id);
  let password = $state("");
  const unlockFailed = $derived(getLockPanel()?.folderId === folder.id && getLockPanel()?.failed === true);

  function unlock(event: SubmitEvent) {
    event.preventDefault();
    if (!password) return;
    // The lock store reports a wrong password for the folder whose panel is open.
    openLockPanel(folder.id, "unlock");
    folderActions.unlockWithPassword(folder.id, password);
  }

  let open = $state(false);
  let chip: HTMLButtonElement | undefined = $state();
  const containsActive = $derived(tabs.some((tab) => tab.id === activeTabId));

  function activate(tab: TabState) {
    open = false;
    closeSettingsShell();
    optimisticallyActivateTab(tab.id);
    tabActions.switchTo(tab.id);
  }

  function showMenu(event: MouseEvent) {
    event.preventDefault();
    const rect = (event.currentTarget as HTMLElement).getBoundingClientRect();
    folderActions.showContextMenu(folder.id, rect.x, rect.y, rect.width, rect.height);
  }
</script>

{#if folder.isSplit}
  <!-- A split view is one pill: each pane's icon and short title, the whole split activates. -->
  <button
    class="strip-split"
    tabindex="-1"
    data-roving
    class:active={containsActive}
    aria-label={tabs.map((tab) => tabDisplayTitle(tab.title)).join(", ")}
    onclick={() => tabs[0] && activate(tabs[0])}
    oncontextmenu={showMenu}
  >
    {#each tabs as tab (tab.id)}
      <span class="pane">
        <SiteFavicon src={tab.faviconDataURL} title={tab.title} url={tab.url} size={14} radius={3} />
        <span class="pane-title">{tabDisplayTitle(tab.title)}</span>
      </span>
    {/each}
  </button>
{:else}
  <button
    bind:this={chip}
    class="strip-folder"
    class:active={containsActive}
    class:drop-target={dropTarget}
    aria-expanded={open}
    aria-label={folder.isLocked ? `${folder.name}, ${t("tabFolder.locked")}` : folder.name}
    tabindex="-1"
    data-roving
    onclick={() => (open = !open)}
    oncontextmenu={showMenu}
    use:dndZone={{
      id: zone.id,
      axis: "horizontal",
      // A chip never shows its rows: like a collapsed folder, it keeps the row's placeholder still and takes the tab last.
      meta: { section, spaceId, parentFolderId: folder.id, isCollapsed: true },
      getItems: () => [],
      canResolve: ({ point, zone: snapshot, dragSource }) =>
        dragSource.kind === "tab" && !folder.isLocked && Math.abs(point.x - (snapshot.rect.left + snapshot.rect.width / 2)) < snapshot.rect.width * 0.3,
      onDrop: (drag) => commitSidebarDrop(zone, childItems, sidebarActions.commitDrop, drag),
      onCancel: resetSidebarDrag,
    }}
  >
    <svg width="15" height="15" viewBox="0 0 16 16" aria-hidden="true">
      <path d="M2 4.5A1.5 1.5 0 0 1 3.5 3h3l1.5 1.5h4.5A1.5 1.5 0 0 1 14 6v5.5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 11.5z" fill="none" stroke="currentColor" stroke-width="1.3" />
    </svg>
    <span class="folder-name">{folder.name}</span>
    {#if folder.isLocked}
      <svg width="10" height="11" viewBox="0 0 11 12" aria-hidden="true"><rect x="1" y="5" width="9" height="6.5" rx="1.5" fill="currentColor" /><path d="M3 5V3.5a2.5 2.5 0 0 1 5 0V5" fill="none" stroke="currentColor" stroke-width="1.3" /></svg>
    {:else}
      <span class="count">{tabs.length}</span>
    {/if}
  </button>
  {#if open && chip && folder.isLocked}
    <StripPopover anchor={chip} onclose={() => (open = false)} label={folder.name}>
      <!-- The sidebar's unlock, from the chip: Touch ID when allowed, else the password. -->
      <form class="unlock" onsubmit={unlock}>
        {#if folder.lock?.allowsBiometrics}
          <button type="button" class="unlock-primary" onclick={() => folderActions.unlockWith(folder.id, "biometrics")}>{t("tabFolder.unlockTouchId")}</button>
        {/if}
        <!-- svelte-ignore a11y_autofocus -->
        <input type="password" class="unlock-input" bind:value={password} placeholder={t("tabFolder.password")} aria-label={t("tabFolder.password")} autofocus={!folder.lock?.allowsBiometrics} />
        {#if unlockFailed}<p class="unlock-error" role="alert">{t("tabFolder.wrongPassword")}</p>{/if}
        <button type="submit" class="unlock-submit" disabled={!password}>{t("tabFolder.unlock")}</button>
      </form>
    </StripPopover>
  {:else if open && chip}
    <StripPopover anchor={chip} onclose={() => (open = false)} label={folder.name}>
      {#each tabs as tab (tab.id)}
        <button class="popover-row" class:active={tab.id === activeTabId} onclick={() => activate(tab)}>
          <SiteFavicon src={tab.faviconDataURL} title={tab.title} url={tab.url} size={16} radius={4} />
          <span class="row-title">{tabDisplayTitle(tab.title) || tab.url}</span>
        </button>
      {/each}
    </StripPopover>
  {/if}
{/if}

<style>
  .strip-folder,
  .strip-split {
    flex: none;
    height: 32px;
    display: flex;
    align-items: center;
    gap: 7px;
    padding: 0 9px;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-primary);
    font: inherit;
    font-size: var(--font-size-sm);
    white-space: nowrap;
  }

  .strip-folder:hover,
  .strip-split:hover,
  .strip-folder[aria-expanded="true"] {
    background: var(--bg-hover);
  }

  .strip-folder.active,
  .strip-split.active {
    background: var(--bg-selected);
  }

  .strip-folder.drop-target {
    background: var(--accent-tint-18);
    box-shadow: inset 0 0 0 1.5px var(--accent);
  }

  .unlock {
    display: grid;
    gap: 8px;
    padding: 4px;
  }

  .unlock-input {
    height: var(--control-height-lg);
    padding: 0 10px;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--bg-primary);
    color: var(--text-primary);
    font: inherit;
    font-size: var(--font-size-sm);
  }

  .unlock-primary,
  .unlock-submit {
    height: var(--control-height-md);
    border: 0;
    border-radius: var(--radius-chip);
    font: inherit;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-semibold);
  }

  .unlock-primary {
    background: var(--accent);
    color: var(--accent-text);
  }

  .unlock-submit {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .unlock-submit:disabled {
    opacity: var(--disabled-opacity);
  }

  .unlock-error {
    margin: 0;
    font-size: var(--font-size-xs);
    color: var(--danger);
  }

  .count {
    color: var(--text-secondary);
  }

  .strip-split {
    max-width: 300px;
    gap: 10px;
  }

  .pane {
    display: flex;
    align-items: center;
    gap: 5px;
    min-width: 0;
  }

  .pane-title {
    max-width: 90px;
    overflow: hidden;
    text-overflow: ellipsis;
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

  .row-title {
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
</style>
