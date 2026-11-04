<script lang="ts">
  import SettingsIcon from "../settings/SettingsIcon.svelte";
  import UiToggle from "../ui/UiToggle.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { settingsActions } from "../../lib/bridge/actions";
  import { connectAgentClient, getAgentClientsSnapshot, getSetting, isConnectingAgentClient, setSetting } from "../../stores/settings.svelte";
  import { goBack, goNext } from "../../stores/onboarding.svelte";

  settingsActions.loadAgentClients();

  const enabled = $derived(getSetting("agentControlEnabled", "false") === "true");
  // Only the apps on this Mac, or already pointed at Lilo.
  const clients = $derived(getAgentClientsSnapshot().clients.filter((client) => client.icon || client.configured));
  let otherCopied = $state(false);
</script>

<div class="ob-head">
  <h2>{t("onboarding.agents.title")}</h2>
  <p class="ob-sub">{t("onboarding.agents.subtitle")}</p>
</div>

<div class="ob-body">
  <div class="ob-group">
    <div class="ob-row">
      <span class="tile accent"><SettingsIcon name="agents" /></span>
      <span class="ob-text">{t("onboarding.agents.allow")}</span>
      <UiToggle checked={enabled} ariaLabel={t("onboarding.agents.allow")}
        onchange={(checked) => setSetting("agentControlEnabled", checked ? "true" : "false")} />
    </div>
  </div>

  {#if enabled}
    <h3 class="ob-section">{t("onboarding.agents.onThisMac")}</h3>
    <div class="ob-group">
      {#each clients as client (client.id)}
        {@const name = t(`settings.agents.names.${client.id}`)}
        <div class="ob-row">
          {#if client.icon}<img class="app" src={client.icon} alt="" width="32" height="32" />{:else}<span class="tile"><SettingsIcon name="agents" /></span>{/if}
          <span class="ob-text">{name}{#if !client.configured}<small>{t("settings.agents.clientDescription")}</small>{/if}</span>
          {#if client.configured}
            <span class="ob-done">{t("onboarding.essentials.defaultDone")}</span>
          {:else}
            {@const busy = isConnectingAgentClient(client.id)}
            <button class="ob-btn primary connect" class:busy disabled={busy} aria-busy={busy}
              aria-label={t("onboarding.agents.connectNamed", { name })} onclick={() => connectAgentClient(client.id)}>
              {#if busy}<span class="spinner" aria-hidden="true"></span>{/if}{t("settings.agents.connect")}
            </button>
          {/if}
        </div>
      {/each}
      <div class="ob-row">
        <span class="tile"><SettingsIcon name="grid" /></span>
        <span class="ob-text">{t("settings.items.agentOther.title")}<small>{t("settings.items.agentOther.description")}</small></span>
        {#if otherCopied}
          <span class="ob-done">{t("onboarding.agents.copied")}</span>
        {:else}
          <button class="ob-btn" aria-label={t("settings.agents.copy")} onclick={() => { settingsActions.connectAgentClient("other"); otherCopied = true; }}>
            {t("common.copy")}
          </button>
        {/if}
      </div>
    </div>
  {/if}
</div>

<div class="ob-foot">
  <button class="ob-btn ghost" onclick={goBack}>{t("onboarding.back")}</button>
  <button class="ob-btn primary" onclick={goNext}>{t("onboarding.letsGo")}</button>
</div>

<style>
  h3.ob-section { margin-top: 28px; }
  .app { width: 32px; height: 32px; flex: none; }
  .tile { width: 32px; height: 32px; flex: none; display: grid; place-items: center; border-radius: var(--radius-sm);
    background: var(--onb-surface-strong); box-shadow: 0 0 0 .5px var(--onb-edge); color: var(--text-secondary); }
  .tile.accent { background: var(--accent); box-shadow: none; color: var(--accent-text); }
  /* Connect carries no Return keycap: Return goes to the screen's own button. */
  .ob-btn.primary.connect::after { display: none; }
  .ob-btn.primary.connect { padding: 0 12px; }
  .ob-btn.busy:disabled { opacity: 1; }
  .spinner { width: .8em; height: .8em; border: .15em solid currentColor; border-right-color: transparent; border-radius: 50%; animation: spin .8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  @media (prefers-reduced-motion: reduce) { .spinner { animation-duration: 2s; } }
</style>
