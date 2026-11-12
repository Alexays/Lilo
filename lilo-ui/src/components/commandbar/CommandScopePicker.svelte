<script lang="ts">
  import { dismissable } from "../../lib/actions/dismissable";
  import { menuKeys } from "../../lib/actions/menuKeys";
  import { portal } from "../../lib/actions/portal";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { popoverOut } from "../../lib/motion/restingTransitions";
  import type { CommandScope } from "../../lib/inputParser";
  import { LINE_ICONS } from "./commandBarIcons";

  let { hints, active, disabled, onselect }: {
    hints: { scope: CommandScope; label: string; prefix: string }[];
    active: CommandScope;
    disabled: boolean;
    onselect: (scope: CommandScope) => void;
  } = $props();

  const ICONS: Record<CommandScope, string> = {
    all: "find", action: "sparkle", terminal: "terminal", tab: "duplicate",
    bookmark: "star", history: "history", archive: "undo",
  };
  const id = $props.id();
  let open = $state(false);
  let button: HTMLButtonElement | undefined = $state();
  let menu: HTMLDivElement | undefined = $state();
  let position = $state({ left: 0, top: 0 });
  const label = $derived(hints.find((hint) => hint.scope === active)?.label ?? "");

  function toggle() {
    if (!open && button) {
      const rect = button.getBoundingClientRect();
      position = { left: Math.max(8, Math.min(rect.left, window.innerWidth - 224)), top: rect.bottom + 8 };
    }
    open = !open;
  }

  $effect(() => {
    if (menu) {
      (menu.querySelector<HTMLButtonElement>('[aria-checked="true"]') ?? menu.querySelector<HTMLButtonElement>("button"))?.focus();
    }
  });

  function handleKeydown(event: KeyboardEvent) {
    if (event.key !== "Escape" && event.key !== "Tab") return;
    event.preventDefault();
    event.stopPropagation();
    open = false;
    button?.focus();
  }
</script>

<button
  bind:this={button}
  type="button"
  class="scope-picker"
  class:active={active !== "all"}
  data-scope-picker={id}
  aria-label={label}
  title={label}
  aria-haspopup="menu"
  aria-expanded={open}
  aria-controls={open ? id : undefined}
  {disabled}
  onclick={toggle}
  onkeydown={(event) => {
    if (event.key === "ArrowDown" && !open) {
      event.preventDefault();
      event.stopPropagation();
      toggle();
    }
  }}
>
  <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
    <path d={LINE_ICONS[ICONS[active]]} stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" />
  </svg>
  <svg width="8" height="8" viewBox="0 0 8 8" fill="none" aria-hidden="true"><path d="m2 3 2 2 2-2" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" /></svg>
</button>

{#if open}
  <div
    bind:this={menu}
    id={id}
    class="scope-menu float-surface float-popover"
    data-command-bar-popover
    role="menu"
    tabindex="-1"
    aria-label={label}
    style:left="{position.left}px"
    style:top="{position.top}px"
    style:max-height="calc(100dvh - {position.top + 16}px)"
    use:portal
    use:reportInteractiveZone={{ id: `scope-${id}` }}
    out:popoverOut
    onkeydown={handleKeydown}
    {@attach menuKeys}
    {@attach dismissable({ onDismiss: () => (open = false), ignore: `[data-scope-picker="${id}"]`, returnFocus: button })}
  >
    {#each hints as hint (hint.scope)}
      <button
        type="button"
        class="float-row scope-row"
        role="menuitemradio"
        aria-checked={active === hint.scope}
        onclick={() => { open = false; onselect(hint.scope); }}
      >
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d={LINE_ICONS[ICONS[hint.scope]]} stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" /></svg>
        <span class="scope-label">{hint.label}</span>
        {#if hint.prefix}<span class="scope-prefix" aria-hidden="true">{hint.prefix}</span>{/if}
        <span class="scope-check" aria-hidden="true">{active === hint.scope ? "✓" : ""}</span>
      </button>
    {/each}
  </div>
{/if}

<style>
  .scope-picker {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 4px;
    flex: none;
    width: 40px;
    height: 28px;
    margin-left: -8px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-secondary);
    cursor: pointer;
  }
  .scope-picker:hover, .scope-picker[aria-expanded="true"] { background: var(--bg-hover); }
  .scope-picker.active { color: var(--accent-ink); }
  .scope-picker:focus-visible { outline: var(--focus-outline); }
  .scope-picker:disabled { opacity: var(--disabled-opacity); cursor: default; }
  .scope-menu {
    position: fixed;
    z-index: var(--z-popover);
    width: 216px;
    overflow-y: auto;
    transform-origin: top left;
  }
  .scope-menu { scrollbar-gutter: stable; }
  .scope-menu::-webkit-scrollbar { width: 8px; background: transparent; }
  .scope-menu::-webkit-scrollbar-thumb {
    background: color-mix(in srgb, var(--text-secondary) 32%, transparent);
    border: 2px solid transparent;
    border-radius: var(--radius-chip);
    background-clip: padding-box;
  }
  .scope-menu::-webkit-scrollbar-thumb:hover { background-color: color-mix(in srgb, var(--text-secondary) 55%, transparent); }
  .scope-row { display: flex; align-items: center; gap: 8px; }
  .scope-label { flex: 1; }
  .scope-prefix { color: var(--text-secondary); font-size: var(--font-size-sm); }
  .scope-check { width: 12px; color: var(--accent-ink); }
</style>
