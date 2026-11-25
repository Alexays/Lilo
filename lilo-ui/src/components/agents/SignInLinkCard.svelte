<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { conversationActions } from "./conversationActions";
  import type { SignInLinkItem } from "./conversationModel";
  import AgentTile from "./AgentTile.svelte";
  import Icon from "../ui/Icon.svelte";
  import UiButton from "../ui/UiButton.svelte";

  let { tabId, item, agentId }: { tabId: string; item: SignInLinkItem; agentId: string } = $props();

  // Lilo opens the page on accept, and answers accept only once its tab opened. Cancel is the refusal
  // every protocol version handles.
  function answer(accept: boolean): void {
    conversationActions.answerQuestion({ tabId, requestId: String(item.requestId), action: accept ? "accept" : "cancel" });
  }
</script>

<!-- An agent's URL elicitation: the page it asks the user to open, shown as its host and path only. -->
<div class="sign-in-link float-surface" role="group" aria-label={item.message}>
  <div class="head">
    <span class="icon">
      <AgentTile {agentId} />
      <span class="dot" aria-hidden="true"></span>
    </span>
    <span class="message">{item.message}</span>
    <span class="state">{t("agents.status.waiting")}</span>
  </div>
  <div class="url">
    <Icon name="globe" size={12} />
    <span class="url-host">{item.host}</span>
    {#if item.path !== "/"}<span class="url-path">{item.path}</span>{/if}
  </div>
  <div class="actions">
    <UiButton onclick={() => answer(false)}>{t("agents.signInLink.decline")}</UiButton>
    <UiButton variant="primary" onclick={() => answer(true)}>{t("agents.signInLink.open")}</UiButton>
  </div>
</div>

<style>
  .sign-in-link {
    display: flex;
    flex-direction: column;
    gap: var(--space-10);
    width: 100%;
    box-sizing: border-box;
    margin-bottom: var(--space-8);
    padding: var(--space-12) var(--space-12) var(--space-12) var(--space-16);
    border-radius: var(--radius-lg);
  }

  .head {
    display: flex;
    align-items: flex-start;
    gap: var(--space-8);
    min-width: 0;
  }

  .icon {
    position: relative;
    flex: none;
    display: grid;
    margin-top: 2px;
  }

  .dot {
    position: absolute;
    right: -3px;
    bottom: -3px;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--attention);
    box-shadow: 0 0 0 2px var(--float-surface);
  }

  .message {
    flex: 1;
    min-width: 0;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
    line-height: 1.4;
  }

  .state {
    flex: none;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    line-height: 1.6;
  }

  .url {
    display: flex;
    align-items: center;
    gap: var(--space-6);
    padding: var(--space-6) var(--space-10);
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--text-primary) 5%, transparent);
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .url :global(svg) {
    flex: none;
    color: var(--text-muted);
  }

  /* The host is never clipped: its end is what names the site. */
  .url-host {
    min-width: 0;
    color: var(--text-primary);
    font-weight: var(--font-weight-medium);
    overflow-wrap: anywhere;
    user-select: text;
  }

  .url-path {
    flex: 1;
    min-width: 0;
    margin-left: calc(-1 * var(--space-6));
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    user-select: text;
  }

  .actions {
    display: flex;
    justify-content: flex-end;
    gap: var(--space-8);
  }
</style>
