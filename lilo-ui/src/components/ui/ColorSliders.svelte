<script lang="ts">
  import { on } from "../../lib/bridge";
  import { chromeActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { colorToSliders, slidersToColor, type ColorTone } from "../../lib/colorSliders";

  let { color, tone, presets, oncolor, compact = false, picking = $bindable(false) }: {
    color: string;
    tone: ColorTone;
    /** Colors a slider position snaps to when close, so the named presets stay easy to find. */
    presets: readonly string[];
    oncolor: (color: string) => void;
    compact?: boolean;
    /** True while the system color sampler is on screen. */
    picking?: boolean;
  } = $props();

  // A slider stays where the pointer left it: reading it back from a snapped preset would make it jump.
  let hue = $state(0);
  let intensity = $state(0);
  let sent = "";

  $effect.pre(() => {
    if (color === sent) return;
    ({ hue, intensity } = colorToSliders(color, tone));
    sent = color;
  });

  function apply(nextHue: number, nextIntensity: number): void {
    hue = nextHue;
    intensity = nextIntensity;
    sent = slidersToColor(hue, intensity, tone, presets);
    if (sent !== color) oncolor(sent);
  }

  function pick(): void {
    if (picking) return;
    picking = true;
    const off = on("screenColorSampled", ({ color: picked }) => {
      off();
      picking = false;
      if (!picked) return;
      const sliders = colorToSliders(picked, tone);
      apply(sliders.hue, sliders.intensity);
    });
    chromeActions.sampleScreenColor();
  }

  const full = $derived(slidersToColor(hue, 1, tone, []));
  const rainbow = $derived(
    Array.from({ length: 13 }, (_, i) => slidersToColor(i * 30, Math.max(intensity, 0.5), tone, [])).join(", "),
  );
</script>

<div class="color-sliders" class:compact>
  <button class="well" class:picking style:background={color} aria-label={t("colorPicker.eyedropper")}
    use:tooltip={t("colorPicker.eyedropper")} onmousedown={(e) => e.preventDefault()} onclick={pick}>
    <span class="badge" aria-hidden="true">
      <svg width="11" height="11" viewBox="0 0 14 14" fill="none"><path d="M8.6 2.4a1.6 1.6 0 0 1 2.3 0l.7.7a1.6 1.6 0 0 1 0 2.3L10 7 7 4zM7.6 4.6l1.8 1.8-5 5H2.6V9.6z" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" /></svg>
    </span>
  </button>
  <div class="sliders">
    <input type="range" min="0" max="359" step="1" value={Math.round(hue)} aria-label={t("colorPicker.hue")}
      style:background="linear-gradient(to right, {rainbow})" style:--thumb={color}
      oninput={(e) => apply(e.currentTarget.valueAsNumber, Math.max(intensity, 0.4))} />
    <input type="range" min="0" max="100" step="1" value={Math.round(intensity * 100)} aria-label={t("colorPicker.intensity")}
      style:background="linear-gradient(to right, {slidersToColor(hue, 0, tone, [])}, {full})" style:--thumb={color}
      oninput={(e) => apply(hue, e.currentTarget.valueAsNumber / 100)} />
  </div>
</div>

<style>
  .color-sliders {
    --well: 54px;
    --track: 22px;
    display: grid;
    grid-template-columns: var(--well) minmax(0, 1fr);
    align-items: center;
    gap: 12px;
  }

  .compact {
    --well: 38px;
    --track: 16px;
    gap: 10px;
  }

  .well {
    position: relative;
    height: var(--well);
    padding: 0;
    border: 0;
    border-radius: var(--radius-box);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--text-primary) 22%, transparent), var(--shadow-control);
    cursor: pointer;
    transition: background-color var(--motion-duration-fast);
  }

  .compact .well {
    border-radius: var(--radius-md);
  }

  .well:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  .badge {
    position: absolute;
    right: -5px;
    bottom: -5px;
    display: grid;
    place-items: center;
    width: 20px;
    height: 20px;
    border-radius: 50%;
    background: var(--on-color);
    color: black;
    box-shadow: var(--shadow-control);
    transition: transform var(--motion-duration-fast) var(--motion-ease-spring);
  }

  .well:hover .badge {
    transform: scale(1.12);
  }

  .well.picking {
    box-shadow: 0 0 0 2px var(--sidebar-bg), 0 0 0 4px var(--text-primary);
  }

  .well.picking .badge {
    background: var(--text-primary);
    color: var(--sidebar-bg);
  }

  .sliders {
    display: flex;
    flex-direction: column;
    gap: 10px;
    min-width: 0;
  }

  .compact .sliders {
    gap: 6px;
  }

  input {
    width: 100%;
    height: var(--track);
    margin: 0;
    border-radius: calc(var(--track) / 2);
    box-shadow: inset 0 0 0 1px var(--text-primary-tint-12);
    appearance: none;
    cursor: pointer;
  }

  input::-webkit-slider-thumb {
    width: var(--track);
    height: var(--track);
    border: 3px solid var(--on-color);
    border-radius: 50%;
    background: var(--thumb);
    box-shadow: 0 1px 5px color-mix(in srgb, black 40%, transparent);
    appearance: none;
  }

  .compact input::-webkit-slider-thumb {
    width: calc(var(--track) + 2px);
    height: calc(var(--track) + 2px);
    border-width: 2.5px;
  }

  input:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  @media (prefers-reduced-motion: reduce) {
    .well,
    .badge {
      transition: none;
    }
  }
</style>
