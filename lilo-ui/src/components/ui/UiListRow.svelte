<script lang="ts">
  import type { Snippet } from "svelte";

  interface Props {
    title: string;
    description?: string;
    icon?: Snippet;
    action?: Snippet;
    children?: Snippet;
  }

  let { title, description, icon, action, children }: Props = $props();
</script>

<div class="ui-list-row">
  {#if icon}
    <span class="ui-list-row-icon" aria-hidden="true">
      {@render icon()}
    </span>
  {/if}
  <span class="ui-list-row-copy">
    <span class="ui-list-row-title">{title}</span>
    {#if description}
      <span class="ui-list-row-description">{description}</span>
    {/if}
    {@render children?.()}
  </span>
  {#if action}
    <span class="ui-list-row-action">
      {@render action()}
    </span>
  {/if}
</div>

<style>
  /* Wraps: once the label would get narrower than its basis, the control drops below it. */
  .ui-list-row {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-8) var(--space-12);
    padding: 11px 14px;
  }

  .ui-list-row-icon {
    flex: none;
    display: grid;
    place-items: center;
    min-width: 18px;
    margin-right: 2px;
    color: var(--text-secondary);
  }

  .ui-list-row-copy {
    flex: 1 1 160px;
    display: grid;
    gap: 2px;
    min-width: 0;
  }

  .ui-list-row-title {
    min-width: 0;
    overflow-wrap: anywhere;
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .ui-list-row-description {
    min-width: 0;
    overflow-wrap: anywhere;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    line-height: 1.4;
  }

  .ui-list-row-action {
    flex: none;
    max-width: 100%;
    margin-left: auto;
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 8px;
  }
</style>
