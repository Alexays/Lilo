<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import type { SpaceColorMode } from "../../lib/bridge/protocol";
  import { interpolateHexColors } from "../../lib/sidebarTheme";
  import { lightForDayPart, type DayPart } from "../../lib/spaceColor";
  import { getWallpaperColor } from "../../stores/spaceColor.svelte";

  let { value, color, labelledby, onchange }: {
    value: SpaceColorMode;
    color: string;
    labelledby: string;
    onchange: (mode: SpaceColorMode) => void;
  } = $props();

  const MODES: SpaceColorMode[] = ["fixed", "time", "page", "wallpaper"];
  const DAY_PARTS: DayPart[] = ["morning", "day", "evening", "night"];
  const PAGE_SAMPLE = "#e5484d";

  // Each thumbnail shows what its mode does to the base color.
  function thumbnail(mode: SpaceColorMode): string {
    switch (mode) {
      case "time":
        return `linear-gradient(90deg, ${DAY_PARTS.map((part, index) => `${lightForDayPart(color, part)} ${index * 25}% ${index * 25 + 25}%`).join(", ")})`;
      case "page":
        return interpolateHexColors(color, PAGE_SAMPLE, 0.6);
      case "wallpaper":
        return [
          "radial-gradient(70% 90% at 20% 85%, #f2a07b 0%, transparent 70%)",
          "radial-gradient(70% 90% at 80% 15%, #7cc4c0 0%, transparent 70%)",
          getWallpaperColor() || "#5f7299",
        ].join(", ");
      default:
        return color;
    }
  }

  function handleKeydown(event: KeyboardEvent): void {
    const step = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1 : event.key === "ArrowLeft" || event.key === "ArrowUp" ? -1 : 0;
    if (step === 0) return;
    event.preventDefault();
    const index = (Math.max(MODES.indexOf(value), 0) + step + MODES.length) % MODES.length;
    onchange(MODES[index]);
    (event.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>("button")[index]?.focus();
  }
</script>

<div class="picker">
<div class="color-modes" role="radiogroup" tabindex="-1" aria-labelledby={labelledby} onkeydown={handleKeydown}>
  {#each MODES as mode (mode)}
    <button
      class="color-mode"
      role="radio"
      aria-checked={value === mode}
      tabindex={value === mode ? 0 : -1}
      onclick={() => onchange(mode)}
    >
      <span class="thumb" aria-hidden="true" style:background={thumbnail(mode)}>
        {#if mode === "page"}<span class="favicon" style:background={PAGE_SAMPLE}></span>{/if}
      </span>
      <span class="label">{t(`spaceEditor.colorMode.${mode}`)}</span>
    </button>
  {/each}
</div>
<p class="hint">{t(`spaceEditor.colorModeHint.${value}`)}</p>
</div>

<style>
  .picker {
    display: flex;
    flex-direction: column;
    gap: 6px;
    container-type: inline-size;
  }

  /* Two by two in a sidebar, so no label breaks inside a word at its narrowest; one row where there is room. */
  .color-modes {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px 8px;
  }

  @container (min-width: 300px) {
    .color-modes {
      grid-template-columns: repeat(4, minmax(0, 1fr));
    }
  }

  .color-mode {
    display: flex;
    flex-direction: column;
    align-items: stretch;
    gap: 5px;
    padding: 0;
    border: 0;
    background: none;
    color: var(--text-secondary);
    font-family: inherit;
    cursor: pointer;
  }

  .thumb {
    position: relative;
    height: var(--color-mode-thumb-height, 30px);
    border-radius: var(--radius-sm);
    box-shadow: inset 0 0 0 1px var(--text-primary-tint-12);
  }

  .color-mode[aria-checked="true"] .thumb {
    outline: 2px solid var(--accent);
    outline-offset: 2px;
  }

  .color-mode:focus-visible {
    outline: none;
  }

  .color-mode:focus-visible .thumb {
    outline: var(--focus-outline);
    outline-offset: 4px;
  }

  .favicon {
    position: absolute;
    top: 50%;
    left: 6px;
    width: 14px;
    height: 14px;
    margin-top: -7px;
    border-radius: var(--radius-xs);
  }

  .label {
    font-size: var(--font-size-xs);
    line-height: 1.25;
    text-align: center;
    overflow-wrap: break-word;
  }

  .color-mode[aria-checked="true"] .label {
    color: var(--text-primary);
    font-weight: var(--font-weight-semibold);
  }

  /* Two lines whatever the mode, so switching never moves what follows. */
  .hint {
    min-height: 2lh;
    margin: 0;
    padding: 0 4px;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    line-height: 1.4;
  }
</style>
