<script lang="ts">
  interface Props {
    label: string;
    /** Names the remove button for assistive tech. */
    removeLabel: string;
    onremove: () => void;
  }

  let { label, removeLabel, onremove }: Props = $props();
</script>

<!-- A removable value, like the extension page's site chips. -->
<span class="ui-chip">
  {label}
  <button class="ui-chip-remove" type="button" aria-label={removeLabel} onclick={onremove}>
    <svg width="8" height="8" viewBox="0 0 8 8" fill="none" aria-hidden="true">
      <path d="M1 1l6 6M7 1L1 7" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
    </svg>
  </button>
</span>

<style>
  .ui-chip {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    min-height: 22px;
    padding: 0 var(--space-4) 0 var(--space-8);
    border-radius: var(--radius-sm);
    background: var(--bg-hover);
    color: var(--text-primary);
    font-size: var(--font-size-sm);
    overflow-wrap: anywhere;
  }

  .ui-chip-remove {
    display: inline-grid;
    place-items: center;
    flex: none;
    width: 16px;
    height: 16px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-xs);
    background: none;
    color: var(--text-muted);
    cursor: pointer;
  }

  .ui-chip-remove:hover {
    background: var(--bg-active);
    color: var(--text-primary);
  }

  .ui-chip-remove:focus-visible {
    outline: var(--focus-outline);
  }
</style>
