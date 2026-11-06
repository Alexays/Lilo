<!-- A screen's commands behind one "..." button: a destructive one comes last, under a separator, in red. -->
<script lang="ts">
  import { dismissable } from "../../lib/actions/dismissable";
  import { menuKeys } from "../../lib/actions/menuKeys";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { portal } from "../../lib/actions/portal";
  import { tooltip } from "../../lib/tooltip";
  import { popoverOut } from "../../lib/motion/restingTransitions";

  interface Props {
    label: string;
    items: { label: string; onclick: () => void; danger?: boolean; disabled?: boolean }[];
  }

  let { label, items }: Props = $props();

  const menuId = $props.id();
  let open = $state(false);
  let button: HTMLButtonElement | undefined = $state();
  let menu: HTMLDivElement | undefined = $state();
  let position = $state({ right: 0, top: 0 });

  function toggle(): void {
    if (!open && button) {
      const rect = button.getBoundingClientRect();
      position = { right: Math.max(8, window.innerWidth - rect.right), top: rect.bottom + 4 };
    }
    open = !open;
  }

  $effect(() => {
    menu?.querySelector<HTMLElement>("[role='menuitem']:not(:disabled)")?.focus();
  });

  function handleKeydown(event: KeyboardEvent): void {
    if (event.key !== "Escape") return;
    // The menu, not the screen around it, takes this Escape.
    event.preventDefault();
    event.stopPropagation();
    open = false;
    button?.focus();
  }
</script>

<button
  type="button"
  class="ui-more-button"
  data-more-menu={menuId}
  aria-label={label}
  aria-haspopup="menu"
  aria-expanded={open}
  aria-controls={open ? menuId : undefined}
  use:tooltip={{ text: label, placement: "bottom" }}
  bind:this={button}
  onclick={toggle}
>
  <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
    <circle cx="3.5" cy="8" r="1.4" /><circle cx="8" cy="8" r="1.4" /><circle cx="12.5" cy="8" r="1.4" />
  </svg>
</button>

{#if open}
  <div
    id={menuId}
    class="ui-more-menu float-surface float-popover"
    out:popoverOut
    role="menu"
    tabindex="-1"
    aria-label={label}
    style:right="{position.right}px"
    style:top="{position.top}px"
    bind:this={menu}
    use:portal
    use:reportInteractiveZone={{ id: `more-${menuId}` }}
    onkeydown={handleKeydown}
    {@attach menuKeys}
    {@attach dismissable({ onDismiss: () => (open = false), ignore: `[data-more-menu="${menuId}"]`, returnFocus: button })}
  >
    {#each items as item (item.label)}
      {#if item.danger}<div class="separator" role="separator"></div>{/if}
      <button
        type="button"
        class="float-row"
        class:danger={item.danger}
        role="menuitem"
        disabled={item.disabled}
        onclick={() => {
          open = false;
          item.onclick();
        }}
      >{item.label}</button>
    {/each}
  </div>
{/if}

<style>
  .ui-more-button {
    flex: none;
    display: grid;
    place-items: center;
    width: 28px;
    height: 28px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-secondary);
    cursor: pointer;
    transition: background var(--transition-fast), color var(--transition-fast);
  }

  .ui-more-button:hover,
  .ui-more-button[aria-expanded="true"] {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .ui-more-button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .ui-more-menu {
    position: fixed;
    z-index: var(--z-popover);
    min-width: 200px;
    max-width: 280px;
    transform-origin: top right;
  }

  .ui-more-menu .float-row {
    white-space: nowrap;
  }

  .ui-more-menu .float-row.danger {
    color: var(--danger-text);
  }

  .ui-more-menu .float-row:disabled {
    opacity: var(--disabled-opacity);
    cursor: default;
    background: transparent;
  }

  .separator {
    height: 1px;
    margin: 4px 8px;
    background: var(--separator);
  }
</style>
