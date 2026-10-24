<!-- A question asked from the address bar: icon, message, then a quiet dismiss, an optional second
     answer, and the accent confirm. Shared by the permission requests and the default-browser invite. -->
<script lang="ts">
  import type { Snippet } from "svelte";
  import UiButton from "../ui/UiButton.svelte";
  import URLDrawerIcon, { type UrlDrawerIconName } from "./URLDrawerIcon.svelte";

  interface Props {
    icon: UrlDrawerIconName;
    dismissLabel: string;
    confirmLabel: string;
    /** A second way to agree, shown between the two. */
    alternateLabel?: string;
    confirmDisabled?: boolean;
    showActions?: boolean;
    error?: boolean;
    ondismiss: () => void;
    onconfirm: () => void;
    onalternate?: () => void;
    children: Snippet;
  }

  let {
    icon,
    dismissLabel,
    confirmLabel,
    alternateLabel,
    confirmDisabled = false,
    showActions = true,
    error = false,
    ondismiss,
    onconfirm,
    onalternate,
    children,
  }: Props = $props();
</script>

<div class="drawer-prompt" role="alert">
  <span class="prompt-icon"><URLDrawerIcon name={icon} /></span>
  <div class="prompt-message" class:error>{@render children()}</div>
</div>
{#if showActions}
  <div class="prompt-actions">
    <UiButton variant="ghost" onclick={ondismiss}>{dismissLabel}</UiButton>
    {#if alternateLabel && onalternate}<UiButton onclick={onalternate}>{alternateLabel}</UiButton>{/if}
    <UiButton variant="primary" disabled={confirmDisabled} onclick={onconfirm}>{confirmLabel}</UiButton>
  </div>
{/if}

<style>
  .drawer-prompt {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    padding: 4px 6px 0;
  }

  .prompt-icon {
    flex: none;
    padding-top: 1px;
    color: var(--text-secondary);
  }

  .prompt-message {
    flex: 1;
    min-width: 0;
    color: var(--text-primary);
    font-size: var(--font-size-md);
    line-height: 1.4;
    overflow-wrap: anywhere;
  }

  .prompt-message :global(strong) {
    font-weight: var(--font-weight-semibold);
  }

  .prompt-message.error {
    color: color-mix(in srgb, var(--danger) 86%, var(--text-primary));
  }

  .prompt-actions {
    display: flex;
    flex-wrap: wrap;
    justify-content: flex-end;
    gap: 6px;
    padding: 8px 2px 2px;
  }

  /* An answer naming a long site wraps rather than run off the drawer: the site must stay readable. */
  .prompt-actions :global(.ui-button) {
    max-width: 100%;
    white-space: normal;
    overflow-wrap: anywhere;
  }
</style>
