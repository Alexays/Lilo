<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import { getSetting, setSetting } from "../../stores/settings.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiConfirmModal from "../ui/UiConfirmModal.svelte";

  let confirmingReset = $state(false);
</script>

<!-- The prompt as a document: what it is in its header, the text below, how it is sent at its foot. -->
<div class="document">
  <div class="toolbar">
    <span class="heading">
      <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round" aria-hidden="true">
        <path d="M4 1.8h5.2L12.5 5v9.2H4Z" /><path d="M9 1.8V5.2h3.5M6 8h4.5M6 10.5h3" stroke-linecap="round" />
      </svg>
      {t("settings.items.agentSystemPromptText.heading")}
    </span>
    <UiButton onclick={() => (confirmingReset = true)}>{t("settings.items.agentSystemPromptText.reset")}</UiButton>
  </div>
  <!-- Saved on blur; an emptied field brings the default back. -->
  <textarea
    class="text"
    spellcheck="false"
    aria-label={t("settings.items.agentSystemPromptText.title")}
    value={getSetting("agentSystemPromptText", "")}
    onchange={(event) => setSetting("agentSystemPromptText", event.currentTarget.value.trim())}
  ></textarea>
</div>

<p class="note">
  <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" aria-hidden="true">
    <circle cx="8" cy="8" r="6.2" /><path d="M8 7.2v4M8 4.9v.1" />
  </svg>
  {t("settings.items.agentSystemPromptText.note")}
</p>

<UiConfirmModal
  visible={confirmingReset}
  title={t("settings.items.agentSystemPromptText.resetTitle")}
  message={t("settings.items.agentSystemPromptText.resetMessage")}
  confirmLabel={t("settings.items.agentSystemPromptText.reset")}
  confirmAction={() => {
    setSetting("agentSystemPromptText", "");
    confirmingReset = false;
  }}
  cancelAction={() => (confirmingReset = false)}
/>

<style>
  .document {
    display: grid;
    grid-template-rows: auto 1fr;
    overflow: hidden;
    border-radius: var(--radius-lg);
    background: var(--bg-primary);
    box-shadow: 0 0 0 1px var(--separator), 0 1px 3px var(--text-primary-tint-12);
  }

  .document:focus-within {
    box-shadow: 0 0 0 1px var(--accent), 0 0 0 4px var(--accent-tint-14);
  }

  .toolbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 8px 8px 8px 14px;
    border-bottom: 1px solid var(--separator);
    background: var(--bg-elevated);
  }

  .heading {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    color: var(--text-primary);
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-medium);
  }

  .heading svg {
    color: var(--accent);
  }

  .text {
    display: block;
    width: 100%;
    min-height: max(360px, calc(100vh - 340px));
    box-sizing: border-box;
    padding: 16px 18px;
    border: 0;
    background: transparent;
    color: var(--text-primary);
    font: var(--font-size-sm) / 1.65 ui-monospace, "SF Mono", Menlo, monospace;
    resize: none;
    outline: none;
  }

  .note {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    margin: 0;
    padding: 0 4px;
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
    line-height: 1.4;
  }

  .note svg {
    flex: none;
    margin-top: 1px;
  }
</style>
