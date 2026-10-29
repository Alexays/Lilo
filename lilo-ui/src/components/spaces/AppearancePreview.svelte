<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import type { SpaceMaterial } from "../../lib/bridge/protocol";

  let { material, desktop, onmaterial, followsDay, onday }: {
    material: SpaceMaterial;
    /** The wallpaper, or what stands in for it, as a CSS background. */
    desktop: string;
    onmaterial: (material: SpaceMaterial) => void;
    /** Whether the color changes with the time of day; null hides the switch. */
    followsDay: boolean | null;
    onday: (on: boolean) => void;
  } = $props();

  const MATERIALS: SpaceMaterial[] = ["solid", "glass", "grain"];

  // The light follows the pointer across the desktop, which leans toward it.
  let light = $state({ x: 0.3, y: 0.2 });
  let tilt = $state({ x: 0, y: 0 });
  function trackLight(event: PointerEvent): void {
    const rect = (event.currentTarget as HTMLElement).getBoundingClientRect();
    const x = (event.clientX - rect.left) / rect.width;
    const y = (event.clientY - rect.top) / rect.height;
    light = { x, y };
    if (!prefersReducedMotion()) tilt = { x: (0.5 - y) * 6, y: (x - 0.5) * 8 };
  }

  function handleKeydown(event: KeyboardEvent): void {
    const step = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1 : event.key === "ArrowLeft" || event.key === "ArrowUp" ? -1 : 0;
    if (step === 0) return;
    event.preventDefault();
    const next = (Math.max(MATERIALS.indexOf(material), 0) + step + MATERIALS.length) % MATERIALS.length;
    onmaterial(MATERIALS[next]);
    (event.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>("button")[next]?.focus();
  }
</script>

<div class="desk" style:background={desktop} style:transform="perspective(700px) rotateX({tilt.x}deg) rotateY({tilt.y}deg)"
  onpointermove={trackLight} onpointerleave={() => (tilt = { x: 0, y: 0 })} role="presentation">
  <!-- Today's window, drawn small in the Space's color and material. -->
  <div class="win {material}" aria-hidden="true">
    <div class="side">
      <div class="bar"><span class="lights"><i></i><i></i><i></i></span><span class="tools"><i></i><i></i><i></i></span></div>
      <div class="url"><b></b></div>
      <div class="label"></div>
      <div class="pins"><i></i><i></i><i></i></div>
      <div class="tab"><b></b><i style:width="60%"></i></div>
      <div class="tab"><b></b><i style:width="46%"></i></div>
      <div class="tab active"><b></b><i style:width="70%"></i></div>
      <div class="tab"><b></b><i style:width="52%"></i></div>
    </div>
    <div class="page"><i style:width="42%"></i><i></i><i style:width="86%"></i><i style:width="64%"></i><span class="block"></span></div>
  </div>
  <div class="sheen" style:background="radial-gradient(200px circle at {light.x * 100}% {light.y * 100}%, rgba(255, 255, 255, 0.3), transparent 60%)"></div>
  {#if followsDay !== null}
    <!-- Turned on, the desktop passes to evening and back once: what the switch does, shown. -->
    <div class="dusk" class:on={followsDay}></div>
    <button class="day" class:on={followsDay} aria-pressed={followsDay} aria-label={t("spaceEditor.followDay")}
      use:tooltip={`${t("spaceEditor.followDay")}. ${t("spaceEditor.followDayHint")}`} onclick={() => onday(!followsDay)}>
      <svg width="13" height="13" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2v1.3M8 12.7V14M2 8h1.3M12.7 8H14M3.8 3.8l.9.9M11.3 11.3l.9.9M3.8 12.2l.9-.9M11.3 4.7l.9-.9M8 5.4a2.6 2.6 0 1 0 0 5.2a2.6 2.6 0 0 0 0-5.2Z" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" /></svg>
      <svg class="to" width="8" height="8" viewBox="0 0 8 8" aria-hidden="true"><path d="M1 4h6M4.5 1.5 7 4 4.5 6.5" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round" /></svg>
      <svg width="12" height="12" viewBox="0 0 16 16" aria-hidden="true"><path d="M13 9.5A5.5 5.5 0 0 1 6.5 3a5.5 5.5 0 1 0 6.5 6.5Z" fill="currentColor" /></svg>
      <span class="track"><span class="knob"></span></span>
    </button>
  {/if}
  <!-- A glass bar on the window: the material is picked where it shows. -->
  <div class="materials" role="radiogroup" tabindex="-1" aria-label={t("spaceEditor.materialLabel")} onkeydown={handleKeydown}>
    {#each MATERIALS as value (value)}
      <button class="material" role="radio" aria-checked={material === value} tabindex={material === value ? 0 : -1} onclick={() => onmaterial(value)}>
        <span class="mini {value}" style:--desktop={desktop}></span>{t(`spaceEditor.material.${value}`)}
      </button>
    {/each}
  </div>
</div>

<style>
  .desk {
    position: relative;
    height: 172px;
    padding: 16px 0 0 20px;
    border-radius: var(--radius-lg);
    overflow: hidden;
    box-shadow: inset 0 0 0 0.5px rgba(0, 0, 0, 0.2);
    transition: transform 0.4s cubic-bezier(0.2, 0.8, 0.2, 1);
  }

  /* Runs off the bottom and fades there, under the material bar. */
  .win {
    display: flex;
    height: 100%;
    -webkit-mask-image: linear-gradient(to bottom, black 55%, transparent 92%);
    mask-image: linear-gradient(to bottom, black 55%, transparent 92%);
    border-radius: var(--radius-md) 0 0 0;
    overflow: hidden;
    background: var(--sidebar-bg);
    box-shadow: 0 10px 30px rgba(10, 5, 40, 0.45), 0 0 0 0.5px rgba(0, 0, 0, 0.3);
    transition: background-color var(--motion-duration-slow);
  }

  .win.glass {
    background: color-mix(in srgb, var(--sidebar-bg) 40%, transparent);
    -webkit-backdrop-filter: blur(10px) saturate(1.8);
    backdrop-filter: blur(10px) saturate(1.8);
    box-shadow: 0 10px 30px rgba(10, 5, 40, 0.35), inset 1px 1px 0 rgba(255, 255, 255, 0.55);
  }

  .win.grain {
    background-image: var(--grain-texture);
    background-size: 120px;
    background-blend-mode: overlay;
  }

  .side {
    display: flex;
    flex: none;
    flex-direction: column;
    gap: 4px;
    width: 96px;
    padding: 6px 6px 0;
  }

  .side i,
  .side b {
    display: block;
    border-radius: var(--radius-2xs);
  }

  .bar {
    display: flex;
    justify-content: space-between;
    align-items: center;
    height: 9px;
    margin-bottom: 1px;
  }

  .lights,
  .tools {
    display: flex;
    gap: 3px;
  }

  .lights i {
    width: 5px;
    height: 5px;
    border-radius: 50%;
    background: #ff5f57;
  }

  .lights i:nth-child(2) {
    background: #febc2e;
  }

  .lights i:nth-child(3) {
    background: #28c840;
  }

  .tools i {
    width: 5px;
    height: 5px;
    background: color-mix(in srgb, var(--text-primary) 22%, transparent);
  }

  .url {
    height: 11px;
    padding: 3.5px 5px;
    border-radius: var(--radius-xs);
    background: color-mix(in srgb, white 45%, transparent);
  }

  .url b {
    width: 70%;
    height: 4px;
    background: color-mix(in srgb, var(--text-primary) 30%, transparent);
  }

  .label {
    width: 22px;
    height: 3px;
    margin: 3px 0 0 2px;
    border-radius: var(--radius-2xs);
    background: color-mix(in srgb, var(--text-primary) 25%, transparent);
  }

  .pins {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 3px;
  }

  .pins i {
    height: 12px;
    background: color-mix(in srgb, white 32%, transparent);
  }

  .tab {
    display: flex;
    align-items: center;
    gap: 4px;
    height: 10px;
    padding: 0 4px;
    border-radius: var(--radius-2xs);
  }

  .tab b {
    flex: none;
    width: 5px;
    height: 5px;
    background: color-mix(in srgb, var(--text-primary) 28%, transparent);
  }

  .tab i {
    height: 3px;
    background: color-mix(in srgb, var(--text-primary) 26%, transparent);
  }

  .tab.active {
    background: color-mix(in srgb, white 72%, transparent);
    box-shadow: 0 0.5px 1.5px rgba(0, 0, 0, 0.12);
  }

  .page {
    display: flex;
    flex: 1;
    flex-direction: column;
    gap: 5px;
    margin: 4px 0;
    padding: 14px 12px;
    border-radius: var(--radius-xs) 0 0 var(--radius-xs);
    background: var(--bg-primary);
  }

  .page i {
    height: 4px;
    border-radius: var(--radius-2xs);
    background: var(--text-primary-tint-12);
  }

  .page .block {
    flex: 1;
    margin: 4px 0 6px;
    border-radius: var(--radius-xs);
    background: color-mix(in srgb, var(--text-primary-tint-12) 50%, transparent);
  }

  .dusk {
    position: absolute;
    inset: 0;
    opacity: 0;
    pointer-events: none;
    background: linear-gradient(160deg, rgba(255, 150, 70, 0.28), rgba(25, 15, 70, 0.45));
  }

  .dusk.on {
    animation: dusk 1.6s ease-in-out 2 alternate;
  }

  @keyframes dusk {
    to {
      opacity: 1;
    }
  }

  /* Light glass whatever the theme, like the material bar. */
  .day {
    position: absolute;
    top: 8px;
    right: 8px;
    display: flex;
    align-items: center;
    gap: 4px;
    height: var(--control-height-sm);
    padding: 0 4px 0 8px;
    border: 0;
    border-radius: var(--radius-chip);
    background: rgba(255, 255, 255, 0.55);
    -webkit-backdrop-filter: blur(14px) saturate(1.6);
    backdrop-filter: blur(14px) saturate(1.6);
    color: #3a3850;
    cursor: pointer;
    box-shadow: 0 4px 14px rgba(10, 5, 40, 0.25), inset 0 0.5px 0 rgba(255, 255, 255, 0.8), 0 0 0 0.5px rgba(0, 0, 0, 0.12);
  }

  .day:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  .to {
    opacity: 0.6;
  }

  .track {
    position: relative;
    width: 26px;
    height: 16px;
    margin-left: 4px;
    border-radius: var(--radius-chip);
    background: rgba(0, 0, 0, 0.15);
    transition: background var(--transition-fast);
  }

  .day.on .track {
    background: var(--accent);
  }

  .knob {
    position: absolute;
    top: 2px;
    left: 2px;
    width: 12px;
    height: 12px;
    border-radius: 50%;
    background: #ffffff;
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.25);
    transition: transform var(--transition-fast);
  }

  .day.on .knob {
    transform: translateX(10px);
  }


  .sheen {
    position: absolute;
    inset: 0;
    pointer-events: none;
    mix-blend-mode: soft-light;
  }

  /* Light glass whatever the theme: it always sits on the wallpaper. */
  .materials {
    position: absolute;
    left: 50%;
    bottom: 9px;
    display: flex;
    gap: 2px;
    padding: 3px;
    transform: translateX(-50%);
    border-radius: var(--radius-md);
    background: rgba(255, 255, 255, 0.55);
    -webkit-backdrop-filter: blur(14px) saturate(1.6);
    backdrop-filter: blur(14px) saturate(1.6);
    box-shadow: 0 4px 14px rgba(10, 5, 40, 0.25), inset 0 0.5px 0 rgba(255, 255, 255, 0.8), 0 0 0 0.5px rgba(0, 0, 0, 0.12);
  }

  .material {
    display: flex;
    align-items: center;
    gap: 5px;
    height: var(--control-height-sm);
    padding: 0 9px 0 5px;
    border: 0;
    border-radius: calc(var(--radius-md) - 3px);
    background: transparent;
    color: #3a3850;
    font-family: inherit;
    font-size: var(--font-size-xs);
    cursor: pointer;
  }

  .material[aria-checked="true"] {
    background: #ffffff;
    color: #1d1d1f;
    font-weight: var(--font-weight-semibold);
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.15);
  }

  .material:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  .mini {
    width: 14px;
    height: 14px;
    border-radius: 50%;
    background: var(--sidebar-bg);
    box-shadow: inset 0 0 0 1px rgba(0, 0, 0, 0.12);
  }

  .mini.glass {
    background: linear-gradient(color-mix(in srgb, var(--sidebar-bg) 40%, transparent), color-mix(in srgb, var(--sidebar-bg) 40%, transparent)), var(--desktop);
  }

  .mini.grain {
    background-image: var(--grain-texture);
    background-size: 40px;
    background-blend-mode: overlay;
  }

  @media (prefers-reduced-motion: reduce) {
    .desk,
    .track,
    .knob {
      transition: none;
    }

    .dusk.on {
      animation: none;
    }
  }
</style>
