<script lang="ts">
  import { untrack, type Snippet } from "svelte";
  import { t } from "../../lib/i18n/state.svelte";

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
    message = '',
    confirmLabel,
    cancelLabel = t('common.cancel'),
    confirmDisabled = false,
    confirmAction,
    cancelAction,
    children,
  }: Props = $props();

  const titleId = $props.id();
  let layerEl: HTMLDivElement | undefined = $state();
  let cancelEl: HTMLButtonElement | undefined = $state();

  // Focus Cancel on open (every confirmation is destructive) and hand focus back to the
  // opener on close, unless the action already moved it elsewhere.
  $effect(() => {
    if (!visible) return;
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    // The sheet still sits below the panel's edge: a scrolling focus would shift the whole panel up.
    untrack(() => cancelEl?.focus({ preventScroll: true }));
    return () => {
      const focused = document.activeElement;
      if (opener?.isConnected && (focused === document.body || layerEl?.contains(focused))) opener.focus();
    };
  });

  // Capture phase, so Escape dismisses the sheet before the surface hosting it sees the key.
  // Tab cycles through the sheet's controls: it is modal, the panel behind it is out of reach.
  function handleWindowKeydown(event: KeyboardEvent): void {
    if (!visible) return;
    if (event.key === 'Tab' && layerEl) {
      const controls = [...layerEl.querySelectorAll<HTMLElement>('.confirm-sheet button:not([disabled]), .confirm-sheet input:not([disabled]), .confirm-sheet select')];
      if (controls.length === 0) return;
      const index = controls.indexOf(document.activeElement as HTMLElement);
      const next = event.shiftKey ? (index <= 0 ? controls.length - 1 : index - 1) : (index + 1) % controls.length;
      event.preventDefault();
      controls[next].focus();
      return;
    }
    if (event.key !== 'Escape') return;
    event.preventDefault();
    event.stopPropagation();
    cancelAction();
  }
</script>

<svelte:window onkeydowncapture={handleWindowKeydown} />

<div bind:this={layerEl} class="confirm-sheet-layer" class:visible inert={!visible}>
  <button
    class="confirm-sheet-backdrop"
    class:visible
    tabindex="-1"
    aria-label={t('confirmSheet.dismiss')}
    onclick={cancelAction}
  ></button>

  <div class="confirm-sheet" class:visible role="dialog" aria-modal="true" aria-hidden={!visible} aria-labelledby={titleId}>
    <div class="confirm-sheet-copy">
      <h3 id={titleId} class="confirm-sheet-title">{title}</h3>
      {#if message}
        <p class="confirm-sheet-message">{message}</p>
      {/if}
      {@render children?.()}
    </div>

    <div class="confirm-sheet-actions">
      <button bind:this={cancelEl} class="sheet-btn sheet-btn-secondary" onclick={cancelAction}>{cancelLabel}</button>
      <button class="sheet-btn sheet-btn-danger" disabled={confirmDisabled} onclick={confirmAction}>{confirmLabel}</button>
    </div>
  </div>
</div>

<style>
  .confirm-sheet-layer {
    position: absolute;
    inset: 0;
    pointer-events: none;
    z-index: 30;
    container: confirm-sheet / inline-size;
  }

  .confirm-sheet-layer.visible {
    pointer-events: auto;
  }

  .confirm-sheet-backdrop {
    position: absolute;
    inset: 0;
    z-index: 1;
    border: none;
    background: transparent;
    padding: 0;
    margin: 0;
    opacity: 0;
    transition: opacity var(--motion-duration-normal) ease, background var(--motion-duration-normal) ease;
    pointer-events: none;
  }

  .confirm-sheet-layer.visible .confirm-sheet-backdrop {
    opacity: 1;
    pointer-events: auto;
    background: var(--chrome-overlay-backdrop-tint);
  }

  .confirm-sheet {
    position: absolute;
    left: 12px;
    right: 12px;
    bottom: 12px;
    z-index: 2;
    max-width: 440px;
    margin-inline: auto;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: space-between;
    gap: 14px;
    padding: 14px;
    border-radius: var(--radius-lg);
    border: 1px solid color-mix(in srgb, var(--border) 80%, transparent);
    background: var(--bg-elevated);
    box-shadow: var(--shadow-md);
    transform: translateY(calc(100% + 16px));
    opacity: 0;
    transition: transform 320ms var(--motion-ease-bounce), opacity var(--motion-duration-normal) var(--motion-ease-organic);
    pointer-events: none;
  }

  .confirm-sheet.visible {
    transform: translateY(0);
    opacity: 1;
    pointer-events: auto;
  }

  /* Past the sidebar's widest (480px), a bottom sheet lands far from the action: center it as a dialog. */
  @container confirm-sheet (min-width: 560px) {
    .confirm-sheet-layer.visible .confirm-sheet-backdrop {
      background: var(--dialog-backdrop-tint);
    }

    .confirm-sheet {
      inset-block: 0;
      height: fit-content;
      margin-block: auto;
      padding: 20px;
      transform: scale(0.96);
      transition: transform var(--motion-duration-normal) var(--motion-ease-organic), opacity var(--motion-duration-normal) var(--motion-ease-organic);
    }

    .confirm-sheet.visible {
      transform: none;
    }
  }

  .confirm-sheet-copy {
    min-width: 0;
    flex: 1;
  }

  .confirm-sheet-title {
    margin: 0;
    font-size: var(--font-size-md);
    font-weight: var(--font-weight-semibold);
    color: var(--text-primary);
  }

  .confirm-sheet-message {
    margin: 4px 0 0;
    font-size: var(--font-size-sm);
    line-height: 1.4;
    color: var(--text-muted);
  }

  /* Buttons that cannot share a line stack, each full width, instead of wrapping their labels. */
  .confirm-sheet-actions {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px;
    max-width: 100%;
  }

  .sheet-btn {
    flex: 1 1 auto;
    white-space: nowrap;
    padding: 8px 14px;
    border: none;
    border-radius: var(--radius-sm);
    font-size: var(--font-size-sm);
    font-weight: var(--font-weight-semibold);
    cursor: pointer;
    font-family: inherit;
  }

  .sheet-btn-secondary {
    background: var(--bg-hover);
    color: var(--text-secondary);
  }

  .sheet-btn-secondary:hover {
    background: var(--bg-active);
    color: var(--text-primary);
  }

  .sheet-btn-danger {
    background: var(--danger-deep);
    color: var(--on-color);
  }

  .sheet-btn:disabled {
    opacity: var(--disabled-opacity);
    cursor: default;
  }

  .sheet-btn-danger:hover {
    background: color-mix(in srgb, var(--danger-deep) 88%, black 12%);
  }
</style>
