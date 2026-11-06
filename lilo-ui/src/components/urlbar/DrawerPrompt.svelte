<!-- A question asked from the address bar: an icon tile, the message, then a quiet dismiss beside the
     accent confirm, which carries a variant of its answer in its menu. Shared by the permission requests and
     the default-browser invite. -->
<script lang="ts">
  import type { Snippet } from "svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import UiButton from "../ui/UiButton.svelte";
  import UiSplitButton from "../ui/UiSplitButton.svelte";
  import URLDrawerIcon, { type UrlDrawerIconName } from "./URLDrawerIcon.svelte";

  interface Props {
    icon: UrlDrawerIconName;
    /** A picture standing for who asks (an extension's icon), in place of the symbol. */
    iconImage?: string;
    dismissLabel: string;
    confirmLabel: string;
    /** A second way to agree, in the confirm button's menu. */
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
    iconImage,
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
  {#if iconImage}
    <img class="prompt-image" src={iconImage} alt="" draggable="false" />
  {:else}
    <span class="prompt-icon"><URLDrawerIcon name={icon} /></span>
  {/if}
  <div class="prompt-message" class:error>{@render children()}</div>
{#if showActions}
  <div class="prompt-actions">
    <div class="prompt-answers">
      <UiButton onclick={ondismiss}>{dismissLabel}</UiButton>
      {#if alternateLabel && onalternate}
        <UiSplitButton
          menuLabel={t("permissionPrompt.moreAnswers")}
          variants={[{ label: alternateLabel, onclick: onalternate }]}
          disabled={confirmDisabled}
          onclick={onconfirm}
        >{confirmLabel}</UiSplitButton>
      {:else}
        <UiButton variant="primary" disabled={confirmDisabled} onclick={onconfirm}>{confirmLabel}</UiButton>
      {/if}
    </div>
  </div>
{/if}
</div>

<style>
  .drawer-prompt {
    display: grid;
    grid-template-columns: 32px minmax(0, 1fr);
    column-gap: 12px;
    padding: 4px;
  }

  .prompt-icon {
    display: grid;
    place-items: center;
    width: 32px;
    height: 32px;
    border-radius: var(--radius-md);
    background: var(--accent-tint-12);
    color: var(--accent-ink);
  }

  .prompt-image {
    flex: none;
    width: 32px;
    height: 32px;
    border-radius: var(--radius-sm);
    object-fit: contain;
  }

  .prompt-message {
    align-self: center;
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
    color: var(--danger-text);
  }

  .prompt-actions {
    grid-column: 2;
    display: flex;
    justify-content: flex-end;
    padding-top: 12px;
  }

  .prompt-answers {
    display: flex;
    flex-wrap: wrap;
    justify-content: flex-end;
    gap: 6px;
    max-width: 100%;
  }

  /* An answer naming a long site wraps rather than run off the drawer: the site must stay readable. */
  .prompt-actions :global(.ui-button) {
    max-width: 100%;
    padding-block: 4px;
    text-align: end;
    white-space: normal;
    overflow-wrap: anywhere;
  }
</style>
