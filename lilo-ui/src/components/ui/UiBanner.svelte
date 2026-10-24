<!-- Pill-shaped alert banner. Positioning comes from the flex-column banner host in
     DeferredChrome.svelte so simultaneous banners stack instead of overlapping. -->
<script lang="ts">
  import type { Snippet } from "svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";

  let {
    zoneId,
    closeLabel,
    onclose,
    children,
    actions,
  }: {
    zoneId: string;
    closeLabel: string;
    onclose: () => void;
    children: Snippet;
    actions?: Snippet;
  } = $props();
</script>

<!-- The banner floats over page content, so it must claim its own interactive zone or every
     click (Set as default, Reload, dismiss) falls through the chrome shield to the page. -->
<div
  class="ui-banner float-surface"
  role="alert"
  use:reportInteractiveZone={{ id: zoneId }}
>
  <div class="message">{@render children()}</div>
  {#if actions}{@render actions()}{/if}
  <button class="close" aria-label={closeLabel} onclick={onclose}>✕</button>
</div>

<style>
  .ui-banner {
    border-radius: var(--radius-md);
    padding: var(--space-8) var(--space-16);
    font-size: var(--font-size-md);
    display: flex;
    align-items: center;
    gap: var(--space-12);
    /* #chrome-root is pointer-events:none so the transparent overlay clicks through to the page;
       every clickable surface must opt back in, and the registered zone routes the OS click here. */
    pointer-events: auto;
  }
  /* Fills the row: in a stack of banners the close buttons line up on the right. */
  .message {
    flex: 1;
    min-width: 0;
  }
  .ui-banner .close {
    background: none;
    border: none;
    color: var(--text-secondary);
    cursor: pointer;
    font-size: var(--font-size-lg);
    padding: 0;
  }
</style>
