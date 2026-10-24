<!-- The recent tabs switcher: over the top of the sidebar, or of the page while the sidebar is hidden. The keyboard stays
     with native (the page keeps focus), so the selection is announced through a live region. -->
<script lang="ts">
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import type { BridgeRecentTab } from "../../lib/bridge/protocol";
  import { t } from "../../lib/i18n/state.svelte";
  import { terminalTitle } from "../../lib/terminalTitle";
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
    list?.querySelector(`[data-index="${selected}"]`)?.scrollIntoView({ block: "nearest" });
  });
</script>

{#if visible}
  <div class="tab-switcher float-surface" use:reportInteractiveZone={{ id: "tab-switcher" }}>
    <div class="tab-switcher-title" id="tab-switcher-title">{t("tabSwitcher.title")}</div>
    <div
      class="tab-switcher-list"
      role="listbox"
      aria-labelledby="tab-switcher-title"
      aria-activedescendant={`tab-switcher-row-${selected}`}
      tabindex="-1"
      bind:this={list}
    >
      {#each tabs as tab, index (tab.id)}
        <button
          type="button"
          role="option"
          id={`tab-switcher-row-${index}`}
          class="tab-switcher-row"
          class:selected={index === selected}
          aria-selected={index === selected}
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
              <svg width="11" height="11" viewBox="0 0 16 16" fill="none">
                <path d="m3.5 4.5 3.5 3.5-3.5 3.5" />
                <path d="M8.5 11.5h4" />
              </svg>
            </span>
          {:else}
            <SiteFavicon src={tab.faviconDataURL} title={tab.title} url={tab.url} size={16} radius={4} />
          {/if}
          <span class="tab-switcher-text">
            <span class="tab-switcher-row-title">{title(tab)}</span>
            <span class="tab-switcher-row-detail">{detail(tab, index)}</span>
          </span>
        </button>
      {/each}
    </div>
    <div class="tab-switcher-hint">{t("tabSwitcher.hint")}</div>
  </div>
{/if}
<div class="tab-switcher-live" role="status" aria-live="polite">{announcement}</div>

<style>
  .tab-switcher {
    position: fixed;
    top: 52px;
    /* Over the sidebar rows' own span, so none peeks out beside it. */
    left: 10px;
    width: calc(var(--sidebar-width) - 12px);
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 6px;
    border-radius: var(--float-radius-popover);
    background: var(--chrome-overlay-surface);
    -webkit-backdrop-filter: blur(var(--chrome-floating-blur));
    backdrop-filter: blur(var(--chrome-floating-blur));
    pointer-events: auto;
    z-index: var(--z-popover);
    animation: float-popover-in 160ms var(--motion-ease-spring) both;
  }

  .tab-switcher-title {
    padding: 4px 8px 6px;
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    letter-spacing: 0.04em;
    text-transform: uppercase;
  }

  /* About ten rows, then it scrolls. */
  .tab-switcher-list {
    display: flex;
    flex-direction: column;
    gap: 2px;
    max-height: 460px;
    overflow-y: auto;
    scrollbar-width: none;
  }

  .tab-switcher-row {
    display: flex;
    align-items: center;
    gap: 10px;
    flex-shrink: 0;
    width: 100%;
    padding: 8px;
    border: 0;
    border-radius: calc(var(--float-radius-popover) - 4px);
    background: transparent;
    color: var(--text-primary);
    font-family: inherit;
    text-align: left;
    cursor: pointer;
  }

  .tab-switcher-row.selected {
    background: var(--sidebar-accent);
    color: var(--sidebar-accent-text);
  }

  .tab-switcher-text {
    display: flex;
    flex-direction: column;
    min-width: 0;
  }

  .tab-switcher-row-title,
  .tab-switcher-row-detail {
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .tab-switcher-row-title {
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
  }

  .tab-switcher-row-detail {
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
  }

  .tab-switcher-row.selected .tab-switcher-row-detail {
    color: color-mix(in srgb, var(--sidebar-accent-text) 80%, transparent);
  }

  .tab-switcher-hint {
    padding: 6px 8px 2px;
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
  }

  /* TabItem's terminal tile, at the favicon's box. */
  .terminal-tile {
    width: 16px;
    height: 16px;
    flex-shrink: 0;
    border-radius: var(--radius-xs);
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
      animation: none;
    }
  }
</style>
