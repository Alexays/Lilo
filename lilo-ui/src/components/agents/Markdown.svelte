<script lang="ts">
  import { SvelteMap } from "svelte/reactivity";
  import { tabActions } from "../../lib/bridge/actions";
  import { copyText } from "../../lib/clipboard";
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import { conversationActions } from "./conversationActions";
  import Icon from "./Icon.svelte";
  import ThreadImage from "./ThreadImage.svelte";
  import { imageSource, parseMarkdown, type Block, type Inline } from "./threadView";

  interface Props {
    text: string;
    /** The conversation's tab: code blocks it can draw get a Preview. */
    tabId?: string;
    /** The project folder, which relative image paths resolve against. */
    cwd?: string;
  }

  let { text, tabId = "", cwd = "" }: Props = $props();

  const blocks = $derived(parseMarkdown(text));
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

{#snippet inline(parts: Inline[])}{#each parts as part, index (index)}{#if part.type === "code"}<code>{part.text}</code>{:else if part.type === "path"}<code class="path">{part.text}</code>{:else if part.type === "strong"}<strong>{part.text}</strong>{:else if part.type === "em"}<em>{part.text}</em>{:else if part.type === "link"}<a href={part.href} onclick={(event) => openLink(event, part.href)}>{part.text}</a>{:else if part.type === "image"}{@const source = imageSource(part.src, cwd)}{#if source?.type === "image"}<ThreadImage src={source.src} alt={part.alt} />{:else if source?.type === "remote"}<a class="image-link" href={source.href} title={part.alt || source.href} onclick={(event) => openLink(event, source.href)}><Icon name="image" size={12} />{source.host}</a>{:else}{part.alt}{/if}{:else}{part.text}{/if}{/each}{/snippet}

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

  .code-block {
    border-radius: var(--radius-md);
    background: var(--bg-secondary);
    border: 1px solid var(--separator);
    overflow: hidden;
  }

  .code-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    height: var(--control-height-sm);
    padding: 0 var(--space-4) 0 var(--space-12);
    border-bottom: 1px solid var(--separator);
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
