<script lang="ts">
  import { onDestroy, untrack } from "svelte";
  import { SvelteMap } from "svelte/reactivity";
  import { tabActions } from "../../lib/bridge/actions";
  import { copyText } from "../../lib/clipboard";
  import { t } from "../../lib/i18n/state.svelte";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { tooltip } from "../../lib/tooltip";
  import { conversationActions } from "./conversationActions";
  import Icon from "../ui/Icon.svelte";
  import ThreadImage from "./ThreadImage.svelte";
  import { imageSource, parseMarkdown, type Block, type Inline, type MarkdownParse } from "./threadView";

  interface Props {
    text: string;
    /** The conversation's tab: code blocks it can draw get a Preview. */
    tabId?: string;
    /** The project folder, which relative image paths resolve against. */
    cwd?: string;
  }

  let { text, tabId = "", cwd = "" }: Props = $props();

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
        if (part.type !== "image") total += part.text.length;
      }
    };
    for (const block of blocks) {
      if (block.type === "code") total += block.text.length;
      else if (block.type === "table") {
        block.head.forEach(add);
        for (const row of block.rows) row.forEach(add);
      } else if (block.type === "list") block.items.forEach(add);
      else add(block.inline);
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

  function openLink(event: MouseEvent, href: string): void {
    event.preventDefault();
    tabActions.create(href);
  }
</script>

{#snippet letters(text: string, start: number)}{#if start + text.length <= settled}{text}{:else}{text.slice(0, Math.max(0, settled - start))}{#each freshLetters(text, start) as letter (letter.at)}<span class="letter" style:animation-delay="{letter.delay}ms">{letter.ch}</span>{/each}{/if}{/snippet}

{#snippet inline(parts: Inline[])}{#each parts as part, index (index)}{#if part.type === "code"}<code>{@render letters(part.text, layout.starts.get(part) ?? 0)}</code>{:else if part.type === "path"}<code class="path">{@render letters(part.text, layout.starts.get(part) ?? 0)}</code>{:else if part.type === "strong"}<strong>{@render letters(part.text, layout.starts.get(part) ?? 0)}</strong>{:else if part.type === "em"}<em>{@render letters(part.text, layout.starts.get(part) ?? 0)}</em>{:else if part.type === "link"}<a href={part.href} onclick={(event) => openLink(event, part.href)}>{@render letters(part.text, layout.starts.get(part) ?? 0)}</a>{:else if part.type === "image"}{@const source = imageSource(part.src, cwd)}{#if source?.type === "image"}<ThreadImage src={source.src} alt={part.alt} />{:else if source?.type === "remote"}<a class="image-link" href={source.href} title={part.alt || source.href} onclick={(event) => openLink(event, source.href)}><Icon name="image" size={12} />{source.host}</a>{:else}{part.alt}{/if}{:else}{@render letters(part.text, layout.starts.get(part) ?? 0)}{/if}{/each}{/snippet}

<div class="markdown">
  {#each blocks as block, index (index)}
    {#if block.type === "p"}
      <p>{@render inline(block.inline)}</p>
    {:else if block.type === "quote"}
      <blockquote>{@render inline(block.inline)}</blockquote>
    {:else if block.type === "heading"}
      <p class="heading" role="heading" aria-level={block.level + 2}>{@render inline(block.inline)}</p>
    {:else if block.type === "code"}
      {@const artifact = artifactKind(block)}
      <!-- A streaming SVG shows as code until its closing tag arrives. -->
      {@const drawable = artifact === "svg" && /<\/svg>\s*$/.test(block.text)}
      {@const picture = drawable && !showCode.get(index)}
      <div class="code-block">
        <div class="code-head">
          {#if artifact === "svg"}
            <span class="code-tabs" role="group" aria-label={t("agents.markdown.view")}>
              <button type="button" class="code-tab" aria-pressed={!picture} onclick={() => showCode.set(index, true)}>{t("agents.markdown.code")}</button>
              <button type="button" class="code-tab" aria-pressed={picture} disabled={!drawable} onclick={() => showCode.set(index, false)}>{t("agents.markdown.preview")}</button>
            </span>
          {:else}
            <span class="code-lang">{block.lang || t("agents.markdown.code")}</span>
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
          <pre><code>{block.text}</code></pre>
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
    {:else if block.type === "list" && block.ordered}
      <ol>
        {#each block.items as item, itemIndex (itemIndex)}<li>{@render inline(item)}</li>{/each}
      </ol>
    {:else if block.type === "list"}
      <ul>
        {#each block.items as item, itemIndex (itemIndex)}<li>{@render inline(item)}</li>{/each}
      </ul>
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

  th,
  td {
    padding: var(--space-4) var(--space-12) var(--space-4) 0;
    border-bottom: 1px solid var(--separator);
    text-align: left;
    vertical-align: top;
  }

  th {
    font-weight: var(--font-weight-semibold);
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

  .heading {
    font-weight: var(--font-weight-semibold);
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

  li + li {
    margin-top: var(--space-2);
  }

  code {
    font: var(--font-size-sm) ui-monospace, "SF Mono", Menlo, monospace;
    padding: 1px var(--space-4);
    border-radius: var(--radius-xs);
    background: var(--text-primary-tint-10);
  }

  code.path {
    color: var(--text-primary);
    background: var(--accent-tint-10);
  }

  /* Neutral, never the Space's tint: code reads the same in every Space. */
  .code-block {
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--text-primary) 4%, var(--bg-primary));
    border: 1px solid var(--separator);
    overflow: hidden;
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

  pre {
    padding: var(--space-8) var(--space-12);
    overflow-x: auto;
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
