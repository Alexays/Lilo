<!-- A site stack's row: the site's icon fanned over the pages under it, its name and how many.
     It opens and closes like a folder; its tabs keep their own rows. Closed on the active page, it
     wears that page as its face, a card's edge under it for the pages behind. -->
<script lang="ts">
  import { getInterfaceSizeStep } from "../../stores/settings.svelte";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { t } from "../../lib/i18n/state.svelte";
  import type { TabState } from "../../stores/tabs.svelte";

  let {
    name,
    tabs,
    face,
    open,
    interactive,
    tabStop,
    onToggle,
    onClose,
    onContextMenu,
  }: {
    name: string;
    tabs: TabState[];
    face?: TabState;
    open: boolean;
    interactive: boolean;
    tabStop: boolean;
    onToggle: (open: boolean) => void;
    onClose: () => void;
    onContextMenu: (rect: DOMRect) => void;
  } = $props();

  const lead = $derived(face ?? tabs[0]);
  const title = $derived(face ? face.customTitle || face.title : name);

  function handleKeydown(event: KeyboardEvent): void {
    if (event.key === "Enter" || event.key === " ") onToggle(!open);
    else if (event.key === "ArrowRight" && !open) onToggle(true);
    else if (event.key === "ArrowLeft" && open) onToggle(false);
    else return;
    event.preventDefault();
    event.stopPropagation();
  }
</script>

<div
  class="stack-row"
  class:open
  class:face={!!face}
  role="treeitem"
  aria-level={1}
  aria-selected={!!face}
  aria-expanded={open}
  aria-label={t("tabSection.stackLabel", { name: title, count: tabs.length })}
  tabindex={tabStop ? 0 : -1}
  onclick={() => interactive && onToggle(!open)}
  onkeydown={handleKeydown}
  oncontextmenu={(event) => {
    if (!interactive) return;
    event.preventDefault();
    onContextMenu((event.currentTarget as HTMLElement).getBoundingClientRect());
  }}
>
  <span class="stack-icon" aria-hidden="true">
    {#if lead}
      <SiteFavicon src={lead.faviconDataURL} title={lead.title} url={lead.url} size={16 + getInterfaceSizeStep() * 2} radius={4} />
    {/if}
  </span>
  <span class="stack-name">{title}</span>
  <span class="stack-count" aria-hidden="true">{tabs.length}</span>
  <span class="stack-chevron" aria-hidden="true">
    <svg width="10" height="10" viewBox="0 0 10 10" fill="none">
      <path d="M3.75 2.25 6.5 5 3.75 7.75" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  </span>
  <!-- No close on the face: it would read as closing that page, not the whole stack. -->
  {#if interactive && !face}
    <button
      class="action-btn stack-close"
      aria-label={t("tabSection.closeStack")}
      tabindex="-1"
      use:tooltip={{ text: t("tabSection.closeStack") }}
      onclick={(event) => {
        event.stopPropagation();
        onClose();
      }}
    >
      <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
        <path d="M2 2L8 8M8 2L2 8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
      </svg>
    </button>
  {/if}
</div>

<style>
  .stack-row {
    position: relative;
    display: flex;
    align-items: center;
    gap: 8px;
    height: var(--interface-row-height);
    padding: 0 8px;
    box-sizing: border-box;
    border-radius: var(--radius-md);
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .stack-row:hover {
    background: var(--bg-hover);
  }

  /* The active row's look, as the face is the page on screen. */
  .stack-row.face {
    background: var(--sidebar-sel);
    box-shadow: inset 0 0 0 0.5px var(--sidebar-sel-ring);
  }

  /* The next card's edge, peeking out under the face. */
  .stack-row.face::after {
    content: "";
    position: absolute;
    left: 10px;
    right: 10px;
    bottom: -3px;
    height: 3px;
    border-radius: 0 0 var(--radius-sm) var(--radius-sm);
    background: var(--sidebar-sel);
    opacity: 0.6;
    pointer-events: none;
  }

  .stack-row:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  /* Two cards peek out above and to the right of the site's icon: pages under it. */
  .stack-icon {
    position: relative;
    flex: none;
    width: var(--interface-icon-size);
    height: var(--interface-icon-size);
  }

  .stack-icon::before,
  .stack-icon::after {
    content: "";
    position: absolute;
    inset: 0;
    border-radius: var(--radius-xs);
    background: var(--text-primary);
  }

  .stack-icon::before {
    opacity: 0.18;
    transform: translate(4px, -4px) scale(0.84);
  }

  .stack-icon::after {
    opacity: 0.32;
    transform: translate(2px, -2px) scale(0.92);
  }

  .stack-icon :global(.site-favicon) {
    position: relative;
    z-index: 1;
  }

  .stack-name {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
    font-size: var(--font-size-md);
    line-height: 1.3;
    color: var(--text-primary);
  }

  /* A plain number, not a pill: a pill would read as unread items. */
  .stack-count {
    flex: none;
    font-size: var(--font-size-sm);
    font-variant-numeric: tabular-nums;
    color: var(--text-muted);
  }

  .stack-chevron {
    flex: none;
    display: grid;
    place-items: center;
    width: 20px;
    height: 20px;
    margin-left: -4px;
    color: var(--text-muted);
    transition: transform var(--motion-duration-normal) var(--motion-ease-spring);
  }

  .open .stack-chevron {
    transform: rotate(90deg);
  }

  /* The close button takes the chevron's place on hover: the row itself still opens the stack. */
  .stack-close {
    position: absolute;
    right: 8px;
    background: transparent;
    color: var(--text-muted);
    opacity: 0;
    transform: scale(0.8);
    pointer-events: none;
    transition:
      background var(--transition-fast),
      color var(--transition-fast),
      opacity var(--transition-fast),
      transform var(--transition-fast);
  }

  .stack-row:hover .stack-close {
    opacity: 1;
    transform: none;
    pointer-events: auto;
  }

  .stack-row:hover .stack-chevron {
    opacity: 0;
  }

  .stack-close:hover {
    background: var(--text-primary-tint-12);
    color: var(--text-primary);
  }

  .stack-close:active {
    background: color-mix(in srgb, var(--text-primary) 18%, transparent);
  }

  @media (prefers-reduced-motion: reduce) {
    .stack-chevron {
      transition: none;
    }
  }
</style>
