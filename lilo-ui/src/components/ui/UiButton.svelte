<script lang="ts">
  import type { Snippet } from "svelte";

  interface Props {
    variant?: "primary" | "secondary" | "ghost" | "danger";
    disabled?: boolean;
    onclick?: (event: MouseEvent) => void;
    children?: Snippet;
  }

  let {
    variant = "secondary",
    disabled = false,
    onclick,
    children,
  }: Props = $props();
</script>

<button
  class="ui-button"
  class:primary={variant === "primary"}
  class:ghost={variant === "ghost"}
  class:danger={variant === "danger"}
  type="button"
  {disabled}
  {onclick}
>
  {@render children?.()}
</button>

<style>
  .ui-button {
    min-height: var(--control-height-md);
    border: 0;
    border-radius: var(--radius-md);
    background: var(--bg-hover);
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
    padding: 0 var(--space-12);
    /* Clipping would let a flex row shrink it under its label: it only ever gives way to max-width. */
    flex-shrink: 0;
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    cursor: pointer;
    transition:
      background var(--transition-fast),
      color var(--transition-fast);
  }

  .ui-button:not(:disabled):hover {
    background: var(--text-primary-tint-12);
  }

  .ui-button.primary {
    background: var(--accent);
    color: var(--accent-text);
  }

  .ui-button.primary:not(:disabled):hover {
    background: var(--accent-hover);
  }

  .ui-button.ghost {
    background: transparent;
    color: var(--text-secondary);
  }

  .ui-button.ghost:not(:disabled):hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .ui-button.danger {
    background: color-mix(in srgb, var(--danger) 12%, transparent);
    color: var(--danger-text);
  }

  .ui-button.danger:not(:disabled):hover {
    background: color-mix(in srgb, var(--danger) 18%, transparent);
  }

  .ui-button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .ui-button:disabled {
    opacity: var(--disabled-opacity);
    cursor: default;
  }
</style>
