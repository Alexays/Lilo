<script lang="ts">
  import { fade } from "svelte/transition";
  import { conversationActions } from "./conversationActions";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { MOTION } from "../../lib/motion/timings";
  import { t } from "../../lib/i18n/state.svelte";
  import type { FileDiff } from "./conversationModel";
  import Icon from "./Icon.svelte";
  import { lineDiff } from "./threadView";

  interface Props {
    tabId: string;
    diff: FileDiff;
    /** The prompt this edit answered: Undo puts the file back as it was before it. */
    checkpoint: number;
    undone: boolean;
    /** The project folder: paths inside it show relative. */
    cwd: string;
  }

  let { tabId, diff, checkpoint, undone, cwd }: Props = $props();

  const MAX_LINES = 400;
  let expanded = $state(false);
  // Only an opened diff pays for its lines; they stay once drawn, so closing can animate.
  let opened = $state(false);
  let kept = $state(false);
  const lines = $derived(opened ? lineDiff(diff.oldText, diff.newText) : []);
  const relative = $derived(cwd && diff.path.startsWith(`${cwd}/`) ? diff.path.slice(cwd.length + 1) : diff.path);
  const slash = $derived(relative.lastIndexOf("/"));
</script>

<div class="diff-card">
  <div class="diff-head">
    <button
      type="button"
      class="diff-toggle"
      aria-expanded={expanded}
      title={diff.path}
      onclick={() => {
        expanded = !expanded;
        opened = true;
      }}
    >
      <span class="file-icon"><Icon name="file" size={13} /></span>
      <span class="diff-path"><span class="dir">{relative.slice(0, slash + 1)}</span><span class="name">{relative.slice(slash + 1)}</span></span>
      <span class="count-added">+{diff.added}</span>
      <span class="count-removed">-{diff.removed}</span>
      <span class="chevron" class:open={expanded}><Icon name="chevronRight" size={10} /></span>
    </button>
    {#if undone}
      <span class="diff-state" in:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs }}>{t("agents.conversation.undone")}</span>
    {:else if kept}
      <span class="diff-state" in:fade={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs }}>{t("agents.conversation.kept")}</span>
    {:else}
      <span class="diff-actions">
        <button type="button" class="diff-button" onclick={() => conversationActions.undoFile(tabId, diff.path, checkpoint)}>
          {t("agents.conversation.undo")}
        </button>
        <button type="button" class="diff-button primary" onclick={() => (kept = true)}>{t("agents.conversation.keep")}</button>
      </span>
    {/if}
  </div>
  <div class="diff-body" class:open={expanded} inert={!expanded}>
    <div class="diff-clip">
      {#if opened}
        <pre class="diff-lines">{#each lines.slice(0, MAX_LINES) as line, index (index)}<span class="line {line.type}"><span class="line-number">{line.line}</span>{line.type === "added" ? "+" : line.type === "removed" ? "-" : " "} {line.text}
</span>{/each}</pre>
        {#if lines.length > MAX_LINES}
          <div class="diff-more">{t("agents.conversation.moreLines", { count: lines.length - MAX_LINES })}</div>
        {/if}
      {/if}
    </div>
  </div>
</div>

<style>
  .diff-card {
    border: 1px solid var(--border);
    border-radius: var(--radius-md);
    overflow: hidden;
  }

  .diff-head {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    padding: var(--space-2) var(--space-6) var(--space-2) var(--space-2);
  }

  .diff-toggle {
    display: flex;
    align-items: center;
    gap: var(--space-6);
    min-width: 0;
    flex: 1;
    height: var(--control-height-sm);
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
    color: var(--success-text);
    font-variant-numeric: tabular-nums;
  }

  .count-removed {
    color: var(--danger-text);
    font-variant-numeric: tabular-nums;
  }

  .diff-actions {
    display: flex;
    gap: var(--space-4);
    flex: none;
  }

  .diff-button {
    height: 20px;
    padding: 0 var(--space-8);
    border: 0;
    border-radius: var(--radius-sm);
    background: var(--text-primary-tint-10);
    color: var(--text-primary);
    font: inherit;
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-medium);
    cursor: pointer;
    transition: transform var(--motion-duration-fast) var(--motion-ease-standard);
  }

  .diff-button:active {
    transform: scale(0.97);
  }

  .diff-button:hover {
    background: var(--text-primary-tint-12);
  }

  .diff-button.primary {
    background: var(--accent);
    color: var(--accent-text);
  }

  .diff-button.primary:hover {
    background: var(--accent-hover);
  }

  .diff-state {
    flex: none;
    padding-right: var(--space-4);
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }

  .diff-body {
    display: grid;
    border-top: 1px solid transparent;
    grid-template-rows: 0fr;
    opacity: 0;
    transition:
      grid-template-rows 150ms var(--motion-ease-spring),
      opacity var(--motion-duration-fast) ease;
  }

  .diff-body.open {
    border-top-color: var(--separator);
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
    font: var(--font-size-xs)/1.55 ui-monospace, "SF Mono", Menlo, monospace;
    user-select: text;
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
