<script lang="ts">
  import { fade } from "svelte/transition";
  import { conversationActions } from "./conversationActions";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { MOTION } from "../../lib/motion/timings";
  import { t } from "../../lib/i18n/state.svelte";
  import type { FileDiff } from "./conversationModel";
  import Icon from "../ui/Icon.svelte";
  import { lineDiff, type DiffLine } from "./threadView";

  interface Props {
    tabId: string;
    /** Every edit of one file in this block, in order. */
    diffs: FileDiff[];
    /** The prompt these edits answered: Undo puts the file back as it was before it. */
    checkpoint: number;
    undone: boolean;
    /** The project folder: paths inside it show relative. */
    cwd: string;
  }

  let { tabId, diffs, checkpoint, undone, cwd }: Props = $props();

  const MAX_LINES = 400;
  let expanded = $state(false);
  // Only an opened diff pays for its lines; they stay once drawn, so closing can animate.
  let opened = $state(false);
  const path = $derived(diffs[0].path);
  const added = $derived(diffs.reduce((sum, diff) => sum + diff.added, 0));
  const removed = $derived(diffs.reduce((sum, diff) => sum + diff.removed, 0));
  // `null` separates one edit's lines from the next.
  const lines = $derived<(DiffLine | null)[]>(
    opened ? diffs.flatMap((diff, index) => (index ? [null, ...lineDiff(diff.oldText, diff.newText)] : lineDiff(diff.oldText, diff.newText))) : [],
  );
  const relative = $derived(cwd && path.startsWith(`${cwd}/`) ? path.slice(cwd.length + 1) : path);
  const slash = $derived(relative.lastIndexOf("/"));
</script>

<div class="diff-card">
  <div class="diff-head">
    <button
      type="button"
      class="diff-toggle"
      aria-expanded={expanded}
      title={path}
      onclick={() => {
        expanded = !expanded;
        opened = true;
      }}
    >
      <span class="file-icon"><Icon name="pen" size={14} /></span>
      <span class="label">
        <span class="verb">{t("agents.work.verb.edit")}</span>
        <span class="diff-path"><span class="dir">{relative.slice(0, slash + 1)}</span><span class="name">{relative.slice(slash + 1)}</span></span>
      </span>
      <span class="counts"><span class="count-added">+{added}</span><span class="count-removed">-{removed}</span></span>
      <span class="chevron" class:open={expanded}><Icon name="chevronRight" size={10} /></span>
    </button>
    {#if undone}
      <span class="diff-state" in:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs }}>{t("agents.conversation.undone")}</span>
    {:else}
      <button type="button" class="diff-button" onclick={() => conversationActions.undoFile(tabId, path, checkpoint)}>
        {t("agents.conversation.undo")}
      </button>
    {/if}
  </div>
  <div class="diff-body" class:open={expanded} inert={!expanded}>
    <div class="diff-clip">
      {#if opened}
        <pre class="diff-lines">{#each lines.slice(0, MAX_LINES) as line, index (index)}{#if line}<span class="line {line.type}"><span class="line-number">{line.line}</span>{line.type === "added" ? "+" : line.type === "removed" ? "-" : " "} {line.text}
</span>{:else}<span class="hunk-gap"></span>{/if}{/each}</pre>
        {#if lines.length > MAX_LINES}
          <div class="diff-more">{t("agents.conversation.moreLines", { count: lines.length - MAX_LINES })}</div>
        {/if}
      {/if}
    </div>
  </div>
</div>

<style>
  .diff-card {
    min-width: 0;
  }

  /* Lines up with the other call rows, which bleed into the gutter by the same amount. */
  .diff-head {
    display: flex;
    align-items: center;
    gap: var(--space-4);
    margin-left: calc(-1 * var(--space-6));
  }

  /* Sized as the tool rows around it, so their icons and labels line up. */
  .diff-toggle {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    min-width: 0;
    flex: 1;
    height: 26px;
    padding: 0 var(--space-6);
    border: 0;
    border-radius: var(--radius-sm);
    background: none;
    color: var(--text-primary);
    font: inherit;
    font-size: var(--font-size-sm);
    text-align: left;
    cursor: pointer;
  }

  .diff-toggle:hover {
    background: var(--bg-hover);
  }

  .diff-toggle:focus-visible,
  .diff-button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  .chevron {
    flex: none;
    display: inline-flex;
    color: var(--text-muted);
    opacity: 0;
    transition:
      transform var(--motion-duration-normal) var(--motion-ease-spring),
      opacity var(--motion-duration-fast) ease;
  }

  .diff-toggle:hover .chevron,
  .diff-toggle:focus-visible .chevron,
  .chevron.open {
    opacity: 1;
  }

  .chevron.open {
    transform: rotate(90deg);
  }

  .file-icon {
    flex: none;
    display: inline-flex;
    color: var(--text-muted);
  }

  .label {
    display: flex;
    gap: var(--space-4);
    min-width: 0;
  }

  .verb {
    flex: none;
    color: var(--text-secondary);
  }

  .counts {
    display: flex;
    flex: none;
    gap: var(--space-6);
  }

  .diff-path {
    display: flex;
    min-width: 0;
    white-space: nowrap;
  }

  /* The folders give way first, so a long path keeps its filename. */
  .dir,
  .name {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .dir {
    flex-shrink: 1;
    color: var(--text-secondary);
  }

  .name {
    flex-shrink: 0.01;
    font-weight: var(--font-weight-medium);
  }

  .count-added {
    color: color-mix(in srgb, var(--diff-added) 70%, var(--text-primary));
    font-variant-numeric: tabular-nums;
  }

  .count-removed {
    color: color-mix(in srgb, var(--diff-removed) 70%, var(--text-primary));
    font-variant-numeric: tabular-nums;
  }

  /* Out of the way until the row is pointed at or focused, but still reachable by Tab. */
  .diff-button {
    flex: none;
    height: var(--control-height-sm);
    padding: 0 var(--space-8);
    border: 0;
    border-radius: var(--radius-sm);
    background: none;
    color: var(--text-secondary);
    font: inherit;
    font-size: var(--font-size-sm);
    cursor: pointer;
    opacity: 0;
    transition: opacity var(--motion-duration-fast) ease;
  }

  .diff-head:hover .diff-button,
  .diff-button:focus-visible {
    opacity: 1;
  }

  .diff-button:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .diff-state {
    flex: none;
    padding-right: var(--space-4);
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }

  /* Closed, it takes no room: the row below sits as close as between two tool rows. */
  .diff-body {
    display: grid;
    border: 0 solid transparent;
    border-radius: var(--radius-md);
    grid-template-rows: 0fr;
    opacity: 0;
    transition:
      grid-template-rows var(--motion-duration-fast) var(--motion-ease-spring),
      opacity var(--motion-duration-fast) ease;
  }

  .diff-body.open {
    margin-top: var(--space-2);
    border-width: 1px;
    border-color: var(--border);
    grid-template-rows: 1fr;
    opacity: 1;
    transition-duration: var(--motion-duration-overlay), var(--motion-duration-normal);
  }

  .diff-clip {
    min-height: 0;
    overflow: hidden;
  }

  .diff-lines {
    margin: 0;
    padding: var(--space-6) 0;
    max-height: 420px;
    overflow: auto;
    font: var(--font-size-sm)/1.55 ui-monospace, "SF Mono", Menlo, monospace;
    user-select: text;
  }

  .hunk-gap {
    display: block;
    margin: var(--space-4) 0;
    border-top: 1px dashed var(--separator);
  }

  .line {
    display: block;
    padding: 0 var(--space-12) 0 0;
    white-space: pre;
  }

  .line.added {
    background: color-mix(in srgb, var(--diff-added) 13%, transparent);
  }

  .line.removed {
    background: color-mix(in srgb, var(--diff-removed) 13%, transparent);
  }

  .line-number {
    display: inline-block;
    width: 40px;
    padding-right: var(--space-8);
    text-align: right;
    color: var(--text-muted);
    user-select: none;
  }

  .diff-more {
    padding: var(--space-4) var(--space-12) var(--space-6);
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }
</style>
