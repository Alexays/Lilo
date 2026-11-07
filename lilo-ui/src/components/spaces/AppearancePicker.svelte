<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import type { SpaceColorMode, SpaceMaterial } from "../../lib/bridge/protocol";
  import { SPACE_TONE } from "../../lib/colorSliders";
  import { getWallpaperThumbnail, watchWallpaperColor } from "../../stores/spaceColor.svelte";
  import { getFocusedSpaceId } from "../../stores/spaces.svelte";
  import { getActiveTab } from "../../stores/tabs.svelte";
  import { isChromaticHex } from "../../lib/sidebarTheme";
  import { PASTEL_COLOR_NAMES, PASTEL_COLORS } from "../settings/profilesModel";
  import ColorSliders from "../ui/ColorSliders.svelte";
  import UiToggle from "../ui/UiToggle.svelte";
  import DayStrip from "./DayStrip.svelte";

  let { mode, color, material, onmode, oncolor, onmaterial }: {
    mode: SpaceColorMode;
    color: string;
    material: SpaceMaterial;
    onmode: (mode: SpaceColorMode) => void;
    oncolor: (color: string) => void;
    onmaterial: (material: SpaceMaterial) => void;
  } = $props();

  const SOURCES = ["pick", "page", "wallpaper"] as const;
  const MATERIALS: SpaceMaterial[] = ["solid", "glass", "grain"];
  // Stands in for the wallpaper until its picture arrives.
  const DESKTOP = "radial-gradient(70% 90% at 12% 18%, #f2a27a, transparent 60%), radial-gradient(70% 90% at 88% 30%, #8a74e8, transparent 60%), radial-gradient(90% 80% at 45% 105%, #4fb3c4, transparent 60%), #2c3a72";

  // The glass swatch stands on the real wallpaper, and the Wallpaper source needs its color.
  $effect(() => watchWallpaperColor());

  const desktop = $derived.by(() => {
    const picture = getWallpaperThumbnail();
    return picture ? `center / cover no-repeat url("${picture}")` : DESKTOP;
  });
  const auto = $derived(mode === "page" || mode === "wallpaper");
  const index = $derived(PASTEL_COLORS.indexOf(color));
  const noSite = $derived(!isChromaticHex(getActiveTab(getFocusedSpaceId())?.faviconDominantColor));
  let picking = $state(false);
</script>

<div class="box">
  <div class="row column">
    <div class="segments" role="radiogroup" aria-label={t("spaceEditor.color")}>
      {#each SOURCES as value (value)}
        <button class="segment" role="radio" aria-checked={(auto ? mode : "pick") === value}
          onclick={() => onmode(value === "pick" ? "fixed" : value)}>
          {t(value === "pick" ? "colorPicker.pick" : `spaceEditor.colorSource.${value}`)}
        </button>
      {/each}
    </div>
    {#if auto}
      <p class="note">{mode === "page" && noSite ? t("spaceEditor.noSiteYet") : t(`spaceEditor.colorSourceHint.${mode}`)}</p>
    {:else}
      <ColorSliders {color} tone={SPACE_TONE} presets={PASTEL_COLORS} {oncolor} bind:picking />
      <p class="note" aria-live="polite">
        {picking ? t("colorPicker.pickHint") : index >= 0 ? t(`spaceEditor.colorName.${PASTEL_COLOR_NAMES[index]}`) : t("spaceEditor.customColor")}
      </p>
    {/if}
  </div>
  <div class="row">
    <div class="segments" role="radiogroup" aria-label={t("spaceEditor.materialLabel")}>
      {#each MATERIALS as value (value)}
        <button class="segment material" role="radio" aria-checked={material === value} onclick={() => onmaterial(value)}>
          <span class="swatch-material {value}" style:--desktop={desktop}></span>
          <span class="material-name">{t(`spaceEditor.material.${value}`)}</span>
        </button>
      {/each}
    </div>
  </div>
  <!-- The time of day changes a chosen color only: Lilo's picks bring their own. -->
  {#if !auto}
    <div class="row column">
      <div class="day-row">
        <span class="day-text">{t("spaceEditor.followDay")}<small>{t("spaceEditor.followDayHint")}</small></span>
        <UiToggle checked={mode === "time"} ariaLabel={t("spaceEditor.followDay")} onchange={(on) => onmode(on ? "time" : "fixed")} />
      </div>
      <DayStrip {color} on={mode === "time"} />
    </div>
  {/if}
</div>

<style>
  /* A Settings grouped box laid on the Space color: the hover layer, the quiet field secondary text keeps 4.5:1 on. */
  .box {
    display: flex;
    flex-direction: column;
    border-radius: var(--radius-box);
    background: var(--bg-hover);
    box-shadow: inset 0 0 0 1px var(--separator);
    container-type: inline-size;
  }

  .row {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 11px 14px;
    color: var(--text-primary);
    font-size: var(--font-size-md);
  }

  .row.column {
    flex-direction: column;
    align-items: stretch;
    gap: 12px;
  }

  .row + .row {
    border-top: 1px solid var(--separator);
  }

  .note {
    margin: 0;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  /* The onboarding's segmented bars, on the Space color. */
  .segments {
    flex: 1;
    min-width: 0;
    display: flex;
    gap: 2px;
    padding: 2px;
    border-radius: var(--radius-sm);
    background: var(--text-primary-tint-12);
  }

  .segment {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    min-width: 0;
    height: var(--control-height-sm);
    padding: 0 6px;
    overflow: hidden;
    border: 0;
    border-radius: calc(var(--radius-sm) - 2px);
    background: none;
    color: var(--text-secondary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    text-overflow: ellipsis;
    white-space: nowrap;
    cursor: pointer;
  }

  /* Too narrow for a swatch beside its name: stack them, like a toolbar item's icon and label. */
  @container (max-width: 260px) {
    .material {
      flex-direction: column;
      gap: 3px;
      height: auto;
      padding: 5px 0;
      /* Shrinks with the box so the longest translations still fit: 11px wide, 9px at the narrowest sidebar. */
      font-size: clamp(9px, 4.8cqi, var(--font-size-xs));
    }

    .material-name {
      max-width: 100%;
    }
  }

  .segment[aria-checked="true"] {
    background: color-mix(in srgb, var(--sidebar-contrast) 22%, transparent);
    color: var(--text-primary);
    font-weight: var(--font-weight-semibold);
  }

  .segment:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .swatch-material {
    position: relative;
    flex: none;
    width: 14px;
    height: 14px;
    overflow: hidden;
    border-radius: var(--radius-xs);
    background-color: var(--sidebar-bg);
    box-shadow: inset 0 0 0 1px var(--text-primary-tint-12);
  }

  .swatch-material.glass {
    background: linear-gradient(color-mix(in srgb, var(--sidebar-bg) 45%, transparent), color-mix(in srgb, var(--sidebar-bg) 45%, transparent)), var(--desktop);
  }

  .swatch-material.grain {
    background-image: var(--grain-texture);
    background-size: 40px;
    background-blend-mode: overlay;
  }

  .material-name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .day-row {
    display: flex;
    align-items: flex-start;
    gap: 10px;
  }

  .day-text {
    flex: 1;
    min-width: 0;
    font-weight: var(--font-weight-semibold);
  }

  .day-text small {
    display: block;
    margin-top: 2px;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-regular);
  }
</style>
