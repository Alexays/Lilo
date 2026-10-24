<script lang="ts">
  interface UiSelectOption {
    value: string;
    label: string;
  }

  interface Props {
    value?: string;
    options: UiSelectOption[];
    ariaLabel?: string;
    onchange?: (value: string) => void;
  }

  let {
    value = "",
    options,
    ariaLabel,
    onchange,
  }: Props = $props();

  function handleChange(event: Event): void {
    value = event.currentTarget instanceof HTMLSelectElement ? event.currentTarget.value : value;
    onchange?.(value);
  }
</script>

<!-- Block-level so a form field stretches it; a row action (flex: none) sizes it to the label. -->
<span class="ui-select">
  <select
    bind:value
    aria-label={ariaLabel}
    onchange={handleChange}
  >
    {#each options as option (option.value)}
      <option value={option.value}>
        {option.label}
      </option>
    {/each}
  </select>
</span>

<style>
  .ui-select {
    position: relative;
    display: grid;
  }

  .ui-select select {
    width: 100%;
    height: var(--control-height-md);
    appearance: none;
    border: 0;
    border-radius: var(--radius-md);
    background: var(--bg-hover);
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-md);
    padding: 0 var(--space-24) 0 var(--space-10);
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .ui-select select:hover {
    background: var(--text-primary-tint-10);
  }

  .ui-select::after {
    content: "";
    position: absolute;
    right: 11px;
    top: 50%;
    width: 5px;
    height: 5px;
    margin-top: -4px;
    border-right: 1.5px solid var(--text-secondary);
    border-bottom: 1.5px solid var(--text-secondary);
    transform: rotate(45deg);
    pointer-events: none;
  }

  .ui-select select:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }
</style>
