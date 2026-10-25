<script lang="ts">
  import StripPopover from "./StripPopover.svelte";
  import { getActiveSpace, getActiveSpaceId, getSpaces } from "../../stores/spaces.svelte";
  import { spaceActions } from "../../lib/bridge/actions";
  import { openAddEditor } from "../../stores/panels.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { shortcutKeys } from "../../stores/shortcutKeys.svelte";

  let open = $state(false);
  let chip: HTMLButtonElement | undefined = $state();
  const active = $derived(getActiveSpace());

  function pick(spaceId: string) {
    open = false;
    // The sidebar's pager is not mounted in a strip: switch without its slide.
    spaceActions.switchTo(spaceId);
  }
</script>

<button
  bind:this={chip}
  class="space-chip"
  aria-haspopup="menu"
  aria-expanded={open}
  aria-label={t("bottomBar.spaces")}
  onclick={() => (open = !open)}
>
  <span class="dot" style:background={active?.color}></span>
  <span class="name">{active?.icon} {active?.name ?? t("spaceBar.defaultSpaceName")}</span>
  <svg width="9" height="6" viewBox="0 0 9 6" aria-hidden="true">
    <path d="M1 1l3.5 3.5L8 1" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
  </svg>
</button>

{#if open && chip}
  <StripPopover anchor={chip} label={t("bottomBar.spaces")} onclose={() => (open = false)}>
    {#each getSpaces() as space, index (space.id)}
      <button class="space-row" role="menuitemradio" aria-checked={space.id === getActiveSpaceId()} onclick={() => pick(space.id)}>
        <span class="dot" style:background={space.color}></span>
        <span class="space-name">{space.icon} {space.name}</span>
        {#if index < 9 && shortcutKeys(`space.select${index + 1}`)}<kbd>{shortcutKeys(`space.select${index + 1}`)}</kbd>{/if}
      </button>
    {/each}
    <div class="separator"></div>
    <button class="space-row" role="menuitem" onclick={() => { open = false; openAddEditor(); }}>
      <span class="plus" aria-hidden="true">+</span>
      <span class="space-name">{t("bottomBar.newSpace")}</span>
    </button>
  </StripPopover>
{/if}

<style>
  .space-chip {
    flex: none;
    height: 30px;
    max-width: 180px;
    display: flex;
    align-items: center;
    gap: 7px;
    padding: 0 10px;
    border: 0;
    border-radius: var(--radius-sm);
    background: var(--bg-hover);
    color: var(--text-primary);
    font: inherit;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-semibold);
  }

  .name,
  .space-name {
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .dot {
    flex: none;
    width: 8px;
    height: 8px;
    border-radius: 50%;
  }

  .space-row {
    width: 100%;
    height: 32px;
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 0 8px;
    border: 0;
    border-radius: calc(var(--float-radius-popover) - 6px);
    background: transparent;
    color: var(--text-primary);
    font: inherit;
    font-size: var(--font-size-sm);
    text-align: left;
  }

  .space-row:hover,
  .space-row:focus-visible,
  .space-row[aria-checked="true"] {
    background: var(--bg-hover);
  }

  .space-name {
    flex: 1;
  }

  kbd {
    font: inherit;
    font-size: var(--font-size-xs);
    color: var(--text-secondary);
  }

  .plus {
    width: 8px;
    text-align: center;
    color: var(--text-secondary);
  }

  .separator {
    height: 1px;
    margin: 5px 8px;
    background: var(--separator);
  }
</style>
