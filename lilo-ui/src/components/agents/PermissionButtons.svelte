<script lang="ts">
  import "../../lib/i18n/agentsCatalog";
  import UiSplitButton from "../ui/UiSplitButton.svelte";
  import { conversationActions } from "./conversationActions";
  import type { BridgePermissionOption } from "../../lib/bridge/protocol";
  import { t } from "../../lib/i18n/state.svelte";
  import { formatShortcut } from "../../lib/inputParser";
  import { tooltip } from "../../lib/tooltip";

  let {
    tabId,
    requestId,
    options,
    keys = false,
  }: {
    tabId: string;
    requestId: string;
    options: BridgePermissionOption[];
    /** Shows Esc, Return and Option-Return on the answers, where those keys answer. */
    keys?: boolean;
  } = $props();

  const LABEL_KEYS: Record<BridgePermissionOption["kind"], string> = {
    allow_once: "agents.question.allow",
    allow_always: "agents.question.allowAlways",
    reject_once: "agents.question.reject",
    reject_always: "agents.question.rejectAlways",
  };
  // Allow is the default, Don't Allow the cancel; "always" and "never" are variants in Allow's menu.
  const answers = $derived.by(() => {
    const byKind = (kind: BridgePermissionOption["kind"]) => options.find((option) => option.kind === kind);
    const allow = byKind("allow_once") ?? byKind("allow_always");
    const reject = byKind("reject_once") ?? byKind("reject_always");
    const variants = (["allow_always", "reject_always"] as const)
      .map(byKind)
      .filter((option): option is BridgePermissionOption => !!option && option !== allow && option !== reject);
    return { allow, reject, variants };
  });

  function answer(option: BridgePermissionOption): void {
    conversationActions.answer(tabId, requestId, option.optionId);
  }
</script>

<!-- Short labels fit a row; the agent's own wording names each answer to VoiceOver and in its tooltip. -->
<div class="permission-buttons">
  {#if answers.reject}
    {@const option = answers.reject}
    {@const label = t(LABEL_KEYS[option.kind])}
    <button
      type="button"
      class="reject"
      aria-label={option.name}
      use:tooltip={{ text: option.name, disabled: option.name === label }}
      onclick={(event) => {
        event.stopPropagation();
        answer(option);
      }}
    >{label}{#if keys}<kbd aria-hidden="true">Esc</kbd>{/if}</button>
  {/if}
  {#if answers.allow}
    {@const option = answers.allow}
    {@const label = t(LABEL_KEYS[option.kind])}
    {#if answers.variants.length > 0}
      <UiSplitButton
        menuLabel={t("agents.question.more")}
        variants={answers.variants.map((variant) => ({
          label: t(LABEL_KEYS[variant.kind]),
          shortcut: keys && variant.kind === "allow_always" ? formatShortcut("Opt+Enter") : undefined,
          onclick: () => answer(variant),
        }))}
        onclick={() => answer(option)}
      >{label}{#if keys}<kbd aria-hidden="true">{formatShortcut("Enter")}</kbd>{/if}</UiSplitButton>
    {:else}
      <button
        type="button"
        class="allow"
        aria-label={option.name}
        onclick={(event) => {
          event.stopPropagation();
          answer(option);
        }}
      >{label}{#if keys}<kbd aria-hidden="true">{formatShortcut("Enter")}</kbd>{/if}</button>
    {/if}
  {/if}
</div>

<style>
  .permission-buttons {
    display: flex;
    flex-wrap: wrap;
    justify-content: flex-end;
    gap: var(--space-8);
  }

  .reject,
  .allow {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    height: var(--control-height-sm);
    max-width: 100%;
    padding: 0 var(--space-10);
    border: 0;
    border-radius: var(--radius-sm);
    font-family: inherit;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-medium);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .reject {
    background: var(--bg-primary);
    box-shadow: inset 0 0 0 1px var(--border);
    color: var(--text-primary);
  }

  .reject:hover {
    background: var(--bg-hover);
  }

  .allow {
    background: var(--accent);
    color: var(--accent-text);
  }

  .allow:hover {
    background: var(--accent-hover);
  }

  .reject:focus-visible,
  .allow:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  kbd {
    font-family: inherit;
    font-size: var(--font-size-xs);
    opacity: 0.6;
  }
</style>
