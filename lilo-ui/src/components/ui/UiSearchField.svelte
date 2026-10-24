<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";

  interface Props {
    value?: string;
    placeholder?: string;
    ariaLabel?: string;
    onchange?: (value: string) => void;
  }

  let {
    value = "",
    placeholder,
    ariaLabel,
    onchange,
  }: Props = $props();

  function handleInput(event: Event): void {
    value = event.currentTarget instanceof HTMLInputElement ? event.currentTarget.value : value;
    onchange?.(value);
  }

  function clearSearch(): void {
    value = "";
    onchange?.(value);
  }
</script>

<label class="ui-search-field">
  <span class="ui-search-field-icon" aria-hidden="true">
    <svg width="13" height="13" viewBox="0 0 13 13" fill="none">
      <circle cx="5.7" cy="5.7" r="3.6" stroke="currentColor" stroke-width="1.4" />
      <path d="M8.45 8.45L11 11" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
    </svg>
  </span>
  <input
    type="search"
    bind:value
    placeholder={placeholder ?? t("common.search")}
    aria-label={ariaLabel ?? t("common.search")}
    oninput={handleInput}
  />
  <button
    class="ui-search-field-clear"
    class:visible={value.length > 0}
    type="button"
    disabled={value.length === 0}
    aria-label={t("common.clearSearch")}
    onclick={clearSearch}
  ></button>
</label>

<style>
  .ui-search-field {
    display: grid;
    grid-template-columns: 16px minmax(0, 1fr) 20px;
    align-items: center;
    gap: var(--space-8);
    width: 100%;
    min-height: var(--control-height-lg);
    box-sizing: border-box;
    border-radius: var(--radius-md);
    border: 0;
    background: var(--bg-hover);
    color: var(--text-muted);
    padding: 0 var(--space-8);
  }

  .ui-search-field input {
    min-width: 0;
    height: 20px;
    appearance: none;
    border: 0;
    outline: 0;
    background: transparent;
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-md);
    line-height: 20px;
    padding: 0;
    text-overflow: ellipsis;
  }

  .ui-search-field input::-webkit-search-cancel-button {
    appearance: none;
    display: none;
  }

  .ui-search-field-icon {
    display: grid;
    place-items: center;
    width: 16px;
    height: 20px;
    line-height: 0;
  }

  .ui-search-field-icon svg {
    display: block;
  }

  .ui-search-field-clear {
    display: grid;
    place-items: center;
    width: 18px;
    height: 18px;
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--text-muted);
    padding: 0;
    cursor: pointer;
    opacity: 0;
    transform: scale(0.72);
    pointer-events: none;
    transition:
      opacity var(--transition-fast),
      transform var(--transition-fast),
      background var(--transition-fast),
      color var(--transition-fast);
  }

  .ui-search-field-clear::before,
  .ui-search-field-clear::after {
    content: "";
    grid-area: 1 / 1;
    width: 9px;
    height: 1.5px;
    border-radius: var(--radius-chip);
    background: currentColor;
  }

  .ui-search-field-clear::before {
    transform: rotate(45deg);
  }

  .ui-search-field-clear::after {
    transform: rotate(-45deg);
  }

  .ui-search-field-clear.visible {
    opacity: 1;
    transform: scale(1);
    pointer-events: auto;
  }

  .ui-search-field-clear:hover {
    background: var(--text-primary-tint-10);
    color: var(--text-primary);
  }

  .ui-search-field input::placeholder {
    color: var(--text-muted);
  }

  .ui-search-field:focus-within {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  @media (prefers-reduced-motion: reduce) {
    .ui-search-field-clear {
      transition: none;
    }
  }
</style>
