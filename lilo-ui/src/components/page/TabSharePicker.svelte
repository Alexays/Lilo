<script lang="ts">
  import { onDestroy } from "svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { t } from "../../lib/i18n/state.svelte";
  import { getActiveSpaceId, getSpaces } from "../../stores/spaces.svelte";
  import { getActiveTabId, getOpenTabs, tabDisplayTitle } from "../../stores/tabs.svelte";
  import {
    getTabShareRequest,
    resolveTabShare,
  } from "../../stores/tabShare.svelte";
  import { isSidebarVisible } from "../../stores/ui.svelte";
  import SiteFavicon from "../ui/SiteFavicon.svelte";

  const request = $derived(getTabShareRequest());
  const activeTabId = $derived(getActiveTabId());
  // Current space's tabs first, then the other spaces in sidebar order; only the tabs native can
  // resolve to a live engine, so a pick never fails silently.
  const shareTabs = $derived.by(() => {
    if (!request) return [];
    const activeSpaceId = getActiveSpaceId();
    const spaceIds = [
      activeSpaceId,
      ...getSpaces()
        .map((space) => space.id)
        .filter((id) => id !== activeSpaceId),
    ];
    return spaceIds
      .flatMap((id) => getOpenTabs(id))
      .filter((tab) => request.shareableTabIds.has(tab.id));
  });

  let panelEl = $state<HTMLDivElement>();

  // A modal: Tab cycles through the picker's buttons instead of reaching the sidebar behind it.
  // Capture phase, so Escape cancels the picker alone, not the panel or bar under it.
  function handleKeydown(e: KeyboardEvent) {
    if (e.target instanceof Element && e.target.closest("dialog[open]")) return;
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      resolveTabShare("cancel");
      return;
    }
    if (e.key !== "Tab" || !panelEl) return;
    const buttons = [...panelEl.querySelectorAll<HTMLButtonElement>("button")];
    if (buttons.length === 0) return;
    e.preventDefault();
    const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
    const step = e.shiftKey ? -1 : 1;
    const next = index < 0 ? (e.shiftKey ? buttons.length - 1 : 0) : (index + step + buttons.length) % buttons.length;
    buttons[next].focus();
  }

  function handleBackdropClick(e: MouseEvent) {
    if (e.target === e.currentTarget) {
      resolveTabShare("cancel");
    }
  }

  // Window teardown must not leave the page's getDisplayMedia promise hanging.
  onDestroy(() => resolveTabShare("cancel"));
</script>

<svelte:window onkeydowncapture={request ? handleKeydown : undefined} />

{#if request}
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div
    class="tab-share-backdrop chrome-content-overlay-root"
    class:sidebar-hidden={!isSidebarVisible()}
    use:reportInteractiveZone={{ id: "tab-share-picker" }}
    onclick={handleBackdropClick}
  >
    <div
      class="tab-share-panel chrome-floating-surface"
      role="dialog"
      aria-modal="true"
      aria-label={t("tabShare.title", { origin: request.origin })}
      tabindex="-1"
      bind:this={panelEl}
      {@attach (node) => node.focus()}
    >
      <header class="tab-share-header">
        <h2 class="tab-share-title">
          {t("tabShare.title", { origin: request.origin })}
        </h2>
        <p class="tab-share-subtitle">{t("tabShare.pickTab")}</p>
      </header>

      <ul class="tab-share-list">
        {#each shareTabs as tab (tab.id)}
          <li class="tab-share-item">
            <button
              class="tab-share-row"
              data-share-tab-id={tab.id}
              onclick={() => resolveTabShare("tab", tab.id)}
            >
              <SiteFavicon
                src={tab.faviconDataURL}
                title={tab.title}
                url={tab.url}
                size={18}
                radius={5}
              />
              <span class="tab-share-row-title">{tabDisplayTitle(tab.title)}</span>
              {#if tab.id === activeTabId}
                <span class="tab-share-current">{t("tabShare.currentTab")}</span>
              {/if}
            </button>
          </li>
        {:else}
          <li class="tab-share-empty">{t("tabShare.noTabs")}</li>
        {/each}
      </ul>

      <footer class="tab-share-footer">
        {#if request.allowsSystem}
          <button
            class="tab-share-btn"
            onclick={() => resolveTabShare("system")}
          >
            {t("tabShare.shareSystem")}
          </button>
        {/if}
        <button
          class="tab-share-btn tab-share-cancel"
          onclick={() => resolveTabShare("cancel")}
        >
          {t("common.cancel")}
        </button>
      </footer>
    </div>
  </div>
{/if}

<style>
  .tab-share-backdrop {
    display: flex;
    align-items: flex-start;
    justify-content: center;
    padding: clamp(18px, 6vh, 64px) 16px 16px;
    z-index: 61;
    pointer-events: auto;
    overflow: hidden;
    background: var(--chrome-overlay-backdrop-tint);
    backdrop-filter: blur(var(--chrome-overlay-backdrop-blur)) saturate(1.04);
  }

  .tab-share-panel {
    width: min(440px, 100%);
    max-height: calc(100% - 24px);
    display: flex;
    flex-direction: column;
    overflow: hidden;
    color: var(--text-primary);
    outline: none;
    animation: tab-share-rise 340ms var(--motion-ease-bounce);
  }

  .tab-share-header {
    padding: 16px 18px 12px;
    border-bottom: 1px solid var(--separator);
  }

  .tab-share-title {
    margin: 0;
    font-size: var(--font-size-lg);
    font-weight: var(--font-weight-semibold);
    line-height: 1.3;
    overflow-wrap: break-word;
  }

  .tab-share-subtitle {
    margin: 4px 0 0;
    font-size: var(--font-size-sm);
    color: var(--text-muted);
  }

  .tab-share-list {
    margin: 0;
    padding: 6px;
    list-style: none;
    overflow-y: auto;
    flex: 1 1 auto;
    min-height: 0;
  }

  .tab-share-item + .tab-share-item {
    border-top: 1px solid var(--separator);
  }

  .tab-share-row {
    width: 100%;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 10px;
    border: none;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-family: inherit;
    text-align: left;
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .tab-share-row:hover {
    background: var(--bg-hover);
  }

  .tab-share-row-title {
    flex: 1;
    min-width: 0;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .tab-share-current {
    flex-shrink: 0;
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    color: var(--accent-text);
    background: var(--accent);
    border-radius: var(--radius-chip);
    padding: 2px 8px;
  }

  .tab-share-empty {
    padding: 18px 10px;
    font-size: var(--font-size-md);
    color: var(--text-muted);
    text-align: center;
  }

  .tab-share-footer {
    display: flex;
    justify-content: space-between;
    gap: 8px;
    padding: 10px 12px;
    border-top: 1px solid var(--separator);
  }

  .tab-share-btn {
    padding: 6px 12px;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-medium);
    font-family: inherit;
    border: 1px solid var(--border);
    border-radius: var(--radius-sm);
    background: var(--bg-primary);
    color: var(--text-primary);
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .tab-share-btn:hover {
    background: var(--bg-hover);
  }

  @keyframes tab-share-rise {
    from {
      opacity: 0;
      transform: translateY(-6px) scale(0.985);
    }

    to {
      opacity: 1;
      transform: translateY(0) scale(1);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .tab-share-panel {
      animation: none;
    }
  }
</style>
