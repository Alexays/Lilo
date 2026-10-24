<script lang="ts">
  import { on } from "../../lib/bridge";
  import { extensionActions, tabActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { getExtensions, uninstallExtension } from "../../stores/extensions.svelte";
  import { closeSettingsShell, closeSettingsSubpage, openSettingsSubpage } from "../../stores/panels.svelte";
  import BottomConfirmSheet from "../ui/BottomConfirmSheet.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import ExtensionDetail from "../extensions/ExtensionDetail.svelte";
  import { takePendingExtensionRemoval } from "../extensions/ExtensionIcons.svelte";
  import ExtensionList from "../extensions/ExtensionList.svelte";
  import { resolveDisplayName } from "../extensions/extensionPanelModel";
  import SettingsGroups from "./SettingsGroups.svelte";

  let { subpage }: { subpage: string | null } = $props();

  const extensions = $derived(getExtensions());
  const detailId = $derived(subpage?.startsWith("extension:") ? subpage.slice("extension:".length) : null);
  const detail = $derived(extensions.find((extension) => extension.id === detailId) ?? null);
  let removeId = $state<string | null>(takePendingExtensionRemoval());
  const removeTarget = $derived(extensions.find((extension) => extension.id === removeId) ?? null);

  // Uninstalled elsewhere while its detail page is open: fall back to the list.
  $effect(() => {
    if (detailId && !detail) closeSettingsSubpage();
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
    if (removeId) uninstallExtension(removeId);
    removeId = null;
  }
</script>

{#if detail}
  <ExtensionDetail extension={detail} onremove={() => (removeId = detail.id)} />
{:else}
  <ExtensionList
    {extensions}
    onopen={(id) => openSettingsSubpage("extensions", `extension:${id}`)}
    onmenu={(id, anchor) => extensionActions.showContextMenu(id, anchor.x, anchor.y, anchor.width, anchor.height)}
  />
  <div class="add-row">
    <UiButton onclick={addExtensions}>{t("extensions.addExtensions")}</UiButton>
  </div>
  <SettingsGroups section="extensions" />
{/if}

<BottomConfirmSheet
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
    justify-content: flex-end;
    margin-top: 10px;
  }
</style>
