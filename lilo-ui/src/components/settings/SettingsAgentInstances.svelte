<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { type AgentInstance, parseAgentInstances, writeAgentInstances } from "../../lib/agentInstances";
  import { getAgent } from "../../stores/conversations.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import AgentTile from "../agents/AgentTile.svelte";
  import SettingsAgentSheet from "./SettingsAgentSheet.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiMoreMenu from "../ui/UiMoreMenu.svelte";
  import UiToggle from "../ui/UiToggle.svelte";

  const instances = $derived(parseAgentInstances(getSetting("agentAcpInstances", "[]")));
  let sheet = $state<"closed" | "add" | AgentInstance>("closed");

  function save(next: AgentInstance[]): void {
    setSetting("agentAcpInstances", writeAgentInstances(next));
  }

  function upsert(entry: AgentInstance): void {
    save(instances.some((i) => i.id === entry.id) ? instances.map((i) => (i.id === entry.id ? entry : i)) : [...instances, entry]);
    sheet = "closed";
  }

  function name(instance: AgentInstance): string {
    if (instance.source === "command") return instance.name || instance.executable?.split("/").filter(Boolean).at(-1) || instance.id;
    return getAgent(instance.registryId ?? instance.id)?.name || instance.name || instance.id;
  }

  // One line on what the entry is: the command it runs, or the registry it comes from.
  function detail(instance: AgentInstance): string {
    if (instance.source === "registry") return t("settings.agentInstances.registry");
    const command = [instance.executable, ...(instance.arguments ?? "").split("\n").map((line) => line.trim()).filter(Boolean)]
      .filter(Boolean)
      .join(" ");
    return command ? `${t("settings.agentInstances.command")} · ${command}` : t("settings.agentInstances.command");
  }

  function menuItems(instance: AgentInstance): { label: string; onclick: () => void; danger?: boolean }[] {
    const remove = { label: t("common.remove"), danger: true, onclick: () => save(instances.filter((entry) => entry.id !== instance.id)) };
    return instance.source === "command" ? [{ label: t("settings.agentInstances.edit"), onclick: () => (sheet = instance) }, remove] : [remove];
  }
</script>

<UiInsetList>
  {#each instances as instance (instance.id)}
    <UiListRow title={name(instance)} description={detail(instance)}>
      {#snippet icon()}
        <AgentTile agentId={instance.registryId ?? instance.id} />
      {/snippet}
      {#snippet action()}
        <UiToggle
          ariaLabel={name(instance)}
          checked={instance.enabled}
          onchange={(checked) => save(instances.map((entry) => (entry.id === instance.id ? { ...entry, enabled: checked } : entry)))}
        />
        <UiMoreMenu label={t("settings.agentInstances.menu", { name: name(instance) })} items={menuItems(instance)} />
      {/snippet}
    </UiListRow>
  {/each}

  <button type="button" class="add-row" onclick={() => (sheet = "add")}>
    <span class="add-plus" aria-hidden="true">
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none"><path d="M7 2.5v9M2.5 7h9" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg>
    </span>
    {t("settings.agentInstances.add")}
  </button>
</UiInsetList>

{#if instances.length === 0}
  <p class="hint">{t("settings.agentInstances.hint")}</p>
{/if}

{#if sheet === "add"}
  <SettingsAgentSheet
    takenRegistryIds={new Set(instances.filter((entry) => entry.source === "registry").map((entry) => entry.registryId ?? entry.id))}
    onsave={upsert}
    oncancel={() => (sheet = "closed")}
  />
{:else if sheet !== "closed"}
  <SettingsAgentSheet
    editing={sheet}
    takenRegistryIds={new Set()}
    onsave={upsert}
    oncancel={() => (sheet = "closed")}
  />
{/if}

<style>
  .hint {
    margin: 0;
    padding: 4px 14px 8px;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    line-height: 1.4;
  }

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
