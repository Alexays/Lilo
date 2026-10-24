<script lang="ts">
  import type { Snippet } from "svelte";

  interface Props {
    variant?: "primary" | "secondary" | "ghost" | "danger";
    disabled?: boolean;
    /** Waiting on what the click started: a spinner, and no second click. */
    busy?: boolean;
    onclick?: (event: MouseEvent) => void;
    children?: Snippet;
  }

  let {
    variant = "secondary",
    disabled = false,
    busy = false,
    onclick,
    children,
  }: Props = $props();
</script>

<button
  class="ui-button"
  class:primary={variant === "primary"}
  class:ghost={variant === "ghost"}
  class:danger={variant === "danger"}
  class:busy
  type="button"
  disabled={disabled || busy}
  aria-busy={busy}
  {onclick}
>
  {#if busy}<span class="ui-button-spinner" aria-hidden="true"></span>{/if}
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

  .ui-button:disabled:not(.busy) {
    opacity: var(--disabled-opacity);
  }

  .ui-button:disabled {
    cursor: default;
  }

  .ui-button.busy {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
  }

  .ui-button-spinner {
    width: 0.8em;
    height: 0.8em;
    border: 0.15em solid currentColor;
    border-right-color: transparent;
    border-radius: 50%;
    animation: ui-button-spin 0.8s linear infinite;
  }

  @keyframes ui-button-spin {
    to {
      transform: rotate(360deg);
    }
  }
</style>
