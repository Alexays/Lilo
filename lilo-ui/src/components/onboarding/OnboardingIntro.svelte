<script lang="ts">
  import Fleuron from "./Fleuron.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { spaceActions } from "../../lib/bridge/actions";
  import { getActiveSpace } from "../../stores/spaces.svelte";
  import { collapseOnboarding, goNext } from "../../stores/onboarding.svelte";

  let mark = $state<HTMLDivElement | null>(null);
  let cta = $state<HTMLButtonElement | null>(null);
  let leaving = $state(false);

  // The welcome is a modal dialog, which VoiceOver keeps to only once the focus is inside it.
  // WebKit would draw a focus ring for a focus no key brought: `focusVisible` is not in the DOM types yet.
  $effect(() => cta?.focus({ preventScroll: true, focusVisible: false } as FocusOptions));

  /** The petals fly into the sidebar's space icon and become the icon of the first space. */
  async function start(): Promise<void> {
    if (leaving) return;
    leaving = true;
    const anchor = document.querySelector<HTMLElement>('[data-onboarding-anchor="space-icon"]');
    const petals = mark ? [...mark.querySelectorAll<SVGGElement>(".petal")] : [];
    if (anchor && petals.length && !prefersReducedMotion()) {
      const target = anchor.getBoundingClientRect();
      await Promise.all(petals.map((petal, i) => {
        const box = petal.getBoundingClientRect();
        const dx = target.left + target.width / 2 - (box.left + box.width / 2);
        const dy = target.top + target.height / 2 - (box.top + box.height / 2);
        const scale = Math.max(0.06, target.width / Math.max(box.width, 1) / 1.6);
        return petal.animate(
          [{ transform: "none" }, { transform: `translate(${dx}px, ${dy}px) scale(${scale})`, opacity: 0.9 }],
          { duration: 700, delay: i * 60, easing: "cubic-bezier(.5,0,.2,1)", fill: "forwards" },
        ).finished;
      }));
    }
    const space = getActiveSpace();
    // Only an icon nobody chose: the default one, or the house of the Home space a first run starts with.
    if (space && (!space.icon || space.icon === "🌐" || space.icon === "🏠")) spaceActions.update({ id: space.id, icon: "🪻" });
    goNext();
  }

  // Capture phase: the chrome under the intro never sees a key, and Tab cannot leave the CTA.
  function onKeydown(event: KeyboardEvent): void {
    event.stopPropagation();
    if (event.key === "Tab") {
      event.preventDefault();
      cta?.focus();
    } else if (event.key === "Enter") {
      event.preventDefault();
      start();
    } else if (event.key === "Escape") {
      // Skips the welcome: the setup waits in the Resume setup pill.
      event.preventDefault();
      goNext();
      collapseOnboarding();
    }
  }
</script>

<svelte:window onkeydowncapture={onKeydown} />

<div class="intro" class:leaving>
  <div class="mark" bind:this={mark}><Fleuron size={180} /></div>
  <span class="wordmark">Lilo</span>
  <h1>{t("onboarding.intro.headline")}</h1>
  <p>{t("onboarding.intro.subline")}</p>
  <button class="cta" bind:this={cta} onclick={start}>{t("onboarding.intro.start")}</button>
  <span class="hint">{t("onboarding.intro.hint")}</span>
</div>

<style>
  .intro { position: fixed; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center;
    background: radial-gradient(90% 80% at 50% 38%, #fff 0, #f3edff 45%, #e2daf1 100%); transition: background-color .7s, opacity .6s .5s; }
  @media (prefers-color-scheme: dark) {
    .intro { background: radial-gradient(70% 60% at 50% 38%, #2c2459 0, #16132b 50%, #0f0f1a 100%); }
  }
  .intro.leaving { opacity: 0; pointer-events: none; }
  /* Shrinks on a short window so the hint under the button stays on screen. */
  .mark :global(.fleuron) { width: min(180px, 30vh); height: auto; }
  .mark :global(.petal) { animation: bloom .9s var(--motion-ease-bounce) both; animation-delay: calc(var(--i) * 110ms + 100ms); }
  @keyframes bloom { from { opacity: 0; transform: rotate(-35deg) scale(0); } to { opacity: 1; transform: none; } }
  .wordmark { margin-top: 24px; font-size: var(--font-size-xl); font-weight: var(--font-weight-bold); letter-spacing: -.2px; color: var(--text-secondary); animation: blurin .9s .45s var(--motion-ease-spring) both; }
  h1 { margin: 6px 0 0; font-size: var(--font-size-display); font-weight: var(--font-weight-bold); letter-spacing: -1.8px; color: var(--text-primary); animation: blurin .9s .55s var(--motion-ease-spring) both; }
  p { margin: 6px 0 0; font-size: var(--font-size-xl); color: var(--text-secondary); animation: blurin .9s .68s var(--motion-ease-spring) both; }
  .cta { margin-top: 26px; border: 0; border-radius: var(--radius-chip); padding: 10px 22px; font: var(--font-weight-semibold) var(--font-size-lg)/1 -apple-system, system-ui;
    background: var(--text-primary); color: var(--bg-primary); cursor: pointer; animation: blurin .9s .85s var(--motion-ease-spring) both; }
  .hint { margin-top: 14px; font-size: var(--font-size-xs); color: var(--text-muted); animation: blurin .9s 1s var(--motion-ease-spring) both; }
  .leaving .wordmark, .leaving h1, .leaving p, .leaving .cta, .leaving .hint { opacity: 0; transition: opacity .25s; }
  @keyframes blurin { from { opacity: 0; transform: translateY(14px); filter: blur(8px); } to { opacity: 1; transform: none; filter: blur(0); } }
  @media (prefers-reduced-motion: reduce) {
    .mark :global(.petal), .wordmark, h1, p, .cta, .hint { animation: fade .3s both; }
    @keyframes fade { from { opacity: 0; } to { opacity: 1; } }
  }
</style>
