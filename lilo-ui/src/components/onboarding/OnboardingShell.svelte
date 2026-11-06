<script lang="ts">
  import { untrack } from "svelte";
  import OnboardingIntro from "./OnboardingIntro.svelte";
  import OnboardingImport from "./OnboardingImport.svelte";
  import OnboardingYourLilo from "./OnboardingYourLilo.svelte";
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
  // One dot per screen, the welcome included; the arrival is a toast.
  const screens = $derived(steps.slice(0, -1));
  const agentsWelcome = $derived(onboarding.usage !== "browse" && getSetting("agentControlEnabled", "false") === "true");
  // Sign-ins are not something a person counts: the welcome names the rest.
  const imported = $derived(importedSummary(["bookmarks", "tabs", "history", "extensions"]));
  const arrivalText = $derived([
    t("onboarding.arrival.title"),
    imported ? t("onboarding.arrival.imported", { list: imported }) : "",
    agentsWelcome ? t("onboarding.arrival.agents") : "",
  ].filter(Boolean).join(" "));
  const title = $derived(step === "intro" ? t("onboarding.intro.headline")
    : onboarding.mode === "passwords" ? t("onboarding.passwords.title") : t(`onboarding.${step}.title`));

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

  function later(): void {
    if (onboarding.mode === "full") collapseOnboarding();
    else finishOnboarding();
  }

  // Escape does what the close button does, unless a surface above (the command bar) took the key. Return runs the
  // primary button from anywhere but a control that answers it itself.
  function handleWindowKeydown(event: KeyboardEvent): void {
    if (event.defaultPrevented || !onboarding.visible || onboarding.collapsed || step === "intro" || step === "arrival") return;
    if (event.key === "Escape") {
      event.preventDefault();
      later();
    } else if (event.key === "Enter" && !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey) {
      const target = event.target as Element | null;
      if (!target?.closest(".onb") || target.closest("button:not([role=radio]), input, textarea, select, a, label")) return;
      const primary = document.querySelector<HTMLButtonElement>(".onb .ob-foot .ob-btn.primary:not([disabled])");
      if (!primary) return;
      event.preventDefault();
      primary.click();
    }
  }

  // A step change destroys the button that had the focus: the next screen's main button takes it, so the keyboard
  // and VoiceOver carry on in the flow, and Return goes on rather than installing or toggling what comes first.
  function keepFocusInScreen(screen: HTMLElement): void {
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
  {#if step === "arrival"}
    <div class="toast" use:reportInteractiveZone={{ id: "onboarding-toast" }}>
      <span>{arrivalText}</span>
      <button onclick={finishOnboarding}>{t("onboarding.arrival.done")}</button>
    </div>
  {:else if onboarding.collapsed}
    <button class="pill" use:reportInteractiveZone={{ id: "onboarding-pill" }} onclick={expandOnboarding}>{t("onboarding.resume")}</button>
  {:else}
    <div class="onb" role="dialog" aria-modal="true" aria-label={title} use:reportInteractiveZone={{ id: "onboarding" }} onclickcapture={ignoreRepeatClick}>
      {#if step !== "intro"}
        {#if onboarding.mode === "full"}
          <div class="dots" aria-hidden="true">
            {#each screens as screen, i (screen)}
              <b class:on={screen === step} class:done={i < onboarding.step}></b>
            {/each}
          </div>
        {/if}
        <button class="close" aria-label={t("onboarding.later")} onclick={later}>
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true"><path d="M2 2l8 8M10 2l-8 8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg>
        </button>
      {/if}
      {#key step}
        <div class="screen step-{step}" {@attach keepFocusInScreen}>
          {#if step === "intro"}<OnboardingIntro />
          {:else if step === "usage"}<OnboardingUsage />
          {:else if step === "import"}<OnboardingImport />
          {:else if step === "yourLilo"}<OnboardingYourLilo />
          {:else if step === "agents"}<OnboardingAgents />{/if}
        </div>
      {/key}
    </div>
  {/if}
{/if}

<style>
  /* One container from the welcome to the last question, over the whole window: the traffic lights stay on it. */
  .onb { position: fixed; inset: 0; z-index: 10050; pointer-events: auto; container-type: inline-size;
    background: radial-gradient(90% 80% at 50% 38%, #fff 0, #f3edff 45%, #e2daf1 100%) #f3edff; }
  @media (prefers-color-scheme: dark) {
    .onb { background: radial-gradient(70% 60% at 50% 38%, #2c2459 0, #16132b 50%, #0f0f1a 100%) #16132b; }
  }
  .dots { position: absolute; top: 24px; left: 50%; translate: -50% 0; display: flex; gap: 6px; }
  .dots b { height: 5px; width: 5px; border-radius: var(--radius-chip); background: var(--text-primary-tint-12); transition: width var(--motion-duration-slow) var(--motion-ease-spring), background-color var(--motion-duration-slow); }
  .dots b.on { width: 24px; background: var(--accent); }
  .dots b.done { background: color-mix(in srgb, var(--accent) 45%, transparent); }
  .close { position: absolute; z-index: 1; top: 14px; right: 16px; width: 28px; height: 28px; display: grid; place-items: center; border: 0; border-radius: var(--radius-sm);
    background: transparent; color: var(--text-secondary); cursor: pointer; }
  .close:hover { background: var(--bg-hover); color: var(--text-primary); }
  .close:focus-visible { outline: var(--focus-outline); outline-offset: 1px; }

  /* A question: its title, a body that scrolls on a short window, and the buttons at the foot of the window. */
  .screen { --column: 960px; position: absolute; inset: 0; display: flex; flex-direction: column; padding: 72px max(40px, calc((100% - var(--column)) / 2)) 28px;
    animation: screen-in .45s var(--motion-ease-spring) both; }
  .screen.step-intro { padding: 0; animation: none; }
  .screen.step-agents { --column: 640px; }
  @keyframes screen-in { from { opacity: 0; transform: translateX(18px); } }
  :where(.onb) :global(.ob-head) { flex: none; margin-bottom: 28px; }
  :where(.onb) :global(h2) { margin: 0; font-size: var(--font-size-headline); font-weight: var(--font-weight-semibold); letter-spacing: -0.4px; color: var(--text-primary); }
  :where(.onb) :global(.ob-sub) { max-width: 720px; margin: 8px 0 0; font-size: var(--font-size-body-lg); line-height: 1.45; color: var(--text-secondary); }
  :where(.onb) :global(.ob-body) { flex: 1; min-height: 0; overflow-y: auto; overscroll-behavior: contain; margin: -8px -8px 0; padding: 8px; }
  :where(.onb) :global(.ob-foot) { flex: none; display: flex; align-items: center; gap: 8px; padding-top: 16px; }
  :where(.onb) :global(.ob-foot > :first-child) { margin-right: auto; }

  /* Section headers and grouped boxes, as in Settings. */
  :where(.onb) :global(.ob-section) { margin: 0 0 8px 2px; font-size: var(--font-size-xs); font-weight: var(--font-weight-semibold); letter-spacing: .04em; text-transform: uppercase; color: var(--text-secondary); }
  :where(.onb) :global(.ob-group) { border-radius: var(--radius-box); background: var(--onb-surface); box-shadow: 0 0 0 .5px var(--onb-edge); overflow: hidden; }
  :where(.onb) :global(.ob-row) { display: flex; align-items: center; gap: 14px; min-height: 56px; padding: 11px 14px; color: var(--text-primary); }
  :where(.onb) :global(.ob-row + .ob-row) { box-shadow: inset 0 1px 0 var(--separator); }
  :where(.onb) :global(.ob-text) { flex: 1; min-width: 0; font-size: var(--font-size-md); font-weight: var(--font-weight-medium); }
  :where(.onb) :global(.ob-text small) { display: block; margin-top: 2px; font-size: var(--font-size-sm); font-weight: var(--font-weight-regular); color: var(--text-secondary); }
  :where(.onb) :global(.ob-done) { display: inline-flex; align-items: center; gap: 4px; font-size: var(--font-size-sm); font-weight: var(--font-weight-medium); color: var(--success-text); }
  :where(.onb) :global(.ob-done::before) { content: ""; width: 10px; height: 10px; background: currentColor;
    mask: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12'%3E%3Cpath d='M2.5 6.2l2.3 2.3 4.7-5' fill='none' stroke='black' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") center / contain no-repeat; }

  :where(.onb) :global(.ob-btn) { display: inline-flex; align-items: center; gap: 8px; height: var(--control-height-sm); padding: 0 12px; border: 0; border-radius: var(--radius-sm); white-space: nowrap;
    font: var(--font-weight-medium) var(--font-size-md)/1 -apple-system, system-ui; cursor: pointer;
    background: var(--onb-surface-strong); box-shadow: 0 0 0 .5px var(--onb-edge), 0 .5px 1px var(--onb-edge); color: var(--text-primary); }
  :where(.onb) :global(.ob-btn:disabled) { opacity: var(--disabled-opacity); cursor: default; }
  :where(.onb) :global(.ob-btn.primary) { padding: 0 10px 0 16px; background: var(--accent); box-shadow: none; color: var(--accent-text); }
  :where(.onb) :global(.ob-btn.primary:hover:not(:disabled)) { background: var(--accent-hover); }
  /* The Return keycap: Return runs it from anywhere on the screen. */
  :where(.onb) :global(.ob-btn.primary::after) { content: ""; width: 11px; height: 11px; background: currentColor; opacity: .75;
    mask: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12'%3E%3Cpath d='M10 2v3.5A1.5 1.5 0 0 1 8.5 7H2.5M4.5 5 2.5 7l2 2' fill='none' stroke='black' stroke-width='1.3' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") center / contain no-repeat; }
  :where(.onb) :global(.ob-btn.ghost) { background: transparent; box-shadow: none; color: var(--text-secondary); }
  :where(.onb) :global(.ob-btn.ghost:hover:not(:disabled)) { background: var(--bg-hover); color: var(--text-primary); }
  :where(.onb) :global(.ob-btn:focus-visible) { outline: var(--focus-outline); outline-offset: 1px; }

  .onb { --onb-surface: color-mix(in srgb, var(--bg-elevated) 62%, transparent); --onb-surface-strong: var(--bg-elevated); --onb-edge: var(--text-primary-tint-12); }
  :global(html.reduced-transparency) .onb { --onb-surface: var(--bg-elevated); }
  @media (prefers-contrast: more) { .onb { --onb-surface: var(--bg-elevated); --onb-edge: var(--text-secondary); } }

  .pill, .toast { position: fixed; z-index: 55; pointer-events: auto; bottom: 24px; right: 24px; border-radius: var(--radius-lg); padding: 10px 16px;
    background: var(--chrome-overlay-surface-strong); border: 1px solid var(--chrome-overlay-border); box-shadow: var(--chrome-overlay-shadow);
    color: var(--text-primary); font-size: var(--font-size-md); }
  .pill { cursor: pointer; }
  /* Centered by its insets, not a translate: a left edge at the center would leave it half the width to wrap in. */
  .toast { left: calc(var(--chrome-content-left-visible) + 16px); right: 16px; width: fit-content; margin-inline: auto;
    display: flex; gap: 12px; align-items: center; animation: toast-in .6s var(--motion-ease-bounce) both; }
  .toast button { flex: none; white-space: nowrap; border: 0; border-radius: var(--radius-chip); padding: 6px 14px; background: var(--text-primary); color: var(--bg-primary); cursor: pointer; }
  @keyframes toast-in { from { opacity: 0; transform: translateY(24px); } }
  @media (prefers-reduced-motion: reduce) {
    .screen { animation: fade .15s both !important; }
    .toast, .dots b { animation: none; transition: none; }
    @keyframes fade { from { opacity: 0; } }
  }
</style>
