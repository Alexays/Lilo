<script lang="ts">
  import { settingsActions } from "../../lib/bridge/actions";
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { getAgentClients } from "../../stores/agents.svelte";
  import { getAgentClientsSnapshot } from "../../stores/settings.svelte";
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
  {#snippet appIcon()}<img src={row.client?.icon} alt="" />{/snippet}
  <div class="agent-row">
    <UiListRow
      icon={row.client?.icon ? appIcon : undefined}
      title={row.title}
      description={live
        ? t(live.busy ? "settings.agents.acting" : "settings.agents.connected")
        : seen
          ? t("settings.agents.lastSeen", { time: lastSeen(seen) })
          : row.agents.length
            ? t("settings.agents.allowed")
            : t(row.client?.configured ? "settings.agents.clientConnected" : "settings.agents.clientDescription")}
    >
      {#snippet action()}
        {#if live}
          <UiBadge tone="success">{t("settings.agents.connectedBadge")}</UiBadge>
        {/if}
        {#if row.client && !row.client.configured}
          <UiButton variant="primary" onclick={() => settingsActions.connectAgentClient(row.client?.id ?? "")}>
            {t("settings.agents.connect")}
          </UiButton>
        {/if}
        {#if row.agents.length}
          <UiButton onclick={() => row.agents.forEach((agent) => settingsActions.revokeAgentClient(agent.name))}>
            {t("settings.agents.revoke")}
          </UiButton>
        {/if}
      {/snippet}
    </UiListRow>
  </div>
{/each}

<style>
  .agent-row {
    padding-left: 16px;
    border-left: 2px solid var(--separator);
  }

  .agent-row :global(.ui-list-row-icon) {
    width: 24px;
  }

  img {
    width: 24px;
    height: 24px;
  }
</style>
