<script lang="ts">
  import { untrack } from "svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { type AgentInstance, type CommandFields, newCommandId } from "../../lib/agentInstances";
  import type { BridgeAgentInfo } from "../../lib/bridge/protocol";
  import { getAgents } from "../../stores/conversations.svelte";
  import { conversationActions } from "../agents/conversationActions";
  import AgentTile from "../agents/AgentTile.svelte";
  import { matchesSearch } from "./settingsPanelModel";
  import SettingsCustomAgent from "./SettingsCustomAgent.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiModal from "../ui/UiModal.svelte";
  import UiSearchField from "../ui/UiSearchField.svelte";
  import UiSegmented from "../ui/UiSegmented.svelte";

  interface Props {
    /** A command entry being edited; absent, the sheet adds. */
    editing?: AgentInstance;
    /** Registry ids already in the list: their rows mark Added instead of offering the button. */
    takenRegistryIds: Set<string>;
    onsave: (entry: AgentInstance) => void;
    oncancel: () => void;
  }

  let { editing, takenRegistryIds, onsave, oncancel }: Props = $props();

  let tab = $state<"registry" | "command">(editing ? "command" : "registry");
  let query = $state("");
  let values = $state<CommandFields>({
    name: editing?.name ?? "",
    executable: editing?.executable ?? "",
    arguments: editing?.arguments ?? "",
    environment: editing?.environment ?? "",
  });

  // The sheet searches the same catalog the picker offers; a still-empty one refreshes once, as the bar does.
  let requested = false;
  let refreshed = false;
  $effect(() => {
    const agents = getAgents();
    untrack(() => {
      if (agents.length > 0) return;
      if (!requested) {
        requested = true;
        conversationActions.loadCatalog(false);
      } else if (!refreshed) {
        refreshed = true;
        conversationActions.loadCatalog(true);
      }
    });
  });

  const results = $derived(
    getAgents().filter(
      (agent) => !agent.command && (!query.trim() || matchesSearch(`${agent.id} ${agent.name} ${agent.description}`, query)),
    ),
  );

  /** The registry's own words on provenance: its repository and license in one line. */
  function meta(agent: BridgeAgentInfo): string {
    const parts = [agent.repository?.replace(/^https?:\/\//, ""), agent.license].filter(Boolean);
    return parts.length ? parts.join(" · ") : agent.description;
  }

  function addRegistry(agent: BridgeAgentInfo): void {
    onsave({ id: agent.id, source: "registry", registryId: agent.id, name: agent.name, enabled: true });
  }

  function saveCommand(): void {
    if (!values.executable.trim()) return;
    onsave({
      id: editing?.id ?? newCommandId(),
      source: "command",
      name: values.name.trim(),
      executable: values.executable.trim(),
      arguments: values.arguments,
      environment: values.environment,
      enabled: editing?.enabled ?? true,
    });
  }
</script>

<UiModal
  zone="add-agent"
  width={560}
  scrolls
  title={editing ? t("settings.agentSheet.editTitle") : t("settings.agentSheet.addTitle")}
  {oncancel}
  ondefault={tab === "command" ? saveCommand : undefined}
>
  {#if !editing}
    <UiSegmented
      value={tab}
      options={[
        { value: "registry", label: t("settings.agentSheet.registryTab") },
        { value: "command", label: t("settings.agentSheet.commandTab") },
      ]}
      ariaLabel={t("settings.agentSheet.sourceLabel")}
      onchange={(value) => (tab = value as "registry" | "command")}
    />
  {/if}

  {#if tab === "registry"}
    <div class="registry">
      <UiSearchField
        value={query}
        placeholder={t("settings.agentSheet.searchPlaceholder")}
        ariaLabel={t("settings.agentSheet.searchPlaceholder")}
        onchange={(value) => (query = value)}
      />
      <div class="results" role="list" aria-label={t("settings.agentSheet.registryTab")}>
        {#each results as agent (agent.id)}
          {@const taken = takenRegistryIds.has(agent.id)}
          <div class="result" role="listitem">
            <AgentTile agentId={agent.id} />
            <span class="copy">
              <span class="name">{agent.name}</span>
              <span class="meta">{meta(agent)}</span>
            </span>
            <UiButton disabled={taken} onclick={() => addRegistry(agent)}>{taken ? t("settings.agentSheet.added") : t("settings.agentSheet.add")}</UiButton>
          </div>
        {:else}
          <p class="none">{query.trim() ? t("settings.agentSheet.none") : t("settings.agentSheet.loading")}</p>
        {/each}
      </div>
    </div>
  {:else}
    <div class="command">
      <SettingsCustomAgent bind:values />
    </div>
  {/if}

  {#snippet actions()}
    <UiButton onclick={oncancel}>{t("common.cancel")}</UiButton>
    {#if tab === "command"}
      <UiButton variant="primary" disabled={!values.executable.trim()} onclick={saveCommand}>
        {editing ? t("common.save") : t("settings.agentSheet.add")}
      </UiButton>
    {/if}
  {/snippet}
</UiModal>

<style>
  .registry {
    display: grid;
    gap: var(--space-12);
    margin-top: var(--space-12);
  }

  .results {
    display: grid;
    max-height: 340px;
    overflow-y: auto;
    overscroll-behavior: contain;
  }

  .result {
    display: flex;
    align-items: center;
    gap: var(--space-10);
    padding: var(--space-8) var(--space-6);
    border-radius: var(--radius-md);
  }

  .result:hover {
    background: var(--bg-hover);
  }

  .copy {
    flex: 1;
    display: grid;
    gap: 1px;
    min-width: 0;
  }

  .name {
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .meta {
    overflow: hidden;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .none {
    margin: var(--space-12) 0;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    text-align: center;
  }

  .command {
    margin-top: var(--space-12);
  }
</style>
