<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { getOnboarding, goNext, setUsage } from "../../stores/onboarding.svelte";
  import type { OnboardingUsage } from "./onboardingModel";

  const USAGES: OnboardingUsage[] = ["browse", "develop"];
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

<h3>{t("onboarding.usage.title")}</h3>
<p class="ob-sub">{t("onboarding.usage.subtitle")}</p>

<div class="usages" role="radiogroup" tabindex="-1" aria-label={t("onboarding.usage.title")} onkeydown={handleKeydown}>
  {#each USAGES as usage (usage)}
    <button class="us" class:on={onboarding.usage === usage} role="radio" aria-checked={onboarding.usage === usage}
      tabindex={onboarding.usage === usage ? 0 : -1} onclick={() => setUsage(usage)}>
      <span class="pv pv-{usage}"><i><s></s><s></s><s></s></i><u></u></span>
      <b>{t(`onboarding.usage.${usage}`)}</b>
      <small>{t(`onboarding.usage.${usage}Desc`)}</small>
    </button>
  {/each}
</div>

<div class="ob-foot">
  <button class="ob-btn ghost" onclick={() => choose("browse")}>{t("onboarding.skip")}</button>
  <button class="ob-btn primary" onclick={() => choose(onboarding.usage)}>{t("onboarding.continue")}</button>
</div>

<style>
  .usages { display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px; }
  .us { border-radius: var(--radius-lg); padding: 8px 8px 10px; background: var(--bg-hover); border: 2px solid transparent; cursor: pointer; color: var(--text-primary);
    transition: border-color var(--motion-duration-normal), transform .2s var(--motion-ease-spring); }
  .us:hover { transform: translateY(-1px); } .us.on { border-color: var(--accent); }
  .us b { display: block; margin-top: 8px; font-size: var(--font-size-lg); }
  .us small { display: block; margin-top: 2px; font-size: var(--font-size-sm); color: var(--text-secondary); }
  /* A sidebar and a page in the theme's own colors; the developer one gets a terminal under the page. */
  .pv { display: flex; height: 74px; border-radius: var(--radius-md); overflow: hidden; background: var(--bg-secondary); }
  .pv i { width: 28%; padding: 8px 4px; display: flex; flex-direction: column; gap: 4px; }
  .pv s { height: 6px; border-radius: var(--radius-2xs); background: color-mix(in srgb, var(--bg-primary) 70%, transparent); }
  .pv u { position: relative; flex: 1; margin: 4px; border-radius: var(--radius-sm); background: var(--bg-primary); overflow: hidden; }
  .pv-browse u::after { content: ""; position: absolute; left: 10%; right: 10%; top: 10px; height: 10px; border-radius: var(--radius-sm); background: var(--bg-hover);
    box-shadow: 0 16px 0 -2px var(--separator), 0 30px 0 -2px var(--separator); }
  .pv-develop u::after { content: ""; position: absolute; inset: auto 0 0; height: 44%; background: #1a1a2e; }
  .pv-develop u::before { content: ""; position: absolute; z-index: 1; left: 7px; bottom: 9px; width: 40%; height: 4px; border-radius: var(--radius-2xs); background: #9b80f6; box-shadow: 0 -8px 0 #5dcaa5; }
  @media (prefers-reduced-motion: reduce) { .us { transition: none; } }
</style>
