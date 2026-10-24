<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { PASSWORD_MANAGERS } from "./onboardingModel";
  import { getExtensions, installStoreExtension, isExtensionInstalling } from "../../stores/extensions.svelte";
  import { getOnboarding, goBack, goNext } from "../../stores/onboarding.svelte";

  const onboarding = getOnboarding();
  const installed = $derived(new Map(getExtensions().map((ext) => [ext.id, ext])));
  const anyInstalled = $derived(PASSWORD_MANAGERS.some((manager) => installed.has(manager.id)));
</script>

<h3>{t("onboarding.passwords.title")}</h3>
<p class="ob-sub">{t("onboarding.passwords.subtitle")}</p>

<div class="managers ob-scroll" role="list">
  {#each PASSWORD_MANAGERS as manager (manager.id)}
    {@const ext = installed.get(manager.id)}
    <div class="manager" class:soon={manager.soon} role="listitem">
      {#if ext?.iconDataURL}
        <img class="logo" src={ext.iconDataURL} alt="" width="30" height="30" />
      {:else}
        <span class="glyph" aria-hidden="true">{manager.name[0]}</span>
      {/if}
      <span class="ob-text">{manager.name}<small>{t(`onboarding.passwords.managers.${manager.key}`)}</small></span>
      {#if manager.soon}
        <span class="badge">{t("onboarding.passwords.soon")}</span>
      {:else if ext}
        <span class="ob-done">{t("onboarding.passwords.added")}</span>
      {:else}
        <button class="ob-btn small" aria-label={t("onboarding.passwords.addNamed", { name: manager.name })}
          disabled={isExtensionInstalling(manager.id)} onclick={() => installStoreExtension(manager.id)}>
          {isExtensionInstalling(manager.id) ? t("onboarding.passwords.adding") : t("onboarding.passwords.add")}
        </button>
      {/if}
    </div>
  {/each}
</div>

<div class="ob-foot">
  {#if onboarding.mode === "full"}<button class="ob-btn ghost" onclick={goBack}>{t("onboarding.back")}</button>{:else}<span></span>{/if}
  <button class="ob-btn primary" onclick={goNext}>{anyInstalled ? t("onboarding.continue") : t("onboarding.skip")}</button>
</div>

<style>
  .managers { display: flex; flex-direction: column; gap: 6px; }
  .manager { display: flex; align-items: center; gap: 12px; padding: 9px 14px; border-radius: var(--radius-lg); background: var(--bg-hover); font-size: var(--font-size-lg); color: var(--text-primary); }
  .manager.soon .glyph, .manager.soon .logo { opacity: .6; }
  .manager .ob-text { min-width: 0; }
  .logo { width: 30px; height: 30px; flex: none; }
  .glyph { width: 30px; height: 30px; flex: none; display: grid; place-items: center; border-radius: var(--radius-sm); font-weight: var(--font-weight-bold);
    background: var(--accent-tint-14); color: var(--accent); }
  .badge { font-size: var(--font-size-xs); font-weight: var(--font-weight-semibold); padding: 4px 8px; border-radius: var(--radius-chip); background: var(--bg-active); color: var(--text-primary); }
</style>
