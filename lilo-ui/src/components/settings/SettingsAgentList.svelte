<script lang="ts">
  import { untrack } from "svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { type AgentCommand, parseAgentCommands, parseHiddenAgents } from "../../lib/agentCommands";
  import { getAgents } from "../../stores/conversations.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import { conversationActions } from "../agents/conversationActions";
  import AgentTile from "../agents/AgentTile.svelte";
  import SettingsAgentSheet from "./SettingsAgentSheet.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiMoreMenu from "../ui/UiMoreMenu.svelte";
  import UiToggle from "../ui/UiToggle.svelte";

  const commands = $derived(parseAgentCommands(getSetting("agentCommands", "[]")));
  const hidden = $derived(parseHiddenAgents(getSetting("agentsHidden", "[]")));
  const registry = $derived(getAgents().filter((agent) => !agent.command));
  let sheet = $state<"closed" | "add" | AgentCommand>("closed");

  // The registry rows come from the catalog the picker uses; a still-empty one is fetched once.
  let requested = false;
  let refreshed = false;
  $effect(() => {
    const empty = getAgents().length === 0;
    untrack(() => {
      if (!empty) return;
      if (!requested) {
        requested = true;
        conversationActions.loadCatalog(false);
      } else if (!refreshed) {
        refreshed = true;
        conversationActions.loadCatalog(true);
      }
    });
  });

  // Every write keeps the ids of agents this window does not list: the settings are shared by all profiles.
  function setShown(id: string, shown: boolean): void {
    const next = [...hidden].filter((other) => other !== id);
    setSetting("agentsHidden", JSON.stringify(shown ? next : [...next, id]));
  }

  // The host lists commands in its catalog: it is asked again so the picker sees the change.
  function saveCommands(next: AgentCommand[]): void {
    setSetting("agentCommands", JSON.stringify(next));
    conversationActions.loadCatalog(false);
  }

  function upsert(command: AgentCommand): void {
    saveCommands(commands.some((entry) => entry.id === command.id) ? commands.map((entry) => (entry.id === command.id ? command : entry)) : [...commands, command]);
    sheet = "closed";
  }

  function remove(command: AgentCommand): void {
    saveCommands(commands.filter((entry) => entry.id !== command.id));
    if (hidden.has(command.id)) setShown(command.id, true);
  }

  function commandName(command: AgentCommand): string {
    return command.name || command.executable.split("/").filter(Boolean).at(-1) || command.id;
  }

  function commandLine(command: AgentCommand): string {
    return [command.executable, ...command.arguments.split("\n").map((line) => line.trim())].filter(Boolean).join(" ");
  }
</script>

<UiInsetList title={t("settings.agentList.commands")}>
  {#each commands as command (command.id)}
    <UiListRow title={commandName(command)} description={commandLine(command)}>
      {#snippet icon()}
        <AgentTile agentId={command.id} />
      {/snippet}
      {#snippet action()}
        <UiToggle ariaLabel={commandName(command)} checked={!hidden.has(command.id)} onchange={(checked) => setShown(command.id, checked)} />
        <UiMoreMenu
          label={t("settings.agentList.menu", { name: commandName(command) })}
          items={[
            { label: t("settings.agentList.edit"), onclick: () => (sheet = command) },
            { label: t("common.remove"), danger: true, onclick: () => remove(command) },
          ]}
        />
      {/snippet}
    </UiListRow>
  {/each}
  <button type="button" class="add-row" onclick={() => (sheet = "add")}>
    <span class="add-plus" aria-hidden="true">
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none"><path d="M7 2.5v9M2.5 7h9" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg>
    </span>
    {t("settings.agentList.add")}
  </button>
</UiInsetList>

{#if registry.length > 0}
  <UiInsetList title={t("settings.agentList.registry")}>
    {#each registry as agent (agent.id)}
      <UiListRow title={agent.name} description={agent.description}>
        {#snippet icon()}
          <AgentTile agentId={agent.id} />
        {/snippet}
        {#snippet action()}
          <UiToggle ariaLabel={agent.name} checked={!hidden.has(agent.id)} onchange={(checked) => setShown(agent.id, checked)} />
        {/snippet}
      </UiListRow>
    {/each}
  </UiInsetList>
{/if}

{#if sheet !== "closed"}
  <SettingsAgentSheet editing={sheet === "add" ? undefined : sheet} onsave={upsert} oncancel={() => (sheet = "closed")} />
{/if}

<style>
  .add-row {
    display: flex;
    align-items: center;
    gap: var(--space-10);
    padding: 11px 14px;
    border: 0;
    background: transparent;
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-md);
    cursor: pointer;
  }

  .add-row:hover {
    background: var(--bg-hover);
  }

  .add-row:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -1px;
  }

  .add-plus {
    display: grid;
    place-items: center;
    width: 20px;
    height: 20px;
    border-radius: 50%;
    box-shadow: inset 0 0 0 1px var(--border);
    color: var(--text-secondary);
  }
</style>
