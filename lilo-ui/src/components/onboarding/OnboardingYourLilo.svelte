<script lang="ts">
  import { MediaQuery } from "svelte/reactivity";
  import AppearancePicker from "../spaces/AppearancePicker.svelte";
  import LayoutPicker from "../settings/LayoutPicker.svelte";
  import UiToggle from "../ui/UiToggle.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { settingsActions, spaceActions } from "../../lib/bridge/actions";
  import type { SpaceMaterial } from "../../lib/bridge/protocol";
  import { deriveSidebarThemeVariables } from "../../lib/sidebarTheme";
  import { effectiveSpaceColor } from "../../lib/spaceColor";
  import { getDefaultBrowserStatus, getSetting, setSetting } from "../../stores/settings.svelte";
  import { getOnboarding, goBack, goNext } from "../../stores/onboarding.svelte";
  import { getActiveSpace } from "../../stores/spaces.svelte";
  import { getDayPart, getWallpaperColor, getWallpaperThumbnail } from "../../stores/spaceColor.svelte";
  import { getTabPosition } from "../../stores/tabLayout.svelte";
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
  const lightFrame = $derived(deriveSidebarThemeVariables(effectiveColor, false)["--sidebar-bg"]);
  const darkFrame = $derived(deriveSidebarThemeVariables(effectiveColor, true)["--sidebar-bg"]);
  const position = $derived(getTabPosition());
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
  const theme = $derived(getSetting("theme", "system"));

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
          {#if vertical}
            <b class="url"></b>
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
        <div class="page"><b class="title"></b><b></b><b style:width="80%"></b><b style:width="60%"></b><span class="block"></span></div>
      </div>

      <div class="under">
        {#if space && (mode === "fixed" || mode === "time")}
          <button class="frosted day" aria-pressed={mode === "time"} aria-label={t("spaceEditor.followDay")}
            use:tooltip={`${t("spaceEditor.followDay")}. ${t("spaceEditor.followDayHint")}`}
            onclick={() => spaceActions.update({ id: space.id, colorMode: mode === "time" ? "fixed" : "time" })}>
            <svg width="13" height="13" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2v1.3M8 12.7V14M2 8h1.3M12.7 8H14M3.8 3.8l.9.9M11.3 11.3l.9.9M3.8 12.2l.9-.9M11.3 4.7l.9-.9M8 5.4a2.6 2.6 0 1 0 0 5.2a2.6 2.6 0 0 0 0-5.2Z" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" /></svg>
            <svg width="11" height="11" viewBox="0 0 16 16" aria-hidden="true"><path d="M13 9.5A5.5 5.5 0 0 1 6.5 3a5.5 5.5 0 1 0 6.5 6.5Z" fill="currentColor" /></svg>
            <span class="track"><span class="knob"></span></span>
          </button>
        {/if}
        {#if space}
          <div class="frosted materials" role="radiogroup" tabindex="-1" aria-label={t("spaceEditor.materialLabel")}
            onkeydown={(event) => arrowKeys(event, MATERIALS.indexOf(material), MATERIALS.length, (i) => spaceActions.update({ id: space.id, material: MATERIALS[i] }))}>
            {#each MATERIALS as value (value)}
              <button class="material" role="radio" aria-checked={material === value} tabindex={material === value ? 0 : -1}
                onclick={() => spaceActions.update({ id: space.id, material: value })}>
                <span class="mini {value}" style={windowStyle} style:--desktop={desktop}></span>{t(`spaceEditor.material.${value}`)}
              </button>
            {/each}
          </div>
        {/if}
      </div>
    </div>

    <div class="controls">
      <section>
        <h3 class="ob-section" id="onboarding-theme-label">{t("onboarding.yourLilo.theme")}</h3>
        <div class="themes" role="radiogroup" tabindex="-1" aria-labelledby="onboarding-theme-label"
          onkeydown={(event) => arrowKeys(event, THEMES.findIndex((value) => value === theme), THEMES.length, (i) => setSetting("theme", THEMES[i]))}>
          {#each THEMES as value (value)}
            <button class="th" class:on={theme === value} role="radio" aria-checked={theme === value} tabindex={theme === value ? 0 : -1}
              style:--light={lightFrame} style:--dark={darkFrame} onclick={() => setSetting("theme", value)}>
              <span class="shot {value}"><u></u></span>{t(`onboarding.yourLilo.${value}`)}
            </button>
          {/each}
        </div>
      </section>

      <section>
        <!-- Each choice also moves the real window under the onboarding. -->
        <h3 class="ob-section">{t("onboarding.yourLilo.tabs")}</h3>
        <LayoutPicker compact />
      </section>

      {#if space}
        <section>
          <h3 class="ob-section">{t("onboarding.yourLilo.color")}</h3>
          <AppearancePicker preview={false} {mode} color={space.color} {material}
            onmode={(colorMode) => spaceActions.update({ id: space.id, colorMode })}
            oncolor={setColor}
            onmaterial={(value) => spaceActions.update({ id: space.id, material: value })} />
        </section>
      {/if}

      <section>
        <h3 class="ob-section">{t("onboarding.yourLilo.essentials")}</h3>
        <div class="ob-group">
          <div class="ob-row">
            <span class="ob-text">{t("onboarding.essentials.blocker")}<small>{t("onboarding.essentials.blockerDesc")}</small></span>
            <UiToggle checked={getSetting("contentBlockerEnabled", "true") === "true"} ariaLabel={t("onboarding.essentials.blocker")}
              onchange={(checked) => setSetting("contentBlockerEnabled", checked ? "true" : "false")} />
          </div>
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
  .layout { display: grid; grid-template-columns: minmax(0, 1fr) 400px; gap: 48px; align-items: start; }
  @container (max-width: 900px) { .layout { grid-template-columns: minmax(0, 1fr); } }
  .controls { display: flex; flex-direction: column; gap: 24px; }

  /* The wallpaper, the window on it, and under the window the controls of its surface. */
  .desk { display: flex; flex-direction: column; align-items: center; gap: 20px; padding: 48px 40px 32px; border-radius: var(--radius-box); overflow: hidden;
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
  .tabs .url { height: 10px; margin-bottom: 2px; border-radius: var(--radius-xs); background: var(--sidebar-active); }
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
  .page b.title { width: 40%; height: 7px; margin-bottom: 4px; background: rgba(0, 0, 0, .1); }
  .page .block { flex: 1; max-height: 64px; margin-top: 6px; border-radius: var(--radius-xs); background: rgba(0, 0, 0, .04); }

  .under { display: flex; flex-wrap: wrap; justify-content: center; gap: 12px; }
  /* Light glass whatever the theme: it always sits on the wallpaper. */
  .frosted { display: flex; align-items: center; height: 28px; padding: 3px; border: 0; border-radius: var(--radius-md); color: #3a3850;
    background: rgba(255, 255, 255, .55); backdrop-filter: blur(14px) saturate(1.6);
    box-shadow: 0 4px 14px rgba(10, 5, 40, .25), inset 0 .5px 0 rgba(255, 255, 255, .8), 0 0 0 .5px rgba(0, 0, 0, .12); }
  @media (prefers-reduced-transparency: reduce) { .frosted { background: #fff; backdrop-filter: none; } }
  .day { gap: 6px; padding: 0 4px 0 10px; border-radius: var(--radius-chip); cursor: pointer; }
  .track { position: relative; width: 26px; height: 16px; margin-left: 2px; border-radius: var(--radius-chip); background: rgba(0, 0, 0, .15); transition: background var(--transition-fast); }
  .day[aria-pressed="true"] .track { background: var(--accent); }
  .knob { position: absolute; top: 2px; left: 2px; width: 12px; height: 12px; border-radius: 50%; background: #fff; box-shadow: 0 1px 2px rgba(0, 0, 0, .25); transition: transform var(--transition-fast); }
  .day[aria-pressed="true"] .knob { transform: translateX(10px); }
  .materials { gap: 2px; }
  .material { display: flex; align-items: center; gap: 6px; height: 22px; padding: 0 10px 0 6px; border: 0; border-radius: calc(var(--radius-md) - 3px);
    background: transparent; color: inherit; font: inherit; font-size: var(--font-size-sm); cursor: pointer; }
  .material[aria-checked="true"] { background: #fff; color: #1d1d1f; font-weight: var(--font-weight-medium); box-shadow: 0 1px 3px rgba(0, 0, 0, .15); }
  .day:focus-visible, .material:focus-visible { outline: var(--focus-outline); outline-offset: 2px; }
  .mini { width: 14px; height: 14px; border-radius: var(--radius-xs); background: var(--sidebar-bg); box-shadow: inset 0 0 0 1px rgba(0, 0, 0, .12); }
  .mini.glass { background: linear-gradient(color-mix(in srgb, var(--sidebar-bg) 40%, transparent), color-mix(in srgb, var(--sidebar-bg) 40%, transparent)), var(--desktop); }
  .mini.grain { background-image: var(--grain-texture); background-size: 40px; background-blend-mode: overlay; }

  .themes { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
  .th { display: grid; justify-items: center; gap: 6px; padding: 0; border: 0; background: none; color: var(--text-secondary); font: inherit; font-size: var(--font-size-sm); cursor: pointer; }
  .th.on { color: var(--text-primary); font-weight: var(--font-weight-medium); }
  .shot { display: flex; width: 100%; aspect-ratio: 16 / 10; padding: 6px 6px 6px 24%; border-radius: var(--radius-md);
    box-shadow: 0 0 0 1px var(--separator); background: var(--light); }
  .shot u { flex: 1; border-radius: var(--radius-xs); background: #fff; }
  .shot.dark { background: var(--dark); } .shot.dark u { background: #1e1e1e; }
  .shot.system { background: linear-gradient(90deg, var(--light) 50%, var(--dark) 50%); }
  .shot.system u { background: linear-gradient(90deg, #fff 50%, #1e1e1e 50%); }
  .th.on .shot { box-shadow: 0 0 0 2px var(--onb-surface-strong), 0 0 0 4px var(--accent); }
  .th:focus-visible { outline: none; }
  .th:focus-visible .shot { outline: var(--focus-outline); outline-offset: 2px; }
  @media (prefers-reduced-motion: reduce) { .win, .track, .knob { transition: none; } }
</style>
