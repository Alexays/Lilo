<script lang="ts">
  import type { Snippet } from "svelte";

  interface Props {
    title?: string;
    children?: Snippet;
  }

  let { title, children }: Props = $props();
</script>

<section class="ui-inset-list" aria-label={title}>
  {#if title}
    <h3 class="ui-inset-list-title">{title}</h3>
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
    margin: 0;
    padding-bottom: 2px;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    letter-spacing: 0.5px;
    text-transform: uppercase;
  }

  .ui-inset-list-body {
    display: grid;
  }

  .ui-inset-list-body > :global(* + *) {
    border-top: 1px solid var(--separator);
  }
</style>
