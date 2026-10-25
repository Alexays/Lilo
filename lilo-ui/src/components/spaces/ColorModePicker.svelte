<script lang="ts">
  import { slide } from "svelte/transition";
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import type { SpaceColorMode } from "../../lib/bridge/protocol";
  import { interpolateHexColors } from "../../lib/sidebarTheme";
  import { lightForDayPart, type DayPart } from "../../lib/spaceColor";
  import { getWallpaperThumbnail, watchWallpaperColor } from "../../stores/spaceColor.svelte";
  import { PASTEL_COLORS } from "../settings/profilesModel";

  let { mode, color, labelledby, onmode, oncolor }: {
    mode: SpaceColorMode;
    color: string;
    labelledby: string;
    onmode: (mode: SpaceColorMode) => void;
    oncolor: (color: string) => void;
  } = $props();

  const MODES: SpaceColorMode[] = ["fixed", "time", "page", "wallpaper"];
  const DAY_PARTS: DayPart[] = ["morning", "day", "evening", "night"];
  const PAGE_SAMPLE = "#e5484d";
  const customColor = $derived(!PASTEL_COLORS.includes(color));

  // The wallpaper tile shows the real picture, so it is read while the picker is open whatever the mode.
  $effect(() => watchWallpaperColor());

  // Each thumbnail shows what its mode does to the color.
  function thumbnail(value: SpaceColorMode): string {
    switch (value) {
      case "time":
        return `linear-gradient(90deg, ${DAY_PARTS.map((part, index) => `${lightForDayPart(color, part)} ${index * 25}% ${index * 25 + 25}%`).join(", ")})`;
      case "page":
        return interpolateHexColors(PAGE_SAMPLE, "#ffffff", 0.3);
      case "wallpaper": {
        const picture = getWallpaperThumbnail();
        // Until the picture arrives, a neutral tile rather than a made-up landscape.
        return picture ? `center / cover no-repeat url("${picture}")` : "var(--text-primary-tint-12)";
      }
      default:
        return color;
    }
  }

  function handleKeydown(event: KeyboardEvent): void {
    const step = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1 : event.key === "ArrowLeft" || event.key === "ArrowUp" ? -1 : 0;
    if (step === 0) return;
    event.preventDefault();
    const index = (Math.max(MODES.indexOf(mode), 0) + step + MODES.length) % MODES.length;
    onmode(MODES[index]);
    (event.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>("button")[index]?.focus();
  }
</script>

<div class="picker">
  <div class="modes" role="radiogroup" tabindex="-1" aria-labelledby={labelledby} onkeydown={handleKeydown}>
    {#each MODES as value (value)}
      <button class="mode" role="radio" aria-checked={mode === value} tabindex={mode === value ? 0 : -1} onclick={() => onmode(value)}>
        <span class="thumb" aria-hidden="true" style:background={thumbnail(value)}>
          {#if value === "page"}<span class="favicon" style:background={PAGE_SAMPLE}></span>{/if}
        </span>
        <span class="label">{t(`spaceEditor.colorMode.${value}`)}</span>
      </button>
    {/each}
  </div>
  <p class="hint">{t(`spaceEditor.colorModeHint.${mode}`)}</p>

  <!-- Page and wallpaper bring their own color: the Space's only stands in when they have none. -->
  {#if mode === "fixed" || mode === "time"}
    <div class="swatches" transition:slide={{ duration: prefersReducedMotion() ? 0 : 180 }}>
      {#each PASTEL_COLORS as swatch, index (swatch)}
        <button
          class="swatch"
          class:selected={color === swatch}
          style:background={swatch}
          onclick={() => oncolor(swatch)}
          aria-label={t("common.colorSwatch", { number: String(index + 1) })}
          aria-pressed={color === swatch}
        ></button>
      {/each}
      <!-- WebKit opens the macOS color panel for a color input. -->
      <label
        class="swatch custom"
        class:selected={customColor}
        style:background={customColor ? `radial-gradient(circle closest-side, ${color} 0 52%, transparent 56%), var(--hue-wheel)` : null}
        use:tooltip={t("spaceEditor.customColor")}
      >
        <input
          type="color"
          aria-label={t("spaceEditor.customColor")}
          value={color}
          oninput={(e) => oncolor((e.currentTarget as HTMLInputElement).value)}
        />
      </label>
    </div>
  {/if}
</div>

<style>
  .picker {
    display: flex;
    flex-direction: column;
    gap: 8px;
    container-type: inline-size;
  }

  /* Two by two in a sidebar, so no label breaks inside a word at its narrowest; one row where there is room. */
  .modes {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 8px;
  }

  @container (min-width: 300px) {
    .modes {
      grid-template-columns: repeat(4, minmax(0, 1fr));
    }
  }

  /* The cards of the onboarding's theme picker, so the two choices read as one family. */
  .mode {
    display: flex;
    flex-direction: column;
    align-items: stretch;
    gap: 6px;
    padding: 6px 6px 5px;
    border: 2px solid transparent;
    border-radius: var(--radius-lg);
    background: var(--bg-hover);
    color: var(--text-secondary);
    font-family: inherit;
    cursor: pointer;
    transition:
      border-color var(--motion-duration-normal),
      transform 0.2s var(--motion-ease-spring);
  }

  .mode:hover {
    transform: translateY(-1px);
  }

  .mode[aria-checked="true"] {
    border-color: var(--accent);
    color: var(--text-primary);
  }

  .mode:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  .thumb {
    position: relative;
    height: var(--color-mode-thumb-height, 32px);
    border-radius: var(--radius-md);
    box-shadow: inset 0 0 0 1px var(--text-primary-tint-12);
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

  .mode[aria-checked="true"] .label {
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

  /* Two rows of seven in a sidebar: the twelve presets and the custom picker; one row where they fit. */
  .swatches {
    display: grid;
    grid-template-columns: repeat(7, minmax(0, 1fr));
    gap: 8px;
    padding: 2px;
  }

  @container (min-width: 440px) {
    .swatches {
      grid-template-columns: repeat(13, minmax(0, 1fr));
    }
  }

  .swatch {
    position: relative;
    aspect-ratio: 1;
    border: 1px solid var(--text-primary-tint-12);
    border-radius: 50%;
    cursor: pointer;
    transition:
      box-shadow var(--motion-duration-fast),
      border-color var(--motion-duration-fast),
      transform 0.12s;
    padding: 0;
    box-shadow: inset 0 0 0 1px color-mix(in srgb, white 22%, transparent);
  }

  .swatch.selected {
    border-color: var(--sidebar-swatch-ring, var(--text-primary));
    box-shadow:
      0 0 0 2px var(--accent-tint-22),
      inset 0 0 0 1px color-mix(in srgb, white 28%, transparent);
    transform: scale(1.1);
  }

  .swatch.selected::after {
    content: "✓";
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    color: color-mix(in srgb, black 55%, transparent);
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-bold);
  }

  .swatch:hover {
    transform: scale(1.1);
  }

  .swatch:focus-visible,
  .swatch.custom:focus-within {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  .swatch.custom {
    overflow: hidden;
    background: var(--hue-wheel);
  }

  .swatch.custom input {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    padding: 0;
    border: 0;
    opacity: 0;
    cursor: pointer;
  }
</style>
