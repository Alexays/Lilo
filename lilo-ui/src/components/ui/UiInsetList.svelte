<script lang="ts">
  import type { Snippet } from "svelte";

  interface Props {
    title?: string;
    /** A decorative glyph before the title. */
    icon?: Snippet;
    children?: Snippet;
  }

  let { title, icon, children }: Props = $props();
</script>

<section class="ui-inset-list" aria-label={title}>
  {#if title}
    <h3 class="ui-inset-list-title">
      {#if icon}<span class="ui-inset-list-icon" aria-hidden="true">{@render icon()}</span>{/if}{title}
    </h3>
  {/if}
  <div class="ui-inset-list-body">
    {@render children?.()}
  </div>
</section>

<style>
  .ui-inset-list {
    display: grid;
    gap: 2px;
  }

  /* Same voice as the sidebar's space label. */
  .ui-inset-list-title {
    display: flex;
    align-items: center;
    gap: var(--space-6);
    margin: 0;
    padding-bottom: 2px;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    letter-spacing: 0.5px;
    text-transform: uppercase;
  }

  /* No height of its own, the icon centered on the text: a title keeps its height with or without one. */
  .ui-inset-list-icon {
    display: flex;
    align-items: center;
    height: 0;
  }

  .ui-inset-list-body {
    display: grid;
  }

  .ui-inset-list-body > :global(* + *) {
    border-top: 1px solid var(--separator);
  }
</style>
