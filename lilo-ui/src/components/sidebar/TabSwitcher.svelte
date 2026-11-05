<!-- The recent tabs switcher: a row of tiles centered on the page area. The keyboard stays with native (the page
     keeps focus), so the selection is announced through a live region. -->
<script lang="ts">
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import type { BridgeRecentTab } from "../../lib/bridge/protocol";
  import { t } from "../../lib/i18n/state.svelte";
  import { terminalTitle } from "../../lib/terminalTitle";
  import { isSidebarVisible } from "../../stores/ui.svelte";
  import { tabDisplayTitle } from "../../stores/tabs.svelte";
  import {
    closeTabSwitcher,
    formatAgo,
    getSwitcherOpenedAt,
    getSwitcherSelection,
    getSwitcherTabs,
    isTabSwitcherVisible,
    selectSwitcherTab,
  } from "../../stores/tabSwitcher.svelte";

  const tabs = $derived(getSwitcherTabs());
  const selected = $derived(getSwitcherSelection());
  const visible = $derived(isTabSwitcherVisible());
  let list: HTMLDivElement | undefined = $state();
  // Where the pointer was last seen over the panel: only a moving pointer selects, so a panel opening under a resting
  // one keeps the keyboard's selection.
  let lastPointer = "";

  function title(tab: BridgeRecentTab): string {
    return tab.kind === "terminal" ? terminalTitle(tab) || tab.title : tabDisplayTitle(tab.title);
  }

  function detail(tab: BridgeRecentTab, index: number): string {
    let when = "";
    if (index === 0) {
      when = t("tabSwitcher.current");
    } else if (tab.kind === "terminal") {
      when = t("tabSwitcher.terminal");
    } else if (tab.leftAt > 0) {
      when = formatAgo(getSwitcherOpenedAt() - tab.leftAt);
    }
    return when ? `${tab.spaceName} · ${when}` : tab.spaceName;
  }

  const announcement = $derived(
    visible && tabs[selected] ? t("tabSwitcher.selected", { title: title(tabs[selected]), detail: detail(tabs[selected], selected) }) : "",
  );

  $effect(() => {
    if (!visible) {
      lastPointer = "";
      return;
    }
    list?.querySelector(`[data-index="${selected}"]`)?.scrollIntoView({ block: "nearest", inline: "nearest" });
  });
</script>

{#if visible}
  <div class="tab-switcher-area" class:sidebar-hidden={!isSidebarVisible()}>
    <div class="tab-switcher float-surface" use:reportInteractiveZone={{ id: "tab-switcher" }}>
      <div
        class="tab-switcher-list"
        role="listbox"
        aria-label={t("tabSwitcher.title")}
        aria-activedescendant={`tab-switcher-row-${selected}`}
        tabindex="-1"
        bind:this={list}
      >
        {#each tabs as tab, index (tab.id)}
          <button
            type="button"
            role="option"
            id={`tab-switcher-row-${index}`}
            class="tab-switcher-tile"
            class:selected={index === selected}
            aria-selected={index === selected}
            aria-label={t("tabSwitcher.selected", { title: title(tab), detail: detail(tab, index) })}
            tabindex="-1"
            data-index={index}
            data-tab-id={tab.id}
            onpointermove={(event) => {
              const at = `${event.clientX},${event.clientY}`;
              if (lastPointer && at !== lastPointer) selectSwitcherTab(index);
              lastPointer = at;
            }}
            onclick={() => closeTabSwitcher(index)}
          >
            {#if tab.kind === "terminal"}
              <span class="terminal-tile" aria-hidden="true">
                <svg width="20" height="20" viewBox="0 0 16 16" fill="none">
                  <path d="m3.5 4.5 3.5 3.5-3.5 3.5" />
                  <path d="M8.5 11.5h4" />
                </svg>
              </span>
            {:else}
              <SiteFavicon src={tab.faviconDataURL} title={tab.title} url={tab.url} size={44} radius={12} />
            {/if}
            <span class="tab-switcher-label" aria-hidden="true">{title(tab)}</span>
          </button>
        {/each}
      </div>
      {#if tabs[selected]}
        <div class="tab-switcher-selection" aria-hidden="true">
          <div class="tab-switcher-title">{title(tabs[selected])}</div>
          <div class="tab-switcher-detail">{detail(tabs[selected], selected)}</div>
        </div>
      {/if}
      <div class="tab-switcher-hint">{t("tabSwitcher.hint")}</div>
    </div>
  </div>
{/if}
<div class="tab-switcher-live" role="status" aria-live="polite">{announcement}</div>

<style>
  .tab-switcher-area {
    position: fixed;
    inset: var(--chrome-content-top) var(--chrome-content-right) var(--chrome-content-bottom) var(--chrome-content-left-visible);
    display: grid;
    place-items: center;
    padding: 24px;
    pointer-events: none;
    z-index: var(--z-popover);
  }

  .tab-switcher-area.sidebar-hidden {
    left: var(--chrome-content-left-hidden);
  }

  .tab-switcher {
    display: flex;
    flex-direction: column;
    min-width: 0;
    max-width: min(720px, 100%);
    border-radius: var(--radius-lg);
    pointer-events: auto;
    overflow: hidden;
    animation: float-popover-in var(--motion-duration-overlay) var(--motion-ease-spring) both;
  }

  .tab-switcher-list {
    display: flex;
    gap: 4px;
    padding: 16px 16px 0;
    overflow-x: auto;
    scrollbar-width: none;
  }

  .tab-switcher-tile {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
    flex: none;
    width: 96px;
    padding: 12px 6px 10px;
    border: 0;
    border-radius: var(--radius-box);
    background: transparent;
    color: var(--text-secondary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    cursor: pointer;
  }

  .tab-switcher-tile.selected {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .tab-switcher-label {
    max-width: 100%;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .tab-switcher-selection {
    padding: 12px 24px 16px;
    text-align: center;
  }

  .tab-switcher-title,
  .tab-switcher-detail {
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .tab-switcher-title {
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .tab-switcher-detail {
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }

  .tab-switcher-hint {
    padding: 10px 16px;
    border-top: 1px solid var(--separator);
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    text-align: center;
  }

  /* TabItem's terminal tile, at the tile's size. */
  .terminal-tile {
    width: 44px;
    height: 44px;
    flex-shrink: 0;
    border-radius: var(--radius-box);
    display: grid;
    place-items: center;
    background: var(--terminal-tile-bg);
    box-shadow: inset 0 0 0 1px var(--terminal-tile-border);
  }

  .terminal-tile path {
    stroke: var(--terminal-tile-accent);
    stroke-width: 1.8;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  .tab-switcher-live {
    position: fixed;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
    white-space: nowrap;
  }

  @media (prefers-reduced-motion: reduce) {
    .tab-switcher {
      animation: tab-switcher-fade 150ms ease both;
    }
  }

  @keyframes tab-switcher-fade {
    from {
      opacity: 0;
    }
  }
</style>
