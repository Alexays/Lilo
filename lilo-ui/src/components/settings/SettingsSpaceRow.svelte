<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { openEditor } from "../../stores/panels.svelte";
  import { getProfileById } from "../../stores/profiles.svelte";
  import type { SpaceState } from "../../stores/spaces.svelte";
  import { getOpenTabs, isSpaceHydrated } from "../../stores/tabs.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiListRow from "../ui/UiListRow.svelte";

  let { space }: { space: SpaceState } = $props();

  // Only the Spaces shown this session have their tabs here: the others would count none.
  const description = $derived(
    [
      getProfileById(space.profileId)?.name,
      isSpaceHydrated(space.id) && t("settings.spaces.tabCount", { count: getOpenTabs(space.id).length }),
    ]
      .filter(Boolean)
      .join(" · "),
  );
</script>

<UiListRow title={space.name} {description}>
  {#snippet icon()}
    <span class="space-badge" style:--space-color={space.color}>{space.icon}</span>
  {/snippet}
  {#snippet action()}
    <UiButton onclick={() => openEditor(space.id)}>{t("settings.spaces.edit")}</UiButton>
  {/snippet}
</UiListRow>

<style>
  .space-badge {
    display: grid;
    place-items: center;
    width: 20px;
    height: 20px;
    border-radius: var(--radius-sm);
    background: color-mix(in srgb, var(--space-color) 45%, transparent);
    font-size: var(--font-size-sm);
    line-height: 1;
  }
</style>
