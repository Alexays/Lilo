<!-- A closed folder's tabs, beside the sidebar at the folder's row: a search over them, then one row
     per tab. Opened by a hover it leaves the keyboard to the page; opened from the keyboard its
     field takes the focus. -->
<script lang="ts">
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import UiSearchField from "../ui/UiSearchField.svelte";
  import { dismissable } from "../../lib/actions/dismissable";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { portal } from "../../lib/actions/portal";
  import { tabActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { popoverOut } from "../../lib/motion/restingTransitions";
  import { hostOf } from "../../lib/url";
  import { closePageShell } from "../../stores/panels.svelte";
  import { optimisticallyActivateTab } from "../../stores/sidebar.svelte";
  import { getTabPosition } from "../../stores/tabLayout.svelte";
  import { tabDisplayTitle, type TabState } from "../../stores/tabs.svelte";

  let { anchor, name, tabs, focusSearch, onclose, onenter, onleave }: {
    anchor: HTMLElement;
    name: string;
    tabs: TabState[];
    focusSearch: boolean;
    onclose: () => void;
    onenter: () => void;
    onleave: () => void;
  } = $props();

  const WIDTH = 280;
  const MARGIN = 8;

  let popover: HTMLDivElement | undefined = $state();
  let height = $state(0);
  let query = $state("");

  const rows = $derived(tabs.map((tab) => ({ tab, title: tabDisplayTitle(tab.title) || tab.url || "", host: hostOf(tab.url) ?? "" })));
  const shown = $derived.by(() => {
    const needle = query.trim().toLocaleLowerCase();
    return needle ? rows.filter((row) => `${row.title} ${row.host}`.toLocaleLowerCase().includes(needle)) : rows;
  });

  // Level with the row, past the sidebar's edge toward the page.
  const rect = $derived(anchor.getBoundingClientRect());
  const sidebar = $derived((anchor.closest(".sidebar-layout") ?? anchor).getBoundingClientRect());
  const onRight = $derived(getTabPosition() === "right");
  const left = $derived(onRight ? sidebar.left - MARGIN - WIDTH : sidebar.right + MARGIN);
  const top = $derived(Math.max(MARGIN, Math.min(rect.top, window.innerHeight - height - MARGIN)));
  const origin = $derived(`${onRight ? "right" : "left"} ${rect.top + rect.height / 2 - top}px`);

  $effect(() => {
    if (focusSearch) popover?.querySelector("input")?.focus({ preventScroll: true });
  });

  // The row moves with the sidebar's scroll: the popover would float beside the wrong one.
  $effect(() => {
    const hide = (event: Event) => {
      if (!popover?.contains(event.target as Node)) close();
    };
    window.addEventListener("scroll", hide, true);
    return () => window.removeEventListener("scroll", hide, true);
  });

  // Escape or a pick from the keyboard hands the focus back to the folder's row.
  function close(): void {
    if (popover?.contains(document.activeElement)) anchor.focus({ preventScroll: true });
    onclose();
  }

  function activate(tab: TabState): void {
    close();
    closePageShell();
    optimisticallyActivateTab(tab.id);
    tabActions.switchTo(tab.id);
  }

  // Up and Down walk the field and the rows; Return in the field opens the first match.
  function handleKeydown(event: KeyboardEvent): void {
    if (event.key === "Enter" && event.target instanceof HTMLInputElement) {
      event.preventDefault();
      if (shown[0]) activate(shown[0].tab);
      return;
    }
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    const stops = Array.from(popover?.querySelectorAll<HTMLElement>("input, .float-row") ?? []);
    event.preventDefault();
    const index = stops.indexOf(document.activeElement as HTMLElement);
    stops[(index + (event.key === "ArrowDown" ? 1 : -1) + stops.length) % stops.length]?.focus();
  }
</script>

<div
  bind:this={popover}
  bind:clientHeight={height}
  class="folder-popover float-surface float-popover"
  role="dialog"
  tabindex="-1"
  aria-label={name}
  style={`left: ${left}px; top: ${top}px; width: ${WIDTH}px; transform-origin: ${origin};`}
  out:popoverOut|global
  use:portal
  use:reportInteractiveZone={{ id: "folder-popover" }}
  onmouseenter={onenter}
  onmouseleave={onleave}
  onkeydown={handleKeydown}
  {@attach dismissable({ onDismiss: close, escape: true, returnFocus: anchor })}
>
  <UiSearchField value={query} onchange={(value) => (query = value)} placeholder={t("tabFolder.searchFolder", { name })} ariaLabel={t("tabFolder.searchFolder", { name })} />
  <div class="list" role="group" aria-label={name}>
    {#each shown as row (row.tab.id)}
      <button class="float-row" onclick={() => activate(row.tab)}>
        <SiteFavicon src={row.tab.faviconDataURL} title={row.tab.title} url={row.tab.url} size={16} radius={4} />
        <span class="text">
          <span class="title">{row.title}</span>
          {#if row.host}<span class="host">{row.host}</span>{/if}
        </span>
      </button>
    {:else}
      <p class="empty">{t("tabFolder.noMatches")}</p>
    {/each}
  </div>
</div>

<style>
  .folder-popover {
    position: fixed;
    z-index: var(--z-popover);
    max-height: 60vh;
    box-sizing: border-box;
    pointer-events: auto;
  }

  .list {
    display: flex;
    flex-direction: column;
    min-height: 0;
    overflow-y: auto;
  }

  .float-row {
    flex: none;
    min-height: 40px;
    gap: 10px;
  }

  .text {
    display: flex;
    flex-direction: column;
    gap: 1px;
    min-width: 0;
  }

  .title,
  .host {
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .host {
    font-size: var(--font-size-xs);
    color: var(--text-muted);
  }

  .empty {
    margin: 0;
    padding: 10px 8px;
    font-size: var(--font-size-sm);
    color: var(--text-muted);
  }
</style>
