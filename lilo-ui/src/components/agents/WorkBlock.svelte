<script lang="ts" module>
  import type { ToolCallItem, ToolKind } from "./conversationModel";
  import type { IconName } from "./icons";

  const KIND_ICONS: Record<ToolKind, IconName> = {
    read: "eye",
    edit: "pen",
    delete: "trash",
    move: "move",
    search: "search",
    execute: "terminal",
    think: "brain",
    fetch: "globe",
    switch_mode: "switch",
    other: "wrench",
  };
  const FILE_KINDS = new Set<ToolKind>(["read", "edit", "delete", "move"]);
  const SUMMARY_KINDS = new Set<ToolKind>(["read", "execute", "search", "fetch", "think"]);
  // Lilo's own browser tools, reached through its MCP server.
  const BROWSER_TOOL = /\blilo\b|mcp__lilo|tabs_|navigate|computer/i;
  const OUTPUT_TAIL = 12;
  const MAX_OUTPUT = 20000;

  interface CallView {
    call: ToolCallItem;
    browser: boolean;
    /** The verb's i18n key; null when the title is shown as is. */
    verb: string | null;
    target: string;
    path: boolean;
    command: boolean;
  }

  // Agents describe calls differently: the raw input names the file, command or query when there is one.
  function describe(call: ToolCallItem, cwd: string): CallView {
    const input = (call.rawInput !== null && typeof call.rawInput === "object" ? call.rawInput : {}) as Record<string, unknown>;
    const browser =
      BROWSER_TOOL.test(call.title) ||
      ["server", "tool", "name"].some((key) => typeof input[key] === "string" && BROWSER_TOOL.test(input[key] as string));
    const view = { call: { ...call }, browser, verb: null, target: call.title, path: false, command: false };
    if (call.toolKind === "execute" && !browser) {
      const command = input.command;
      // Codex sends argv, usually ["bash", "-lc", script].
      const line = Array.isArray(command)
        ? command.length === 3 && command[1] === "-lc" ? String(command[2]) : command.join(" ")
        : typeof command === "string" ? command : call.title.replace(/^`(.*)`$/, "$1");
      return { ...view, target: line, command: true };
    }
    const path = FILE_KINDS.has(call.toolKind);
    const target = path
      ? input.file_path ?? input.path ?? input.notebook_path ?? call.locations[0]?.path
      : call.toolKind === "search" ? input.pattern ?? input.query
      : call.toolKind === "fetch" ? input.url ?? input.query
      : null;
    if (browser || typeof target !== "string" || !target) {
      return { ...view, target: call.title.replace(/^mcp__lilo__/, "") };
    }
    const shown = path && cwd && target.startsWith(`${cwd}/`) ? target.slice(cwd.length + 1) : target;
    return { ...view, verb: `agents.work.verb.${call.toolKind}`, target: shown, path };
  }
</script>

<script lang="ts">
  import { untrack } from "svelte";
  import { cubicOut } from "svelte/easing";
  import { SvelteSet } from "svelte/reactivity";
  import { fade } from "svelte/transition";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { restingFly } from "../../lib/motion/restingTransitions";
  import { MOTION } from "../../lib/motion/timings";
  import DiffCard from "./DiffCard.svelte";
  import Icon from "./Icon.svelte";
  import MascotGlyph from "./MascotGlyph.svelte";
  import ThreadImage from "./ThreadImage.svelte";
  import { formatDuration } from "./threadView";

  interface Props {
    tabId: string;
    /** Consecutive tool calls of one turn, mutated in place: `sig` changes when any of them does. */
    calls: ToolCallItem[];
    sig: string;
    /** The turn ended: the block folds to its summary unless opened by hand. */
    done: boolean;
    /** Calls arriving now rise in; replayed ones draw still. */
    live: boolean;
    cwd: string;
    promptIndex: number;
    undone: Set<string>;
  }

  let { tabId, calls, sig, done, live, cwd, promptIndex, undone }: Props = $props();

  let userOpen = $state<boolean | null>(null);
  // A block where something failed stays open when the turn ends: that is what to read first.
  const failed = $derived(calls.some((call) => call.status === "failed"));
  const open = $derived(userOpen ?? (!done || failed));
  // A folded block from the replay builds its rows on first open.
  let opened = $state(untrack(() => !done || calls.some((call) => call.status === "failed")));
  const toggled = new SvelteSet<string>();
  const fullOutput = new SvelteSet<string>();

  const views = $derived.by(() => {
    void sig;
    return calls.map((call) => describe(call, cwd));
  });

  const summary = $derived.by(() => {
    // eslint-disable-next-line svelte/prefer-svelte-reactivity -- local to one run
    const counts = new Map<string, number>();
    // eslint-disable-next-line svelte/prefer-svelte-reactivity -- local to one run
    const files = new Set<string>();
    let added = 0;
    let removed = 0;
    let images = 0;
    for (const view of views) {
      images += view.call.images.length;
      const kind = view.call.toolKind;
      const category = view.browser ? "browser" : FILE_KINDS.has(kind) && kind !== "read" ? "edit" : SUMMARY_KINDS.has(kind) ? kind : "tool";
      if (category !== "edit") {
        counts.set(category, (counts.get(category) ?? 0) + 1);
        continue;
      }
      // Holds the place of edits in the summary; the count is the files touched.
      counts.set("edit", 0);
      if (!view.call.diffs.length) files.add(view.call.toolCallId);
      for (const diff of view.call.diffs) {
        files.add(diff.path);
        added += diff.added;
        removed += diff.removed;
      }
    }
    if (files.size) counts.set("edit", files.size);
    const text = [...counts].map(([category, count]) => t(`agents.work.summary.${category}`, { count })).join(", ");
    return { text: text.charAt(0).toUpperCase() + text.slice(1), added, removed, images, categories: [...counts.keys()] };
  });

  const running = $derived(views.some((view) => view.call.status === "in_progress" || view.call.status === "pending"));
  const enter = $derived(live && !done && !prefersReducedMotion() ? MOTION.itemEnterMs : 0);
</script>

{#snippet status(call: ToolCallItem)}
  <span class="status">
    {#if call.status === "in_progress"}
      <span class="spinner" role="img" aria-label={t("agents.tool.status.in_progress")} out:fade={{ duration: enter && MOTION.itemExitMs }}></span>
    {:else if call.status === "pending"}
      <span class="spinner pending" role="img" aria-label={t("agents.tool.status.pending")} out:fade={{ duration: enter && MOTION.itemExitMs }}></span>
    {:else if call.status === "failed"}
      <span class="failed" role="img" aria-label={t("agents.tool.status.failed")} in:fade={{ duration: enter }}><Icon name="alert" size={13} /></span>
    {:else}
      <span class="done-check" class:fresh={enter > 0} in:fade={{ duration: enter }}><Icon name="check" size={12} /></span>
    {/if}
  </span>
{/snippet}

{#snippet icon(view: CallView)}
  <span class="call-icon" class:command={view.command}>
    {#if view.browser}<MascotGlyph />{:else}<Icon name={KIND_ICONS[view.call.toolKind] ?? "wrench"} size={14} />{/if}
  </span>
{/snippet}

<div class="work">
  <button
    type="button"
    class="work-head"
    aria-expanded={open}
    onclick={() => {
      userOpen = !open;
      opened = true;
    }}
  >
    <span class="chevron" class:open><Icon name="chevronRight" size={10} /></span>
    <!-- What kind of work, readable at a glance before the words. -->
    <span class="kinds" aria-hidden="true">
      {#each summary.categories.slice(0, 4) as category (category)}
        {#if category === "browser"}<MascotGlyph />{:else}<Icon name={category === "tool" ? "wrench" : KIND_ICONS[category as ToolKind]} size={12} />{/if}
      {/each}
    </span>
    <span class="work-summary">{summary.text}</span>
    {#if summary.added || summary.removed}
      <span class="count-added">+{summary.added}</span>
      <span class="count-removed">-{summary.removed}</span>
    {/if}
    {#if summary.images}
      <span class="image-count" role="img" aria-label={t("agents.work.images", { count: summary.images })}>
        <Icon name="image" size={12} />{summary.images}
      </span>
    {/if}
    {#if failed}
      <span class="failed" role="img" aria-label={t("agents.tool.status.failed")}><Icon name="alert" size={12} /></span>
    {/if}
    {#if running && !open}
      <span class="spinner" aria-hidden="true"></span>
    {/if}
  </button>
  <div class="expand" class:open inert={!open}>
    <div class="expand-clip">
      {#if opened}
        <div class="calls">
          {#each views as view (view.call.toolCallId)}
            {@const call = view.call}
            {@const duration = call.startedAt !== null && call.endedAt !== null && call.endedAt - call.startedAt >= 1000
              ? formatDuration(call.endedAt - call.startedAt)
              : ""}
            <div class="call" in:restingFly={{ duration: enter, easing: cubicOut, x: 0, y: 4 }}>
              {#if call.diffs.length}
                {#each call.diffs as diff, index (index)}
                  <DiffCard {tabId} {diff} {cwd} checkpoint={Math.max(promptIndex, 0)} undone={undone.has(diff.path)} />
                {/each}
              {:else}
                {@const output = call.output.length > 0}
                {@const expandable = output || (!view.command && call.locations.length > 0)}
                <!-- A failed command opens on its output; a click flips whichever way it starts. -->
                {@const showOutput = expandable && toggled.has(call.toolCallId) !== (view.command && call.status === "failed")}
                <button
                  type="button"
                  class="call-row"
                  class:expandable
                  aria-expanded={expandable ? showOutput : undefined}
                  disabled={!expandable}
                  onclick={() => {
                    if (!toggled.delete(call.toolCallId)) toggled.add(call.toolCallId);
                  }}
                >
                  {@render icon(view)}
                  {#if view.command}
                    <span class="call-label mono"><span class="prompt" aria-hidden="true">$</span> {view.target}</span>
                  {:else if view.verb}
                    <span class="call-label">
                      <span class="verb">{t(view.verb)}</span>
                      {#if view.path}
                        {@const slash = view.target.lastIndexOf("/")}
                        <span class="target path"><span class="dir">{view.target.slice(0, slash + 1)}</span><span class="name">{view.target.slice(slash + 1)}</span></span>
                      {:else}
                        <span class="target">{view.target}</span>
                      {/if}
                    </span>
                  {:else}
                    <span class="call-label">{view.target || t("agents.tool.untitled")}</span>
                  {/if}
                  {#if view.command && call.exitCode !== null && call.exitCode !== 0}
                    <span class="exit">{t("agents.work.exit", { code: call.exitCode })}</span>
                  {/if}
                  {#if duration}<span class="duration">{duration}</span>{/if}
                  {@render status(call)}
                </button>
                {#if showOutput}
                  {@const lines = call.output.split("\n")}
                  {@const all = fullOutput.has(call.toolCallId)}
                  <div class="detail" in:restingFly={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs, easing: cubicOut, x: 0, y: -4 }}>
                    {#if !view.command}
                      {#each call.locations as location, index (index)}
                        <div class="location">{location.path}{location.line ? `:${location.line}` : ""}</div>
                      {/each}
                    {/if}
                    {#if output}
                      <pre class="output" class:failed={call.status === "failed"}>{all
                          ? call.output.slice(0, MAX_OUTPUT)
                          : lines.slice(-OUTPUT_TAIL).join("\n")}</pre>
                      {#if lines.length > OUTPUT_TAIL}
                        <button
                          type="button"
                          class="show-all"
                          onclick={() => {
                            if (!fullOutput.delete(call.toolCallId)) fullOutput.add(call.toolCallId);
                          }}
                        >{all ? t("agents.work.showLess") : t("agents.work.showAll", { count: lines.length })}</button>
                      {/if}
                    {/if}
                  </div>
                {/if}
              {/if}
              {#if call.images.length}
                <div class="call-images">
                  {#each call.images as image, index (index)}
                    <ThreadImage src={image.src} alt={image.alt} small />
                  {/each}
                </div>
              {/if}
            </div>
          {/each}
        </div>
      {/if}
    </div>
  </div>
</div>

<style>
  .work {
    display: flex;
    flex-direction: column;
  }

  .work-head,
  .call-row,
  .show-all {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    border: 0;
    background: none;
    font: inherit;
    text-align: left;
  }

  .work-head {
    align-self: flex-start;
    max-width: 100%;
    height: var(--control-height-sm);
    padding: 0 var(--space-8) 0 var(--space-6);
    margin-left: calc(-1 * var(--space-6));
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    cursor: pointer;
    gap: var(--space-6);
  }

  .work-head:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .kinds {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    color: var(--text-muted);
  }

  .kinds :global(.mascot-glyph) {
    width: 12px;
    height: 12px;
  }

  .work-summary {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .chevron {
    flex: none;
    display: inline-flex;
    color: var(--text-muted);
    transition: transform var(--motion-duration-normal) var(--motion-ease-spring);
  }

  .chevron.open {
    transform: rotate(90deg);
  }

  .count-added,
  .count-removed {
    flex: none;
    font-variant-numeric: tabular-nums;
  }

  .count-added {
    color: var(--success-text);
  }

  .image-count {
    flex: none;
    display: inline-flex;
    align-items: center;
    gap: var(--space-2);
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-variant-numeric: tabular-nums;
  }

  .call-images {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-6);
    padding: 0 0 var(--space-4) var(--space-20);
  }

  .count-removed {
    color: var(--danger-text);
  }

  .expand {
    display: grid;
    grid-template-rows: 0fr;
    opacity: 0;
    transition:
      grid-template-rows 150ms var(--motion-ease-spring),
      opacity var(--motion-duration-fast) ease;
  }

  .expand.open {
    grid-template-rows: 1fr;
    opacity: 1;
    transition-duration: var(--motion-duration-overlay), var(--motion-duration-normal);
  }

  .expand-clip {
    min-height: 0;
    overflow: hidden;
  }

  .calls {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    margin: var(--space-2) 0 0 var(--space-4);
    padding-left: var(--space-10);
    border-left: 1px solid var(--separator);
  }

  .call {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    min-width: 0;
  }

  .call-row {
    width: 100%;
    min-height: 26px;
    padding: 0 var(--space-6);
    margin-left: calc(-1 * var(--space-6));
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .call-row:disabled {
    cursor: default;
  }

  .call-row.expandable {
    cursor: pointer;
  }

  .call-row.expandable:hover {
    background: var(--bg-hover);
  }

  .call-icon {
    flex: none;
    display: inline-flex;
    color: var(--text-muted);
  }

  .call-icon :global(.mascot-glyph) {
    width: 14px;
    height: 14px;
  }

  .call-label {
    display: flex;
    gap: var(--space-4);
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .verb {
    flex: none;
  }

  .target {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    color: var(--text-primary);
  }

  .target.path {
    display: flex;
  }

  /* The folders give way first, so a long path keeps its filename. */
  .dir,
  .name {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .dir {
    color: var(--text-secondary);
  }

  .name {
    flex-shrink: 0.01;
    font-weight: var(--font-weight-medium);
  }

  .mono {
    display: block;
    color: var(--text-primary);
    font: var(--font-size-xs) ui-monospace, "SF Mono", Menlo, monospace;
  }

  .prompt {
    color: var(--text-muted);
  }

  .exit {
    flex: none;
    color: var(--danger-text);
    font-size: var(--font-size-xs);
  }

  .duration {
    flex: none;
    margin-left: auto;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-variant-numeric: tabular-nums;
  }

  .status {
    flex: none;
    display: grid;
    width: 14px;
    height: 14px;
    margin-left: auto;
  }

  .duration + .status {
    margin-left: 0;
  }

  .status > * {
    grid-area: 1 / 1;
    place-self: center;
  }

  .failed {
    display: inline-flex;
    color: var(--danger-text);
  }

  .done-check {
    display: inline-flex;
    color: var(--text-muted);
    opacity: 0.6;
  }

  /* A call finishing now flashes its check, then settles to the quiet one. */
  .done-check.fresh {
    color: var(--success-text);
    animation: check-settle 1.2s var(--motion-ease-standard) forwards;
  }

  @keyframes check-settle {
    0%,
    40% {
      opacity: 1;
    }

    100% {
      opacity: 0.45;
    }
  }

  .spinner {
    flex: none;
    width: 12px;
    height: 12px;
    box-sizing: border-box;
    border-radius: var(--radius-chip);
    border: 1.5px solid var(--text-primary-tint-12);
    border-top-color: var(--agents);
    border-right-color: var(--agents);
    animation: spin 0.9s linear infinite;
  }

  .spinner.pending {
    animation: none;
    border-color: var(--text-primary-tint-12);
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  .detail {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    padding: 0 0 var(--space-4) var(--space-20);
  }

  .location {
    color: var(--text-muted);
    font: var(--font-size-xs) ui-monospace, "SF Mono", Menlo, monospace;
  }

  .output {
    margin: 0;
    max-height: 320px;
    overflow: auto;
    padding: var(--space-8) var(--space-10);
    border-radius: var(--radius-md);
    border: 1px solid var(--separator);
    background: var(--bg-secondary);
    color: var(--text-secondary);
    font: var(--font-size-xs)/1.5 ui-monospace, "SF Mono", Menlo, monospace;
    white-space: pre;
    user-select: text;
  }

  .output.failed {
    border-color: color-mix(in srgb, var(--danger) 35%, transparent);
  }

  .show-all {
    align-self: flex-start;
    height: 20px;
    padding: 0 var(--space-6);
    margin-left: calc(-1 * var(--space-6));
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
    cursor: pointer;
  }

  .show-all:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }
</style>
