<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { getOnboarding, goNext, setUsage } from "../../stores/onboarding.svelte";
  import type { OnboardingUsage } from "./onboardingModel";

  const USAGES: OnboardingUsage[] = ["browse", "agents", "develop"];
  const onboarding = getOnboarding();

  // The preselected tile counts as a choice too, so its settings apply without a click on it.
  function choose(usage: OnboardingUsage): void {
    setUsage(usage);
    goNext();
  }

  function handleKeydown(event: KeyboardEvent): void {
    const step = event.key === "ArrowRight" || event.key === "ArrowDown" ? 1 : event.key === "ArrowLeft" || event.key === "ArrowUp" ? -1 : 0;
    if (step === 0) return;
    event.preventDefault();
    const index = (USAGES.indexOf(onboarding.usage) + step + USAGES.length) % USAGES.length;
    setUsage(USAGES[index]);
    (event.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>("button")[index]?.focus();
  }
</script>

<div class="ob-body center">
  <div class="ob-head">
    <h2>{t("onboarding.usage.title")}</h2>
    <p class="ob-sub">{t("onboarding.usage.subtitle")}</p>
  </div>

  <div class="usages" role="radiogroup" tabindex="-1" aria-label={t("onboarding.usage.title")} onkeydown={handleKeydown}>
    {#each USAGES as usage (usage)}
      <button class="us" class:on={onboarding.usage === usage} role="radio" aria-checked={onboarding.usage === usage}
        tabindex={onboarding.usage === usage ? 0 : -1} onclick={() => setUsage(usage)}>
        <!-- What the answer turns on, drawn in the window's own colors. -->
        <span class="pv" aria-hidden="true">
          <span class="side"><i class="lights"></i><s></s><s class="sel"></s><s></s><s class="short"></s><s></s><s class="short"></s></span>
          <span class="page" class:split={usage === "agents"}>
            <span class="doc"><b class="title"></b><b></b><b></b><b class="short"></b><span class="block"></span></span>
            {#if usage === "agents"}
              <span class="agent"><b class="pill"></b><b class="spark"></b><b></b><b class="short"></b><span class="field"></span></span>
            {:else if usage === "develop"}
              <span class="term"><b class="ok"></b><b></b><b class="short"></b></span>
            {/if}
          </span>
        </span>
        <b class="label">{t(`onboarding.usage.${usage}`)}</b>
        <small>{t(`onboarding.usage.${usage}Desc`)}</small>
      </button>
    {/each}
  </div>
</div>

<div class="ob-foot">
  <span></span>
  <button class="ob-btn ghost" onclick={() => choose("browse")}>{t("onboarding.skip")}</button>
  <button class="ob-btn primary" onclick={() => choose(onboarding.usage)}>{t("onboarding.continue")}</button>
</div>

<style>
  .center { display: flex; flex-direction: column; justify-content: center; text-align: center; }
  .center .ob-head { margin-bottom: 40px; }
  .center .ob-sub { margin-inline: auto; }
  .usages { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 28px; }
  .us { display: flex; flex-direction: column; align-items: center; padding: 0; border: 0; background: none; cursor: pointer; color: var(--text-primary); font: inherit; }
  .us:focus-visible { outline: none; }
  .us:focus-visible .pv { outline: var(--focus-outline); outline-offset: 4px; }
  .label { margin-top: 16px; font-size: var(--font-size-md); font-weight: var(--font-weight-medium); }
  .us small { margin-top: 4px; font-size: var(--font-size-sm); color: var(--text-secondary); }

  /* A window: the sidebar in the Space's color, the page beside it. */
  .pv { --page: #fff; --ink: rgba(0, 0, 0, .1); --ink-soft: rgba(0, 0, 0, .05);
    display: flex; width: 100%; aspect-ratio: 3 / 2; padding: 4px; border-radius: var(--radius-box); overflow: hidden;
    background: var(--sidebar-bg); box-shadow: 0 0 0 1px var(--text-primary-tint-12), 0 8px 24px rgba(40, 30, 90, .08);
    transition: box-shadow var(--motion-duration-normal); }
  .us:hover .pv { box-shadow: 0 0 0 1px var(--text-primary-tint-12), 0 10px 28px rgba(40, 30, 90, .14); }
  .us.on .pv { box-shadow: 0 0 0 3px var(--onb-surface-strong), 0 0 0 6px var(--accent), 0 10px 28px rgba(40, 30, 90, .14); }
  @media (prefers-color-scheme: dark) { .pv { --page: #1e1e1e; --ink: rgba(255, 255, 255, .14); --ink-soft: rgba(255, 255, 255, .06); } }
  .pv b, .pv s, .pv i { display: block; border-radius: var(--radius-2xs); }
  .side { width: 27%; display: flex; flex-direction: column; gap: 9px; padding: 8px 8px 0; }
  .lights { width: 26px; height: 6px; margin-bottom: 6px; background: radial-gradient(circle at 3px 3px, #ff5f57 2.6px, transparent 3px), radial-gradient(circle at 13px 3px, #febc2e 2.6px, transparent 3px), radial-gradient(circle at 23px 3px, #28c840 2.6px, transparent 3px); }
  .side s { height: 5px; margin-inline: 4px; background: color-mix(in srgb, var(--sidebar-contrast) 22%, transparent); }
  .side s.short { width: 40%; }
  .side s.sel { height: 13px; margin: -4px 0; padding: 0; background: var(--sidebar-sel); }
  .page { flex: 1; display: flex; flex-direction: column; min-width: 0; border-radius: var(--radius-sm); overflow: hidden; background: var(--page); }
  .page > span { min-height: 0; }
  .doc { flex: 1; display: flex; flex-direction: column; gap: 7px; padding: 12px 14px; }
  .doc b { height: 5px; background: var(--ink-soft); }
  .doc b.title { width: 50%; height: 9px; margin-bottom: 3px; background: var(--ink); }
  .doc b.short { width: 70%; }
  .doc .block { flex: 1; max-height: 50px; margin-top: 6px; border-radius: var(--radius-xs); background: var(--ink-soft); }
  /* An agent's conversation beside the page. */
  .page.split { flex-direction: row; }
  .agent { width: 50%; display: flex; flex-direction: column; gap: 7px; padding: 10px; box-shadow: inset 1px 0 0 var(--ink-soft); }
  .agent b { height: 4px; background: var(--ink-soft); }
  .agent b.short { width: 60%; }
  .agent .pill { align-self: flex-end; width: 55%; height: 10px; border-radius: var(--radius-chip); background: var(--ink-soft); }
  .agent .spark { width: 8px; height: 8px; border-radius: 50%; background: conic-gradient(#e8743b 0 25%, transparent 0 50%, #e8743b 0 75%, transparent 0); }
  .agent .field { margin-top: auto; height: 18px; border-radius: var(--radius-xs); box-shadow: inset 0 0 0 1px var(--ink); }
  /* The terminal under the page. */
  .term { height: 40%; display: flex; flex-direction: column; gap: 6px; padding: 12px 14px; background: #1f2029; }
  .term b { width: 80%; height: 3px; background: rgba(255, 255, 255, .28); }
  .term b.ok { width: 50%; background: #3ccb7f; }
  .term b.short { width: 40%; }
  @media (prefers-reduced-motion: reduce) { .pv { transition: none; } }
</style>
