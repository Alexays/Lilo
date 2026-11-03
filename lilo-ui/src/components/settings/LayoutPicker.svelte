<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import type { AddressPlacement, TabPosition } from "../../lib/bridge";
  import { canPlaceAddressWithTabs, getAddressPlacement, getTabPosition, setAddressPlacement, setTabPosition } from "../../stores/tabLayout.svelte";
  import { getActiveSpace } from "../../stores/spaces.svelte";

  // Where the tabs go, or where the address goes: each choice drawn as a small window.
  let { kind = "position", compact = false }: { kind?: "position" | "address"; compact?: boolean } = $props();

  const POSITIONS: TabPosition[] = ["left", "right", "top", "bottom"];
  const ADDRESSES: AddressPlacement[] = ["tabs", "page", "hidden"];
  const position = $derived(getTabPosition());
  // With the tabs on the right, an address kept with the tabs shows above the page.
  const address = $derived(!canPlaceAddressWithTabs() && getAddressPlacement() === "tabs" ? "page" : getAddressPlacement());
  const options: string[] = $derived(kind === "position" ? POSITIONS : ADDRESSES);
  const selected: string = $derived(kind === "position" ? position : address);

  function disabled(option: string): boolean {
    return kind === "address" && option === "tabs" && !canPlaceAddressWithTabs();
  }

  function select(option: string): void {
    if (kind === "position") setTabPosition(option as TabPosition);
    else setAddressPlacement(option as AddressPlacement);
  }

  function handleKeydown(event: KeyboardEvent): void {
    const step = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1 : event.key === "ArrowLeft" || event.key === "ArrowUp" ? -1 : 0;
    if (step === 0) return;
    event.preventDefault();
    const enabled = options.filter((option) => !disabled(option));
    const next = enabled[(enabled.indexOf(selected) + step + enabled.length) % enabled.length];
    select(next);
    (event.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>("button")[options.indexOf(next)]?.focus();
  }
</script>

<div
  class="options {kind}"
  class:compact
  style:--space-color={getActiveSpace()?.color}
  role="radiogroup"
  tabindex="-1"
  aria-label={t(kind === "position" ? "settings.items.tabPosition.title" : "settings.items.addressPlacement.title")}
  onkeydown={handleKeydown}
>
  {#each options as option (option)}
    {@const shotPosition = kind === "position" ? option : position}
    {@const shotAddress = kind === "address" ? option : shotPosition === "right" && address === "tabs" ? "page" : address}
    <button
      class="option"
      class:on={selected === option}
      role="radio"
      aria-checked={selected === option}
      disabled={disabled(option)}
      tabindex={selected === option ? 0 : -1}
      onclick={() => select(option)}
    >
      <span class="shot {shotPosition}" aria-hidden="true">
        <span class="tabs">
          {#if shotAddress === "tabs"}<span class="url"></span>{/if}
        </span>
        <span class="page">
          {#if shotAddress === "page"}<span class="url"></span>{/if}
        </span>
      </span>
      {t(kind === "position" ? `settings.tabPosition.${option}` : `settings.addressPlacement.${option}`)}
    </button>
  {/each}
</div>

<style>
  .options {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 96px));
    gap: 12px;
    margin-top: 10px;
  }

  .options.address {
    grid-template-columns: repeat(3, minmax(0, 96px));
  }

  .options.compact {
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 10px;
    margin-top: 0;
  }

  .option {
    display: grid;
    gap: 6px;
    padding: 0;
    border: 0;
    background: transparent;
    color: var(--text-secondary);
    font: inherit;
    font-size: var(--font-size-sm);
    cursor: pointer;
    transition: transform 0.2s var(--motion-ease-spring);
  }

  .option:hover:not(:disabled) {
    transform: translateY(-1px);
  }

  .option:disabled {
    opacity: 0.4;
    cursor: default;
  }

  .option.on {
    color: var(--text-primary);
    font-weight: var(--font-weight-medium);
  }

  /* A window: the tabs on their edge, the page in the rest. */
  .shot {
    position: relative;
    aspect-ratio: 16 / 10;
    overflow: hidden;
    border: 2px solid transparent;
    border-radius: var(--radius-md);
    box-shadow: 0 0 0 1px var(--separator);
    /* The window as it looks: the active Space's color around the page. */
    background: color-mix(in srgb, var(--space-color, var(--accent)) 16%, var(--bg-hover));
  }

  .option.on .shot {
    border-color: var(--accent);
  }

  .option:focus-visible {
    outline: none;
  }

  .option:focus-visible .shot {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  .tabs,
  .page {
    position: absolute;
    border-radius: var(--radius-2xs);
  }

  /* Faded by its color, not its opacity, which would fade the address drawn in it too. */
  .tabs {
    background: color-mix(in srgb, var(--text-muted) 55%, transparent);
  }

  .position .option.on .tabs {
    background: var(--space-color, var(--accent));
  }

  .page {
    background: var(--bg-primary);
  }

  .url {
    position: absolute;
    height: 4px;
    border-radius: var(--radius-2xs);
    background: var(--text-muted);
    opacity: 0.7;
  }

  .address .option.on .url {
    background: var(--accent);
    opacity: 1;
  }

  /* In the sidebar's top corner, centered in a strip, or at the top of the page. */
  .left .tabs .url,
  .right .tabs .url { left: 3px; right: 3px; top: 3px; }
  .top .tabs .url,
  .bottom .tabs .url { left: 30%; right: 30%; top: calc(50% - 2px); }
  .page .url { left: 25%; right: 25%; top: 3px; }

  .left .tabs { left: 4px; top: 4px; bottom: 4px; width: 22%; }
  .left .page { left: calc(22% + 8px); top: 4px; right: 4px; bottom: 4px; }
  .right .tabs { right: 4px; top: 4px; bottom: 4px; width: 22%; }
  .right .page { left: 4px; top: 12%; right: calc(22% + 8px); bottom: 4px; }
  .top .tabs { left: 4px; right: 4px; top: 4px; height: 14%; }
  .top .page { left: 4px; right: 4px; top: calc(14% + 8px); bottom: 4px; }
  .bottom .tabs { left: 8px; right: 8px; bottom: 4px; height: 14%; }
  .bottom .page { left: 4px; right: 4px; top: 10%; bottom: calc(14% + 8px); }
</style>
