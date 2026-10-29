<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import type { SpaceColorMode, SpaceMaterial } from "../../lib/bridge/protocol";
  import { getWallpaperThumbnail, watchWallpaperColor } from "../../stores/spaceColor.svelte";
  import { getFocusedSpaceId } from "../../stores/spaces.svelte";
  import { getActiveTab } from "../../stores/tabs.svelte";
  import { PASTEL_COLOR_NAMES, PASTEL_COLORS } from "../settings/profilesModel";
  import AppearancePreview from "./AppearancePreview.svelte";

  let { mode, color, material, onmode, oncolor, onmaterial }: {
    mode: SpaceColorMode;
    color: string;
    material: SpaceMaterial;
    onmode: (mode: SpaceColorMode) => void;
    oncolor: (color: string) => void;
    onmaterial: (material: SpaceMaterial) => void;
  } = $props();

  const AUTO_SOURCES = ["page", "wallpaper"] as const;
  // Stands in for the wallpaper until its picture arrives.
  const DESKTOP = "radial-gradient(70% 90% at 12% 18%, #f2a27a, transparent 60%), radial-gradient(70% 90% at 88% 30%, #8a74e8, transparent 60%), radial-gradient(90% 80% at 45% 105%, #4fb3c4, transparent 60%), #2c3a72";

  // The preview stands on the real wallpaper, and the Wallpaper source needs its color.
  $effect(() => watchWallpaperColor());

  const desktop = $derived.by(() => {
    const picture = getWallpaperThumbnail();
    return picture ? `center / cover no-repeat url("${picture}")` : DESKTOP;
  });
  // Lilo picks the color from the active tab or the wallpaper: the first swatches, as Multicolor is in macOS.
  const auto = $derived(mode === "page" || mode === "wallpaper");
  const index = $derived(PASTEL_COLORS.indexOf(color));
  // The tab swatch wears the favicon of the tab on screen, the one whose color it takes.
  const favicon = $derived(getActiveTab(getFocusedSpaceId())?.faviconDataURL);

  function pickColor(value: string): void {
    oncolor(value);
    if (auto) onmode("fixed");
  }

  function setHex(input: HTMLInputElement): void {
    const value = input.value.trim();
    if (/^#?[0-9a-f]{6}$/i.test(value)) pickColor((value.startsWith("#") ? value : `#${value}`).toLowerCase());
    else input.value = color.toUpperCase();
  }
</script>

<div class="picker">
  <!-- The time of day changes a chosen color only: Lilo's picks bring their own. -->
  <AppearancePreview {material} {desktop} {onmaterial} followsDay={auto ? null : mode === "time"}
    onday={(on) => onmode(on ? "time" : "fixed")} />

  <div class="group">
    <div class="name-row">
      {#if auto}
        <span class="name">{t(`spaceEditor.colorFrom.${mode}`)}</span>
      {:else if index >= 0}
        <span class="name">{t(`spaceEditor.colorName.${PASTEL_COLOR_NAMES[index]}`)}</span>
      {:else}
        <!-- A custom color is named by its hex, which can be typed. -->
        <input class="name hex" value={color.toUpperCase()} spellcheck="false" aria-label={t("spaceEditor.hexColor")}
          onchange={(e) => setHex(e.currentTarget as HTMLInputElement)} onkeydown={(e) => e.key === "Enter" && (e.currentTarget as HTMLInputElement).blur()} />
      {/if}
    </div>
    <div class="swatches">
      {#each AUTO_SOURCES as value (value)}
        <button class="swatch from-{value}" class:selected={mode === value} style:--desktop={desktop} aria-pressed={mode === value}
          aria-label={t(`spaceEditor.colorFrom.${value}`)} use:tooltip={t(`spaceEditor.colorSourceHint.${value}`)} onclick={() => onmode(value)}>
          {#if value === "page"}
            {#if favicon}
              <img class="favicon" src={favicon} alt="" />
            {:else}
              <svg width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.2" /><path d="M2 8h12M8 2c-2.2 2.4-2.2 9.6 0 12M8 2c2.2 2.4 2.2 9.6 0 12" fill="none" stroke="currentColor" stroke-width="1.2" /></svg>
            {/if}
          {/if}
        </button>
      {/each}
      <span class="divider" aria-hidden="true"></span>
      {#each PASTEL_COLORS as swatch, i (swatch)}
        <button class="swatch" class:selected={!auto && color === swatch} style:background={swatch} aria-pressed={!auto && color === swatch}
          aria-label={t(`spaceEditor.colorName.${PASTEL_COLOR_NAMES[i]}`)} onclick={() => pickColor(swatch)}></button>
      {/each}
      <!-- WebKit opens the macOS color panel for a color input. -->
      <label class="swatch custom" class:selected={!auto && index < 0}
        style:background={!auto && index < 0 ? `radial-gradient(circle closest-side, ${color} 0 52%, transparent 56%), var(--hue-wheel)` : null}>
        <input type="color" aria-label={t("spaceEditor.customColor")} value={color} oninput={(e) => pickColor((e.currentTarget as HTMLInputElement).value)} />
      </label>
    </div>
  </div>

</div>

<style>
  .picker {
    display: flex;
    flex-direction: column;
    gap: 16px;
    container-type: inline-size;
  }

  .group {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  /* As tall with or without its controls, so picking a source never moves the swatches. */
  .name-row {
    display: flex;
    align-items: center;
    gap: 6px;
    min-height: var(--control-height-sm);
  }

  .name {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .hex {
    width: 0;
    margin-left: -4px;
    padding: 2px 4px;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    outline: none;
  }

  .hex:hover {
    background: var(--bg-hover);
  }

  .hex:focus {
    background: var(--bg-active);
    box-shadow: 0 0 0 2px var(--accent);
    color: var(--text-primary);
  }

  /* Two rows of eight: the tab, the wallpaper, a divider, the twelve presets and the custom picker; one row where they fit. */
  .swatches {
    display: grid;
    grid-template-columns: repeat(8, minmax(0, 30px));
    justify-content: space-between;
    gap: 10px;
    padding: 2px;
  }

  @container (min-width: 400px) {
    .swatches {
      grid-template-columns: repeat(2, minmax(0, 24px)) 9px repeat(13, minmax(0, 24px));
      gap: 4px;
    }
  }

  .swatch {
    position: relative;
    aspect-ratio: 1;
    padding: 0;
    border: 0;
    border-radius: 50%;
    cursor: pointer;
    box-shadow: inset 0 0 0 1px var(--text-primary-tint-12), inset 0 1px 1px color-mix(in srgb, white 50%, transparent);
    transition: transform 0.2s var(--motion-ease-spring);
  }

  .swatch:hover {
    transform: scale(1.1);
  }

  .swatch.selected {
    box-shadow: inset 0 0 0 1px var(--text-primary-tint-12), 0 0 0 2px var(--bg-elevated), 0 0 0 3.5px var(--text-primary);
  }

  .swatch.from-page {
    display: grid;
    place-items: center;
    background: var(--bg-primary);
    color: var(--text-secondary);
  }

  .favicon {
    width: 55%;
    aspect-ratio: 1;
    border-radius: var(--radius-2xs);
    object-fit: contain;
  }

  .swatch.from-wallpaper {
    background: var(--desktop);
    background-size: cover;
  }

  /* Lilo's picks on the left, the colors to choose on the right. */
  .divider {
    justify-self: center;
    align-self: center;
    width: 1px;
    height: 60%;
    background: var(--text-primary-tint-12);
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

  .swatch:focus-visible,
  .swatch.custom:focus-within {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  @media (prefers-reduced-motion: reduce) {
    .swatch {
      transition: none;
    }
  }
</style>
