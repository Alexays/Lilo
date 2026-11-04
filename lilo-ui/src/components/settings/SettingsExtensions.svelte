<script lang="ts">
  import { on } from "../../lib/bridge";
  import { extensionActions, tabActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { getAgentsProfileId } from "../../stores/agents.svelte";
  import {
    areShownExtensionsLive,
    getShownExtensions,
    getShownExtensionsProfileId,
    loadLiveShownExtensions,
    showProfileExtensions,
    uninstallExtension,
  } from "../../stores/extensions.svelte";
  import { closeSettingsShell, closeSettingsSubpage, openSettingsSubpage } from "../../stores/panels.svelte";
  import { getActiveProfileId, getProfileById, getProfiles } from "../../stores/profiles.svelte";
  import UiConfirmModal from "../ui/UiConfirmModal.svelte";
  import UiInsetList from "../ui/UiInsetList.svelte";
  import UiListRow from "../ui/UiListRow.svelte";
  import UiSelect from "../ui/UiSelect.svelte";
  import ExtensionDetail from "../extensions/ExtensionDetail.svelte";
  import { takePendingExtensionRemoval } from "../extensions/ExtensionIcons.svelte";
  import ExtensionList from "../extensions/ExtensionList.svelte";
  import ExtensionSpinner from "../extensions/ExtensionSpinner.svelte";
  import { resolveDisplayName } from "../extensions/extensionPanelModel";
  import SettingsGroups from "./SettingsGroups.svelte";

  let { subpage }: { subpage: string | null } = $props();

  const extensions = $derived(getShownExtensions());
  const otherProfileId = $derived(getShownExtensionsProfileId());
  // The agents' throwaway profile is listed only while this window shows it.
  const profiles = $derived(getProfiles().filter((profile) => profile.id !== getAgentsProfileId() || profile.id === getActiveProfileId()));
  const shownProfile = $derived(getProfileById(otherProfileId || getActiveProfileId()));
  const live = $derived(areShownExtensionsLive());
  const detailId = $derived(subpage?.startsWith("extension:") ? subpage.slice("extension:".length) : null);
  const detail = $derived(extensions?.find((extension) => extension.id === detailId) ?? null);
  let removeId = $state<string | null>(takePendingExtensionRemoval());
  const removeTarget = $derived(extensions?.find((extension) => extension.id === removeId) ?? null);

  // Uninstalled elsewhere while its detail page is open: fall back to the list.
  $effect(() => {
    if (detailId && extensions && !detail) closeSettingsSubpage();
  });

  // Stored rows lack what only a loaded extension knows (permissions, shortcuts, site access).
  $effect(() => {
    if (detailId && !live) loadLiveShownExtensions();
  });

  $effect(() =>
    on("extensionMenuAction", (data) => {
      if (data.action === "details") openSettingsSubpage("extensions", `extension:${data.id}`);
      if (data.action === "remove") removeId = data.id;
    }),
  );

  function addExtensions(): void {
    tabActions.create("https://chromewebstore.google.com");
    closeSettingsShell();
  }

  function confirmRemove(): void {
    if (removeId) uninstallExtension(removeId, removeTarget?.profileId);
    removeId = null;
  }
</script>

{#if detail}
  {#if live}
    <ExtensionDetail extension={detail} onremove={() => (removeId = detail.id)} />
  {:else}
    <div class="detail-loading"><ExtensionSpinner /></div>
  {/if}
{:else}
  {#if profiles.length > 1}
    <UiInsetList>
      <UiListRow title={t("extensions.profileTitle")} description={t("extensions.profileHint")}>
        {#snippet action()}
          <span class="profile-dot" style:background={shownProfile?.color} aria-hidden="true"></span>
          <UiSelect
            value={shownProfile?.id ?? ""}
            options={profiles.map((profile) => ({ value: profile.id, label: profile.name }))}
            ariaLabel={t("extensions.profileTitle")}
            onchange={showProfileExtensions}
          />
        {/snippet}
      </UiListRow>
    </UiInsetList>
  {/if}
  <UiInsetList title={t("extensions.installed")} boxed={false}>
    {#snippet accessory()}
      <span class="add-row">
        <!-- The store installs into the profile of the window it opens in. -->
        {#if otherProfileId}
          <span>{t("extensions.addInstallsIn", { profile: getProfileById(getActiveProfileId())?.name ?? "" })}</span>
        {/if}
        <button class="add-button" type="button" onclick={addExtensions}>{t("extensions.addExtensions")}</button>
      </span>
    {/snippet}
    {#if extensions}
      <ExtensionList
        {extensions}
        onopen={(id) => openSettingsSubpage("extensions", `extension:${id}`)}
        onmenu={(id, anchor) =>
          extensionActions.showContextMenu(id, anchor.x, anchor.y, anchor.width, anchor.height, undefined, otherProfileId || undefined)}
      />
    {/if}
  </UiInsetList>
  <SettingsGroups section="extensions" />
{/if}

<UiConfirmModal
  visible={removeTarget !== null}
  title={t("extensions.removeConfirmTitle", { name: removeTarget ? resolveDisplayName(removeTarget) : "" })}
  message={t("extensions.removeConfirmMessage")}
  confirmLabel={t("common.remove")}
  confirmAction={confirmRemove}
  cancelAction={() => (removeId = null)}
/>

<style>
  .add-row {
    display: flex;
    align-items: baseline;
    gap: var(--space-12);
  }

  /* The list's main action: a text button at the end of its header. */
  .add-button {
    padding: 0;
    border: 0;
    border-radius: var(--radius-xs);
    background: none;
    color: var(--accent-ink);
    font-family: inherit;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
    cursor: pointer;
  }

  .add-button:hover {
    text-decoration: underline;
  }

  .add-button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  .profile-dot {
    width: 10px;
    height: 10px;
    border-radius: 50%;
  }

  .detail-loading {
    display: grid;
    place-items: center;
    padding: 48px 0;
  }
</style>
