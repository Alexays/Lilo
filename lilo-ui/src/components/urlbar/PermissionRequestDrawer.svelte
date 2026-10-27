<!-- A site or extension permission request, asked from the address bar. -->
<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { type PermissionRequest, dismissSitePermissionRequest, respondToPermissionRequest } from "../../stores/urlBarDrawer.svelte";
  import { extensionPermissionLines, permissionRequestIcon, sitePermissionAskKey } from "./urlBarDrawerModel";
  import DrawerPrompt from "./DrawerPrompt.svelte";

  let { request }: { request: PermissionRequest } = $props();

  const MAX_LINES = 4;
  // An agent about to send, pay, delete or publish.
  const agentAction = $derived(request.kind === "agentControl" ? (request.action ?? null) : null);
  const lines = $derived(request.kind === "extensionPermission" ? extensionPermissionLines(request, (key) => t(key)) : []);

  // Read once the whole dispatch is over: an Escape any other surface took (a panel, the command
  // bar, the find bar), whichever window listener ran first, is not ours.
  function handleKeydown(event: KeyboardEvent): void {
    if (request.kind !== "sitePermission" || event.key !== "Escape") return;
    const { requestId } = request;
    setTimeout(() => {
      if (!event.defaultPrevented) dismissSitePermissionRequest(requestId);
    });
  }
</script>

<svelte:window onkeydown={handleKeydown} />

<DrawerPrompt
  icon={permissionRequestIcon(request)}
  dismissLabel={t("permissionPrompt.deny")}
  confirmLabel={t(agentAction ? "permissionPrompt.allowOnce" : "permissionPrompt.allow")}
  alternateLabel={agentAction?.site && agentAction.kind !== "upload" ? t("permissionPrompt.alwaysAllowOnSite") : undefined}
  ondismiss={() => respondToPermissionRequest(request, false)}
  onconfirm={() => respondToPermissionRequest(request, true)}
  onalternate={() => respondToPermissionRequest(request, true, agentAction?.site)}
>
  {#if request.kind === "sitePermission"}
    <strong>{request.origin}</strong> {t(sitePermissionAskKey(request.type))}
  {:else if request.kind === "agentControl"}
    <strong>{request.clientName}</strong>
    {#if agentAction}
      {t({
        enter: "permissionPrompt.agentSubmit",
        fetch: "permissionPrompt.agentFetch",
        upload: "permissionPrompt.agentUpload",
        click: "permissionPrompt.agentClick",
      }[agentAction.kind], {
        label: agentAction.label,
        site: agentAction.site,
        tab: agentAction.tab,
      })}
    {:else}
      {request.profileName ? t("permissionPrompt.agentProfile", { profile: request.profileName }) : t("permissionPrompt.agentControl")}
    {/if}
    {#if request.executable}
      <ul class="request-lines"><li>{t("permissionPrompt.agentExecutable", { path: request.executable })}</li></ul>
    {/if}
  {:else}
    <strong>{request.extensionName}</strong> {t("permissionPrompt.requestsAccess")}
    {#if lines.length > 0}
      <ul class="request-lines">
        {#each lines.slice(0, MAX_LINES) as line, index (`${line}-${index}`)}<li>{line}</li>{/each}
        {#if lines.length > MAX_LINES}
          <li class="more">{t("permissionPrompt.more", { count: lines.length - MAX_LINES })}</li>
        {/if}
      </ul>
    {/if}
  {/if}
</DrawerPrompt>

<style>
  .request-lines {
    margin: 4px 0 0;
    padding: 0;
    list-style: none;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    line-height: 1.5;
  }

  .more {
    color: var(--text-muted);
  }
</style>
