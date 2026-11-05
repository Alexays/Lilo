<!-- An agent asking to control Lilo, or to move to another profile: a decision worth a modal. -->
<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { getSetting } from "../../stores/settings.svelte";
  import { getAgentConnectRequest, respondToPermissionRequest } from "../../stores/urlBarDrawer.svelte";
  import AgentMascot from "../sidebar/AgentMascot.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiModal from "../ui/UiModal.svelte";
  import { modelLogo } from "./modelLogos";

  const request = $derived(getAgentConnectRequest());
  const logo = $derived(request ? modelLogo(request.clientName) : undefined);
  const asksFirst = $derived(getSetting("agentAskBeforeActions", "true") === "true");
  const abilities = ["permissionPrompt.agentConnect.openTabs", "permissionPrompt.agentConnect.readPages", "permissionPrompt.agentConnect.actSignedIn"];
</script>

{#if request}
  {#key request.requestId}
    <UiModal
      zone="agent-connect"
      width={480}
      oncancel={() => respondToPermissionRequest(request, false)}
      ondefault={() => respondToPermissionRequest(request, true)}
    >
      {#snippet header(titleId)}
        <div class="agent-head">
          <span class="agent-icon" aria-hidden="true">
            {#if logo}
              <svg width="24" height="24" viewBox="0 0 24 24"><path d={logo.path} fill={logo.color ?? "currentColor"} /></svg>
            {:else}
              <AgentMascot />
            {/if}
          </span>
          <div class="agent-heading">
            <h2 id={titleId}>
              {request.profileName
                ? t("permissionPrompt.agentConnect.profileTitle", { client: request.clientName, profile: request.profileName })
                : t("permissionPrompt.agentConnect.title", { client: request.clientName })}
            </h2>
            {#if request.executable}<p class="agent-path">{request.executable}</p>{/if}
          </div>
        </div>
      {/snippet}

      {#if request.profileName}
        <p class="agent-note">{t("permissionPrompt.agentConnect.profileMessage")}</p>
      {:else}
        <ul class="agent-abilities">
          {#each abilities as key (key)}
            <li>
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
                <circle cx="8" cy="8" r="6.5" stroke="currentColor" stroke-width="1.2" />
                <path d="m5.4 8.2 1.8 1.8 3.5-3.6" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round" />
              </svg>
              {t(key)}
            </li>
          {/each}
        </ul>
        {#if asksFirst}<p class="agent-note">{t("permissionPrompt.agentConnect.asksFirst")}</p>{/if}
      {/if}

      {#snippet actions()}
        <UiButton onclick={() => respondToPermissionRequest(request, false)}>
          {t("permissionPrompt.dontAllow")} <kbd>Esc</kbd>
        </UiButton>
        <UiButton variant="primary" onclick={() => respondToPermissionRequest(request, true)}>
          {t("permissionPrompt.allow")} <kbd>⌘↩</kbd>
        </UiButton>
      {/snippet}
    </UiModal>
  {/key}
{/if}

<style>
  .agent-head {
    display: flex;
    align-items: center;
    gap: var(--space-16);
  }

  .agent-icon {
    display: grid;
    flex-shrink: 0;
    place-items: center;
    width: 44px;
    height: 44px;
    border-radius: var(--radius-md);
    background: var(--bg-elevated);
    box-shadow: inset 0 0 0 1px var(--separator);
    color: var(--text-primary);
  }

  .agent-heading {
    min-width: 0;
  }

  h2 {
    margin: 0;
    font-size: var(--font-size-modal);
    font-weight: var(--font-weight-semibold);
    line-height: 1.3;
    overflow-wrap: anywhere;
  }

  .agent-path {
    margin: 2px 0 0;
    overflow: hidden;
    color: var(--text-secondary);
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: var(--font-size-sm);
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .agent-abilities {
    display: grid;
    gap: var(--space-12);
    margin: var(--space-4) 0 0;
    padding: var(--space-12) var(--space-16);
    border-radius: var(--radius-md);
    background: var(--bg-hover);
    list-style: none;
  }

  .agent-abilities li {
    display: flex;
    align-items: center;
    gap: var(--space-12);
  }

  .agent-abilities svg {
    flex-shrink: 0;
    color: var(--accent);
  }

  .agent-note {
    margin: var(--space-12) 0 0;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  kbd {
    margin-left: var(--space-4);
    font-family: inherit;
    font-size: var(--font-size-xs);
    opacity: 0.7;
  }
</style>
