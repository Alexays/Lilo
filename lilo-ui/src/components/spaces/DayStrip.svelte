<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { lightForDayPart, type DayPart } from "../../lib/spaceColor";
  import { getDayPart } from "../../stores/spaceColor.svelte";

  let { color, on }: { color: string; on: boolean } = $props();

  const PARTS = ["day", "evening", "night"] as const;
  // Morning light is close to the day's: its marker stands on the day.
  const COLUMN: Record<DayPart, number> = { morning: 0, day: 0, evening: 1, night: 2 };
  const stops = $derived(PARTS.map((part) => lightForDayPart(color, part)));
</script>

<!-- Shows what the toggle does to this color: the words are the toggle's label and hint. -->
<div class="day-strip" class:on aria-hidden="true">
  <div class="bar" style:background="linear-gradient(to right, {stops[0]} 16%, {stops[1]} 50%, {stops[2]} 84%)">
    {#if on}<i style:left="{COLUMN[getDayPart()] * 33.33 + 16.67}%" style:background={stops[COLUMN[getDayPart()]]}></i>{/if}
  </div>
  <div class="labels">
    {#each PARTS as part (part)}<span>{t(`spaceEditor.dayPart.${part}`)}</span>{/each}
  </div>
</div>

<style>
  .day-strip {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .bar {
    position: relative;
    height: 12px;
    border-radius: var(--radius-chip);
    box-shadow: inset 0 0 0 1px var(--text-primary-tint-12);
    opacity: 0.45;
    transition: opacity var(--motion-duration-normal);
  }

  .on .bar {
    opacity: 1;
  }

  i {
    position: absolute;
    top: 50%;
    width: 14px;
    height: 14px;
    margin: -7px;
    border: 2.5px solid var(--on-color);
    border-radius: 50%;
    box-shadow: var(--shadow-control);
  }

  .labels {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
    text-align: center;
  }

  @media (prefers-reduced-motion: reduce) {
    .bar {
      transition: none;
    }
  }
</style>
