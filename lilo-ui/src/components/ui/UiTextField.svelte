<script lang="ts">
  interface Props {
    value?: string;
    placeholder?: string;
    ariaLabel?: string;
    type?: "text" | "email" | "password" | "url";
    onchange?: (value: string) => void;
    /** Fires once the edit is done: on Enter or when the field loses focus. */
    oncommit?: (value: string) => void;
  }

  let {
    value = "",
    placeholder = "",
    ariaLabel,
    type = "text",
    onchange,
    oncommit,
  }: Props = $props();

  function handleInput(event: Event): void {
    value = event.currentTarget instanceof HTMLInputElement ? event.currentTarget.value : value;
    onchange?.(value);
  }
</script>

<input
  class="ui-text-field"
  {type}
  bind:value
  {placeholder}
  aria-label={ariaLabel}
  oninput={handleInput}
  onchange={() => oncommit?.(value)}
/>

<style>
  .ui-text-field {
    width: 100%;
    height: var(--control-height-lg);
    min-height: var(--control-height-lg);
    box-sizing: border-box;
    border-radius: var(--radius-md);
    border: 1px solid var(--text-primary-tint-12);
    background: color-mix(in srgb, var(--bg-primary) 92%, transparent);
    color: var(--text-primary);
    font-size: var(--font-size-md);
    padding: var(--space-6) var(--space-10);
  }

  .ui-text-field::placeholder {
    color: var(--text-muted);
  }

  .ui-text-field:focus {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }
</style>
