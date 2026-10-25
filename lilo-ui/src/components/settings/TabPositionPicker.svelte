<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import type { TabPosition } from "../../lib/bridge";
  import { getTabPosition, setTabPosition } from "../../stores/tabLayout.svelte";
  import { getActiveSpace } from "../../stores/spaces.svelte";

  let { compact = false }: { compact?: boolean } = $props();

  const POSITIONS: TabPosition[] = ["left", "right", "top", "bottom"];
  const selected = $derived(getTabPosition());

  function handleKeydown(event: KeyboardEvent): void {
    const step = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1 : event.key === "ArrowLeft" || event.key === "ArrowUp" ? -1 : 0;
    if (step === 0) return;
    event.preventDefault();
    const index = (POSITIONS.indexOf(selected) + step + POSITIONS.length) % POSITIONS.length;
    setTabPosition(POSITIONS[index]);
    (event.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>("button")[index]?.focus();
  }
</script>

<div class="positions" class:compact style:--space-color={getActiveSpace()?.color} role="radiogroup" tabindex="-1" aria-label={t("settings.items.tabPosition.title")} onkeydown={handleKeydown}>
  {#each POSITIONS as position (position)}
    <button
      class="position"
      class:on={selected === position}
      role="radio"
      aria-checked={selected === position}
      tabindex={selected === position ? 0 : -1}
      onclick={() => setTabPosition(position)}
    >
      <span class="shot {position}" aria-hidden="true">
        <span class="tabs"></span>
        <span class="page"></span>
      </span>
      {t(`settings.tabPosition.${position}`)}
    </button>
  {/each}
</div>

<style>
  .positions {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 96px));
    gap: 12px;
    margin-top: 10px;
  }

  .positions.compact {
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 10px;
    margin-top: 0;
  }

  .position {
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

  .position:hover {
    transform: translateY(-1px);
  }

  .position.on {
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

  .position.on .shot {
    border-color: var(--accent);
  }

  .position:focus-visible {
    outline: none;
  }

  .position:focus-visible .shot {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  .tabs,
  .page {
    position: absolute;
    border-radius: var(--radius-2xs);
  }

  .tabs {
    background: var(--text-muted);
    opacity: 0.55;
  }

  .position.on .tabs {
    background: var(--space-color, var(--accent));
    opacity: 1;
  }

  .page {
    background: var(--bg-primary);
  }

  .left .tabs { left: 4px; top: 4px; bottom: 4px; width: 22%; }
  .left .page { left: calc(22% + 8px); top: 4px; right: 4px; bottom: 4px; }
  .right .tabs { right: 4px; top: 4px; bottom: 4px; width: 22%; }
  .right .page { left: 4px; top: 12%; right: calc(22% + 8px); bottom: 4px; }
  .top .tabs { left: 4px; right: 4px; top: 4px; height: 14%; }
  .top .page { left: 4px; right: 4px; top: calc(14% + 8px); bottom: 4px; }
  .bottom .tabs { left: 8px; right: 8px; bottom: 4px; height: 14%; }
  .bottom .page { left: 4px; right: 4px; top: 10%; bottom: calc(14% + 8px); }
</style>
