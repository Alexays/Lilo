<script lang="ts">
  import { tooltip } from "../../lib/tooltip";

  interface Option {
    value: string;
    label: string;
    /** SVG path (16x16 box) shown in place of the label when compact. */
    icon?: string;
  }

  interface Props {
    value: string;
    options: Option[];
    ariaLabel: string;
    onchange: (value: string) => void;
    /** Too narrow for the labels: options with an icon show it, their label as a tooltip. */
    compact?: boolean;
    disabled?: boolean;
  }

  let { value, options, ariaLabel, onchange, compact = false, disabled = false }: Props = $props();

  function handleKeydown(event: KeyboardEvent): void {
    const step = event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
    if (step === 0) return;
    event.preventDefault();
    const index = options.findIndex((option) => option.value === value);
    const next = options[(index + step + options.length) % options.length];
    onchange(next.value);
    const buttons = (event.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>("button");
    buttons[options.indexOf(next)]?.focus();
  }
</script>

<div class="ui-segmented" role="radiogroup" aria-label={ariaLabel} tabindex="-1" onkeydown={handleKeydown}>
  {#each options as option (option.value)}
    <button
      type="button"
      role="radio"
      aria-checked={option.value === value}
      tabindex={option.value === value ? 0 : -1}
      class:active={option.value === value}
      {disabled}
      aria-label={compact && option.icon ? option.label : undefined}
      use:tooltip={{ text: option.label, disabled: !(compact && option.icon) }}
      onclick={() => onchange(option.value)}
    >
      {#if compact && option.icon}
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={option.icon} /></svg>
      {:else}
        {option.label}
      {/if}
    </button>
  {/each}
</div>

<style>
  .ui-segmented {
    display: inline-flex;
    flex: none;
    gap: var(--space-2);
    padding: var(--space-2);
    border-radius: var(--radius-md);
    background: var(--bg-hover);
  }

  .ui-segmented button {
    min-height: var(--control-height-sm);
    padding: 0 var(--space-10);
    border: 0;
    border-radius: calc(var(--radius-md) - var(--space-2));
    background: transparent;
    /* Primary, not secondary: the track's tint takes secondary text under AA. The pill marks the choice. */
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-md);
    white-space: nowrap;
    cursor: pointer;
    transition:
      background var(--transition-fast),
      color var(--transition-fast),
      box-shadow var(--transition-fast);
  }

  /* The sidebar's active-tab pill. */
  .ui-segmented button.active {
    background: var(--bg-active);
    color: var(--text-primary);
    box-shadow:
      0 0 0 1px color-mix(in srgb, var(--bg-active) 54%, transparent),
      var(--shadow-control);
  }

  .ui-segmented button:disabled {
    opacity: var(--disabled-opacity);
    cursor: default;
  }

  .ui-segmented button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }
</style>
