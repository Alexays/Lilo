<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { formatShortcut } from "../../lib/inputParser";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { restingFly } from "../../lib/motion/restingTransitions";
  import { springEase } from "../../lib/motion/spring";
  import { MOTION } from "../../lib/motion/timings";
  import AgentTile from "./AgentTile.svelte";
  import { conversationActions } from "./conversationActions";
  import type { QuestionItem } from "./conversationModel";

  let { tabId, item, agentId }: { tabId: string; item: QuestionItem; agentId: string } = $props();

  let values = $state<Record<string, string | string[] | boolean>>({});
  // Digits pick from the first list, as the agent numbers its options; a text box keeps them.
  const keyed = $derived(item.fields.find((field) => field.kind === "single" || field.kind === "multi"));

  // What the agent gets back: only the fields given, each in its schema's type.
  const content = $derived.by(() => {
    const out: Record<string, string | number | boolean | string[]> = {};
    for (const field of item.fields) {
      const value = values[field.key];
      if (field.kind === "boolean") out[field.key] = value === true;
      // A plain copy: the state proxy would not survive the bridge's structured clone.
      else if (Array.isArray(value)) { if (value.length) out[field.key] = [...value]; }
      else if (typeof value === "string" && value.trim()) out[field.key] = field.kind === "number" ? Number(value) : value.trim();
    }
    return out;
  });
  const canAnswer = $derived(
    item.fields.every((field) => !field.required || field.key in content) &&
      item.fields.some((field) => field.kind !== "boolean" && field.key in content),
  );

  /** Also called from the empty composer, which keeps the focus as it does for a permission. */
  export function answer(action: "accept" | "decline"): boolean {
    if (action === "accept" && !canAnswer) return false;
    conversationActions.answerQuestion(action === "accept" ? { tabId, requestId: String(item.requestId), action, content } : { tabId, requestId: String(item.requestId), action });
    return true;
  }

  /** A digit picks from the first list; return true when it did. */
  export function pick(key: string): boolean {
    const list = keyed;
    const index = Number(key) - 1;
    if (!list || !Number.isInteger(index) || index < 0 || index >= Math.min(9, list.options.length)) return false;
    if (list.kind === "single") values[list.key] = list.options[index].value;
    else toggle(list.key, list.options[index].value);
    return true;
  }

  function toggle(key: string, value: string): void {
    const picked = Array.isArray(values[key]) ? (values[key] as string[]) : [];
    values[key] = picked.includes(value) ? picked.filter((pick) => pick !== value) : [...picked, value];
  }

  function onkeydown(event: KeyboardEvent): void {
    if (event.key === "Escape" || (event.key === "Enter" && !event.shiftKey && !event.isComposing)) {
      // Return answers from anywhere in the form, a choice as well as a text box.
      if (event.target instanceof HTMLButtonElement && event.key === "Enter") return;
      event.preventDefault();
      answer(event.key === "Escape" ? "decline" : "accept");
      return;
    }
    const typing = event.target instanceof HTMLInputElement && event.target.type === "text";
    if (!typing && !event.metaKey && !event.ctrlKey && pick(event.key)) event.preventDefault();
  }
</script>

<!-- The keys answer from whichever control has focus: the form listens for its controls. -->
<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<form
  class="question-form float-surface"
  aria-label={item.message}
  in:restingFly={{ duration: prefersReducedMotion() ? 0 : MOTION.itemEnterMs + 120, easing: springEase, x: 0, y: 10 }}
  {onkeydown}
  onsubmit={(event) => {
    event.preventDefault();
    answer("accept");
  }}
>
  <div class="head">
    <span class="icon">
      <AgentTile {agentId} />
      <span class="dot" aria-hidden="true"></span>
    </span>
    <span class="message">{item.message}</span>
    <span class="state">{t("agents.status.waiting")}</span>
  </div>
  {#each item.fields as field (field.key)}
    {#if field.kind === "single" || field.kind === "multi"}
      <fieldset class="field">
        {#if field.title || field.description}
          <legend>{#if field.title}<span class="field-title">{field.title}</span>{/if}{#if field.description}<span class="field-text">{field.description}</span>{/if}</legend>
        {/if}
        {#each field.options as option, index (option.value)}
          {@const checked = field.kind === "single" ? values[field.key] === option.value : (values[field.key] as string[] | undefined)?.includes(option.value) === true}
          <label class="option" class:checked>
            {#if field.kind === "single"}
              <input type="radio" name={field.key} value={option.value} {checked} onchange={() => (values[field.key] = option.value)} />
            {:else}
              <input type="checkbox" value={option.value} {checked} onchange={() => toggle(field.key, option.value)} />
            {/if}
            <span class="option-text">
              <span class="option-title">{option.title}</span>
              {#if option.description}<span class="option-description">{option.description}</span>{/if}
            </span>
            {#if field === keyed && index < 9}<kbd aria-hidden="true">{index + 1}</kbd>{/if}
          </label>
        {/each}
      </fieldset>
    {:else if field.kind === "boolean"}
      <label class="option" class:checked={values[field.key] === true}>
        <input type="checkbox" checked={values[field.key] === true} onchange={(event) => (values[field.key] = event.currentTarget.checked)} />
        <span class="option-text"><span class="option-title">{field.title || field.key}</span>{#if field.description}<span class="option-description">{field.description}</span>{/if}</span>
      </label>
    {:else}
      <input
        class="answer-text"
        type="text"
        inputmode={field.kind === "number" ? "decimal" : undefined}
        placeholder={field.title || field.description}
        aria-label={field.description || field.title}
        value={typeof values[field.key] === "string" ? values[field.key] : ""}
        oninput={(event) => (values[field.key] = event.currentTarget.value)}
      />
    {/if}
  {/each}
  <div class="foot">
    <button type="button" class="skip" onclick={() => answer("decline")}>{t("agents.question.skip")}<kbd aria-hidden="true">Esc</kbd></button>
    <button type="submit" class="submit" disabled={!canAnswer}>{t("agents.question.submit")}<kbd aria-hidden="true">{formatShortcut("Enter")}</kbd></button>
  </div>
</form>

<style>
  .question-form {
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
    width: 100%;
    max-height: min(60vh, 520px);
    overflow-y: auto;
    box-sizing: border-box;
    margin-bottom: var(--space-8);
    padding: var(--space-12) var(--space-12) var(--space-12) var(--space-16);
    border-radius: var(--radius-lg);
  }

  .head {
    display: flex;
    align-items: flex-start;
    gap: var(--space-8);
    min-width: 0;
  }

  .icon {
    position: relative;
    flex: none;
    display: grid;
    margin-top: 2px;
  }

  .dot {
    position: absolute;
    right: -3px;
    bottom: -3px;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--attention);
    box-shadow: 0 0 0 2px var(--float-surface);
  }

  .message {
    flex: 1;
    min-width: 0;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
    line-height: 1.4;
    user-select: text;
  }

  .state {
    flex: none;
    color: var(--text-muted);
    font-size: var(--font-size-sm);
    line-height: 1.6;
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    min-width: 0;
    margin: 0;
    padding: 0;
    border: 0;
  }

  legend {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    margin-bottom: var(--space-4);
    padding: 0;
  }

  .field-title {
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    font-weight: var(--font-weight-medium);
  }

  .field-text {
    color: var(--text-primary);
    font-size: var(--font-size-sm);
  }

  .option {
    display: flex;
    align-items: flex-start;
    gap: var(--space-10);
    padding: var(--space-6) var(--space-8);
    margin-inline: calc(-1 * var(--space-8));
    border-radius: var(--radius-md);
    cursor: pointer;
    transition: background var(--transition-fast);
  }

  .option:hover {
    background: var(--bg-hover);
  }

  .option.checked {
    background: color-mix(in srgb, var(--accent) 12%, transparent);
  }

  .option input {
    flex: none;
    margin: 2px 0 0;
    accent-color: var(--accent);
  }

  .option input:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 2px;
  }

  .option-text {
    display: flex;
    flex: 1;
    flex-direction: column;
    gap: var(--space-2);
    min-width: 0;
  }

  .option-title {
    color: var(--text-primary);
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-medium);
  }

  .option-description {
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    line-height: 1.4;
  }

  .option kbd {
    flex: none;
    margin-top: 1px;
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    line-height: 1.6;
    font-variant-numeric: tabular-nums;
  }

  .answer-text {
    min-height: 30px;
    padding: var(--space-6) var(--space-10);
    border: 0;
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--text-primary) 5%, transparent);
    color: var(--text-primary);
    font: inherit;
    font-size: var(--font-size-sm);
  }

  .answer-text:focus-visible {
    outline: var(--focus-outline);
    outline-offset: -1px;
  }

  /* A long form scrolls under its answers, which stay in reach. */
  .foot {
    position: sticky;
    bottom: calc(-1 * var(--space-12));
    display: flex;
    justify-content: flex-end;
    gap: var(--space-8);
    margin-bottom: calc(-1 * var(--space-12));
    padding: var(--space-8) 0 var(--space-12);
    background: var(--float-surface);
  }

  .skip,
  .submit {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    height: var(--control-height-sm);
    padding: 0 var(--space-10);
    border: 0;
    border-radius: var(--radius-sm);
    font-family: inherit;
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-medium);
    white-space: nowrap;
    cursor: pointer;
    transition:
      background var(--transition-fast),
      opacity var(--transition-fast);
  }

  .skip {
    background: var(--bg-primary);
    box-shadow: inset 0 0 0 1px var(--border);
    color: var(--text-primary);
  }

  .skip:hover {
    background: var(--bg-hover);
  }

  .submit {
    background: var(--accent);
    color: var(--accent-text);
  }

  .submit:hover:not(:disabled) {
    background: var(--accent-hover);
  }

  .submit:disabled {
    opacity: 0.45;
    cursor: default;
  }

  .skip:focus-visible,
  .submit:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .foot kbd {
    font-family: inherit;
    font-size: var(--font-size-xs);
    opacity: 0.6;
  }
</style>
