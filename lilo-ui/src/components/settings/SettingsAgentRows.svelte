<script lang="ts">
  import { settingsActions } from "../../lib/bridge/actions";
  import { getFormatLocale, t } from "../../lib/i18n/state.svelte";
  import { CLAUDE, type TerminalProgramIcon } from "../../lib/terminalIcons";
  import { getAgentClients } from "../../stores/agents.svelte";
  import { getAgentClientsSnapshot, getAgentPreview, getSetting, isConnectingAgentClient, previewAgentClient } from "../../stores/settings.svelte";
  import { OPENAI } from "../agents/modelLogos";
  import SettingsAgentConfigSheet from "./SettingsAgentConfigSheet.svelte";
  import SettingsAgentPermissions from "./SettingsAgentPermissions.svelte";
  import SettingsIcon from "./SettingsIcon.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiMoreMenu from "../ui/UiMoreMenu.svelte";

  let { title }: { title: string } = $props();

  // The command-line clients come with Terminal's icon from the bridge: their provider's mark says more.
  const PROVIDER_ICONS: Record<string, TerminalProgramIcon> = { claudeCode: CLAUDE, codex: OPENAI };

  const relative = $derived(new Intl.RelativeTimeFormat(getFormatLocale(), { numeric: "auto" }));
  const snapshot = $derived(getAgentClientsSnapshot());
  const preview = $derived(getAgentPreview());

  // One row per app on this Mac or naming Lilo, with the agents it connected as; then the agents Lilo has no
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

<UiInsetList {title}>
  {#each rows as row (row.key)}
    {@const client = row.client}
    {@const busy = getAgentClients().some((live) => live.busy && row.agents.some((agent) => agent.name === live.name))}
    {@const seen = Math.max(0, ...row.agents.map((agent) => agent.lastSeen ?? 0))}
    {@const provider = client ? PROVIDER_ICONS[client.id] : undefined}
    {@const status = busy ? "acting" : client?.configured ? "connected" : client ? "found" : "allowed"}
    <div class="agent-row" data-agent-status={status}>
      <UiListRow title={row.title}>
        {#snippet icon()}
          <span class="app-icon" class:provider={!!provider} class:placeholder={!provider && !client?.icon}>
            {#if provider}
              <svg viewBox="0 0 24 24" fill={provider.color ?? "currentColor"}><path d={provider.path} /></svg>
            {:else if client?.icon}
              <img src={client.icon} alt="" />
            {:else}
              <SettingsIcon name="agents" />
            {/if}
          </span>
        {/snippet}
        <span class="detail">
          {#if status !== "found"}<span class="dot {status}" aria-hidden="true"></span>{/if}
          {#if status === "acting"}{t("settings.agents.status.acting")}
          {:else if status === "found"}{client?.copyOnly ? t("settings.agents.copyOnlyLine") : t("settings.agents.foundLine")}
          {:else if status === "connected"}{seen ? t("settings.agents.connectedSeen", { time: lastSeen(seen) }) : t("settings.agents.status.connected")}
          {:else}{seen ? t("settings.agents.allowedSeen", { time: lastSeen(seen) }) : t("settings.agents.status.allowed")}{/if}
        </span>
        {#snippet action()}
          {#if client && (!client.configured || client.stale)}
            {#if client.copyOnly && !client.configured}
              <UiButton onclick={() => settingsActions.copyAgentClientEntry(client.id)}>{t("settings.agents.copyEntry")}</UiButton>
            {:else}
              <UiButton busy={isConnectingAgentClient(client.id)} onclick={() => previewAgentClient(client.id)}>
                {client.configured ? t("settings.agents.repair") : t("settings.agents.connect")}
              </UiButton>
            {/if}
          {/if}
          {#if client?.configured}
            <UiMoreMenu
              label={t("settings.agents.moreFor", { client: row.title })}
              items={[
                // Claude Code's store is its CLI's own: there is no part of a file to show.
                ...(client.id === "claudeCode" ? [] : [{ label: t("settings.agents.showAdded"), onclick: () => previewAgentClient(client.id, true, true) }]),
                { label: t("settings.agents.revealFile"), onclick: () => settingsActions.revealAgentClientConfig(client.id) },
                { label: t("settings.agents.removeFrom", { client: row.title }), danger: true, onclick: () => previewAgentClient(client.id, true) },
              ]}
            />
          {:else if !client}
            <UiMoreMenu
              label={t("settings.agents.moreFor", { client: row.title })}
              items={[{ label: t("settings.agents.revoke"), danger: true, onclick: () => row.agents.forEach((agent) => settingsActions.revokeAgentClient(agent.name)) }]}
            />
          {/if}
        {/snippet}
      </UiListRow>
    </div>
    {#if client?.configured || !client}
      <SettingsAgentPermissions key={client?.id ?? row.key} title={row.title} />
    {/if}
  {/each}
  <div data-setting-id="agentOther">
    <UiListRow title={t("settings.items.agentOther.title")} description={t("settings.items.agentOther.description")}>
      {#snippet icon()}
        <span class="app-icon placeholder"><SettingsIcon name="grid" /></span>
      {/snippet}
      {#snippet action()}
        <UiButton onclick={() => settingsActions.connectAgentClient("other")}>{t("settings.agents.copy")}</UiButton>
      {/snippet}
    </UiListRow>
  </div>
</UiInsetList>
<p class="footnote">
  {#if rows.some((row) => row.client?.configured || !row.client)}
    {getSetting("agentAskBeforeActions", "true") === "true" ? t("settings.agents.permissions.floor") : t("settings.agents.permissions.floorOff")}
  {/if}
  {t("settings.agents.footnote")}
</p>

{#if preview}
  <SettingsAgentConfigSheet {preview} repair={snapshot.clients.find((client) => client.id === preview.client)?.stale === true} />
{/if}

<style>
  .footnote {
    margin: calc(var(--space-4) - var(--space-8)) 4px 0;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
  }

  .app-icon {
    display: grid;
    place-items: center;
    width: 32px;
    height: 32px;
    border-radius: var(--radius-md);
    color: var(--text-muted);
  }

  .app-icon.placeholder {
    background: var(--bg-hover);
  }

  .app-icon.provider {
    background: var(--bg-elevated);
    box-shadow: inset 0 0 0 1px var(--separator);
  }

  .app-icon svg {
    width: 18px;
    height: 18px;
  }

  .app-icon img {
    width: 32px;
    height: 32px;
  }

  .detail {
    display: flex;
    align-items: baseline;
    gap: var(--space-6);
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .dot {
    flex: none;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--text-muted);
    transform: translateY(-1px);
  }

  .dot.acting {
    background: var(--accent);
  }

  .dot.connected {
    background: var(--success);
  }

  .agent-row :global(.ui-list-row-action) {
    display: flex;
    align-items: center;
    gap: var(--space-8);
  }
</style>
