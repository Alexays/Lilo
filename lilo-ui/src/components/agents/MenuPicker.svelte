<script lang="ts" module>
  import type { TerminalProgramIcon } from "../../lib/terminalIcons";
  import type { IconName } from "./icons";

  export interface MenuOption {
    value: string;
    label: string;
    /** Options with a `group` are listed under that heading. */
    group?: string;
    detail?: string;
    icon?: IconName;
    logo?: TerminalProgramIcon;
    agentId?: string;
    /** Shown checked, for a menu whose `value` does not name its choice (several settings in one menu). */
    checked?: boolean;
  }
</script>

<script lang="ts">
  import type { Snippet } from "svelte";
  import { fade } from "svelte/transition";
  import { dismissable } from "../../lib/actions/dismissable";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { portal } from "../../lib/actions/portal";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import AgentTile from "./AgentTile.svelte";
  import Icon from "./Icon.svelte";

  interface Props {
    value: string;
    options: MenuOption[];
    ariaLabel: string;
    onchange: (value: string) => void;
    children: Snippet;
  }

  let { value, options, ariaLabel, onchange, children }: Props = $props();

  const MARGIN = 8;
  const menuId = $props.id();
  let open = $state(false);
  let buttonEl: HTMLButtonElement | undefined = $state();
  let menuEl: HTMLDivElement | undefined = $state();
  // Read when it opens: above the button when there is no room below, as at the composer.
  let position = $state({ left: 0, top: 0, bottom: 0, up: false });

  function toggle(): void {
    if (!open && buttonEl) {
      const rect = buttonEl.getBoundingClientRect();
      const up = rect.top > window.innerHeight / 2;
      position = {
        left: Math.max(MARGIN, Math.min(rect.left, window.innerWidth - 260 - MARGIN)),
        top: rect.bottom + 6,
        bottom: window.innerHeight - rect.top + 6,
        up,
      };
    }
    open = !open;
  }

  $effect(() => {
    if (!menuEl) return;
    (menuEl.querySelector<HTMLElement>("[aria-checked='true']") ?? menuEl.querySelector<HTMLElement>("[role='menuitemradio']"))?.focus();
  });

  function choose(option: MenuOption): void {
    open = false;
    buttonEl?.focus();
    if (option.value !== value) onchange(option.value);
  }

  function handleKeydown(event: KeyboardEvent): void {
    if (event.key === "Escape") {
      event.preventDefault();
      open = false;
      buttonEl?.focus();
      return;
    }
    const rows = Array.from(menuEl?.querySelectorAll<HTMLElement>("[role='menuitemradio']") ?? []);
    const index = rows.indexOf(document.activeElement as HTMLElement);
    const next =
      event.key === "ArrowDown" ? (index + 1) % rows.length
      : event.key === "ArrowUp" ? (index - 1 + rows.length) % rows.length
      : event.key === "Home" ? 0
      : event.key === "End" ? rows.length - 1
      : -1;
    if (next < 0 || rows.length === 0) return;
    event.preventDefault();
    rows[next]?.focus();
  }
</script>

{#snippet glyph(option: MenuOption)}
  {#if option.logo}
    <svg class="logo" viewBox="0 0 24 24" aria-hidden="true" style:color={option.logo.color}><path d={option.logo.path} /></svg>
  {:else if option.agentId}
    <AgentTile agentId={option.agentId} />
  {:else if option.icon}
    <Icon name={option.icon} size={14} />
  {/if}
{/snippet}

<button
  type="button"
  class="menu-picker"
  class:open
  bind:this={buttonEl}
  aria-label={ariaLabel}
  aria-haspopup="menu"
  aria-expanded={open}
  aria-controls={open ? menuId : undefined}
  data-menu-picker={menuId}
  onclick={toggle}
>
  <!-- A new choice fades its label in; only a change plays it, never the first draw. -->
  {#key value}
    <span class="label" in:fade={{ duration: prefersReducedMotion() ? 0 : 160 }}>{@render children()}</span>
  {/key}
  <svg class="chevron" width="8" height="8" viewBox="0 0 8 8" aria-hidden="true">
    <path d="M1 3l3 3 3-3" stroke="currentColor" fill="none" stroke-width="1.4" />
  </svg>
</button>

{#if open}
  <div
    id={menuId}
    class="menu float-surface float-popover"
    class:up={position.up}
    role="menu"
    tabindex="-1"
    aria-label={ariaLabel}
    style:left="{position.left}px"
    style:top={position.up ? undefined : `${position.top}px`}
    style:bottom={position.up ? `${position.bottom}px` : undefined}
    bind:this={menuEl}
    use:portal
    use:reportInteractiveZone={{ id: `menu-${menuId}` }}
    onkeydown={handleKeydown}
    {@attach dismissable({ onDismiss: () => (open = false), ignore: `[data-menu-picker="${menuId}"]`, returnFocus: buttonEl })}
  >
    {#each options as option, index (option.value)}
      {#if option.group && option.group !== options[index - 1]?.group}
        <div class="group">{option.group}</div>
      {/if}
      {@const checked = option.checked ?? option.value === value}
      <button type="button" class="float-row item" role="menuitemradio" aria-checked={checked} onclick={() => choose(option)}>
        <span class="glyph">{@render glyph(option)}</span>
        <span class="text">
          <span class="name">{option.label}</span>
          {#if option.detail}<span class="detail">{option.detail}</span>{/if}
        </span>
        {#if checked}<span class="check"><Icon name="check" size={12} /></span>{/if}
      </button>
    {/each}
  </div>
{/if}

<style>
  .menu-picker {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    min-width: 0;
    height: var(--control-height-sm);
    padding: 0 var(--space-8);
    border: none;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-secondary);
    font: inherit;
    font-size: var(--font-size-sm);
    white-space: nowrap;
    cursor: pointer;
    transition: background var(--transition-fast), color var(--transition-fast);
  }

  .menu-picker:hover,
  .menu-picker.open {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .menu-picker:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .label {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    min-width: 0;
  }

  .chevron {
    flex: none;
    opacity: 0.7;
  }

  .menu {
    position: fixed;
    z-index: var(--z-popover);
    min-width: 200px;
    max-width: 260px;
    max-height: 60vh;
    overflow-y: auto;
    transform-origin: top left;
  }

  .menu.up {
    transform-origin: bottom left;
  }

  .group {
    padding: var(--space-6) var(--space-8) var(--space-2);
    color: var(--float-text-muted);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
  }

  .item {
    border: none;
    background: transparent;
    color: var(--float-text);
    font: inherit;
    text-align: left;
    cursor: pointer;
  }

  .item:hover,
  .item:focus-visible {
    background: var(--float-hover);
    outline: none;
  }

  .glyph {
    flex: none;
    width: 16px;
    height: 16px;
    display: grid;
    place-items: center;
    color: var(--float-text-secondary);
  }

  .logo {
    width: 14px;
    height: 14px;
    fill: currentColor;
  }

  .text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
  }

  .name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: var(--font-size-md);
  }

  .detail {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--float-text-muted);
    font-size: var(--font-size-xs);
  }

  .check {
    flex: none;
    display: grid;
    color: var(--accent-ink);
  }
</style>
