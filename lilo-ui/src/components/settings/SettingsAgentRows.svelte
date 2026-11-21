<script lang="ts">
  import { settingsActions } from "../../lib/bridge/actions";
  import { getFormatLocale, t } from "../../lib/i18n/state.svelte";
  import { CLAUDE, type TerminalProgramIcon } from "../../lib/terminalIcons";
  import { getAgentClients } from "../../stores/agents.svelte";
  import { getAgentClientsSnapshot, getAgentPreview, isConnectingAgentClient, previewAgentClient } from "../../stores/settings.svelte";
  import { OPENAI } from "../agents/modelLogos";
  import SettingsAgentConfigSheet from "./SettingsAgentConfigSheet.svelte";
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

  // One tile per installed or configured app, with the agents it connected as; then the agents Lilo has no
  // configuration for. The catalog's other apps wait under "More apps".
  const rows = $derived([
    ...snapshot.clients.filter(shown).map((client) => ({
      key: client.id,
      title: t(`settings.agents.names.${client.id}`),
      client,
      agents: snapshot.allowed.filter((agent) => agent.client === client.id),
    })),
    ...snapshot.allowed
      .filter((agent) => !snapshot.clients.some((client) => client.id === agent.client))
      .map((agent) => ({ key: agent.name, title: agent.displayName, client: null, agents: [agent] })),
  ]);
  const moreRows = $derived(
    snapshot.clients.filter((client) => !shown(client)).map((client) => ({ key: client.id, title: t(`settings.agents.names.${client.id}`), client, agents: [] })),
  );
  let moreOpen = $state(false);

  function shown(client: { installed: boolean; configured: boolean }): boolean {
    return client.installed || client.configured;
  }

  // Coarsest unit that keeps the number above one: "3 minutes ago", "yesterday".
  function lastSeen(seconds: number): string {
    const elapsed = Math.round(seconds - Date.now() / 1000);
    for (const [unit, size] of [["day", 86_400], ["hour", 3_600], ["minute", 60]] as const) {
      if (Math.abs(elapsed) >= size) return relative.format(Math.round(elapsed / size), unit);
    }
    return relative.format(0, "minute");
  }
</script>

{#snippet tile(row: { key: string; title: string; client: (typeof snapshot.clients)[number] | null; agents: typeof snapshot.allowed })}
  {@const live = getAgentClients().find((client) => row.agents.some((agent) => agent.name === client.name))}
  {@const seen = Math.max(0, ...row.agents.map((agent) => agent.lastSeen ?? 0))}
  {@const provider = row.client ? PROVIDER_ICONS[row.client.id] : undefined}
  <!-- Most telling first: acting or connected now, allowed in before, then how far the app is set up: configured, found on this Mac but not set up, or not installed. -->
  {@const status = live
    ? live.busy ? "acting" : "connected"
    : row.agents.length ? "allowed" : row.client?.configured ? row.client.installed ? "ready" : "notInstalled" : row.client?.installed ? "detected" : "notInstalled"}
  <div class="agent-tile" data-agent-status={status}>
    <span class="app-icon" class:provider={!!provider} class:placeholder={!provider && !row.client?.icon} aria-hidden="true">
      {#if provider}
        <svg viewBox="0 0 24 24" fill={provider.color ?? "currentColor"}><path d={provider.path} /></svg>
      {:else if row.client?.icon}
        <img src={row.client.icon} alt="" />
      {:else}
        <SettingsIcon name="agents" />
      {/if}
    </span>
    <span class="copy">
      <span class="name">{row.title}</span>
      <span class="status">
        {#if status !== "detected"}<span class="dot {status}" aria-hidden="true"></span>{/if}
        {status === "allowed" && seen
          ? t("settings.agents.allowedSeen", { time: lastSeen(seen) })
          : status === "ready" ? t("settings.agents.readyLine")
          : status === "detected" ? t("settings.agents.detectedLine")
          : t(`settings.agents.status.${status}`)}
      </span>
    </span>
    {#if row.agents.length}
      <UiButton onclick={() => row.agents.forEach((agent) => settingsActions.revokeAgentClient(agent.name))}>
        {t("settings.agents.revoke")}
      </UiButton>
    {:else if row.client && (!row.client.configured || row.client.stale)}
      <UiButton variant="primary" busy={isConnectingAgentClient(row.client.id)} onclick={() => previewAgentClient(row.client?.id ?? "")}>
        {row.client.configured ? t("settings.agents.repair") : t("settings.agents.connect")}
      </UiButton>
    {/if}
    {#if row.client?.configured}
      <UiMoreMenu
        label={t("settings.agents.moreFor", { client: row.title })}
        items={[{ label: t("settings.agents.removeFrom", { client: row.title }), danger: true, onclick: () => previewAgentClient(row.client?.id ?? "", true) }]}
      />
    {/if}
  </div>
{/snippet}

<UiInsetList {title} boxed={false}>
  {#if rows.length}
    <div class="agent-tiles">
      {#each rows as row (row.key)}
        {@render tile(row)}
      {/each}
    </div>
  {/if}
</UiInsetList>

{#if moreRows.length}
  <button class="more-apps" aria-expanded={moreOpen} onclick={() => (moreOpen = !moreOpen)}>
    <svg class="chevron" class:open={moreOpen} width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 3.5L10.5 8 6 12.5" /></svg>
    {t("settings.agents.moreApps")}
  </button>
  {#if moreOpen}
    <div class="agent-tiles">
      {#each moreRows as row (row.key)}
        {@render tile(row)}
      {/each}
    </div>
  {/if}
{/if}

{#if preview}
  <SettingsAgentConfigSheet {preview} repair={snapshot.clients.find((client) => client.id === preview.client)?.stale === true} />
{/if}

<UiInsetList>
  <div data-setting-id="agentOther">
    <UiListRow title={t("settings.items.agentOther.title")} description={t("settings.items.agentOther.description")}>
      {#snippet action()}
        <UiButton onclick={() => settingsActions.connectAgentClient("other")}>{t("settings.agents.copy")}</UiButton>
      {/snippet}
    </UiListRow>
  </div>
</UiInsetList>

<style>
  .agent-tiles {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
    gap: var(--space-12);
  }

  .more-apps {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    margin-top: var(--space-12);
    padding: var(--space-4) var(--space-6);
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .more-apps:hover {
    color: var(--text-primary);
  }

  .more-apps:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .chevron {
    transition: transform var(--transition-fast);
  }

  .chevron.open {
    transform: rotate(90deg);
  }

  @media (prefers-reduced-motion: reduce) {
    .chevron {
      transition: none;
    }
  }

  .agent-tiles + .more-apps + .agent-tiles {
    margin-top: var(--space-12);
  }

  .agent-tile {
    display: flex;
    align-items: center;
    gap: 14px;
    min-width: 0;
    padding: var(--space-16) 14px;
    border-radius: var(--radius-box);
    background: var(--group-box-bg);
    box-shadow: inset 0 0 0 1px var(--separator);
  }

  .app-icon {
    flex: none;
    display: grid;
    place-items: center;
    width: 44px;
    height: 44px;
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
    width: 24px;
    height: 24px;
  }

  .app-icon img {
    width: 44px;
    height: 44px;
  }

  .copy {
    flex: 1;
    display: grid;
    gap: 2px;
    min-width: 0;
  }

  .name {
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .status {
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

  .dot.connected,
  .dot.ready {
    background: var(--success);
  }
</style>
