<script lang="ts">
  import { untrack } from "svelte";
  import OnboardingIntro from "./OnboardingIntro.svelte";
  import OnboardingImport from "./OnboardingImport.svelte";
  import OnboardingPasswords from "./OnboardingPasswords.svelte";
  import OnboardingAppearance from "./OnboardingAppearance.svelte";
  import OnboardingEssentials from "./OnboardingEssentials.svelte";
  import OnboardingTips from "./OnboardingTips.svelte";
  import OnboardingUsage from "./OnboardingUsage.svelte";
  import OnboardingAgents from "./OnboardingAgents.svelte";
  import { onboardingSteps } from "./onboardingModel";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { announce } from "../../lib/announce";
  import { chromeActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { getSetting } from "../../stores/settings.svelte";
  import { getActiveTab } from "../../stores/tabs.svelte";
  import {
    collapseOnboarding, expandOnboarding, finishOnboarding, getOnboarding, importedSummary, noteExternalNavigation,
  } from "../../stores/onboarding.svelte";

  const onboarding = getOnboarding();
  const steps = $derived(onboardingSteps(onboarding.usage));
  const step = $derived(steps[onboarding.step]);
  const cardSteps = $derived(steps.slice(1, -1));
  const agentsWelcome = $derived(onboarding.usage !== "browse" && getSetting("agentControlEnabled", "false") === "true");
  // Sign-ins are not something a person counts: the welcome names the rest.
  const imported = $derived(importedSummary(["bookmarks", "tabs", "history", "extensions"]));
  const arrivalText = $derived([
    t("onboarding.arrival.title"),
    imported ? t("onboarding.arrival.imported", { list: imported }) : "",
    agentsWelcome ? t("onboarding.arrival.agents") : "",
  ].filter(Boolean).join(" "));
  const title = $derived(step === "tips" && onboarding.usage === "develop" ? t("onboarding.devTips.title") : t(`onboarding.${step}.title`));

  // A tab gaining a new real URL during the intro means a link came from another app. Only URL
  // changes count: a replay starts with a page already open.
  let lastUrl = untrack(() => getActiveTab()?.url);
  $effect(() => {
    const url = getActiveTab()?.url;
    if (url === lastUrl) return;
    lastUrl = url;
    if (url && /^https?:/.test(url)) untrack(noteExternalNavigation);
  });

  // Startup metric: the frame that first paints the onboarding. A first run's chrome waits for it.
  let markedVisible = false;
  $effect(() => {
    if (!onboarding.visible || markedVisible) return;
    markedVisible = true;
    document.documentElement.removeAttribute("data-booting");
    requestAnimationFrame(() => chromeActions.startupMark("onboardingVisible"));
  });

  // Escape does what the card's close button does, unless a surface above it (the command bar) took the key.
  function handleWindowKeydown(event: KeyboardEvent): void {
    if (event.key !== "Escape" || event.defaultPrevented || !onboarding.visible || onboarding.collapsed) return;
    if (step === "intro" || step === "arrival") return;
    event.preventDefault();
    if (onboarding.mode === "full") collapseOnboarding();
    else finishOnboarding();
  }

  // A step change destroys the button that had the focus: the next screen's main button takes it, so the keyboard
  // and VoiceOver carry on in the card, and Return goes on rather than installing or toggling what comes first.
  function keepFocusInCard(screen: HTMLElement): void {
    queueMicrotask(() => {
      if (document.activeElement !== document.body) return;
      (screen.querySelector<HTMLElement>(".ob-foot .ob-btn.primary:not([disabled])")
        ?? screen.querySelector<HTMLElement>("button:not([disabled]), input:not([disabled]), a[href], [tabindex='0']"))?.focus({ preventScroll: true });
    });
  }

  // The second click of a double click lands on the next screen's button, in the same place: it would skip a step.
  function ignoreRepeatClick(event: MouseEvent): void {
    if (event.detail > 1) event.stopPropagation();
  }

  // The arrival only shows the toast, which nothing focuses: it is spoken, and closes on its own.
  $effect(() => {
    if (step !== "arrival") return;
    announce(untrack(() => arrivalText));
    const timer = setTimeout(finishOnboarding, 6000);
    return () => clearTimeout(timer);
  });
</script>

<svelte:window onkeydown={handleWindowKeydown} />

{#if onboarding.visible}
  {#if step === "intro"}
    <div class="full" role="dialog" aria-modal="true" aria-label={t("onboarding.intro.headline")} use:reportInteractiveZone={{ id: "onboarding-intro" }}><OnboardingIntro /></div>
  {:else if step === "arrival"}
    <div class="toast" use:reportInteractiveZone={{ id: "onboarding-toast" }}>
      <span>{arrivalText}</span>
      <button onclick={finishOnboarding}>{t("onboarding.arrival.done")}</button>
    </div>
  {:else if onboarding.collapsed}
    <button class="pill" use:reportInteractiveZone={{ id: "onboarding-pill" }} onclick={expandOnboarding}>{t("onboarding.resume")}</button>
  {:else}
    <section class="card" aria-label={title} use:reportInteractiveZone={{ id: "onboarding-card" }} onclickcapture={ignoreRepeatClick}>
      <header>
        {#if onboarding.mode === "full"}
          <div class="dots" aria-hidden="true">
            {#each cardSteps as cardStep, i (cardStep)}
              <b class:on={cardStep === step} class:done={i + 1 < onboarding.step}></b>
            {/each}
          </div>
        {/if}
        <button class="close" aria-label={t("onboarding.later")} onclick={onboarding.mode === "full" ? collapseOnboarding : finishOnboarding}>
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true"><path d="M2 2l8 8M10 2l-8 8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg>
        </button>
      </header>
      {#key step}
        <div class="screen" {@attach keepFocusInCard}>
          {#if step === "usage"}<OnboardingUsage />
          {:else if step === "import"}<OnboardingImport />
          {:else if step === "passwords"}<OnboardingPasswords />
          {:else if step === "appearance"}<OnboardingAppearance />
          {:else if step === "essentials"}<OnboardingEssentials />
          {:else if step === "agents"}<OnboardingAgents />
          {:else if step === "tips"}<OnboardingTips />{/if}
        </div>
      {/key}
    </section>
  {/if}
{/if}

<style>
  .full { position: fixed; inset: 0; z-index: 10050; pointer-events: auto; }
  /* Under the command bar (z 60) so Cmd+T taught on the gestures step stays visible. */
  /* Centered by its insets and auto margins, not a translate: WebKit keeps a finished animation's -50% resolved
     against the height it started with, so a card that grows would hang off the window until something repaints it. */
  .card { position: fixed; z-index: 55; pointer-events: auto; inset: 16px var(--chrome-content-right) 16px var(--chrome-content-left-visible); margin: auto;
    width: min(540px, calc(100vw - var(--chrome-content-left-visible) - 48px)); height: fit-content; max-height: calc(100vh - 32px);
    display: flex; flex-direction: column; overflow: hidden;
    border-radius: var(--radius-xl); padding: 22px 28px 22px; container-type: inline-size;
    background: var(--chrome-overlay-surface-strong); border: 1px solid var(--chrome-overlay-border); box-shadow: var(--chrome-overlay-shadow);
    backdrop-filter: blur(var(--chrome-floating-blur)) saturate(1.3); animation: card-in .5s var(--motion-ease-spring) backwards; }
  @keyframes card-in { from { opacity: 0; transform: translateY(16px) scale(.97); } }
  header { flex: none; display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px; }
  .dots { display: flex; gap: 4px; }
  .dots b { height: 5px; width: 5px; border-radius: var(--radius-xs); background: var(--bg-hover); transition: width .4s var(--motion-ease-bounce), background-color var(--motion-duration-slow); }
  .dots b.on { width: 20px; background: var(--accent); }
  .dots b.done { background: color-mix(in srgb, var(--accent) 45%, transparent); }
  .close { border: 0; background: transparent; color: var(--text-muted); font-size: var(--font-size-xl); cursor: pointer; }
  /* The screen scrolls under the header; it spans the card's padding so focus rings at its edges are not clipped. */
  .screen { min-height: 0; overflow-y: auto; overscroll-behavior: contain; margin: 0 -28px -22px; padding: 0 28px 22px;
    animation: screen-in .45s var(--motion-ease-spring) both; }
  /* A screen with its own scrolling part keeps its title and buttons in view and scrolls only that part. It keeps
     a line of it in sight: on a window too short for that, the whole screen scrolls instead. */
  .screen:has(> :global(.ob-scroll)) { display: flex; flex-direction: column; }
  .screen:has(> :global(.ob-scroll)) > :global(:not(.ob-scroll)) { flex: none; }
  .card :global(.ob-scroll) { min-height: 32px; overflow-y: auto; overscroll-behavior: contain; margin: 0 -6px; padding: 0 6px 4px; }
  @keyframes screen-in { from { opacity: 0; transform: translateX(18px); } }
  .card :global(h3) { margin: 0; font-size: var(--font-size-3xl); letter-spacing: -0.4px; color: var(--text-primary); }
  .card :global(.ob-sub) { margin: 6px 0 18px; font-size: var(--font-size-md); line-height: 1.45; color: var(--text-secondary); }
  /* Wraps: on a narrow card a button drops under the label rather than squeezing it. */
  .card :global(.ob-row) { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; padding: 12px 14px; border-radius: var(--radius-lg); background: var(--bg-hover); margin-bottom: 8px; font-size: var(--font-size-lg); color: var(--text-primary); }
  .card :global(.ob-text) { flex: 1 1 100px; min-width: 0; font-weight: var(--font-weight-semibold); }
  .card :global(.ob-row > :last-child:not(.ob-text)) { margin-left: auto; }
  .card :global(.ob-text small) { display: block; margin-top: 2px; font-size: var(--font-size-sm); font-weight: var(--font-weight-regular); color: var(--text-secondary); }
  /* A Settings section icon, scaled to the row. */
  .card :global(.ob-icon) { width: 30px; height: 30px; flex: none; display: grid; place-items: center; border-radius: var(--radius-sm); background: var(--accent-tint-22); color: var(--accent-ink); }
  .card :global(.ob-done) { font-size: var(--font-size-sm); font-weight: var(--font-weight-semibold); color: var(--success-text); }
  .card :global(.ob-btn.small) { padding: 8px 14px; font-size: var(--font-size-sm); }
  .card :global(.ob-foot) { flex: none; display: flex; justify-content: space-between; align-items: center; margin-top: 20px; }
  .card :global(.ob-btn) { border: 0; border-radius: var(--radius-chip); padding: 8px 20px; white-space: nowrap; font: var(--font-weight-semibold) var(--font-size-md)/1 -apple-system, system-ui; cursor: pointer;
    background: var(--bg-hover); color: var(--text-primary); transition: transform .2s var(--motion-ease-spring), opacity var(--motion-duration-normal); }
  .card :global(.ob-btn:hover:not(:disabled)) { transform: translateY(-1px); }
  .card :global(.ob-btn:active:not(:disabled)) { transform: scale(.96); }
  .card :global(.ob-btn:disabled) { opacity: var(--disabled-opacity); cursor: default; }
  .card :global(.ob-btn.primary) { background: var(--accent); color: var(--accent-text); }
  .card :global(.ob-btn.ghost) { background: transparent; color: var(--text-secondary); padding: 8px 12px; }
  .card :global(.ob-btn:focus-visible) { outline: var(--focus-outline); outline-offset: 1px; }
  .pill, .toast { position: fixed; z-index: 55; pointer-events: auto; bottom: 24px; right: 24px; border-radius: var(--radius-lg); padding: 10px 16px;
    background: var(--chrome-overlay-surface-strong); border: 1px solid var(--chrome-overlay-border); box-shadow: var(--chrome-overlay-shadow);
    color: var(--text-primary); font-size: var(--font-size-md); }
  .pill { cursor: pointer; }
  /* Centered by its insets, not a translate: a left edge at the center would leave it half the width to wrap in. */
  .toast { left: calc(var(--chrome-content-left-visible) + 16px); right: 16px; width: fit-content; margin-inline: auto;
    display: flex; gap: 12px; align-items: center; animation: toast-in .6s var(--motion-ease-bounce) both; }
  .toast button { flex: none; white-space: nowrap; border: 0; border-radius: var(--radius-chip); padding: 6px 14px; background: var(--text-primary); color: var(--bg-primary); cursor: pointer; }
  @keyframes toast-in { from { opacity: 0; transform: translateY(24px); } }
  @media (prefers-reduced-motion: reduce) { .card, .screen, .toast, .dots b { animation: none; transition: none; } }
</style>
