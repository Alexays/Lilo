<script lang="ts">
  import { tabActions } from "../../lib/bridge/actions";
  import { copyText } from "../../lib/clipboard";
  import { t } from "../../lib/i18n/state.svelte";
  import { tooltip } from "../../lib/tooltip";
  import Icon from "./Icon.svelte";
  import { parseMarkdown, type Inline } from "./threadView";

  interface Props {
    text: string;
  }

  let { text }: Props = $props();

  const blocks = $derived(parseMarkdown(text));
  let copiedIndex = $state(-1);

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

{#snippet inline(parts: Inline[])}{#each parts as part, index (index)}{#if part.type === "code"}<code>{part.text}</code>{:else if part.type === "path"}<code class="path">{part.text}</code>{:else if part.type === "strong"}<strong>{part.text}</strong>{:else if part.type === "em"}<em>{part.text}</em>{:else if part.type === "link"}<a href={part.href} onclick={(event) => openLink(event, part.href)}>{part.text}</a>{:else}{part.text}{/if}{/each}{/snippet}

<div class="markdown">
  {#each blocks as block, index (index)}
    {#if block.type === "p"}
      <p>{@render inline(block.inline)}</p>
    {:else if block.type === "quote"}
      <blockquote>{@render inline(block.inline)}</blockquote>
    {:else if block.type === "heading"}
      <p class="heading" role="heading" aria-level={block.level + 2}>{@render inline(block.inline)}</p>
    {:else if block.type === "code"}
      <div class="code-block">
        <div class="code-head">
          <span class="code-lang">{block.lang || t("agents.markdown.code")}</span>
          <button
            type="button"
            class="code-copy"
            class:copied={copiedIndex === index}
            aria-label={copiedIndex === index ? t("agents.markdown.copied") : t("agents.markdown.copy")}
            use:tooltip={copiedIndex === index ? t("agents.markdown.copied") : t("agents.markdown.copy")}
            onclick={() => copyCode(index, block.text)}
          ><Icon name={copiedIndex === index ? "check" : "copy"} size={12} /></button>
        </div>
        <pre><code>{block.text}</code></pre>
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

  a:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
    border-radius: var(--radius-xs);
  }
</style>
