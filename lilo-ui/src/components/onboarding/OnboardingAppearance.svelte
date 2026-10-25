<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import { goBack, goNext } from "../../stores/onboarding.svelte";
  import { getActiveSpace } from "../../stores/spaces.svelte";
  import { spaceActions } from "../../lib/bridge/actions";
  import ColorModePicker from "../spaces/ColorModePicker.svelte";

  // The first Space is the one on screen: its color answers the choice right away.
  const space = $derived(getActiveSpace());

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
  const current = $derived(getSetting("theme", "system"));

  function handleKeydown(event: KeyboardEvent): void {
    const step = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1 : event.key === "ArrowLeft" || event.key === "ArrowUp" ? -1 : 0;
    if (step === 0) return;
    event.preventDefault();
    const index = (Math.max(THEMES.findIndex((theme) => theme === current), 0) + step + THEMES.length) % THEMES.length;
    setSetting("theme", THEMES[index]);
    (event.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>("button")[index]?.focus();
  }
</script>

<h3>{t("onboarding.appearance.title")}</h3>
<p class="ob-sub">{t("onboarding.appearance.subtitle")}</p>

<span class="group-label" id="onboarding-theme-label">{t("onboarding.appearance.theme")}</span>
<div class="themes" role="radiogroup" tabindex="-1" aria-labelledby="onboarding-theme-label" onkeydown={handleKeydown}>
  {#each THEMES as theme (theme)}
    <button class="th" class:on={current === theme} role="radio" aria-checked={current === theme} tabindex={current === theme ? 0 : -1}
      onclick={() => setSetting("theme", theme)}>
      <span class="pv pv-{theme}"><i></i><u></u></span>{t(`onboarding.appearance.${theme}`)}
    </button>
  {/each}
</div>

{#if space}
  <div class="color-source">
    <span class="group-label" id="onboarding-color-label">{t("onboarding.appearance.color")}</span>
    <ColorModePicker
      mode={space.colorMode ?? "fixed"}
      color={space.color}
      labelledby="onboarding-color-label"
      onmode={(colorMode) => spaceActions.update({ id: space.id, colorMode })}
      oncolor={setColor}
    />
  </div>
{/if}

<div class="ob-foot">
  <button class="ob-btn ghost" onclick={goBack}>{t("onboarding.back")}</button>
  <button class="ob-btn primary" onclick={goNext}>{t("onboarding.continue")}</button>
</div>

<style>
  .group-label { display: block; margin-bottom: 8px; font-size: var(--font-size-sm); font-weight: var(--font-weight-semibold); color: var(--text-primary); }
  .color-source { margin-top: 18px; --color-mode-thumb-height: 44px; }
  .themes { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
  .th { border-radius: var(--radius-lg); padding: 8px; background: var(--bg-hover); border: 2px solid transparent; cursor: pointer; font-size: var(--font-size-sm); color: var(--text-primary);
    transition: border-color var(--motion-duration-normal), transform .2s var(--motion-ease-spring); }
  .th:hover { transform: translateY(-1px); } .th.on { border-color: var(--accent); }
  .pv { display: flex; height: 62px; border-radius: var(--radius-md); margin-bottom: 6px; overflow: hidden; }
  .pv i { width: 30%; } .pv u { flex: 1; margin: 4px; border-radius: var(--radius-sm); }
  .pv-system { background: linear-gradient(90deg, #e2daf1 50%, #1a1a2e 50%); } .pv-system u { background: linear-gradient(90deg, #fff 50%, #0f0f1a 50%); }
  .pv-light { background: #e2daf1; } .pv-light u { background: #fff; }
  .pv-dark { background: #1a1a2e; } .pv-dark u { background: #0f0f1a; }
</style>
