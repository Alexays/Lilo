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
  import { tabActions } from "../../lib/bridge/actions";
  import { copyText } from "../../lib/clipboard";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { restingFly } from "../../lib/motion/restingTransitions";
  import { MOTION } from "../../lib/motion/timings";
  import { tooltip } from "../../lib/tooltip";
  import type { ThreadItem } from "./conversationModel";
  import Icon from "../ui/Icon.svelte";
  import SiteFavicon from "../ui/SiteFavicon.svelte";
  import { getOpenTabs } from "../../stores/tabs.svelte";
  import Markdown from "./Markdown.svelte";
  import PlanTray from "./PlanTray.svelte";
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
    /** The thread's file a name in a message stands for, which a click opens. */
    knownFile?: (name: string) => string | null;
    /** A user item: puts its text back in the composer. */
    onedit?: (text: string) => void;
  }

  let { tabId, item, sig, promptIndex, canRestore, turn = null, cwd, knownFile, onedit }: Props = $props();

  const view = $derived.by((): ThreadItem => {
    void sig;
    return { ...item };
  });

  let expanded = $state(false);
  // Mounted on first open, then kept so closing can animate.
  let opened = $state(false);
  // Only a question answered while on screen settles; one answered before the replay draws still.
  const askedHere = untrack(() => (item.kind === "permission" || item.kind === "question") && item.answer === null);
  let confirmingRestore = $state(false);
  let copied = $state(false);
</script>

{#if view.kind === "user"}
  <div class="user-turn" class:confirming={confirmingRestore}>
    <div class="user-row">
      <!-- Beside the message, shown on hover or focus: it never moves the thread. -->
      <div class="prompt-actions">
        {#if onedit}
          <button
            type="button"
            class="prompt-action"
            aria-label={t("agents.conversation.editPrompt")}
            use:tooltip={t("agents.conversation.editPrompt")}
            onclick={() => onedit(view.text)}
          >
            <Icon name="pen" size={13} />
          </button>
        {/if}
        <button
          type="button"
          class="prompt-action"
          aria-label={copied ? t("agents.turn.copied") : t("agents.turn.copy")}
          use:tooltip={copied ? t("agents.turn.copied") : t("agents.turn.copy")}
          onclick={async () => {
            if (!(await copyText(view.text))) return;
            copied = true;
            setTimeout(() => (copied = false), 1500);
          }}
        >
          <Icon name={copied ? "check" : "copy"} size={13} />
        </button>
        {#if canRestore}
          <button
            type="button"
            class="prompt-action"
            aria-label={t("agents.conversation.restoreToHere")}
            use:tooltip={t("agents.conversation.restoreToHere")}
            onclick={() => (confirmingRestore = true)}
          >
            <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
              <path d="M3 8a5 5 0 105-5H5M5 1L3 3l2 2" />
            </svg>
          </button>
        {/if}
      </div>
      <div class="user-message">
        <div class="user-text">{view.text}</div>
        {#if view.context.length}
          <div class="context-chips">
            {#each view.context as chip, index (index)}
              {@const web = /^https?:/i.test(chip.uri)}
              {@const open = web ? getOpenTabs().find((tab) => tab.url === chip.uri) : undefined}
              <!-- A page goes back to its tab while it is open; a file opens as a link in a reply does. -->
              <button
                type="button"
                class="context-chip"
                use:tooltip={!web && cwd && chip.uri.startsWith(`${cwd}/`) ? chip.uri.slice(cwd.length + 1) : chip.uri}
                onclick={(event) =>
                  open ? tabActions.switchTo(open.id) : web ? tabActions.create(chip.uri) : conversationActions.openFile(tabId, chip.uri, event.metaKey)}
              >
                {#if web}
                  <SiteFavicon src={open?.faviconDataURL} title={chip.label} url={chip.uri} size={14} radius={3} />
                {:else}
                  <Icon name={chip.uri.endsWith("/") ? "folder" : "file"} size={12} />
                {/if}
                <span class="context-label">{chip.label}</span>
              </button>
            {/each}
          </div>
        {/if}
      </div>
    </div>
    {#if confirmingRestore}
      <!-- Laid over the gap below the message: it never moves the thread. -->
      <div class="checkpoint">
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
      </div>
    {/if}
  </div>
{:else if view.kind === "agent"}
  <Markdown text={view.text} {tabId} {cwd} {knownFile} />
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
  {#if view.stopReason === "refusal"}
    <!-- Any agent's model can refuse; what it wrote about why stays above, this says what to do next. -->
    <div class="refusal" role="note">
      <span class="refusal-icon" aria-hidden="true"><Icon name="shield" size={14} /></span>
      <span class="refusal-copy">
        <span class="refusal-title">{t("agents.turn.refusalTitle")}</span>
        <span class="refusal-hint">{t("agents.turn.refusalHint")}</span>
      </span>
    </div>
  {/if}
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
  <PlanTray entries={view.entries} docked={false} />
{:else if view.kind === "permission" && view.answer !== null}
  <!-- A pending question docks over the composer; once answered, its answer stays in the thread. -->
  {@const chosen = view.options.find((option) => option.optionId === view.answer)}
  <div class="permission" class:settled={askedHere}>
    <span class="permission-title">{view.toolCall.title || t("agents.conversation.permissionTitle")}</span>
    <span class="permission-answer">
      {chosen ? t("agents.conversation.answered", { option: chosen.name }) : t("agents.conversation.cancelled")}
    </span>
  </div>
{:else if view.kind === "question" && view.answer !== null}
  <!-- What was picked, by the options' titles; text typed in reads as typed. -->
  {@const given = view.answer.content ?? {}}
  {@const picks = view.fields.flatMap((field) => {
    const value = given[field.key];
    const list = Array.isArray(value) ? value : value === undefined || value === false ? [] : [value === true ? field.title : value];
    return list.map((pick) => field.options.find((option) => option.value === pick)?.title ?? String(pick));
  })}
  <div class="permission" class:settled={askedHere}>
    <span class="permission-title">{view.message}</span>
    <span class="permission-answer">
      {view.answer.action === "accept" && picks.length
        ? t("agents.conversation.answered", { option: picks.join(", ") })
        : view.answer.action === "decline" ? t("agents.question.skipped") : t("agents.conversation.cancelled")}
    </span>
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
  .user-row {
    display: flex;
    justify-content: flex-end;
    align-items: flex-end;
    gap: var(--space-4);
  }

  .prompt-actions {
    display: flex;
    flex: none;
    opacity: 0;
    transition: opacity var(--motion-duration-normal) var(--motion-ease-standard);
  }

  .user-turn:hover .prompt-actions,
  .prompt-actions:focus-within {
    opacity: 1;
  }

  .prompt-action {
    display: grid;
    place-items: center;
    width: 24px;
    height: 24px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-sm);
    background: none;
    color: var(--text-muted);
    cursor: pointer;
  }

  .prompt-action:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .prompt-action:focus-visible {
    outline: var(--focus-outline);
  }

  .user-message {
    min-width: 0;
    max-width: 85%;
    padding: var(--space-10) var(--space-12);
    border-radius: var(--radius-lg);
    background: color-mix(in srgb, var(--text-primary) 6%, transparent);
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

  .context-chip {
    max-width: 240px;
    height: 22px;
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    padding: 0 var(--space-8) 0 var(--space-6);
    border-radius: var(--radius-sm);
    border: none;
    background: transparent;
    box-shadow: inset 0 0 0 1px var(--border);
    color: var(--text-secondary);
    font: inherit;
    font-size: var(--font-size-sm);
    cursor: pointer;
    transition: background var(--transition-fast), color var(--transition-fast);
  }

  .context-chip:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .context-chip:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .context-chip > :global(:first-child) {
    flex: none;
  }

  .context-label {
    min-width: 0;
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
    transform: translateY(-50%);
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
      grid-template-rows var(--motion-duration-fast) var(--motion-ease-spring),
      opacity var(--motion-duration-fast) ease,
      transform var(--motion-duration-fast) var(--motion-ease-spring);
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

  .refusal {
    display: flex;
    align-items: flex-start;
    gap: var(--space-10);
    padding: var(--space-10) var(--space-12);
    border: 1px solid var(--separator);
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--text-primary) 3%, var(--bg-primary));
  }

  .refusal-icon {
    display: grid;
    flex: none;
    place-items: center;
    width: 26px;
    height: 26px;
    border-radius: var(--radius-sm);
    background: var(--text-primary-tint-10);
    color: var(--text-secondary);
  }

  .refusal-copy {
    display: grid;
    gap: var(--space-2);
  }

  .refusal-title {
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .refusal-hint {
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    line-height: 1.4;
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
    color: color-mix(in srgb, var(--diff-added) 70%, var(--text-primary));
  }

  .count-removed {
    color: color-mix(in srgb, var(--diff-removed) 70%, var(--text-primary));
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

  .permission {
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    gap: var(--space-4) var(--space-8);
    font-size: var(--font-size-sm);
    color: var(--text-secondary);
  }

  .permission.settled .permission-answer {
    animation: answer-in var(--motion-duration-normal) var(--motion-ease-standard) both;
  }

  @keyframes answer-in {
    from {
      opacity: 0;
      transform: translateY(2px);
    }
  }

  .permission-title {
    color: var(--text-primary);
    font-weight: var(--font-weight-medium);
    overflow-wrap: anywhere;
  }

  .permission-answer {
    color: var(--text-muted);
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
