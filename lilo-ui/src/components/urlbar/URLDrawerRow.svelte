<!-- One row of an address-bar drawer: the settings row voice at drawer density. A button when
     the whole row acts, otherwise a plain row whose trailing controls act. -->
<script lang="ts">
  import type { Snippet } from "svelte";
  import URLDrawerIcon, { type UrlDrawerIconName } from "./URLDrawerIcon.svelte";

  interface Props {
    icon?: UrlDrawerIconName;
    label: string;
    onclick?: (event: MouseEvent) => void;
    trailing?: Snippet;
  }

  let { icon, label, onclick, trailing }: Props = $props();
</script>

{#snippet body()}
  <span class="row-leading" aria-hidden="true">
    {#if icon}<URLDrawerIcon name={icon} />{/if}
  </span>
  <span class="row-label">{label}</span>
  {#if trailing}<span class="row-trailing">{@render trailing()}</span>{/if}
{/snippet}

{#if onclick}
  <button class="url-drawer-row clickable" type="button" {onclick}>{@render body()}</button>
{:else}
  <div class="url-drawer-row">{@render body()}</div>
{/if}

<style>
  .url-drawer-row {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    min-height: 30px;
    padding: 0 6px;
    border: 0;
    border-radius: var(--radius-md);
    background: transparent;
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-md);
    text-align: left;
  }

  .url-drawer-row.clickable {
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .url-drawer-row.clickable:hover {
    background: var(--bg-hover);
  }

  .url-drawer-row.clickable:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .row-leading {
    flex: none;
    display: grid;
    place-items: center;
    width: 16px;
    color: var(--text-secondary);
  }

  .row-label {
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .row-trailing {
    flex: none;
    display: flex;
    align-items: center;
    gap: 4px;
  }
</style>
