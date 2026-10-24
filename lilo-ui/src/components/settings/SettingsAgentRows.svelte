<script lang="ts">
  import { settingsActions } from "../../lib/bridge/actions";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { getAgentClients } from "../../stores/agents.svelte";
  import { connectAgentClient, getAgentClientsSnapshot, isConnectingAgentClient } from "../../stores/settings.svelte";
  import SettingsIcon from "./SettingsIcon.svelte";
  import UiBadge from "../ui/UiBadge.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiListRow from "../ui/UiListRow.svelte";

  const relative = $derived(new Intl.RelativeTimeFormat(getLocale(), { numeric: "auto" }));
  const snapshot = $derived(getAgentClientsSnapshot());

  // One row per installed or configured app, with the agents it connected as; then the agents Lilo has no
  // configuration for.
  const rows = $derived([
    ...snapshot.clients.map((client) => ({
      key: client.id,
      title: t(`settings.agents.names.${client.id}`),
      client,
      agents: snapshot.allowed.filter((agent) => agent.client === client.id),
    })),
    ...snapshot.allowed
      .filter((agent) => !snapshot.clients.some((client) => client.id === agent.client))
      .map((agent) => ({ key: agent.name, title: agent.displayName, client: null, agents: [agent] })),
  ]);

  // Coarsest unit that keeps the number above one: "3 minutes ago", "yesterday".
  function lastSeen(seconds: number): string {
    const elapsed = Math.round(seconds - Date.now() / 1000);
    for (const [unit, size] of [["day", 86_400], ["hour", 3_600], ["minute", 60]] as const) {
      if (Math.abs(elapsed) >= size) return relative.format(Math.round(elapsed / size), unit);
    }
    return relative.format(0, "minute");
  }
</script>

{#each rows as row (row.key)}
  {@const live = getAgentClients().find((client) => row.agents.some((agent) => agent.name === client.name))}
  {@const seen = Math.max(0, ...row.agents.map((agent) => agent.lastSeen ?? 0))}
  <!-- Most telling first: acting or connected now, allowed in before, then how far the app is set up. -->
  {@const status = live
    ? live.busy ? "acting" : "connected"
    : row.agents.length ? "allowed" : row.client?.configured ? row.client.icon ? "ready" : "notInstalled" : "notSetUp"}
  {#snippet icon()}
    {#if row.client?.icon}<img src={row.client.icon} alt="" />{:else}<span class="placeholder"><SettingsIcon name="agents" /></span>{/if}
  {/snippet}
  <div class="agent-row" data-agent-status={status}>
    <UiListRow
      {icon}
      title={row.title}
      description={status === "allowed" && seen
        ? t("settings.agents.lastSeen", { time: lastSeen(seen) })
        : status === "ready" ? t("settings.agents.readyDescription")
        : status === "notSetUp" ? t("settings.agents.clientDescription") : undefined}
    >
      {#snippet action()}
        {#if status !== "notSetUp"}
          <UiBadge tone={status === "acting" ? "accent" : status === "connected" ? "success" : "neutral"}>
            {t(`settings.agents.status.${status}`)}
          </UiBadge>
        {/if}
        {#if row.agents.length}
          <UiButton onclick={() => row.agents.forEach((agent) => settingsActions.revokeAgentClient(agent.name))}>
            {t("settings.agents.revoke")}
          </UiButton>
        {:else if row.client && !row.client.configured}
          <UiButton variant="primary" busy={isConnectingAgentClient(row.client.id)} onclick={() => connectAgentClient(row.client?.id ?? "")}>
            {t("settings.agents.connect")}
          </UiButton>
        {/if}
      {/snippet}
    </UiListRow>
  </div>
{/each}

<div class="agent-row" data-setting-id="agentOther">
  <UiListRow title={t("settings.items.agentOther.title")} description={t("settings.items.agentOther.description")}>
    {#snippet icon()}<span class="placeholder"><SettingsIcon name="grid" /></span>{/snippet}
    {#snippet action()}
      <UiButton onclick={() => settingsActions.connectAgentClient("other")}>{t("settings.agents.copy")}</UiButton>
    {/snippet}
  </UiListRow>
</div>

<style>
  .agent-row :global(.ui-list-row-icon) {
    width: 24px;
  }

  img,
  .placeholder {
    width: 24px;
    height: 24px;
  }

  /* Where an app icon would be: a quiet tile, so every title lines up. */
  .placeholder {
    display: grid;
    place-items: center;
    border-radius: 26%;
    background: var(--bg-hover);
    color: var(--text-muted);
  }
</style>
