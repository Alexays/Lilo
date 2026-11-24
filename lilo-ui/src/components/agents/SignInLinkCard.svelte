<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { copyText } from "../../lib/clipboard";
  import { tabActions } from "../../lib/bridge/actions";
  import { conversationActions } from "./conversationActions";
  import type { SignInLinkItem } from "./conversationModel";
  import AgentTile from "./AgentTile.svelte";
  import Icon from "../ui/Icon.svelte";

  let { tabId, item, agentId }: { tabId: string; item: SignInLinkItem; agentId: string } = $props();

  let copied = $state(false);

  const host = $derived.by(() => {
    try { return new URL(item.url).host; } catch { return item.url; }
  });

  function copy(): void {
    void copyText(item.url).then((ok) => {
      if (!ok) return;
      copied = true;
      setTimeout(() => (copied = false), 1500);
    });
  }

  function confirm(accept: boolean): void {
    // ACP's accept is the user's consent to open the page; decline and cancel are refusals, and Lilo
    // answers the safe one an agent must handle in every protocol version.
    conversationActions.answerQuestion({ tabId, requestId: String(item.requestId), action: accept ? "accept" : "cancel" });
  }
</script>

<!-- An agent's URL elicitation: it asks the user to open a page (a sign-in) itself; accept is consent to open it. -->
<div class="sign-in-link float-surface" role="group" aria-label={item.message}>
  <div class="head">
    <span class="icon">
      <AgentTile {agentId} />
      <span class="dot" aria-hidden="true"></span>
    </span>
    <span class="message">{item.message}</span>
    {#if item.answer === null}<span class="state">{t("agents.status.waiting")}</span>{/if}
  </div>
  {#if item.url}
    <div class="url">
      <Icon name="globe" size={12} />
      <span class="url-host">{host}</span>
      <span class="url-path">{item.url}</span>
      <button
        type="button"
        class="url-copy"
        aria-label={copied ? t("agents.turn.copied") : t("agents.turn.copy")}
        use:tooltip={copied ? t("agents.turn.copied") : t("agents.turn.copy")}
        onclick={copy}
      >
        <Icon name={copied ? "check" : "copy"} size={12} />
      </button>
    </div>
    <div class="actions">
      <button type="button" class="decline" onclick={() => confirm(false)}>{t("agents.signInLink.decline")}</button>
      <button type="button" class="open" onclick={() => { confirm(true); tabActions.create(item.url); }}>
        <Icon name="external" size={12} />
        {t("agents.signInLink.open")}
      </button>
    </div>
  {/if}
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
    user-select: text;
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
    min-width: 0;
    padding: var(--space-6) var(--space-10);
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--text-primary) 5%, transparent);
    font-size: var(--font-size-sm);
    user-select: text;
  }

  .url :global(svg) {
    flex: none;
    color: var(--text-muted);
  }

  .url-host {
    flex: none;
    color: var(--text-primary);
    font-weight: var(--font-weight-medium);
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .url-path {
    flex: 1;
    min-width: 0;
    color: var(--text-secondary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .url-copy {
    flex: none;
    display: grid;
    padding: var(--space-2);
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-secondary);
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .url-copy:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .url-copy:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .actions {
    display: flex;
    justify-content: flex-end;
    gap: var(--space-8);
  }

  .decline,
  .open {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    height: var(--control-height-sm);
    padding: 0 var(--space-10);
    border: 0;
    border-radius: var(--radius-sm);
    font-family: inherit;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-medium);
    white-space: nowrap;
    cursor: pointer;
    transition:
      background var(--transition-fast),
      opacity var(--transition-fast);
  }

  .decline {
    background: var(--bg-primary);
    box-shadow: inset 0 0 0 1px var(--border);
    color: var(--text-primary);
  }

  .decline:hover {
    background: var(--bg-hover);
  }

  .open {
    background: var(--accent);
    color: var(--accent-text);
  }

  .open:hover {
    background: var(--accent-hover);
  }

  .decline:focus-visible,
  .open:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }
</style>
