<script lang="ts">
  import type { Snippet } from "svelte";
  import UiListRow from "./UiListRow.svelte";

  interface Props {
    title: string;
    description?: string;
    /** Shown before the chevron: how many entries the page behind holds. */
    count?: number;
    icon?: Snippet;
    /** Set on a row that folds content open under it: the chevron then turns down while open. */
    expanded?: boolean;
    onclick: () => void;
  }

  let { title, description, count = 0, icon, expanded, onclick }: Props = $props();
</script>

<!-- A row that opens a page: the whole row is the button, ending with a chevron. -->
<button class="ui-link-row" type="button" aria-expanded={expanded} {onclick}>
  <UiListRow {title} {description} {icon}>
    {#snippet action()}
      {#if count > 0}<span class="ui-link-row-count">{count}</span>{/if}
      <svg class="ui-link-row-chevron" class:open={expanded} width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
        <path d="m4.5 2.5 3.5 3.5-3.5 3.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    {/snippet}
  </UiListRow>
</button>

<style>
  .ui-link-row {
    display: block;
    width: 100%;
    padding: 0 var(--space-8);
    margin: 0 calc(-1 * var(--space-8));
    box-sizing: content-box;
    border: 0;
    border-radius: var(--radius-md);
    background: transparent;
    color: inherit;
    font: inherit;
    text-align: left;
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .ui-link-row:hover {
    background: var(--bg-hover);
  }

  .ui-link-row:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .ui-link-row-count {
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    font-variant-numeric: tabular-nums;
  }

  .ui-link-row-chevron {
    color: var(--text-muted);
    transition: transform var(--transition-fast);
  }

  .ui-link-row-chevron.open {
    transform: rotate(90deg);
  }

  @media (prefers-reduced-motion: reduce) {
    .ui-link-row-chevron {
      transition: none;
    }
  }
</style>
