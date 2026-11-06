<!-- A window the page opened without a click was refused. WebKit never offers it back, so allowing the site
     lets its next try through: the page has to open it again. -->
<script lang="ts">
  import { chromeActions } from "../../lib/bridge/actions";
  import { t } from "../../lib/i18n/state.svelte";
  import { setPopupBlockedDrawerOpen } from "../../stores/urlBarDrawer.svelte";
  import DrawerPrompt from "./DrawerPrompt.svelte";

  let { origin }: { origin: string } = $props();

  let allowed = $state(false);

  $effect(() => {
    if (!allowed) return;
    const timer = setTimeout(() => setPopupBlockedDrawerOpen(false), 2500);
    return () => clearTimeout(timer);
  });

  function allow(): void {
    chromeActions.allowPopups();
    allowed = true;
  }
</script>

<DrawerPrompt
  icon="popups"
  dismissLabel={t("permissionPrompt.popup.keepBlocking")}
  confirmLabel={t("permissionPrompt.popup.alwaysAllow")}
  showActions={!allowed}
  ondismiss={() => setPopupBlockedDrawerOpen(false)}
  onconfirm={allow}
>
  {#if allowed}
    {t("permissionPrompt.popup.allowed")}
  {:else}
    <strong>{origin}</strong> {t("permissionPrompt.popup.tried")}
  {/if}
</DrawerPrompt>
