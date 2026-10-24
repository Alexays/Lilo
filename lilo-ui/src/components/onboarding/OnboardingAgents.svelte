<script lang="ts">
  import SettingsIcon from "../settings/SettingsIcon.svelte";
  import UiToggle from "../ui/UiToggle.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { settingsActions } from "../../lib/bridge/actions";
  import { getAgentClientsSnapshot, getSetting, setSetting } from "../../stores/settings.svelte";
  import { goBack, goNext } from "../../stores/onboarding.svelte";

  settingsActions.loadAgentClients();

  const enabled = $derived(getSetting("agentControlEnabled", "false") === "true");
  // Only the apps on this Mac, or already pointed at Lilo.
  const clients = $derived(getAgentClientsSnapshot().clients.filter((client) => client.icon || client.configured));
</script>

<h3>{t("onboarding.agents.title")}</h3>
<p class="ob-sub">{t("onboarding.agents.subtitle")}</p>

<div class="ob-row">
  <span class="ob-icon"><SettingsIcon name="agents" /></span>
  <span class="ob-text">{t("onboarding.agents.allow")}</span>
  <UiToggle checked={enabled} ariaLabel={t("onboarding.agents.allow")}
    onchange={(checked) => setSetting("agentControlEnabled", checked ? "true" : "false")} />
</div>

{#if enabled}
  {#each clients as client (client.id)}
    <div class="ob-row">
      {#if client.icon}<img class="app" src={client.icon} alt="" width="30" height="30" />{:else}<span class="ob-icon"><SettingsIcon name="agents" /></span>{/if}
      <span class="ob-text">{t(`settings.agents.names.${client.id}`)}<small>{t(client.configured ? "settings.agents.clientConnected" : "settings.agents.clientDescription")}</small></span>
      {#if client.configured}
        <span class="ob-done">{t("onboarding.essentials.defaultDone")}</span>
      {:else}
        <button class="ob-btn primary small" onclick={() => settingsActions.connectAgentClient(client.id)}>{t("settings.agents.connect")}</button>
      {/if}
    </div>
  {/each}
{/if}

<div class="ob-foot">
  <button class="ob-btn ghost" onclick={goBack}>{t("onboarding.back")}</button>
  <button class="ob-btn primary" onclick={goNext}>{t("onboarding.continue")}</button>
</div>

<style>
  .app { width: 30px; height: 30px; flex: none; }
</style>
