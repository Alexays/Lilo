<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import type { SpaceColorMode, SpaceMaterial } from "../../lib/bridge/protocol";
  import { getWallpaperThumbnail, watchWallpaperColor } from "../../stores/spaceColor.svelte";
  import { getFocusedSpaceId } from "../../stores/spaces.svelte";
  import { getActiveTab } from "../../stores/tabs.svelte";
  import { isChromaticHex } from "../../lib/sidebarTheme";
  import { PASTEL_COLOR_NAMES, PASTEL_COLORS } from "../settings/profilesModel";
  import UiToggle from "../ui/UiToggle.svelte";
  import StripPopover from "../strip/StripPopover.svelte";
  import AppearancePreview from "./AppearancePreview.svelte";

  let { mode, color, material, onmode, oncolor, onmaterial, preview = true, inline = false }: {
    mode: SpaceColorMode;
    color: string;
    material: SpaceMaterial;
    onmode: (mode: SpaceColorMode) => void;
    oncolor: (color: string) => void;
    onmaterial: (material: SpaceMaterial) => void;
    /** False when the caller draws its own preview, with the material and time of day controls. */
    preview?: boolean;
    /** Laid out in the sidebar, which repaints as its own preview: one grouped box, the palette in a popover. */
    inline?: boolean;
  } = $props();

  const MATERIALS: SpaceMaterial[] = ["solid", "glass", "grain"];

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
  const activeTab = $derived(getActiveTab(getFocusedSpaceId()));
  const favicon = $derived(activeTab?.faviconDataURL);
  // With no site open (the onboarding's blank tab), the preview shows an example site taking effect.
  const siteColor = $derived(isChromaticHex(activeTab?.faviconDominantColor) ? activeTab?.faviconDominantColor : undefined);
  const EXAMPLE_SITE = "#e5484d";

  const id = $props.id();
  let trigger: HTMLButtonElement | undefined = $state();
  let palette: HTMLDivElement | undefined = $state();
  let open = $state(false);
  const shortName = $derived(auto ? t(`spaceEditor.colorSource.${mode}`)
    : index >= 0 ? t(`spaceEditor.colorName.${PASTEL_COLOR_NAMES[index]}`) : color.toUpperCase());

  // Escape and a pick leave the focus in the closing popover: it goes back to the trigger.
  function close(): void {
    if (!open) return;
    if (palette?.contains(document.activeElement)) trigger?.focus();
    open = false;
  }

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

{#snippet swatches()}
  <div class="swatches">
    {#each AUTO_SOURCES as value (value)}
      <button class="swatch from-{value}" class:selected={mode === value} style:--desktop={desktop} aria-pressed={mode === value}
        aria-label={t(`spaceEditor.colorFrom.${value}`)} use:tooltip={t(`spaceEditor.colorSourceHint.${value}`)} onclick={() => { onmode(value); close(); }}>
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
        aria-label={t(`spaceEditor.colorName.${PASTEL_COLOR_NAMES[i]}`)} onclick={() => { pickColor(swatch); close(); }}></button>
    {/each}
    <!-- WebKit opens the macOS color panel for a color input. -->
    <label class="swatch custom" class:selected={!auto && index < 0}
      style:background={!auto && index < 0 ? `radial-gradient(circle closest-side, ${color} 0 52%, transparent 56%), var(--hue-wheel)` : null}>
      <input type="color" aria-label={t("spaceEditor.customColor")} value={color} oninput={(e) => pickColor((e.currentTarget as HTMLInputElement).value)} />
    </label>
  </div>
{/snippet}

{#if inline}
  <div class="box">
    <div class="row">
      <div class="materials" role="radiogroup" aria-label={t("spaceEditor.materialLabel")}>
        {#each MATERIALS as value (value)}
          <button class="material" role="radio" aria-checked={material === value} onclick={() => onmaterial(value)}>
            <span class="swatch-material {value}" style:--desktop={desktop}></span>
            <span class="material-name">{t(`spaceEditor.material.${value}`)}</span>
          </button>
        {/each}
      </div>
    </div>
    <div class="row">
      <span id="{id}-label">{t("spaceEditor.color")}</span>
      <button class="color-button" bind:this={trigger} aria-haspopup="dialog" aria-expanded={open} aria-labelledby="{id}-label {id}-name"
        use:tooltip={mode === "page" && !siteColor ? t("spaceEditor.noSiteYet") : ""} onclick={() => (open = !open)}>
        <span class="dot"></span>
        <span id="{id}-name" class="short-name">{shortName}</span>
        <svg width="9" height="9" viewBox="0 0 10 10" aria-hidden="true"><path d="M2 3.5l3 3 3-3" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /></svg>
      </button>
    </div>
    {#if !auto}
      <div class="row" use:tooltip={t("spaceEditor.followDayHint")}>
        <!-- Day to night, as the onboarding draws it: the switch says the rest, its label and tooltip the words. -->
        <span class="day-icons" aria-hidden="true">
          <svg width="14" height="14" viewBox="0 0 16 16"><path d="M8 2v1.3M8 12.7V14M2 8h1.3M12.7 8H14M3.8 3.8l.9.9M11.3 11.3l.9.9M3.8 12.2l.9-.9M11.3 4.7l.9-.9M8 5.4a2.6 2.6 0 1 0 0 5.2a2.6 2.6 0 0 0 0-5.2Z" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" /></svg>
          <svg width="13" height="13" viewBox="0 0 16 16"><path d="M13 9.5A5.5 5.5 0 0 1 6.5 3a5.5 5.5 0 1 0 6.5 6.5Z" fill="currentColor" /></svg>
        </span>
        <UiToggle checked={mode === "time"} ariaLabel={t("spaceEditor.followDay")} onchange={(on) => onmode(on ? "time" : "fixed")} />
      </div>
    {/if}
  </div>
  {#if open && trigger}
    <StripPopover anchor={trigger} label={t("spaceEditor.color")} role="dialog" onclose={close}>
      <div class="palette" bind:this={palette}>{@render swatches()}</div>
    </StripPopover>
  {/if}
{:else}
  <div class="picker">
    {#if preview}
      <!-- The time of day changes a chosen color only: Lilo's picks bring their own. -->
      <AppearancePreview {material} {desktop} {onmaterial} followsDay={auto ? null : mode === "time"}
        site={mode === "page" ? { color: siteColor ?? EXAMPLE_SITE, favicon: siteColor ? favicon : undefined, example: !siteColor } : null}
        onday={(on) => onmode(on ? "time" : "fixed")} />
    {/if}

    <div class="group">
      <div class="name-row">
        {#if auto}
          <span class="name">{t(`spaceEditor.colorFrom.${mode}`)}</span>
          {#if mode === "page" && !siteColor}<span class="note">{t("spaceEditor.noSiteYet")}</span>{/if}
        {:else if index >= 0}
          <span class="name">{t(`spaceEditor.colorName.${PASTEL_COLOR_NAMES[index]}`)}</span>
        {:else}
          <!-- A custom color is named by its hex, which can be typed. -->
          <input class="name hex" value={color.toUpperCase()} spellcheck="false" aria-label={t("spaceEditor.hexColor")}
            onchange={(e) => setHex(e.currentTarget as HTMLInputElement)} onkeydown={(e) => e.key === "Enter" && (e.currentTarget as HTMLInputElement).blur()} />
        {/if}
      </div>
      {@render swatches()}
    </div>
  </div>
{/if}

<style>
  .picker {
    display: flex;
    flex-direction: column;
    gap: 16px;
    container-type: inline-size;
  }

  /* A Settings grouped box laid on the Space color: the hover layer, the quiet field secondary text keeps 4.5:1 on. */
  .box {
    display: flex;
    flex-direction: column;
    border-radius: var(--radius-box);
    background: var(--bg-hover);
    box-shadow: inset 0 0 0 1px var(--separator);
  }

  .row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    min-height: 28px;
    padding: 11px 14px;
    color: var(--text-primary);
    font-size: var(--font-size-md);
  }

  .row + .row {
    border-top: 1px solid var(--separator);
  }

  /* The onboarding's material bar, on the Space color: each choice shows its material in a small square. */
  .materials {
    flex: 1;
    min-width: 0;
    display: flex;
    gap: 2px;
    padding: 2px;
    border-radius: var(--radius-sm);
    background: var(--text-primary-tint-12);
  }

  .material {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    min-width: 0;
    height: var(--control-height-sm);
    padding: 0 6px;
    border: 0;
    border-radius: calc(var(--radius-sm) - 2px);
    background: none;
    color: var(--text-secondary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    cursor: pointer;
  }

  .material[aria-checked="true"] {
    background: color-mix(in srgb, var(--sidebar-contrast) 22%, transparent);
    color: var(--text-primary);
    font-weight: var(--font-weight-semibold);
  }

  .material:focus-visible {
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

  .day-icons {
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--text-secondary);
  }

  .material-name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .swatch-material.grain {
    background-image: var(--grain-texture);
    background-size: 40px;
    background-blend-mode: overlay;
  }

  .color-button {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    height: var(--control-height-sm);
    margin-right: -8px;
    padding: 0 8px;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-secondary);
    font-family: inherit;
    font-size: var(--font-size-md);
    cursor: pointer;
  }

  .color-button:hover,
  .color-button[aria-expanded="true"] {
    background: var(--bg-hover);
  }

  .color-button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .dot {
    flex: none;
    width: 14px;
    height: 14px;
    border-radius: 50%;
    background: var(--sidebar-bg);
    box-shadow: inset 0 0 0 1px var(--text-primary-tint-12);
  }

  .short-name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .palette {
    padding: 4px;
  }

  /* Out of the picker's container: the eight columns share the popover's width. */
  .palette .swatches {
    grid-template-columns: repeat(8, minmax(0, 1fr));
    gap: 6px;
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

  .note {
    flex: none;
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
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
    transition: transform var(--motion-duration-normal) var(--motion-ease-spring);
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
