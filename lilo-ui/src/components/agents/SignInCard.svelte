<script lang="ts">
  import "../../lib/i18n/agentsCatalog";
  import AgentTile from "./AgentTile.svelte";
  import { conversationActions } from "./conversationActions";
  import type { SignInScreen } from "./conversationThread";
  import { t } from "../../lib/i18n/state.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiTextField from "../ui/UiTextField.svelte";

  let { tabId, agentId, agentName, screen }: { tabId: string; agentId: string; agentName: string; screen: SignInScreen } = $props();

  let answer = $state("");

  // An empty answer is a bare Return: what "Press Enter to continue" waits for.
  function submit(event: SubmitEvent): void {
    event.preventDefault();
    conversationActions.answerSignIn(tabId, answer + "\r");
    answer = "";
  }
</script>

<!-- The agent's sign-in runs on a terminal no tab shows: this draws what its screen asks and types the answers. -->
<div class="sign-in-card" role="group" aria-label={t("agents.status.signingIn", { agent: agentName })}>
  <div class="head">
    <AgentTile {agentId} />
    <span class="title">{t("agents.status.signingIn", { agent: agentName })}</span>
  </div>
  {#if screen.choices.length > 0}
    {#if screen.question}<div class="question">{screen.question}</div>{/if}
    <div class="choices">
      {#each screen.choices as choice (choice.key)}
        <UiButton onclick={() => conversationActions.answerSignIn(tabId, choice.key)}>{choice.label}</UiButton>
      {/each}
    </div>
  {:else}
    {#if screen.lines.length > 0}<div class="screen">{screen.lines.join("\n")}</div>{/if}
    <form class="answer" onsubmit={submit}>
      <UiTextField value={answer} onchange={(value) => (answer = value)} placeholder={t("agents.status.signInPlaceholder")} ariaLabel={t("agents.status.signInAnswer")} />
      <button type="submit" class="send">{t("agents.status.signInSend")}</button>
    </form>
  {/if}
  <div class="foot">
    <span class="hint">{t("agents.status.signingInHint")}</span>
    <UiButton variant="ghost" onclick={() => conversationActions.openSignInTerminal(tabId)}>{t("agents.status.signInOpenTerminal")}</UiButton>
  </div>
</div>

<style>
  .sign-in-card {
    display: flex;
    flex-direction: column;
    gap: var(--space-10);
    margin-top: var(--space-8);
    padding: var(--space-12) var(--space-12) var(--space-12) var(--space-16);
    border-radius: var(--radius-lg);
    background: var(--bg-primary);
    box-shadow: inset 0 0 0 1px var(--border);
    font-size: var(--font-size-sm);
  }

  .head {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    min-width: 0;
  }

  .title {
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
  }

  .question {
    color: var(--text-secondary);
  }

  .choices {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-8);
  }

  .screen {
    max-height: 160px;
    overflow: auto;
    padding: var(--space-8) var(--space-12);
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--text-primary) 5%, transparent);
    font: var(--font-size-sm) / 1.5 ui-monospace, "SF Mono", Menlo, monospace;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    user-select: text;
  }

  .answer {
    display: flex;
    gap: var(--space-8);
  }

  .send {
    flex: none;
    height: var(--control-height-lg);
    padding: 0 var(--space-12);
    border: 0;
    border-radius: var(--radius-md);
    background: var(--accent);
    color: var(--accent-text);
    font: inherit;
    font-weight: var(--font-weight-medium);
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .send:hover {
    background: var(--accent-hover);
  }

  .send:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .foot {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-12);
  }

  .hint {
    min-width: 0;
    color: var(--text-muted);
  }
</style>
