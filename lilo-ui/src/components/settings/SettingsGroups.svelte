<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import type { SettingsSectionId } from "../../stores/panels.svelte";
  import { getSetting } from "../../stores/settings.svelte";
  import { isAgentsSpace } from "../../stores/agents.svelte";
  import { getSpaces } from "../../stores/spaces.svelte";
  import SettingRow from "./SettingRow.svelte";
  import { isToggleOn, parseBlockerSites, SETTINGS, type SettingId, sectionGroups } from "./settingsPanelModel";
  import SettingsAgentRows from "./SettingsAgentRows.svelte";
  import SettingsProfiles from "./SettingsProfiles.svelte";
  import SettingsSpaceRow from "./SettingsSpaceRow.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";

  let { section }: { section: SettingsSectionId } = $props();

  // Visual choices that share a row two by two, so the page holds on one screen.
  const PAIRED: Partial<Record<SettingId, SettingId>> = {
    theme: "appIcon",
    tabPosition: "addressPlacement",
    defaultZoom: "minimumFontSize",
  };

  // A setting under a switch shows only while that switch is on; the always-allowed sites while there are some,
  // Lilo's system prompt while it is the one chosen.
  const groups = $derived(
    sectionGroups(
      section,
      (setting) =>
        (!setting.requires || isToggleOn(setting.requires, getSetting)) &&
        (setting.id !== "agentAlwaysAllowed" || parseBlockerSites(getSetting("agentAlwaysAllowedSites", "")).length > 0) &&
        (setting.id !== "agentSystemPromptText" || getSetting("agentSystemPrompt", "lilo") === "lilo"),
    ),
  );

  function rows(settings: SettingId[]): SettingId[][] {
    const result: SettingId[][] = [];
    for (const id of settings) {
      const previous = result.at(-1);
      if (previous?.length === 1 && PAIRED[previous[0]] === id) previous.push(id);
      else result.push([id]);
    }
    return result;
  }

  // Indented under its switch when that switch sits in the same box.
  function nested(id: SettingId, settings: SettingId[]): boolean {
    const requires = SETTINGS.find((setting) => setting.id === id)?.requires;
    return !!requires && settings.includes(requires);
  }
</script>

{#each groups as group (group.groupKey)}
  {#if group.groupKey === "settings.groups.profiles"}
    <!-- Cards, not rows: each holds its own menu, and the last one creates a profile. -->
    <UiInsetList title={t(group.groupKey)} boxed={false}>
      <SettingsProfiles />
    </UiInsetList>
  {:else if group.groupKey === "settings.groups.agentClients"}
    <SettingsAgentRows title={t(group.groupKey)} />
  {:else}
    <UiInsetList title={t(group.groupKey)}>
      {#if group.groupKey === "settings.groups.spaces"}
        <!-- The Agents space is Lilo's, for agents: like the profiles page, the list leaves it out. -->
        {#each getSpaces().filter((space) => !isAgentsSpace(space.id)) as space (space.id)}<SettingsSpaceRow {space} />{/each}
      {/if}
      {#each rows(group.settings) as row (row[0])}
        {#if row.length === 2}
          <div class="setting-pair">
            {#each row as id (id)}
              <div class="setting-row" data-setting-id={id}><SettingRow {id} /></div>
            {/each}
          </div>
        {:else}
          <div class="setting-row" class:nested={nested(row[0], group.settings)} data-setting-id={row[0]}>
            <SettingRow id={row[0]} />
          </div>
        {/if}
      {/each}
    </UiInsetList>
  {/if}
{/each}

<style>
  .setting-pair {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
  }

  /* A hairline between the two halves. */
  .setting-pair > .setting-row + .setting-row {
    box-shadow: -1px 0 var(--separator);
  }

  .nested :global(.ui-list-row) {
    padding-left: 38px;
  }
</style>
