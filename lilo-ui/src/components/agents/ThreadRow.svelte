<script lang="ts" module>
  /** What a turn's footer sums up, from the items of that turn. */
  export interface TurnSummary {
    files: number;
    added: number;
    removed: number;
    /** The turn's last agent message, as markdown. */
    finalText: string;
  }
</script>

<script lang="ts">
  import { untrack } from "svelte";
  import { cubicOut } from "svelte/easing";
  import { fade } from "svelte/transition";
  import { conversationActions } from "./conversationActions";
  import { copyText } from "../../lib/clipboard";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { restingFly } from "../../lib/motion/restingTransitions";
  import { MOTION } from "../../lib/motion/timings";
  import { tooltip } from "../../lib/tooltip";
  import type { ThreadItem } from "./conversationModel";
  import Icon from "./Icon.svelte";
  import Markdown from "./Markdown.svelte";
  import PermissionButtons from "./PermissionButtons.svelte";
  import ThreadImage from "./ThreadImage.svelte";
  import { formatDuration, imageSource } from "./threadView";

  interface Props {
    tabId: string;
    item: ThreadItem;
    /** From `itemSignature`: the item is mutated in place, a new signature is what redraws it. */
    sig: string;
    /** Index of the prompt this item belongs to (a user item's own index); -1 before the first. */
    promptIndex: number;
    /** A user item: whether "Restore to here" can bring its files back. */
    canRestore: boolean;
    /** A turn end: what its footer sums up. */
    turn?: TurnSummary | null;
    /** The project folder, which local image paths resolve against. */
    cwd: string;
  }

  let { tabId, item, sig, promptIndex, canRestore, turn = null, cwd }: Props = $props();

  const view = $derived.by((): ThreadItem => {
    void sig;
    return { ...item };
  });

  let expanded = $state(false);
  // Mounted on first open, then kept so closing can animate.
  let opened = $state(false);
  // Only a question answered while on screen settles; one answered before the replay draws still.
  const askedHere = untrack(() => item.kind === "permission" && item.answer === null);
  let confirmingRestore = $state(false);
  let copied = $state(false);

  function rejectPermission(): void {
    if (view.kind !== "permission" || view.answer !== null) return;
    const reject = view.options.find((option) => option.kind === "reject_once") ?? view.options.find((option) => option.kind === "reject_always");
    conversationActions.answer(tabId, String(view.requestId), reject?.optionId);
  }
</script>

{#if view.kind === "user"}
  <div class="user-turn" class:confirming={confirmingRestore}>
    <div class="user-message">
      <div class="user-text">{view.text}</div>
      {#if view.context.length}
        <div class="context-chips">
          {#each view.context as chip, index (index)}
            <span class="context-chip" title={chip.uri}>{chip.label}</span>
          {/each}
        </div>
      {/if}
    </div>
    {#if canRestore}
      <!-- Laid over the gap below the message, shown on hover or focus: it never moves the thread. -->
      <div class="checkpoint">
        {#if confirmingRestore}
          <span
            class="checkpoint-confirm"
            role="group"
            aria-label={t("agents.conversation.restoreConfirm")}
            in:restingFly={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs, easing: cubicOut, x: 8, y: 0 }}
          >
            {t("agents.conversation.restoreConfirm")}
            <button
              type="button"
              class="checkpoint-button primary"
              onclick={() => {
                confirmingRestore = false;
                conversationActions.restore(tabId, promptIndex);
              }}
            >{t("agents.conversation.restore")}</button>
            <button type="button" class="checkpoint-button" onclick={() => (confirmingRestore = false)}>{t("common.cancel")}</button>
          </span>
        {:else}
          <button
            type="button"
            class="checkpoint-button"
            in:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemExitMs }}
            onclick={() => (confirmingRestore = true)}
          >
            <svg width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true">
              <path d="M3 8a5 5 0 105-5H5M5 1L3 3l2 2" />
            </svg>
            {t("agents.conversation.restoreToHere")}
          </button>
        {/if}
      </div>
    {/if}
  </div>
{:else if view.kind === "agent"}
  <Markdown text={view.text} {tabId} {cwd} />
{:else if view.kind === "image"}
  {@const source = imageSource(view.src, cwd)}
  {#if source?.type === "image"}<ThreadImage src={source.src} alt={view.alt} />{/if}
{:else if view.kind === "thought"}
  <div class="thought">
    <button
      type="button"
      class="thought-toggle"
      aria-expanded={expanded}
      onclick={() => {
        expanded = !expanded;
        opened = true;
      }}
    >
      <svg class="chevron" class:open={expanded} width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
        <path d="M3.5 2l3 3-3 3" stroke="currentColor" fill="none" stroke-width="1.4" stroke-linecap="round" />
      </svg>
      {t("agents.conversation.thought")}
    </button>
    <div class="expand" class:open={expanded} inert={!expanded}>
      <div class="expand-clip">
        {#if opened}<div class="thought-text">{view.text}</div>{/if}
      </div>
    </div>
  </div>
{:else if view.kind === "turnEnd"}
  <div class="turn-footer">
    {#if view.stopReason === "cancelled"}
      <span class="turn-meta">{t("agents.turn.stopped")}</span>
    {:else if view.durationMs !== null}
      <span class="turn-meta">
        <Icon name="clock" size={12} />
        {t("agents.turn.workedFor", { duration: formatDuration(view.durationMs) })}
      </span>
    {/if}
    {#if turn && turn.files > 0}
      <span class="turn-meta">
        <Icon name="fileDiff" size={12} />
        {t("agents.turn.files", { count: turn.files })}
        <span class="count-added">+{turn.added}</span>
        <span class="count-removed">-{turn.removed}</span>
      </span>
      <button type="button" class="turn-button" onclick={() => conversationActions.openChanges(tabId)}>
        {t("agents.turn.review")}
      </button>
    {/if}
    {#if turn?.finalText}
      <button
        type="button"
        class="turn-button icon-only"
        aria-label={copied ? t("agents.turn.copied") : t("agents.turn.copy")}
        use:tooltip={copied ? t("agents.turn.copied") : t("agents.turn.copy")}
        onclick={async () => {
          if (!turn || !(await copyText(turn.finalText))) return;
          copied = true;
          setTimeout(() => (copied = false), 1500);
        }}
      >
        {#key copied}
          <span class="copy-glyph" in:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemExitMs }}>
            <Icon name={copied ? "check" : "copy"} size={13} />
          </span>
        {/key}
      </button>
    {/if}
  </div>
{:else if view.kind === "plan"}
  {@const done = view.entries.filter((entry) => entry.status === "completed").length}
  <div class="plan">
    <div class="plan-head">
      <span>{t("agents.conversation.plan")}</span>
      <span>{t("agents.conversation.planProgress", { done, total: view.entries.length })}</span>
    </div>
    <ul class="plan-entries">
      {#each view.entries as entry, index (index)}
        <li class="plan-entry {entry.status}">
          <span class="plan-box" aria-hidden="true"></span>
          <span>{entry.content}</span>
          <span class="visually-hidden">{t(`agents.conversation.planStatus.${entry.status}`)}</span>
        </li>
      {/each}
    </ul>
  </div>
{:else if view.kind === "permission"}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="permission"
    class:answered={view.answer !== null}
    class:settled={askedHere && view.answer !== null}
    onkeydown={(event) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      rejectPermission();
    }}
  >
    <div class="permission-title">
      {#if view.answer === null}<span class="pip" aria-hidden="true"></span>{/if}
      {view.toolCall.title || t("agents.conversation.permissionTitle")}
    </div>
    {#if view.answer === null}
      <PermissionButtons {tabId} requestId={String(view.requestId)} options={view.options} />
    {:else}
      {@const chosen = view.options.find((option) => option.optionId === view.answer)}
      <div class="permission-answer">
        {chosen ? t("agents.conversation.answered", { option: chosen.name }) : t("agents.conversation.cancelled")}
      </div>
    {/if}
  </div>
{:else if view.kind === "notice"}
  <div class="notice">
    {view.text === "restored"
      ? t("agents.conversation.notice.restored")
      : view.text === "restoreFailed"
        ? t("agents.conversation.notice.restoreFailed")
        : view.text === "signedIn"
          ? t("agents.conversation.notice.signedIn")
          : view.text}
  </div>
{/if}

<style>
  .user-message {
    align-self: flex-end;
    max-width: 85%;
    padding: var(--space-10) var(--space-12);
    border-radius: var(--radius-lg);
    background: var(--text-primary-tint-10);
    font-size: var(--font-size-md);
    line-height: 1.5;
    user-select: text;
  }

  .user-text {
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }

  .context-chips {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-6);
    margin-top: var(--space-8);
  }

  /* A block, not a flex box: text-overflow only cuts text it holds directly. */
  .context-chip {
    max-width: 240px;
    height: 22px;
    display: inline-block;
    line-height: 22px;
    padding: 0 var(--space-8);
    border-radius: var(--radius-chip);
    background: var(--accent-tint-18);
    font-size: var(--font-size-xs);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .user-turn {
    position: relative;
    display: flex;
    flex-direction: column;
  }

  .checkpoint {
    position: absolute;
    z-index: 1;
    left: 0;
    right: 0;
    top: calc(100% + var(--space-6));
    display: flex;
    align-items: center;
    gap: var(--space-8);
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    opacity: 0;
    pointer-events: none;
    transform: translateY(-50%);
    transition: opacity var(--motion-duration-normal) var(--motion-ease-standard);
  }

  .user-turn:hover .checkpoint,
  .user-turn:focus-within .checkpoint,
  .user-turn.confirming .checkpoint {
    opacity: 1;
    pointer-events: auto;
  }

  .checkpoint::before,
  .checkpoint::after {
    content: "";
    flex: 1;
    height: 1px;
    background: var(--separator);
  }

  .checkpoint-confirm {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    padding-left: var(--space-8);
    border-radius: var(--radius-chip);
    background: var(--bg-primary);
    color: var(--text-secondary);
  }

  .checkpoint-button {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    height: 20px;
    padding: 0 var(--space-8);
    border: 1px solid var(--border);
    border-radius: var(--radius-chip);
    background: var(--bg-primary);
    color: var(--text-secondary);
    font: inherit;
    font-size: var(--font-size-xs);
    cursor: pointer;
    transition: transform var(--motion-duration-fast) var(--motion-ease-standard);
  }

  .checkpoint-button:active {
    transform: scale(0.97);
  }

  .checkpoint-button:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .checkpoint-button.primary {
    border-color: transparent;
    background: var(--accent);
    color: var(--accent-text);
  }

  .thought-toggle,
  .turn-button {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    border: 0;
    background: none;
    font: inherit;
    text-align: left;
  }

  .thought-toggle {
    gap: var(--space-6);
    height: var(--control-height-sm);
    padding: 0 var(--space-6);
    margin-left: calc(-1 * var(--space-6));
    border-radius: var(--radius-sm);
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    cursor: pointer;
  }

  .thought-toggle:hover {
    color: var(--text-secondary);
    background: var(--bg-hover);
  }

  .thought-text {
    margin-top: var(--space-4);
    padding-left: var(--space-16);
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    line-height: 1.5;
    white-space: pre-wrap;
    user-select: text;
  }

  .chevron {
    flex: none;
    color: var(--text-muted);
    transition: transform var(--motion-duration-normal) var(--motion-ease-spring);
  }

  .expand {
    display: grid;
    grid-template-rows: 0fr;
    opacity: 0;
    transform: translateY(-3px);
    transition:
      grid-template-rows 150ms var(--motion-ease-spring),
      opacity var(--motion-duration-fast) ease,
      transform 150ms var(--motion-ease-spring);
  }

  .expand.open {
    grid-template-rows: 1fr;
    opacity: 1;
    transform: none;
    transition-duration: var(--motion-duration-overlay), var(--motion-duration-normal), var(--motion-duration-overlay);
  }

  .expand-clip {
    min-height: 0;
    overflow: hidden;
  }

  .chevron.open {
    transform: rotate(90deg);
  }

  .turn-footer {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-4) var(--space-12);
    min-height: var(--control-height-sm);
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }

  .turn-meta {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    font-variant-numeric: tabular-nums;
  }

  .count-added {
    color: var(--success-text);
  }

  .count-removed {
    color: var(--danger-text);
  }

  .turn-button {
    height: 22px;
    padding: 0 var(--space-6);
    margin-left: calc(-1 * var(--space-6));
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
    cursor: pointer;
  }

  .turn-button:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .turn-button.icon-only {
    display: grid;
    place-items: center;
    width: 22px;
    padding: 0;
    margin-left: auto;
  }

  .copy-glyph {
    display: inline-flex;
  }

  .plan {
    padding: var(--space-8) var(--space-10);
    border: 1px solid var(--border);
    border-radius: var(--radius-md);
  }

  .plan-head {
    display: flex;
    justify-content: space-between;
    margin-bottom: var(--space-4);
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-semibold);
  }

  .plan-entries {
    margin: 0;
    padding: 0;
    list-style: none;
  }

  .plan-entry {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    min-height: 24px;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .plan-entry.in_progress {
    color: var(--text-primary);
  }

  .plan-entry.completed {
    color: var(--text-muted);
    text-decoration: line-through;
  }

  .plan-box {
    flex: none;
    width: 13px;
    height: 13px;
    box-sizing: border-box;
    border-radius: var(--radius-xs);
    border: 1.5px solid var(--text-muted);
  }

  .plan-entry.in_progress .plan-box {
    border-color: var(--agents);
    background: var(--agents);
    box-shadow: inset 0 0 0 2px var(--bg-primary);
  }

  .plan-entry.completed .plan-box {
    border-color: var(--accent);
    background: var(--accent);
  }

  .visually-hidden {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
    white-space: nowrap;
  }

  .permission {
    display: flex;
    flex-direction: column;
    gap: var(--space-10);
    padding: var(--space-12);
    border: 1px solid color-mix(in srgb, var(--attention) 45%, transparent);
    border-radius: var(--radius-lg);
    background: color-mix(in srgb, var(--attention) 7%, transparent);
    transition:
      background-color var(--motion-duration-slow) ease,
      border-color var(--motion-duration-slow) ease;
  }

  .permission.settled {
    animation: permission-settle var(--motion-duration-slow) var(--motion-ease-bounce);
  }

  .permission.settled .permission-answer {
    animation: answer-in var(--motion-duration-normal) var(--motion-ease-standard) both;
  }

  @keyframes permission-settle {
    from {
      transform: scale(0.985);
    }
  }

  @keyframes answer-in {
    from {
      opacity: 0;
      transform: translateY(2px);
    }
  }

  .permission.answered {
    border-color: var(--border);
    background: none;
  }

  .permission-title {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
    overflow-wrap: anywhere;
  }

  .pip {
    flex: none;
    width: 7px;
    height: 7px;
    border-radius: var(--radius-chip);
    background: var(--attention);
  }

  .permission-answer {
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .notice {
    align-self: center;
    padding: var(--space-2) var(--space-10);
    border: 1px solid var(--border);
    border-radius: var(--radius-chip);
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
  }

  button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }
</style>
