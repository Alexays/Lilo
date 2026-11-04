<script lang="ts">
  import type { Snippet } from "svelte";

  interface Props {
    title?: string;
    /** The list's main action or a short note, at the right end of its header. */
    accessory?: Snippet;
    /** False for content that is not rows (cards, thumbnails): it then sits under the header as is. */
    boxed?: boolean;
    children?: Snippet;
  }

  let { title, accessory, boxed = true, children }: Props = $props();
</script>

<section class="ui-inset-list" aria-label={title}>
  {#if title || accessory}
    <div class="ui-inset-list-header">
      {#if title}<h3 class="ui-inset-list-title">{title}</h3>{/if}
      {#if accessory}<div class="ui-inset-list-accessory">{@render accessory()}</div>{/if}
    </div>
  {/if}
  <div class="ui-inset-list-body" class:boxed>
    {@render children?.()}
  </div>
</section>

<style>
  .ui-inset-list {
    display: grid;
    gap: var(--space-8);
  }

  .ui-inset-list-header {
    display: flex;
    align-items: baseline;
    gap: var(--space-12);
    min-height: 16px;
    padding-inline: 4px;
  }

  .ui-inset-list-title {
    flex: 1;
    margin: 0;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
    letter-spacing: 0.04em;
    text-transform: uppercase;
  }

  .ui-inset-list-accessory {
    margin-left: auto;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    text-align: right;
  }

  .ui-inset-list-body {
    display: grid;
  }

  .ui-inset-list-body.boxed {
    border-radius: var(--radius-box);
    background: var(--group-box-bg);
    box-shadow: inset 0 0 0 1px var(--separator);
    /* Rows fill the box: their hover keeps its corners. */
    overflow: clip;
  }

  .ui-inset-list-body:empty {
    display: none;
  }

  .ui-inset-list-body.boxed > :global(* + *) {
    border-top: 1px solid var(--separator);
  }
</style>
