<!-- A confirmation before something destructive: Cancel, then the destructive default button. -->
<script lang="ts">
  import type { Snippet } from "svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import UiButton from "./UiButton.svelte";
  import UiModal from "./UiModal.svelte";

  interface Props {
    visible: boolean;
    title: string;
    message?: string;
    confirmLabel: string;
    cancelLabel?: string;
    confirmDisabled?: boolean;
    confirmAction: () => void;
    cancelAction: () => void;
    /** Extra controls under the message (choices the confirmation applies to). */
    children?: Snippet;
  }

  let {
    visible,
    title,
    message = "",
    confirmLabel,
    cancelLabel = t("common.cancel"),
    confirmDisabled = false,
    confirmAction,
    cancelAction,
    children,
  }: Props = $props();
</script>

{#if visible}
  <UiModal zone="confirm-modal" {title} oncancel={cancelAction} ondefault={confirmDisabled ? undefined : confirmAction}>
    {#if message || children}
      {#if message}<p class="message">{message}</p>{/if}
      {@render children?.()}
    {/if}
    {#snippet actions()}
      <UiButton onclick={cancelAction}>{cancelLabel}</UiButton>
      <UiButton variant="destructive" disabled={confirmDisabled} onclick={confirmAction}>{confirmLabel}</UiButton>
    {/snippet}
  </UiModal>
{/if}

<style>
  .message {
    margin: 0;
    color: var(--text-secondary);
  }
</style>
