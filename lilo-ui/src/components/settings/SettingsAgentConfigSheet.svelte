<!-- What Connect, Repair or Remove writes to an agent app's configuration, shown before anything is written:
     the file, then the lines that change (or the command Lilo runs). -->
<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { copyText } from "../../lib/clipboard";
  import { connectAgentClient, closeAgentPreview, isConnectingAgentClient, removeAgentClient } from "../../stores/settings.svelte";
  import type { BridgeAgentClientPreview } from "../../lib/bridge/protocol";
  import UiButton from "../ui/UiButton.svelte";
  import UiModal from "../ui/UiModal.svelte";

  let { preview, repair }: { preview: BridgeAgentClientPreview; repair: boolean } = $props();

  const client = $derived(t(`settings.agents.names.${preview.client}`));
  const kind = $derived(preview.remove ? "remove" : repair ? "repair" : "add");
  const busy = $derived(isConnectingAgentClient(preview.client));
  const canWrite = $derived(!preview.blocked && (preview.command !== null || preview.lines.length > 0));
  const numberWidth = $derived(`${Math.max(2, ...preview.lines.map((line) => String(line.number).length))}ch`);

  function confirm(): void {
    if (!canWrite || busy) return;
    if (preview.remove) removeAgentClient(preview.client);
    else connectAgentClient(preview.client);
  }

  let copied = $state(false);
  async function copy(): Promise<void> {
    copied = await copyText(preview.command ?? preview.snippet);
  }
</script>

<UiModal zone="agent-config" width={560} scrolls oncancel={closeAgentPreview} ondefault={canWrite ? confirm : undefined}>
  {#snippet header(titleId)}
    <div class="sheet-head">
      <h2 id={titleId}>{t(`settings.agents.sheet.${kind}Title`, { client })}</h2>
      <p class="sheet-path">{preview.path}</p>
    </div>
  {/snippet}

  {#if preview.blocked}
    <p class="sheet-note" role="alert">{preview.blocked}</p>
  {:else if preview.command !== null}
    <p class="sheet-note">{t("settings.agents.sheet.runs")}</p>
    <pre class="sheet-code"><code>{preview.command}</code></pre>
  {:else if preview.lines.length}
    <p class="sheet-note">{t("settings.agents.sheet.diff")}</p>
    <div class="diff" role="table" aria-label={preview.path} style:--number-width={numberWidth}>
      {#each preview.lines as line (`${line.removed ? "-" : "+"}${line.number}`)}
        <div class="diff-line" class:removed={line.removed} role="row">
          <span class="diff-number" role="cell" aria-hidden="true">{line.number}</span>
          <span class="diff-sign" role="cell">
            <span aria-hidden="true">{line.removed ? "−" : "+"}</span>
            <span class="sr-only">{t(line.removed ? "settings.agents.sheet.removedLine" : "settings.agents.sheet.addedLine")}</span>
          </span>
          <span class="diff-text" role="cell">{line.text}</span>
        </div>
      {/each}
    </div>
  {:else}
    <p class="sheet-note">{t("settings.agents.sheet.unchanged")}</p>
  {/if}

  {#snippet leading()}
    {#if preview.snippet && !preview.remove}
      <UiButton variant="ghost" onclick={copy}>{copied ? t("settings.agents.sheet.copied") : t("settings.agents.sheet.copy")}</UiButton>
    {/if}
  {/snippet}

  {#snippet actions()}
    <UiButton onclick={closeAgentPreview}>{t("common.cancel")}</UiButton>
    <UiButton variant={preview.remove ? "destructive" : "primary"} {busy} disabled={!canWrite} onclick={confirm}>
      {t(`settings.agents.sheet.${kind}`)} <kbd>⌘↩</kbd>
    </UiButton>
  {/snippet}
</UiModal>

<style>
  .sheet-head {
    min-width: 0;
  }

  h2 {
    margin: 0;
    font-size: var(--font-size-modal);
    font-weight: var(--font-weight-semibold);
    line-height: 1.3;
  }

  .sheet-path {
    margin: 2px 0 0;
    overflow: hidden;
    color: var(--text-secondary);
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: var(--font-size-sm);
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .sheet-note {
    margin: 0 0 var(--space-12);
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .sheet-code,
  .diff {
    margin: 0;
    border-radius: var(--radius-md);
    background: var(--bg-hover);
    box-shadow: inset 0 0 0 1px var(--separator);
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: var(--font-size-sm);
    line-height: 1.5;
  }

  .sheet-code {
    padding: var(--space-12) var(--space-16);
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }

  .diff {
    padding: var(--space-4) 0;
    user-select: text;
  }

  .diff-line {
    display: grid;
    grid-template-columns: var(--number-width) 1.5ch 1fr;
    gap: var(--space-8);
    padding: 0 var(--space-12);
    background: color-mix(in srgb, var(--success) 14%, transparent);
  }

  .diff-line.removed {
    background: color-mix(in srgb, var(--danger) 14%, transparent);
  }

  .diff-number {
    color: var(--text-muted);
    text-align: right;
  }

  .diff-sign {
    color: var(--success-text);
  }

  .removed .diff-sign {
    color: var(--danger-text);
  }

  .diff-text {
    font: inherit;
    overflow-wrap: anywhere;
    white-space: pre-wrap;
  }

  .sr-only {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
  }

  kbd {
    margin-left: var(--space-4);
    font-family: inherit;
    font-size: var(--font-size-xs);
    opacity: 0.7;
  }
</style>
