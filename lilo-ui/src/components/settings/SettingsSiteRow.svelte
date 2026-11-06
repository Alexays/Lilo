<script module lang="ts">
  import { getFormatLocale, t } from "../../lib/i18n/state.svelte";

  // Shared by every row: a formatter per row is costly on a long list.
  const percent = $derived(new Intl.NumberFormat(getFormatLocale(), { style: "percent" }));
</script>

<script lang="ts">
  import { openSettingsSubpage } from "../../stores/panels.svelte";
  import { sitePermissionLabel, type SiteSummary } from "./settingsPanelModel";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import UiLinkRow from "../ui/UiLinkRow.svelte";

  let { site }: { site: SiteSummary } = $props();

  const summary = $derived(
    [
      ...site.permissions.map((permission) =>
        t("settings.sites.permissionSummary", {
          type: sitePermissionLabel(permission.type, t),
          decision: t(permission.decision === "deny" ? "settings.permissionDeny" : "settings.permissionAllow"),
        }),
      ),
      ...site.zoomLevels.map((level) => t("settings.sites.zoomSummary", { zoom: percent.format(level.zoom) })),
      ...(site.dataName ? [t("settings.sites.dataSummary")] : []),
    ].join(" · "),
  );
</script>

<UiLinkRow title={site.key} description={summary} onclick={() => openSettingsSubpage("privacy", `site:${site.key}`)}>
  {#snippet icon()}
    <SiteFavicon url={`https://${site.key}`} title={site.key} size={16} />
  {/snippet}
</UiLinkRow>
