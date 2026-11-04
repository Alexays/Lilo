<script lang="ts">
  import { featureFlagsActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { getFeatureFlags } from "../../stores/settings.svelte";
  import SettingsFlagRow from "./SettingsFlagRow.svelte";
  import SettingsGroups from "./SettingsGroups.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiLinkRow from "../ui/UiLinkRow.svelte";
  import UiListRow from "../ui/UiListRow.svelte";

  const flags = $derived(getFeatureFlags());
  const experimental = $derived(flags.filter((flag) => flag.kind === "experimental"));
  const debug = $derived(flags.filter((flag) => flag.kind === "debug"));
  const modifiedCount = $derived(flags.filter((flag) => flag.modified).length);
  let showDebug = $state(false);
</script>

<SettingsGroups section="advanced" />

<UiInsetList title={t("featureFlags.title")}>
  {#snippet accessory()}{t("featureFlags.reloadNote")}{/snippet}
  <UiListRow title={t("featureFlags.resetTitle")} description={t("featureFlags.warning")}>
    {#snippet action()}
      <UiButton disabled={modifiedCount === 0} onclick={() => featureFlagsActions.resetAll()}>
        {t("featureFlags.resetAll")}{modifiedCount > 0 ? ` (${modifiedCount})` : ""}
      </UiButton>
    {/snippet}
  </UiListRow>
  {#each experimental as flag (flag.key)}<SettingsFlagRow {flag} />{/each}
  <!-- Internal WebKit switches can break sites: folded away until asked for. -->
  {#if debug.length > 0}
    <UiLinkRow
      title={t("featureFlags.sectionDebug", { count: debug.length })}
      expanded={showDebug}
      onclick={() => (showDebug = !showDebug)}
    />
    {#if showDebug}
      {#each debug as flag (flag.key)}<SettingsFlagRow {flag} />{/each}
    {/if}
  {/if}
</UiInsetList>
