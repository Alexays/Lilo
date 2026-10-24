<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import type { SettingsSectionId } from "../../stores/panels.svelte";
  import { getSetting } from "../../stores/settings.svelte";
  import { getAgentsSpaceId } from "../../stores/agents.svelte";
  import { getSpaces } from "../../stores/spaces.svelte";
  import SettingRow from "./SettingRow.svelte";
  import { isToggleOn, parseBlockerSites, SETTINGS, sectionGroups } from "./settingsPanelModel";
  import SettingsAgentRows from "./SettingsAgentRows.svelte";
  import SettingsProfiles from "./SettingsProfiles.svelte";
  import SettingsSpaceRow from "./SettingsSpaceRow.svelte";
  import SettingsGroupIcon from "./SettingsGroupIcon.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";

  let { section }: { section: SettingsSectionId } = $props();

  // A setting under a switch shows, indented, only while that switch is on; the always-allowed sites while there are some.
  const groups = $derived(
    sectionGroups(
      section,
      (setting) =>
        (!setting.requires || isToggleOn(setting.requires, getSetting)) &&
        (setting.id !== "agentAlwaysAllowed" || parseBlockerSites(getSetting("agentAlwaysAllowedSites", "")).length > 0),
    ),
  );
  const nested = new Set(SETTINGS.filter((setting) => setting.requires).map((setting) => setting.id));
</script>

{#each groups as group (group.groupKey)}
  <UiInsetList title={t(group.groupKey)}>
    {#snippet icon()}<SettingsGroupIcon group={group.groupKey} />{/snippet}
    {#if group.groupKey === "settings.groups.spaces"}
      <!-- The Agents space is Lilo's, for agents: like the profiles page, the list leaves it out. -->
      {#each getSpaces().filter((space) => space.id !== getAgentsSpaceId()) as space (space.id)}<SettingsSpaceRow {space} />{/each}
    {:else if group.groupKey === "settings.groups.profiles"}
      <SettingsProfiles />
    {:else if group.groupKey === "settings.groups.agentClients"}
      <SettingsAgentRows />
    {/if}
    <!-- The profile cards hold their own "New profile" control. -->
    {#each group.groupKey === "settings.groups.profiles" ? [] : group.settings as id (id)}
      <div class="setting-row" class:nested={nested.has(id)} data-setting-id={id}>
        <SettingRow {id} />
      </div>
    {/each}
  </UiInsetList>
{/each}

<style>
  .nested {
    padding-left: 16px;
    border-left: 2px solid var(--separator);
  }
</style>
