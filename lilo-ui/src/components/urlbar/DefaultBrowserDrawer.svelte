<!-- The default-browser invite. macOS may decline the change (or the user may dismiss its own
     prompt), so the drawer waits for the host's answer and reports it instead of hiding on click. -->
<script lang="ts">
  import { on } from "../../lib/bridge";
  import { settingsActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { dismissDefaultBrowserInvite, hideDefaultBrowserInvite } from "../../stores/urlBarDrawer.svelte";
  import DrawerPrompt from "./DrawerPrompt.svelte";

  let pending = $state(false);
  let outcome = $state<"info" | "error" | null>(null);

  $effect(() =>
    on("settingsActionCompleted", (data) => {
      if (data.action !== "setDefaultBrowser" || !pending) return;
      pending = false;
      outcome = data.level;
      if (data.level === "info") setTimeout(hideDefaultBrowserInvite, 2500);
    }),
  );

  function setDefault(): void {
    pending = true;
    outcome = null;
    settingsActions.setDefaultBrowser();
  }
</script>

<DrawerPrompt
  icon="browser"
  dismissLabel={t("settings.defaultBrowserLater")}
  confirmLabel={t("settings.defaultBrowserSet")}
  confirmDisabled={pending}
  showActions={outcome !== "info"}
  error={outcome === "error"}
  ondismiss={dismissDefaultBrowserInvite}
  onconfirm={setDefault}
>
  {#if outcome === "info"}
    {t("settings.defaultBrowserSetSuccess")}
  {:else if outcome === "error"}
    {t("settings.defaultBrowserSetFailed")}
  {:else}
    {t("settings.defaultBrowserBannerText")}
  {/if}
</DrawerPrompt>
