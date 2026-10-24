<script lang="ts">
  import Fleuron from "./Fleuron.svelte";
  import SettingsIcon from "../settings/SettingsIcon.svelte";
  import UiToggle from "../ui/UiToggle.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { settingsActions } from "../../lib/bridge/actions";
  import { getDefaultBrowserStatus, getSetting, setSetting } from "../../stores/settings.svelte";
  import { goBack, goNext } from "../../stores/onboarding.svelte";

  const isDefault = $derived(getDefaultBrowserStatus().isDefault);
</script>

<h3>{t("onboarding.essentials.title")}</h3>
<p class="ob-sub">{t("onboarding.essentials.subtitle")}</p>

<div class="ob-row">
  <span class="ob-icon"><SettingsIcon name="privacy" /></span>
  <span class="ob-text">{t("onboarding.essentials.blocker")}<small>{t("onboarding.essentials.blockerDesc")}</small></span>
  <UiToggle checked={getSetting("contentBlockerEnabled", "true") === "true"} ariaLabel={t("onboarding.essentials.blocker")}
    onchange={(checked) => setSetting("contentBlockerEnabled", checked ? "true" : "false")} />
</div>

<div class="ob-row">
  <span class="mark"><Fleuron size={30} /><span class="ok" class:on={isDefault}><svg width="10" height="10" viewBox="0 0 12 12" fill="none" aria-hidden="true"><path d="M2.5 6.2l2.3 2.3 4.7-5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" /></svg></span></span>
  <span class="ob-text">{t("onboarding.essentials.default")}<small>{t("onboarding.essentials.defaultDesc")}</small></span>
  {#if isDefault}
    <span class="ob-done">{t("onboarding.essentials.defaultDone")}</span>
  {:else}
    <button class="ob-btn primary small" onclick={() => settingsActions.setDefaultBrowser()}>{t("onboarding.essentials.defaultSet")}</button>
  {/if}
</div>

<div class="ob-foot">
  <button class="ob-btn ghost" onclick={goBack}>{t("onboarding.back")}</button>
  <button class="ob-btn primary" onclick={goNext}>{t("onboarding.continue")}</button>
</div>

<style>
  .mark { position: relative; width: 30px; height: 30px; flex: none; }
  .ok { position: absolute; right: -6px; bottom: -6px; width: 16px; height: 16px; border-radius: 50%; background: var(--success); color: var(--on-color);
    display: grid; place-items: center; font-size: var(--font-size-2xs); transform: scale(0); transition: transform .5s var(--motion-ease-bounce); }
  .ok.on { transform: scale(1); }
  @media (prefers-reduced-motion: reduce) { .ok { transition: none; } }
</style>
