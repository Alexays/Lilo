<script lang="ts">
  import "../../lib/i18n/agentsCatalog";
  import { conversationActions } from "./conversationActions";
  import type { BridgePermissionOption } from "../../lib/bridge/protocol";
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";

  let { tabId, requestId, options }: { tabId: string; requestId: string; options: BridgePermissionOption[] } = $props();

  const ORDER: BridgePermissionOption["kind"][] = ["allow_once", "allow_always", "reject_once", "reject_always"];
  const LABEL_KEYS: Record<BridgePermissionOption["kind"], string> = {
    allow_once: "agents.question.allow",
    allow_always: "agents.question.allowAlways",
    reject_once: "agents.question.reject",
    reject_always: "agents.question.rejectAlways",
  };
  const sorted = $derived([...options].sort((a, b) => ORDER.indexOf(a.kind) - ORDER.indexOf(b.kind)));
</script>

<!-- Short labels fit a sidebar row; the agent's own wording names each button to VoiceOver and in its tooltip. -->
<div class="permission-buttons">
  {#each sorted as option (option.optionId)}
    {@const label = t(LABEL_KEYS[option.kind])}
    <button
      type="button"
      class="permission-button"
      data-kind={option.kind}
      aria-label={option.name}
      use:tooltip={{ text: option.name, disabled: option.name === label }}
      onclick={(event) => {
        event.stopPropagation();
        conversationActions.answer(tabId, requestId, option.optionId);
      }}
    >{label}</button>
  {/each}
</div>

<style>
  .permission-buttons {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-6);
  }

  .permission-button {
    height: var(--control-height-sm);
    max-width: 100%;
    padding: 0 var(--space-10);
    border: 0;
    border-radius: var(--radius-sm);
    background: var(--text-primary-tint-10);
    color: var(--text-primary);
    font-family: inherit;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-medium);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    cursor: pointer;
    transition:
      background var(--transition-fast),
      color var(--transition-fast),
      transform var(--motion-duration-fast) var(--motion-ease-standard);
  }

  .permission-button:active {
    transform: scale(0.97);
  }

  .permission-button:hover {
    background: var(--text-primary-tint-12);
  }

  .permission-button[data-kind="allow_once"] {
    background: var(--accent);
    color: var(--accent-text);
  }

  .permission-button[data-kind="allow_once"]:hover {
    background: var(--accent-hover);
  }

  .permission-button[data-kind^="reject"] {
    background: transparent;
    color: var(--text-secondary);
  }

  .permission-button[data-kind^="reject"]:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .permission-button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }
</style>
