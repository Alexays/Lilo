<script lang="ts">
  import { chromeActions, folderActions, tabActions } from "../../lib/bridge/actions";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { t } from "../../lib/i18n/state.svelte";
  import { getContentPlaceholderLockedFolderId, getContentPlaceholderTabId } from "../../stores/banners.svelte";
  import { openLockPanel } from "../../stores/folderLock.svelte";
  import { getFoldersById } from "../../stores/folders.svelte";
  import { isSidebarVisible } from "../../stores/ui.svelte";

  const tabId = $derived(getContentPlaceholderTabId());
  const lockedFolder = $derived.by(() => {
    const id = getContentPlaceholderLockedFolderId();
    return id ? getFoldersById().get(id) ?? null : null;
  });

  function usePassword(folderId: string): void {
    if (!isSidebarVisible()) chromeActions.toggleSidebar();
    openLockPanel(folderId, "unlock");
  }
</script>

{#if tabId}
  <div
    class="content-placeholder chrome-content-overlay-root"
    class:sidebar-hidden={!isSidebarVisible()}
    use:reportInteractiveZone={{ id: "content-placeholder" }}
  >
    <div class="card">
      {#if lockedFolder}
        <h1 class="title">{t("contentPlaceholder.lockedTitle", { name: lockedFolder.name })}</h1>
        <p class="description">{t("contentPlaceholder.lockedDescription")}</p>
        {#if lockedFolder.lock?.allowsBiometrics}
          <button class="show-here" onclick={() => folderActions.unlockWith(lockedFolder.id, "biometrics")}>{t("tabFolder.unlockTouchId")}</button>
        {/if}
        <button class="use-password" onclick={() => usePassword(lockedFolder.id)}>{t("contentPlaceholder.usePassword")}</button>
      {:else}
        <h1 class="title">{t("contentPlaceholder.title")}</h1>
        <p class="description">{t("contentPlaceholder.description")}</p>
        <button class="show-here" onclick={() => tabActions.claim(tabId)}>{t("contentPlaceholder.showHere")}</button>
      {/if}
    </div>
  </div>
{/if}

<style>
  .content-placeholder {
    display: flex;
    align-items: center;
    justify-content: center;
    pointer-events: auto;
    background: var(--bg-primary);
  }

  .card {
    text-align: center;
    max-width: 420px;
    padding: 40px 32px;
  }

  .title {
    font-size: var(--font-size-2xl);
    font-weight: var(--font-weight-semibold);
    color: var(--text-primary);
    margin: 0 0 8px;
  }

  .description {
    font-size: var(--font-size-lg);
    color: var(--text-secondary);
    line-height: 1.5;
    margin: 0 0 20px;
  }

  .show-here {
    padding: 8px 24px;
    border-radius: var(--radius-md);
    font-size: var(--font-size-lg);
    font-weight: var(--font-weight-medium);
    cursor: pointer;
    background: var(--accent);
    color: var(--accent-text);
    border: none;
    transition: background var(--transition-fast);
  }

  .show-here:hover {
    background: var(--accent-hover);
  }

  .use-password {
    display: block;
    margin: 12px auto 0;
    border: none;
    background: none;
    color: var(--text-secondary);
    font-size: var(--font-size-md);
    cursor: pointer;
    text-decoration: underline;
  }
</style>
