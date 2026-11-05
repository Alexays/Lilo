<script lang="ts">
  import type { Snippet } from "svelte";
  import { MediaQuery } from "svelte/reactivity";
  import { slide } from "svelte/transition";
  import AppearancePicker from "../spaces/AppearancePicker.svelte";
  import UiToggle from "../ui/UiToggle.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { settingsActions, spaceActions } from "../../lib/bridge/actions";
  import type { AddressPlacement, SpaceMaterial, TabPosition } from "../../lib/bridge/protocol";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { PASTEL_COLOR_NAMES, PASTEL_COLORS } from "../settings/profilesModel";
  import { deriveSidebarThemeVariables } from "../../lib/sidebarTheme";
  import { effectiveSpaceColor } from "../../lib/spaceColor";
  import { getDefaultBrowserStatus, getSetting, setSetting } from "../../stores/settings.svelte";
  import { getOnboarding, goBack, goNext } from "../../stores/onboarding.svelte";
  import { getActiveSpace } from "../../stores/spaces.svelte";
  import { getDayPart, getWallpaperColor, getWallpaperThumbnail } from "../../stores/spaceColor.svelte";
  import { getAddressPlacement, getTabPosition, setAddressPlacement, setTabPosition } from "../../stores/tabLayout.svelte";
  import { getActiveTab } from "../../stores/tabs.svelte";
  import { onboardingSteps } from "./onboardingModel";

  const onboarding = getOnboarding();
  const last = $derived(onboardingSteps(onboarding.usage).at(-2) === "yourLilo");
  // The first Space is the one on screen: its color answers the choice right away.
  const space = $derived(getActiveSpace());
  const mode = $derived(space?.colorMode ?? "fixed");
  const material = $derived(space?.material ?? "solid");
  const isDefault = $derived(getDefaultBrowserStatus().isDefault);
  const dark = new MediaQuery("(prefers-color-scheme: dark)");

  // The preview derives its colors as the sidebar does, from the color the Space's mode makes of its own.
  const effectiveColor = $derived(effectiveSpaceColor(mode, space?.color ?? "", {
    dayPart: getDayPart(),
    pageColor: getActiveTab()?.faviconDominantColor,
    wallpaperColor: getWallpaperColor(),
  }));
  const windowStyle = $derived(Object.entries(deriveSidebarThemeVariables(effectiveColor, dark.current, material === "glass"))
    .map(([name, value]) => `${name}: ${value}`).join("; "));
  const position = $derived(getTabPosition());
  const address = $derived(getAddressPlacement());
  const vertical = $derived(position === "left" || position === "right");
  // Stands in for the wallpaper until its picture arrives.
  const DESKTOP = "radial-gradient(70% 90% at 12% 18%, #f2a27a, transparent 60%), radial-gradient(70% 90% at 88% 30%, #8a74e8, transparent 60%), radial-gradient(90% 80% at 45% 105%, #4fb3c4, transparent 60%), #2c3a72";
  const desktop = $derived.by(() => {
    const picture = getWallpaperThumbnail();
    return picture ? `center / cover no-repeat url("${picture}")` : DESKTOP;
  });

  // The color panel streams values while its wheel is dragged: the first goes out at once, then one every 100 ms.
  let colorTimer: ReturnType<typeof setTimeout> | undefined;
  let queuedColor = "";
  function setColor(color: string): void {
    queuedColor = color;
    if (colorTimer) return;
    const send = () => space && spaceActions.update({ id: space.id, color: queuedColor });
    send();
    const sent = queuedColor;
    colorTimer = setTimeout(() => {
      colorTimer = undefined;
      if (queuedColor !== sent) send();
    }, 100);
  }

  const THEMES = ["system", "light", "dark"] as const;
  const MATERIALS: SpaceMaterial[] = ["solid", "glass", "grain"];
  const POSITIONS: TabPosition[] = ["left", "right", "top", "bottom"];
  const ADDRESSES: AddressPlacement[] = ["tabs", "page", "hidden"];
  const theme = $derived(getSetting("theme", "system"));

  // The palette unfolds under its row: a popover would open under the onboarding, which covers the window.
  let paletteOpen = $state(false);
  const colorName = $derived.by(() => {
    if (mode === "page" || mode === "wallpaper") return t(`spaceEditor.colorSource.${mode}`);
    const index = PASTEL_COLORS.indexOf(space?.color ?? "");
    return index >= 0 ? t(`spaceEditor.colorName.${PASTEL_COLOR_NAMES[index]}`) : (space?.color ?? "").toUpperCase();
  });

  /** Arrow keys move the choice of a radio group of `count`, as macOS does. */
  function arrowKeys(event: KeyboardEvent, index: number, count: number, pick: (index: number) => void): void {
    const step = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1 : event.key === "ArrowLeft" || event.key === "ArrowUp" ? -1 : 0;
    if (step === 0) return;
    event.preventDefault();
    const next = (Math.max(index, 0) + step + count) % count;
    pick(next);
    (event.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>("button")[next]?.focus();
  }
</script>

<!-- A segmented control, as in System Settings: each choice a radio, moved by the arrow keys. -->
{#snippet segmented(id: string, options: readonly string[], selected: string, label: (value: string) => string, pick: (value: string) => void, icon: Snippet<[string]>)}
  <div class="seg" role="radiogroup" tabindex="-1" aria-labelledby={id}
    onkeydown={(event) => arrowKeys(event, options.indexOf(selected), options.length, (i) => pick(options[i]))}>
    {#each options as value (value)}
      <button role="radio" aria-checked={selected === value} tabindex={selected === value ? 0 : -1} onclick={() => pick(value)}>
        {@render icon(value)}<span>{label(value)}</span>
      </button>
    {/each}
  </div>
{/snippet}

{#snippet layoutIcon(value: string)}
  <svg width="15" height="12" viewBox="0 0 15 12" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" aria-hidden="true">
    <rect x=".6" y=".6" width="13.8" height="10.8" rx="2" />
    {#if value === "left"}<path d="M4.6 .6v10.8" />{:else if value === "right"}<path d="M10.4 .6v10.8" />
    {:else if value === "top"}<path d="M.6 3.8h13.8" />{:else if value === "bottom"}<path d="M.6 8.2h13.8" />
    {:else if value === "tabs"}<path d="M4.6 .6v10.8M2 3h1" />{:else if value === "page"}<path d="M6 3h6" />{/if}
  </svg>
{/snippet}

{#snippet themeIcon(value: string)}
  <svg width="13" height="13" viewBox="0 0 14 14" aria-hidden="true">
    <circle cx="7" cy="7" r="5.9" fill={value === "dark" ? "currentColor" : "none"} stroke="currentColor" stroke-width="1.2" />
    {#if value === "system"}<path d="M7 1.1a5.9 5.9 0 0 1 0 11.8Z" fill="currentColor" />{/if}
  </svg>
{/snippet}

{#snippet materialIcon(value: string)}
  <span class="mini {value}" style={windowStyle} style:--desktop={desktop}></span>
{/snippet}

<div class="ob-head">
  <h2>{t("onboarding.yourLilo.title")}</h2>
  <p class="ob-sub">{t("onboarding.yourLilo.subtitle")}</p>
</div>

<div class="ob-body">
  <div class="layout">
    <!-- The window as it will look: one surface in the Space's color and material, the page inset in it. -->
    <div class="desk" style:background={desktop}>
      <div class="win {material} tabs-{position}" style={windowStyle} aria-hidden="true">
        <span class="lights"><i></i><i></i><i></i></span>
        <div class="tabs">
          {#if address === "tabs"}<b class="url"></b>{/if}
          {#if vertical}
            <span class="pins"><i></i><i></i><i></i></span>
            {#each [62, 48, 72, 54, 66, 40] as width, i (i)}
              <span class="row" class:sel={i === 2}><i></i><b style:width="{width}%"></b></span>
            {/each}
          {:else}
            {#each [0, 1, 2, 3] as i (i)}
              <span class="row" class:sel={i === 1}><i></i><b></b></span>
            {/each}
          {/if}
        </div>
        <div class="page">{#if address === "page"}<b class="addr"></b>{/if}<b class="title"></b><b></b><b style:width="80%"></b><b style:width="60%"></b><span class="block"></span></div>
      </div>
    </div>

    <div class="controls">
      <section>
        <h3 class="ob-section">{t("onboarding.yourLilo.look")}</h3>
        <div class="ob-group">
          <!-- The tabs and the address also move the real window under the onboarding. -->
          <div class="ob-row choice">
            <span class="ob-text" id="onboarding-tabs-label">{t("onboarding.yourLilo.tabs")}</span>
            {@render segmented("onboarding-tabs-label", POSITIONS, position, (value) => t(`settings.tabPosition.${value}`),
              (value) => setTabPosition(value as TabPosition), layoutIcon)}
          </div>
          <div class="ob-row choice">
            <span class="ob-text" id="onboarding-address-label">{t("settings.items.addressPlacement.title")}</span>
            {@render segmented("onboarding-address-label", ADDRESSES, address, (value) => t(`settings.addressPlacement.${value}`),
              (value) => setAddressPlacement(value as AddressPlacement), layoutIcon)}
          </div>
          <div class="ob-row choice">
            <span class="ob-text" id="onboarding-theme-label">{t("onboarding.yourLilo.theme")}</span>
            {@render segmented("onboarding-theme-label", THEMES, theme, (value) => t(`onboarding.yourLilo.${value}`),
              (value) => setSetting("theme", value), themeIcon)}
          </div>
          {#if space}
            <div class="ob-row">
              <span class="ob-text" id="onboarding-color-label">{t("onboarding.yourLilo.color")}</span>
              <button class="color-button" aria-expanded={paletteOpen} aria-controls="onboarding-palette"
                aria-labelledby="onboarding-color-label onboarding-color-name" onclick={() => (paletteOpen = !paletteOpen)}>
                <span id="onboarding-color-name" class="color-name">{colorName}</span>
                <span class="dot" style:background={effectiveColor}></span>
                <svg width="9" height="9" viewBox="0 0 10 10" aria-hidden="true"><path d="M2 3.5l3 3 3-3" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /></svg>
              </button>
            </div>
            {#if paletteOpen}
              <div class="palette" id="onboarding-palette" transition:slide={{ duration: prefersReducedMotion() ? 0 : 200 }}>
                <AppearancePicker preview={false} {mode} color={space.color} {material}
                  onmode={(colorMode) => spaceActions.update({ id: space.id, colorMode })}
                  oncolor={setColor}
                  onmaterial={(value) => spaceActions.update({ id: space.id, material: value })} />
              </div>
            {/if}
            <div class="ob-row choice">
              <span class="ob-text" id="onboarding-material-label">{t("spaceEditor.materialLabel")}</span>
              {@render segmented("onboarding-material-label", MATERIALS, material, (value) => t(`spaceEditor.material.${value}`),
                (value) => spaceActions.update({ id: space.id, material: value as SpaceMaterial }), materialIcon)}
            </div>
            <!-- The time of day changes a chosen color only: Lilo's picks bring their own. -->
            {#if mode === "fixed" || mode === "time"}
              <div class="ob-row">
                <span class="ob-text">{t("spaceEditor.followDay")}<small>{t("spaceEditor.followDayHint")}</small></span>
                <UiToggle checked={mode === "time"} ariaLabel={t("spaceEditor.followDay")}
                  onchange={(on) => spaceActions.update({ id: space.id, colorMode: on ? "time" : "fixed" })} />
              </div>
            {/if}
          {/if}
        </div>
      </section>

      <section>
        <h3 class="ob-section">{t("onboarding.yourLilo.essentials")}</h3>
        <div class="ob-group">
          <div class="ob-row">
            <span class="ob-text">{t("onboarding.essentials.blocker")}<small>{t("onboarding.essentials.blockerDesc")}</small></span>
            <UiToggle checked={getSetting("contentBlockerEnabled", "true") === "true"} ariaLabel={t("onboarding.essentials.blocker")}
              onchange={(checked) => setSetting("contentBlockerEnabled", checked ? "true" : "false")} />
          </div>
          {#if onboarding.highRefreshDisplay}
            <div class="ob-row">
              <span class="ob-text">{t("onboarding.essentials.refreshRate")}<small>{t("onboarding.essentials.refreshRateDesc")}</small></span>
              <UiToggle checked={getSetting("fullRefreshRate", "true") === "true"} ariaLabel={t("onboarding.essentials.refreshRate")}
                onchange={(checked) => setSetting("fullRefreshRate", checked ? "true" : "false")} />
            </div>
          {/if}
          <div class="ob-row">
            <span class="ob-text">{t("onboarding.essentials.default")}<small>{t("onboarding.essentials.defaultDesc")}</small></span>
            {#if isDefault}
              <span class="ob-done">{t("onboarding.essentials.defaultDone")}</span>
            {:else}
              <button class="ob-btn" onclick={() => settingsActions.setDefaultBrowser()}>{t("onboarding.essentials.defaultSet")}</button>
            {/if}
          </div>
        </div>
      </section>
    </div>
  </div>
</div>

<div class="ob-foot">
  <button class="ob-btn ghost" onclick={goBack}>{t("onboarding.back")}</button>
  <button class="ob-btn primary" onclick={goNext}>{last ? t("onboarding.letsGo") : t("onboarding.continue")}</button>
</div>

<style>
  .layout { display: grid; grid-template-columns: minmax(0, 1fr) 440px; gap: 40px; align-items: start; }
  @container (max-width: 900px) { .layout { grid-template-columns: minmax(0, 1fr); } }
  .controls { display: flex; flex-direction: column; gap: 24px; }

  /* The wallpaper and the window on it. */
  .desk { display: flex; padding: 48px 40px; border-radius: var(--radius-box); overflow: hidden;
    box-shadow: inset 0 0 0 .5px rgba(0, 0, 0, .2); }
  .win { position: relative; display: grid; gap: 6px; width: 100%; aspect-ratio: 16 / 10; padding: 6px; border-radius: var(--radius-md);
    background: var(--sidebar-bg); box-shadow: 0 16px 40px rgba(10, 5, 40, .4), 0 0 0 .5px rgba(0, 0, 0, .3);
    transition: background-color var(--motion-duration-slow); }
  .win.glass { background: color-mix(in srgb, var(--sidebar-bg) 40%, transparent); backdrop-filter: blur(10px) saturate(1.8);
    box-shadow: 0 16px 40px rgba(10, 5, 40, .35), inset 1px 1px 0 rgba(255, 255, 255, .55); }
  .win.grain { background-image: var(--grain-texture); background-size: 120px; background-blend-mode: overlay; }
  .win.tabs-left { grid-template: "tabs page" 1fr / 22% 1fr; padding-left: 0; }
  .win.tabs-right { grid-template: "page tabs" 1fr / 1fr 22%; padding-top: 18px; padding-right: 0; }
  .win.tabs-top { grid-template: "tabs" 18px "page" 1fr / 1fr; padding-top: 4px; }
  .win.tabs-bottom { grid-template: "page" 1fr "tabs" 18px / 1fr; padding-top: 18px; padding-bottom: 2px; }
  .win.tabs-right .lights, .win.tabs-bottom .lights { position: absolute; top: 6px; left: 8px; }
  .win.tabs-top .lights { position: absolute; top: 9px; left: 8px; }
  .lights { display: flex; gap: 3px; }
  .lights i { width: 5px; height: 5px; border-radius: 50%; background: #ff5f57; }
  .lights i:nth-child(2) { background: #febc2e; } .lights i:nth-child(3) { background: #28c840; }
  .win.tabs-left .lights { position: absolute; top: 8px; left: 8px; }

  .tabs { grid-area: tabs; display: flex; flex-direction: column; gap: 5px; min-width: 0; padding: 18px 6px 0; }
  .win.tabs-right .tabs { padding-top: 0; }
  .win.tabs-top .tabs, .win.tabs-bottom .tabs { flex-direction: row; align-items: center; padding: 0 6px; }
  .win.tabs-top .tabs { padding-left: 34px; }
  .tabs b, .tabs i { display: block; border-radius: var(--radius-2xs); }
  .tabs .url { flex: none; height: 10px; margin-bottom: 2px; border-radius: var(--radius-xs); background: var(--sidebar-active); }
  .win.tabs-top .tabs .url, .win.tabs-bottom .tabs .url { width: 22%; margin: 0 6px 0 0; }
  .pins { display: grid; grid-template-columns: repeat(3, 1fr); gap: 3px; margin-bottom: 3px; }
  .tabs .pins i { height: 14px; border-radius: var(--radius-xs); background: var(--sidebar-hover); }
  .row { display: flex; align-items: center; gap: 4px; height: 11px; padding: 0 4px; border-radius: var(--radius-xs); }
  .row i { flex: none; width: 5px; height: 5px; background: color-mix(in srgb, var(--sidebar-contrast) 30%, transparent); }
  .row b { height: 3px; background: color-mix(in srgb, var(--sidebar-contrast) 28%, transparent); }
  .win.tabs-top .row, .win.tabs-bottom .row { flex: 0 1 18%; height: 12px; }
  .win.tabs-top .row b, .win.tabs-bottom .row b { flex: 1; }
  .row.sel { background: var(--sidebar-sel); }

  /* A page is white, whatever the theme. */
  .page { grid-area: page; display: flex; flex-direction: column; gap: 6px; min-height: 0; padding: 14px 16px; border-radius: var(--radius-xs); background: #fff;
    box-shadow: 0 0 0 .5px rgba(0, 0, 0, .08); }
  .page b { display: block; height: 4px; border-radius: var(--radius-2xs); background: rgba(0, 0, 0, .06); }
  .page b.addr { flex: none; height: 9px; margin: -8px -10px 4px; border-radius: var(--radius-xs); background: rgba(0, 0, 0, .07); }
  .page b.title { width: 40%; height: 7px; margin-bottom: 4px; background: rgba(0, 0, 0, .1); }
  .page .block { flex: 1; max-height: 64px; margin-top: 6px; border-radius: var(--radius-xs); background: rgba(0, 0, 0, .04); }

  /* A choice keeps its label beside it while both fit, and drops under it when not. */
  .choice { flex-wrap: wrap; row-gap: 8px; }
  .choice .ob-text { flex: 1 0 auto; }
  .seg { display: flex; flex: 0 1 auto; max-width: 100%; margin-left: auto; padding: 2px; border-radius: var(--radius-sm);
    background: color-mix(in srgb, var(--text-primary) 6%, transparent); }
  .seg button { display: flex; flex: 1 1 auto; align-items: center; justify-content: center; gap: 5px; min-width: 0; height: 24px; padding: 0 9px;
    border: 0; border-radius: calc(var(--radius-sm) - 2px); background: transparent; color: var(--text-secondary);
    font: inherit; font-size: var(--font-size-sm); white-space: nowrap; cursor: pointer; transition: background var(--transition-fast), color var(--transition-fast); }
  .seg button span { overflow: hidden; text-overflow: ellipsis; }
  .seg button svg, .seg .mini { flex: none; }
  .seg button:hover { color: var(--text-primary); }
  .seg button[aria-checked="true"] { background: var(--onb-surface-strong); color: var(--text-primary); font-weight: var(--font-weight-medium);
    box-shadow: 0 1px 2px rgba(0, 0, 0, .12), 0 0 0 .5px rgba(0, 0, 0, .06); }
  .seg button:focus-visible { outline: var(--focus-outline); outline-offset: 1px; }
  .mini { width: 13px; height: 13px; border-radius: var(--radius-2xs); background: var(--sidebar-bg); box-shadow: inset 0 0 0 1px rgba(0, 0, 0, .12); }
  .mini.glass { background: linear-gradient(color-mix(in srgb, var(--sidebar-bg) 40%, transparent), color-mix(in srgb, var(--sidebar-bg) 40%, transparent)), var(--desktop); }
  .mini.grain { background-image: var(--grain-texture); background-size: 40px; background-blend-mode: overlay; }

  .color-button { display: flex; align-items: center; gap: 8px; min-width: 0; height: 26px; padding: 0 8px 0 10px; border: 0;
    border-radius: var(--radius-sm); background: color-mix(in srgb, var(--text-primary) 6%, transparent); color: var(--text-secondary);
    font: inherit; font-size: var(--font-size-sm); cursor: pointer; transition: background var(--transition-fast); }
  .color-button:hover, .color-button[aria-expanded="true"] { background: color-mix(in srgb, var(--text-primary) 10%, transparent); color: var(--text-primary); }
  .color-button:focus-visible { outline: var(--focus-outline); outline-offset: 1px; }
  .color-name { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; font-variant-numeric: tabular-nums; }
  .dot { flex: none; width: 14px; height: 14px; border-radius: 50%; box-shadow: inset 0 0 0 1px rgba(0, 0, 0, .14); }
  .color-button svg { flex: none; transition: transform var(--transition-fast); }
  .color-button[aria-expanded="true"] svg { transform: rotate(180deg); }
  .palette { padding: 4px 14px 14px; }
  .palette + .ob-row { box-shadow: inset 0 1px 0 var(--separator); }
  @media (prefers-reduced-motion: reduce) { .win, .seg button, .color-button, .color-button svg { transition: none; } }
</style>
