<script lang="ts">
  import { tick } from "svelte";
  import { settingsActions } from "../../lib/bridge/actions";
  import type { BridgeAgentPermission } from "../../lib/bridge/protocol";
  import { t } from "../../lib/i18n/state.svelte";
  import { getAgentClientsSnapshot, getSetting } from "../../stores/settings.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiChip from "../ui/UiChip.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiSelect from "../ui/UiSelect.svelte";
  import UiTextField from "../ui/UiTextField.svelte";
  import { normalizeSite } from "./agentPermissions";

  // The nested rows under a connected app: how its agent acts on pages, and where, for On Chosen Sites.
  let { key, title }: { key: string; title: string } = $props();

  const permission = $derived<BridgeAgentPermission>(getAgentClientsSnapshot().permissions[key] ?? { act: "ask", sites: [] });
  const asking = $derived(getSetting("agentAskBeforeActions", "true") === "true");
  let adding = $state(false);
  let field = $state<HTMLElement>();

  async function startAdding(): Promise<void> {
    adding = true;
    await tick();
    field?.querySelector("input")?.focus();
  }

  function addSite(value: string): void {
    adding = false;
    const site = normalizeSite(value);
    if (site && !permission.sites.includes(site)) settingsActions.setAgentClientPermission(key, { ...permission, sites: [...permission.sites, site] });
  }
</script>

<div class="agent-nested" data-agent-permission={key}>
  <UiListRow
    title={t("settings.agents.permissions.act")}
    description={asking ? t(`settings.agents.permissions.${permission.act}Line`) : t("settings.agents.permissions.askingOff")}
  >
    {#snippet action()}
      <UiSelect
        value={permission.act}
        ariaLabel={t("settings.agents.permissions.actLabel", { client: title })}
        options={[
          { value: "ask", label: t("settings.agents.permissions.ask") },
          { value: "sites", label: t("settings.agents.permissions.sites") },
          { value: "always", label: t("settings.agents.permissions.always") },
        ]}
        onchange={(act) => settingsActions.setAgentClientPermission(key, { ...permission, act: act as BridgeAgentPermission["act"] })}
      />
    {/snippet}
  </UiListRow>
</div>
{#if permission.act === "sites"}
  <div class="agent-nested">
    <UiListRow title={t("settings.agents.permissions.sitesTitle")}>
      <span class="chips">
        {#each permission.sites as site (site)}
          <UiChip
            label={site}
            removeLabel={t("settings.agents.permissions.removeSite", { site })}
            onremove={() => settingsActions.setAgentClientPermission(key, { ...permission, sites: permission.sites.filter((entry) => entry !== site) })}
          />
        {:else}
          <span class="empty">{t("settings.agents.permissions.noSites")}</span>
        {/each}
      </span>
      {#snippet action()}
        {#if adding}
          <!-- Enter or leaving the field adds what it holds; Esc puts the button back. -->
          <span class="add" role="presentation" bind:this={field} onfocusout={() => (adding = false)} onkeydown={(event) => event.key === "Escape" && (adding = false)}>
            <UiTextField ariaLabel={t("settings.agents.permissions.addSiteLabel", { client: title })} oncommit={addSite} />
          </span>
        {:else}
          <UiButton onclick={startAdding}>{t("settings.agents.permissions.addSite")}</UiButton>
        {/if}
      {/snippet}
    </UiListRow>
  </div>
{/if}

<style>
  .agent-nested :global(.ui-list-row) {
    padding-left: 38px;
  }

  .chips {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-6);
    margin-top: var(--space-4);
  }

  .empty {
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .add {
    display: block;
    width: 180px;
  }
</style>
