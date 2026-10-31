<script lang="ts">
  import { getLocale, t } from "../../lib/i18n/state.svelte";
  import { openSettingsSubpage } from "../../stores/panels.svelte";
  import { sitePermissionLabel, type SiteSummary } from "./settingsPanelModel";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import UiLinkRow from "../ui/UiLinkRow.svelte";

  let { site }: { site: SiteSummary } = $props();

  const summary = $derived.by(() => {
    const percent = new Intl.NumberFormat(getLocale(), { style: "percent" });
    return [
      ...site.permissions.map((permission) =>
        t("settings.sites.permissionSummary", {
          type: sitePermissionLabel(permission.type, t),
          decision: t(permission.decision === "deny" ? "settings.permissionDeny" : "settings.permissionAllow"),
        }),
      ),
      ...site.zoomLevels.map((level) => t("settings.sites.zoomSummary", { zoom: percent.format(level.zoom) })),
      ...(site.dataName ? [t("settings.sites.dataSummary")] : []),
    ].join(" · ");
  });
</script>

<UiLinkRow title={site.key} description={summary} onclick={() => openSettingsSubpage("privacy", `site:${site.key}`)}>
  {#snippet icon()}
    <SiteFavicon url={`https://${site.key}`} title={site.key} size={16} />
  {/snippet}
</UiLinkRow>
