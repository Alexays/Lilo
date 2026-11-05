<!-- A default button carrying the variants of its choice ("always", "for this site") in a menu
     attached to it, rather than as more buttons beside it. -->
<script lang="ts">
  import type { Snippet } from "svelte";
  import { dismissable } from "../../lib/actions/dismissable";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { portal } from "../../lib/actions/portal";

  interface Props {
    /** Names the chevron to VoiceOver ("More ways to answer"). */
    menuLabel: string;
    variants: { label: string; onclick: () => void }[];
    disabled?: boolean;
    onclick: () => void;
    children: Snippet;
  }

  let { menuLabel, variants, disabled = false, onclick, children }: Props = $props();

  const menuId = $props.id();
  const MARGIN = 8;
  let open = $state(false);
  let root: HTMLDivElement | undefined = $state();
  let chevron: HTMLButtonElement | undefined = $state();
  let menu: HTMLDivElement | undefined = $state();
  // Right-aligned under the button, or above it when there is no room below.
  let position = $state({ right: 0, top: 0, bottom: 0, up: false });

  function toggle(): void {
    if (!open && root) {
      const rect = root.getBoundingClientRect();
      position = {
        right: Math.max(MARGIN, window.innerWidth - rect.right),
        top: rect.bottom + 4,
        bottom: window.innerHeight - rect.top + 4,
        up: rect.bottom + 120 > window.innerHeight,
      };
    }
    open = !open;
  }

  $effect(() => {
    menu?.querySelector<HTMLElement>("[role='menuitem']")?.focus();
  });

  function handleKeydown(event: KeyboardEvent): void {
    if (event.key === "Escape") {
      // The menu, not the drawer or card around it, takes this Escape.
      event.preventDefault();
      event.stopPropagation();
      open = false;
      chevron?.focus();
      return;
    }
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    const items = Array.from(menu?.querySelectorAll<HTMLElement>("[role='menuitem']") ?? []);
    const index = items.indexOf(document.activeElement as HTMLElement);
    event.preventDefault();
    items[(index + (event.key === "ArrowDown" ? 1 : -1) + items.length) % items.length]?.focus();
  }
</script>

<div class="ui-split-button" class:open bind:this={root}>
  <button type="button" class="main" {disabled} {onclick}>{@render children()}</button>
  <button
    type="button"
    class="chevron"
    data-split-menu={menuId}
    aria-label={menuLabel}
    aria-haspopup="menu"
    aria-expanded={open}
    aria-controls={open ? menuId : undefined}
    {disabled}
    bind:this={chevron}
    onclick={(event) => {
      event.stopPropagation();
      toggle();
    }}
  >
    <svg width="8" height="8" viewBox="0 0 8 8" aria-hidden="true">
      <path d="M1 2.75l3 3 3-3" stroke="currentColor" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  </button>
</div>

{#if open}
  <div
    id={menuId}
    class="ui-split-menu float-surface float-popover"
    class:up={position.up}
    role="menu"
    tabindex="-1"
    aria-label={menuLabel}
    style:right="{position.right}px"
    style:top={position.up ? undefined : `${position.top}px`}
    style:bottom={position.up ? `${position.bottom}px` : undefined}
    bind:this={menu}
    use:portal
    use:reportInteractiveZone={{ id: `split-${menuId}` }}
    onkeydown={handleKeydown}
    {@attach dismissable({ onDismiss: () => (open = false), ignore: `[data-split-menu="${menuId}"]`, returnFocus: chevron })}
  >
    {#each variants as variant (variant.label)}
      <button
        type="button"
        class="float-row"
        role="menuitem"
        onclick={(event) => {
          event.stopPropagation();
          open = false;
          variant.onclick();
        }}
      >{variant.label}</button>
    {/each}
  </div>
{/if}

<style>
  .ui-split-button {
    display: inline-flex;
    flex: none;
    max-width: 100%;
    height: var(--control-height-sm);
    border-radius: var(--radius-sm);
    background: var(--accent);
    color: var(--accent-text);
  }

  .ui-split-button button {
    border: 0;
    background: transparent;
    color: inherit;
    font-family: inherit;
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .main {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    min-width: 0;
    padding: 0 var(--space-10);
    border-radius: var(--radius-sm) 0 0 var(--radius-sm);
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-medium);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .chevron {
    flex: none;
    display: grid;
    place-items: center;
    width: 20px;
    padding: 0;
    border-radius: 0 var(--radius-sm) var(--radius-sm) 0;
    box-shadow: inset 1px 0 0 color-mix(in srgb, var(--accent-text) 30%, transparent);
  }

  .ui-split-button button:not(:disabled):hover,
  .ui-split-button.open .chevron {
    background: var(--accent-hover);
  }

  .ui-split-button button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .ui-split-button button:disabled {
    cursor: default;
    opacity: var(--disabled-opacity);
  }

  .ui-split-menu {
    position: fixed;
    z-index: var(--z-popover);
    min-width: 160px;
    max-width: 280px;
    transform-origin: top right;
  }

  .ui-split-menu.up {
    transform-origin: bottom right;
  }

  .ui-split-menu .float-row {
    font-size: var(--font-size-sm);
    white-space: nowrap;
  }
</style>
