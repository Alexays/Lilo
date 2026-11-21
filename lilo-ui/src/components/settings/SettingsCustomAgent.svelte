<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import type { CommandFields } from "../../lib/agentInstances";
  import UiTextField from "../ui/UiTextField.svelte";

  type Field = keyof CommandFields;

  /** The form's fields, edited in place by the sheet that hosts it. */
  let { values = $bindable() }: { values: CommandFields } = $props();

  function save(field: Field, value: string): void {
    values = { ...values, [field]: value.trim() };
  }
</script>

<!-- A program Lilo starts as an agent next to the registry's: one text per field, arguments and variables one per line. -->
<div class="form">
  <label>
    <span class="label">{t("settings.items.customAgent.name")}</span>
    <UiTextField value={values.name} placeholder={t("settings.items.customAgent.namePlaceholder")} oncommit={(value) => save("name", value)} />
  </label>
  <label>
    <span class="label">{t("settings.items.customAgent.executable")}</span>
    <UiTextField value={values.executable} placeholder="/usr/local/bin/my-agent" oncommit={(value) => save("executable", value)} />
  </label>
  <label>
    <span class="label">{t("settings.items.customAgent.arguments")}</span>
    <textarea rows="3" spellcheck="false" placeholder="--profile&#10;acp" value={values.arguments} onchange={(event) => save("arguments", event.currentTarget.value)}></textarea>
  </label>
  <label>
    <span class="label">{t("settings.items.customAgent.environment")}</span>
    <textarea rows="4" spellcheck="false" placeholder="NAME=value" value={values.environment} onchange={(event) => save("environment", event.currentTarget.value)}></textarea>
  </label>
</div>

<p class="note">{t("settings.items.customAgent.note")}</p>

<style>
  .form {
    display: grid;
    gap: var(--space-12);
  }

  label {
    display: grid;
    gap: var(--space-4);
  }

  .label {
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  textarea {
    width: 100%;
    box-sizing: border-box;
    padding: var(--space-6) var(--space-10);
    border: 1px solid var(--text-primary-tint-12);
    border-radius: var(--radius-md);
    background: color-mix(in srgb, var(--bg-primary) 92%, transparent);
    color: var(--text-primary);
    font: var(--font-size-sm) / 1.5 ui-monospace, "SF Mono", Menlo, monospace;
    resize: vertical;
  }

  textarea:focus {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .note {
    margin: var(--space-12) 0 0;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    line-height: 1.4;
  }
</style>
