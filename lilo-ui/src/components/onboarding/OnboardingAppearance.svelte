<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import { goBack, goNext } from "../../stores/onboarding.svelte";

  const THEMES = ["system", "light", "dark"] as const;
</script>

<h3>{t("onboarding.appearance.title")}</h3>
<p class="ob-sub">{t("onboarding.appearance.subtitle")}</p>

<div class="themes" role="radiogroup" aria-label={t("onboarding.appearance.theme")}>
  {#each THEMES as theme (theme)}
    <button class="th" class:on={getSetting("theme", "system") === theme} role="radio" aria-checked={getSetting("theme", "system") === theme}
      onclick={() => setSetting("theme", theme)}>
      <span class="pv pv-{theme}"><i></i><u></u></span>{t(`onboarding.appearance.${theme}`)}
    </button>
  {/each}
</div>


<div class="ob-foot">
  <button class="ob-btn ghost" onclick={goBack}>{t("onboarding.back")}</button>
  <button class="ob-btn primary" onclick={goNext}>{t("onboarding.continue")}</button>
</div>

<style>
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
