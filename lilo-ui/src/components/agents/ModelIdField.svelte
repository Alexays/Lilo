<!-- For an agent that lists no models: a field to type the id of one, where its model picker would be. -->
<script lang="ts">
  import "../../lib/i18n/agentsCatalog";
  import { dismissable } from "../../lib/actions/dismissable";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { portal } from "../../lib/actions/portal";
  import { parseModelId } from "../../lib/agentReadiness";
  import { t } from "../../lib/i18n/state.svelte";
  import { popoverOut } from "../../lib/motion/restingTransitions";
  import { tooltip } from "../../lib/tooltip";
  import Icon from "../ui/Icon.svelte";

  let { onsubmit }: { onsubmit: (id: string) => void } = $props();

  const popoverId = $props.id();
  let open = $state(false);
  let text = $state("");
  let button: HTMLButtonElement | undefined = $state();
  let position = $state({ left: 0, bottom: 0 });

  const id = $derived(parseModelId(text));

  function toggle(): void {
    if (!open && button) {
      const rect = button.getBoundingClientRect();
      position = { left: Math.max(8, Math.min(rect.left, window.innerWidth - 268)), bottom: window.innerHeight - rect.top + 6 };
    }
    open = !open;
  }

  function submit(event: SubmitEvent): void {
    event.preventDefault();
    if (!id) return;
    onsubmit(id);
    open = false;
    text = "";
    button?.focus();
  }

  function focusField(node: HTMLInputElement): void {
    node.focus();
  }
</script>

<button
  bind:this={button}
  type="button"
  class="model-button"
  class:open
  aria-label={t("agents.readiness.modelCustom")}
  aria-haspopup="dialog"
  aria-expanded={open}
  aria-controls={open ? popoverId : undefined}
  data-model-field={popoverId}
  use:tooltip={t("agents.readiness.modelCustom")}
  onclick={toggle}
><Icon name="sparkle" size={13} /></button>

{#if open}
  <div
    id={popoverId}
    class="popover float-surface float-popover"
    out:popoverOut
    role="dialog"
    aria-label={t("agents.readiness.modelCustom")}
    style:left="{position.left}px"
    style:bottom="{position.bottom}px"
    use:portal
    use:reportInteractiveZone={{ id: `model-${popoverId}` }}
    {@attach dismissable({ onDismiss: () => (open = false), ignore: `[data-model-field="${popoverId}"]`, returnFocus: button, escape: true })}
  >
    <form onsubmit={submit}>
      <input
        class="field"
        type="text"
        autocomplete="off"
        autocapitalize="off"
        spellcheck="false"
        placeholder={t("agents.readiness.modelPlaceholder")}
        aria-label={t("agents.readiness.modelPlaceholder")}
        bind:value={text}
        use:focusField
      />
      <p class="hint">{t("agents.readiness.modelHint")}</p>
    </form>
  </div>
{/if}

<style>
  .model-button {
    display: grid;
    place-items: center;
    flex: none;
    width: var(--control-height-sm);
    height: var(--control-height-sm);
    border: 0;
    border-radius: var(--radius-sm);
    background: none;
    color: var(--text-secondary);
    cursor: pointer;
    transition: background var(--transition-fast), color var(--transition-fast);
  }

  .model-button:hover,
  .model-button.open {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .model-button:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .popover {
    position: fixed;
    z-index: var(--z-popover);
    box-sizing: border-box;
    width: 260px;
    padding: var(--space-8);
    transform-origin: bottom left;
  }

  form {
    display: flex;
    flex-direction: column;
    gap: var(--space-6);
  }

  .field {
    box-sizing: border-box;
    width: 100%;
    height: var(--control-height-lg);
    padding: 0 var(--space-10);
    border: 1px solid var(--float-border);
    border-radius: var(--radius-md);
    background: transparent;
    color: var(--float-text);
    font: inherit;
    font-size: var(--font-size-md);
  }

  .field::placeholder {
    color: var(--float-text-muted);
  }

  .field:focus {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .hint {
    margin: 0;
    padding: 0 var(--space-2);
    color: var(--float-text-muted);
    font-size: var(--font-size-xs);
    line-height: 1.4;
  }
</style>
