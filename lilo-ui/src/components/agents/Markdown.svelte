<script lang="ts">
  import { onDestroy, untrack } from "svelte";
  import { SvelteMap, SvelteSet } from "svelte/reactivity";
  import { tabActions } from "../../lib/bridge/actions";
  import { copyText } from "../../lib/clipboard";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { tooltip } from "../../lib/tooltip";
  import { conversationActions } from "./conversationActions";
  import Icon from "../ui/Icon.svelte";
  import ThreadImage from "./ThreadImage.svelte";
  import { codeTokens, HEX_COLOR, imageSource, parseMarkdown, type Block, type Inline, type ListBlock, type MarkdownParse } from "./threadView";

  interface Props {
    text: string;
    /** The conversation's tab: code blocks it can draw get a Preview. */
    tabId?: string;
    /** The project folder, which relative image paths resolve against. */
    cwd?: string;
    /** The thread's file a `code` name stands for, which a click opens. */
    knownFile?: (name: string) => string | null;
  }

  let { text, tabId = "", cwd = "", knownFile }: Props = $props();

  // A streaming message only grows: each frame parses its tail, and the blocks above it stay put.
  let parsed: MarkdownParse | undefined;
  const blocks = $derived.by(() => {
    parsed = parseMarkdown(text, parsed);
    return parsed.blocks;
  });

  // Streamed text shows as soon as it arrives and only fades in, letter by letter; letters are spans just
  // while they animate, so the DOM never grows with the message and nothing runs once the stream is quiet.
  const LETTER_STEP_MS = 6;
  const LETTER_STAGGER = 24;
  const LETTER_SETTLE_MS = 120 + LETTER_STEP_MS * LETTER_STAGGER + 40;

  // Where each inline part starts in the drawn text, which only grows while streaming.
  const layout = $derived.by(() => {
    // eslint-disable-next-line svelte/prefer-svelte-reactivity -- rebuilt whole per run, never mutated after
    const starts = new Map<Inline, number>();
    let total = 0;
    const add = (parts: Inline[]) => {
      for (const part of parts) {
        starts.set(part, total);
        if (part.type === "strong" || part.type === "em" || part.type === "del") add(part.inline);
        else if (part.type !== "image" && part.type !== "task") total += part.text.length;
      }
    };
    const addList = (list: ListBlock) => {
      for (const item of list.items) {
        add(item.inline);
        item.lists.forEach(addList);
      }
    };
    for (const block of blocks) {
      if (block.type === "code") total += block.text.length;
      else if (block.type === "table") {
        block.head.forEach(add);
        for (const row of block.rows) row.forEach(add);
      } else if (block.type === "list") addList(block);
      else if (block.type !== "rule") add(block.inline);
    }
    return { starts, total };
  });

  /** Drawn text before this offset is plain; Infinity once every letter has settled. */
  let settled = $state(Infinity);
  // Where each chunk still animating starts, and when it came, oldest first.
  let arrivals: { at: number; time: number }[] = [];
  let lastTotal = untrack(() => layout.total);
  let settleTimer: ReturnType<typeof setTimeout> | undefined;

  $effect(() => {
    const total = layout.total;
    untrack(() => {
      if (total < lastTotal) {
        arrivals = [];
        settled = Infinity;
      } else if (total > lastTotal && !prefersReducedMotion()) {
        if (settled === Infinity) settled = lastTotal;
        arrivals.push({ at: lastTotal, time: performance.now() });
        settleTimer ??= setTimeout(settle, LETTER_SETTLE_MS);
      }
      lastTotal = total;
    });
  });

  function settle(): void {
    settleTimer = undefined;
    arrivals.shift();
    settled = arrivals[0]?.at ?? Infinity;
    if (arrivals[0]) settleTimer = setTimeout(settle, Math.max(0, arrivals[0].time + LETTER_SETTLE_MS - performance.now()));
  }

  onDestroy(() => clearTimeout(settleTimer));

  /** The letters of `text` (drawn from `start`) still animating, each delayed by its place in its chunk. */
  function freshLetters(text: string, start: number): { at: number; ch: string; delay: number }[] {
    const letters = [];
    for (let i = Math.max(0, settled - start); i < text.length; i++) {
      const at = start + i;
      let chunk = settled;
      for (const arrival of arrivals) if (arrival.at <= at) chunk = arrival.at;
      letters.push({ at, ch: text[i], delay: Math.min(at - chunk, LETTER_STAGGER) * LETTER_STEP_MS });
    }
    return letters;
  }

  let copiedIndex = $state(-1);
  // SVG blocks show their picture unless switched to the code, by block index.
  const showCode = new SvelteMap<number, boolean>();
  // A long block shows its first lines: the reply around it stays in view. Block indexes opened in full.
  const CODE_FOLD_LINES = 16;
  const openedCode = new SvelteSet<number>();

  /** The block's first lines and how many more it has, or null when it is short enough to show whole. */
  function codeFold(code: string): { head: string; hidden: number } | null {
    let at = -1;
    for (let line = 0; line < CODE_FOLD_LINES; line++) {
      at = code.indexOf("\n", at + 1);
      if (at < 0) return null;
    }
    let hidden = 1;
    for (let next = code.indexOf("\n", at + 1); next >= 0; next = code.indexOf("\n", next + 1)) hidden++;
    // Folding away a few lines saves less than the button costs.
    return hidden > 8 ? { head: code.slice(0, at), hidden } : null;
  }

  function artifactKind(block: Block & { type: "code" }): "html" | "svg" | null {
    const lang = block.lang.toLowerCase();
    if (lang === "svg" || (lang === "xml" && block.text.trimStart().startsWith("<svg"))) return "svg";
    return lang === "html" ? "html" : null;
  }

  async function copyCode(index: number, code: string): Promise<void> {
    if (!(await copyText(code))) return;
    copiedIndex = index;
    setTimeout(() => {
      if (copiedIndex === index) copiedIndex = -1;
    }, 1500);
  }

  function openFile(event: MouseEvent, path: string): void {
    conversationActions.openFile(tabId, path, event.metaKey);
  }

  function openLink(event: MouseEvent, href: string): void {
    event.preventDefault();
    tabActions.create(href);
  }
</script>

{#snippet letters(text: string, start: number)}{#if start + text.length <= settled}{text}{:else}{text.slice(0, Math.max(0, settled - start))}{#each freshLetters(text, start) as letter (letter.at)}<span class="letter" style:animation-delay="{letter.delay}ms">{letter.ch}</span>{/each}{/if}{/snippet}

{#snippet list(block: ListBlock)}
  {#if block.ordered}
    <ol start={block.start}>{@render items(block)}</ol>
  {:else}
    <ul>{@render items(block)}</ul>
  {/if}
{/snippet}

{#snippet items(block: ListBlock)}
  {#each block.items as item, itemIndex (itemIndex)}
    <li class:task={item.inline[0]?.type === "task"}>{@render inline(item.inline)}{#each item.lists as sub, subIndex (subIndex)}{@render list(sub)}{/each}</li>
  {/each}
{/snippet}

{#snippet inline(parts: Inline[])}{#each parts as part, index (index)}{#if part.type === "code" || part.type === "path"}{@const file = !tabId ? null : part.type === "path" && part.text.includes("/") ? part.text : (knownFile?.(part.text) ?? null)}{#if file}<button type="button" class="file" use:tooltip={t("agents.markdown.openFile")} onclick={(event) => openFile(event, file)}><code class="path">{@render letters(part.text, layout.starts.get(part) ?? 0)}</code></button>{:else if part.type === "path" && !part.text.includes("/")}{@render letters(part.text, layout.starts.get(part) ?? 0)}{:else}<code class:path={part.type === "path"}>{#if HEX_COLOR.test(part.text)}<span class="swatch" style:background={part.text} aria-hidden="true"></span>{/if}{@render letters(part.text, layout.starts.get(part) ?? 0)}</code>{/if}{:else if part.type === "color"}<span class="swatch" style:background={part.text} aria-hidden="true"></span>{@render letters(part.text, layout.starts.get(part) ?? 0)}{:else if part.type === "strong"}<strong>{@render inline(part.inline)}</strong>{:else if part.type === "em"}<em>{@render inline(part.inline)}</em>{:else if part.type === "del"}<del>{@render inline(part.inline)}</del>{:else if part.type === "link"}<a href={part.href} onclick={(event) => openLink(event, part.href)}>{@render letters(part.text, layout.starts.get(part) ?? 0)}</a>{:else if part.type === "image"}{@const source = imageSource(part.src, cwd)}{#if source?.type === "image"}<ThreadImage src={source.src} alt={part.alt} />{:else if source?.type === "remote"}<a class="image-link" href={source.href} title={part.alt || source.href} onclick={(event) => openLink(event, source.href)}><Icon name="image" size={12} />{source.host}</a>{:else}{part.alt}{/if}{:else if part.type === "ref"}<sup class="ref">{@render letters(part.text, layout.starts.get(part) ?? 0)}</sup>{:else if part.type === "kbd"}<kbd>{@render letters(part.text, layout.starts.get(part) ?? 0)}</kbd>{:else if part.type === "task"}<input type="checkbox" class="task-box" checked={part.checked} disabled />{:else}{@render letters(part.text, layout.starts.get(part) ?? 0)}{/if}{/each}{/snippet}

<div class="markdown">
  {#each blocks as block, index (index)}
    {#if block.type === "p"}
      <p>{@render inline(block.inline)}</p>
    {:else if block.type === "quote"}
      <blockquote>{@render inline(block.inline)}</blockquote>
    {:else if block.type === "heading"}
      <p class="heading level-{Math.min(block.level, 3)}" role="heading" aria-level={block.level + 2}>{@render inline(block.inline)}</p>
    {:else if block.type === "code"}
      {@const artifact = artifactKind(block)}
      <!-- A streaming SVG shows as code until its closing tag arrives. -->
      {@const drawable = artifact === "svg" && /<\/svg>\s*$/.test(block.text)}
      {@const picture = drawable && !showCode.get(index)}
      <div class="code-block" class:bare={!block.lang && !artifact} class:nested={block.nested}>
        <div class="code-head">
          {#if artifact === "svg"}
            <span class="code-tabs" role="group" aria-label={t("agents.markdown.view")}>
              <button type="button" class="code-tab" aria-pressed={!picture} onclick={() => showCode.set(index, true)}>{t("agents.markdown.code")}</button>
              <button type="button" class="code-tab" aria-pressed={picture} disabled={!drawable} onclick={() => showCode.set(index, false)}>{t("agents.markdown.preview")}</button>
            </span>
          {:else if block.lang}
            <span class="code-lang">{block.lang}</span>
          {/if}
          <span class="code-actions">
            {#if artifact && tabId}
              <button
                type="button"
                class="code-open"
                class:labeled={artifact === "html"}
                aria-label={t("agents.markdown.openPreview")}
                use:tooltip={t("agents.markdown.openPreview")}
                onclick={() => conversationActions.previewArtifact(tabId, block.text, artifact)}
              >
                <Icon name="external" size={12} />
                {#if artifact === "html"}{t("agents.markdown.preview")}{/if}
              </button>
            {/if}
            <button
              type="button"
              class="code-copy"
              class:copied={copiedIndex === index}
              aria-label={copiedIndex === index ? t("agents.markdown.copied") : t("agents.markdown.copy")}
              use:tooltip={copiedIndex === index ? t("agents.markdown.copied") : t("agents.markdown.copy")}
              onclick={() => copyCode(index, block.text)}
            ><Icon name={copiedIndex === index ? "check" : "copy"} size={12} /></button>
          </span>
        </div>
        {#if picture}
          <!-- An <img> never runs the SVG's scripts or loads what it links to. -->
          <div class="svg-preview"><img src="data:image/svg+xml;charset=utf-8,{encodeURIComponent(block.text)}" alt="" decoding="async" /></div>
        {:else}
          {@const fold = openedCode.has(index) ? null : codeFold(block.text)}
          {@const shown = fold ? fold.head : block.text}
          {@const tokens = codeTokens(shown, block.lang)}
          <pre class:folded={fold}><code>{#if tokens}{#each tokens as token, at (at)}{#if token.kind}<span class="token-{token.kind}">{token.text}</span>{:else}{token.text}{/if}{/each}{:else}{shown}{/if}</code></pre>
          {#if fold}
            <button type="button" class="code-more" onclick={() => openedCode.add(index)}>
              <Icon name="chevronDown" size={12} />{t("agents.conversation.moreLines", { count: fold.hidden })}
            </button>
          {/if}
        {/if}
      </div>
    {:else if block.type === "table"}
      <div class="table-scroll">
        <table>
          <thead>
            <tr>{#each block.head as cell, column (column)}<th style:text-align={block.align[column] ?? undefined}>{@render inline(cell)}</th>{/each}</tr>
          </thead>
          <tbody>
            {#each block.rows as row, rowIndex (rowIndex)}
              <tr>{#each block.head as _, column (column)}<td style:text-align={block.align[column] ?? undefined}>{@render inline(row[column] ?? [])}</td>{/each}</tr>
            {/each}
          </tbody>
        </table>
      </div>
    {:else if block.type === "list"}
      {@render list(block)}
    {:else if block.type === "rule"}
      <hr />
    {:else if block.type === "note"}
      <p class="note"><sup class="ref">{block.id}</sup>{@render inline(block.inline)}</p>
    {/if}
  {/each}
</div>

<style>
  /* Opacity only: no layout, and the spans fold back into text once it ends. */
  .letter {
    animation: letter-in var(--motion-duration-fast) ease-out both;
  }

  @keyframes letter-in {
    from {
      opacity: 0;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .letter {
      animation: none;
    }
  }

  .table-scroll {
    overflow-x: auto;
  }

  table {
    border-collapse: collapse;
    font-size: var(--font-size-sm);
    overflow-wrap: normal;
  }

  /* A floor per column, so a squeezed table scrolls sideways instead of breaking words over lines. */
  th,
  td {
    min-width: 8em;
    padding: var(--space-4) var(--space-12) var(--space-4) 0;
    border-bottom: 1px solid var(--separator);
    text-align: left;
    vertical-align: top;
  }

  th {
    font-weight: var(--font-weight-semibold);
  }

  td code {
    white-space: nowrap;
  }

  tbody tr:last-child td {
    border-bottom: 0;
  }

  .markdown {
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
    font-size: var(--font-size-md);
    line-height: 1.55;
    color: var(--text-primary);
    overflow-wrap: anywhere;
    user-select: text;
  }

  p,
  blockquote,
  ul,
  ol,
  pre {
    margin: 0;
  }

  p,
  blockquote {
    white-space: pre-wrap;
  }

  hr {
    margin: var(--space-4) 0;
    border: none;
    border-top: 1px solid var(--separator);
  }

  del {
    color: var(--text-secondary);
  }

  .ref {
    margin-left: 1px;
    color: var(--accent-ink, var(--accent));
    font-size: var(--font-size-2xs);
    line-height: 0;
  }

  .note {
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .note > .ref {
    margin: 0 var(--space-4) 0 0;
  }

  kbd {
    padding: 0 var(--space-4);
    border-radius: var(--radius-xs);
    box-shadow: inset 0 0 0 1px var(--border), inset 0 -1px 0 var(--border);
    font: inherit;
    font-size: var(--font-size-sm);
  }

  .heading {
    font-weight: var(--font-weight-semibold);
    line-height: 1.35;
  }

  /* A section opens with air above it, so a long answer reads as parts. */
  .heading:not(:first-child) {
    margin-top: var(--space-8);
  }

  .level-1 {
    font-size: var(--font-size-xl);
  }

  .level-2 {
    font-size: var(--font-size-lg);
  }

  blockquote {
    padding-left: var(--space-10);
    border-left: 2px solid var(--separator);
    color: var(--text-secondary);
  }

  ul,
  ol {
    padding-left: var(--space-20);
  }

  li + li,
  li > :is(ul, ol) {
    margin-top: var(--space-2);
  }

  li.task {
    list-style: none;
  }

  /* A task's box hangs in the marker's place, so its text lines up with the other items'. */
  .task-box {
    appearance: none;
    width: 13px;
    height: 13px;
    margin: 0 var(--space-6) 0 calc(-13px - var(--space-6));
    vertical-align: -2px;
    border: 1px solid var(--text-muted);
    border-radius: var(--radius-xs);
  }

  .task-box:checked {
    border-color: var(--accent);
    background: var(--accent) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12'%3E%3Cpath d='M3 6.2l2 2 4-4.4' fill='none' stroke='white' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") center / 11px no-repeat;
  }

  code {
    font: var(--font-size-sm) ui-monospace, "SF Mono", Menlo, monospace;
    padding: 1px var(--space-4);
    border-radius: var(--radius-xs);
    background: var(--text-primary-tint-10);
  }

  /* The colour a hex code names, outlined so white and black still show on any background. */
  .swatch {
    display: inline-block;
    width: 0.75em;
    height: 0.75em;
    margin-right: 0.3em;
    border-radius: var(--radius-xs);
    vertical-align: -0.05em;
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--text-primary) 25%, transparent);
  }

  code.path {
    color: var(--text-primary);
    background: var(--accent-tint-10);
  }

  .file {
    display: inline;
    padding: 0;
    border: 0;
    background: none;
    color: inherit;
    font: inherit;
    cursor: pointer;
  }

  .file:hover code {
    text-decoration: underline;
    text-underline-offset: 2px;
  }

  .file:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
    border-radius: var(--radius-xs);
  }

  /* Neutral, never the Space's tint: code reads the same in every Space. */
  .code-block {
    position: relative;
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--text-primary) 4%, var(--bg-primary));
    border: 1px solid var(--separator);
    overflow: hidden;
  }

  /* Lines up with the text of the list item it belongs to. */
  .code-block.nested {
    margin-left: var(--space-20);
  }

  .code-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    height: var(--control-height-sm);
    padding: 0 var(--space-4) 0 var(--space-12);
    color: var(--text-muted);
    font-size: var(--font-size-xs);
  }

  /* With no language to name, the block is only its code: Copy floats over its corner. */
  .code-block.bare .code-head {
    position: absolute;
    top: var(--space-6);
    right: 0;
    height: auto;
    background: inherit;
  }

  .code-actions {
    display: flex;
    align-items: center;
    gap: var(--space-2);
  }

  .code-tabs {
    display: inline-flex;
    gap: var(--space-2);
    margin-left: calc(-1 * var(--space-8));
  }

  .code-tab,
  .code-open {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    height: 20px;
    padding: 0 var(--space-6);
    border: 0;
    border-radius: var(--radius-xs);
    background: none;
    color: var(--text-muted);
    font: inherit;
    cursor: pointer;
  }

  .code-open:not(.labeled) {
    width: 20px;
    justify-content: center;
    padding: 0;
  }

  .code-tab:hover:not(:disabled),
  .code-open:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .code-tab[aria-pressed="true"] {
    background: var(--text-primary-tint-10);
    color: var(--text-primary);
  }

  .code-tab:disabled {
    opacity: var(--disabled-opacity);
    cursor: default;
  }

  .code-tab:focus-visible,
  .code-open:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  /* Xcode's palette, which every theme reads the same way. */
  .token-keyword {
    color: var(--code-keyword);
  }

  .token-string {
    color: var(--code-string);
  }

  .token-number {
    color: var(--code-number);
  }

  .token-type {
    color: var(--code-type);
  }

  .token-comment {
    color: var(--code-comment);
  }

  .svg-preview {
    display: grid;
    place-items: center;
    padding: var(--space-12);
  }

  .svg-preview img {
    display: block;
    max-width: 100%;
    max-height: 320px;
  }

  .code-copy {
    display: grid;
    place-items: center;
    width: 20px;
    height: 20px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-xs);
    background: none;
    color: var(--text-secondary);
    cursor: pointer;
    opacity: 0;
    transition: opacity var(--motion-duration-fast) ease;
  }

  .code-block:hover .code-copy,
  .code-copy:focus-visible,
  .code-copy.copied {
    opacity: 1;
  }

  .code-copy:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .code-copy:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  /* A long line fades out at the right edge while more of it is to the right, since macOS hides the
     scrollbar; the scroll timeline is inactive when nothing overflows, which leaves no fade. */
  @property --code-fade {
    syntax: "<length>";
    inherits: false;
    initial-value: 0px;
  }

  @keyframes code-fade {
    from,
    95% {
      --code-fade: 32px;
    }
    to {
      --code-fade: 0px;
    }
  }

  pre {
    padding: var(--space-8) var(--space-12);
    overflow-x: auto;
    mask-image: linear-gradient(to left, transparent, #000 var(--code-fade));
    animation: code-fade linear both;
    animation-timeline: scroll(self inline);
  }

  /* The header row already spaces the language label from the code. */
  .code-block:not(.bare) .code-head + pre {
    padding-top: var(--space-2);
  }

  pre.folded {
    mask-image:
      linear-gradient(to left, transparent, #000 var(--code-fade)),
      linear-gradient(to bottom, #000 60%, transparent);
    mask-composite: intersect;
  }

  .code-more {
    display: flex;
    align-items: center;
    gap: var(--space-4);
    width: 100%;
    height: var(--control-height-sm);
    margin-top: calc(-1 * var(--space-8));
    padding: 0 var(--space-12);
    border: 0;
    background: none;
    color: var(--text-secondary);
    font: inherit;
    font-size: var(--font-size-xs);
    cursor: pointer;
  }

  .code-more:hover {
    color: var(--text-primary);
  }

  .code-more:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -2px;
  }

  pre code {
    padding: 0;
    background: none;
    line-height: 1.5;
    white-space: pre;
    overflow-wrap: normal;
  }

  a {
    color: var(--accent-ink, var(--accent));
    text-decoration: underline;
    text-underline-offset: 2px;
  }

  .image-link {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    height: 22px;
    padding: 0 var(--space-8);
    vertical-align: middle;
    border: 1px solid var(--separator);
    border-radius: var(--radius-chip);
    color: var(--text-secondary);
    font-size: var(--font-size-xs);
    text-decoration: none;
  }

  .image-link:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  a:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
    border-radius: var(--radius-xs);
  }
</style>
