<!-- The one modal surface: centered on the page area, which it dims, closed by its buttons and Esc alone.
     Mount it while open: it shows itself, takes the focus and hands it back when unmounted. -->
<script lang="ts">
  import { onMount, type Snippet } from "svelte";
  import { fade } from "svelte/transition";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { isSidebarVisible } from "../../stores/ui.svelte";

  interface Props {
    /** The interactive zone native routes the page area's clicks to. */
    zone: string;
    title?: string;
    /** Replaces the title when it needs company (an icon, a subtitle); gets the id to label the modal with. */
    header?: Snippet<[string]>;
    children?: Snippet<[string]>;
    /** The buttons on the right, Cancel then the default one. */
    actions: Snippet;
    /** What stands apart on the left: a destructive action or a hint. */
    leading?: Snippet;
    width?: number;
    /** The body scrolls between separators instead of growing the modal past the page. */
    scrolls?: boolean;
    /** False keeps the rest of the window usable: the modal blocks only the page under it. */
    windowModal?: boolean;
    oncancel: () => void;
    ondefault?: () => void;
    onbackdrop?: () => void;
  }

  let {
    zone,
    title,
    header,
    children,
    actions,
    leading,
    width = 440,
    scrolls = false,
    windowModal = true,
    oncancel,
    ondefault,
    onbackdrop,
  }: Props = $props();

  const titleId = $props.id();
  const FOCUSABLE = "button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), summary, [tabindex]:not([tabindex='-1'])";
  let dialog: HTMLDialogElement;
  let actionsEl: HTMLDivElement;

  onMount(() => {
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    if (windowModal) dialog.showModal();
    else dialog.show();
    // The first useful control: one the caller marks, else Cancel, never a destructive action standing apart.
    (dialog.querySelector<HTMLElement>("[data-autofocus]") ?? actionsEl.querySelector<HTMLElement>(FOCUSABLE))?.focus({ preventScroll: true });
    return () => {
      const focused = document.activeElement;
      if (opener?.isConnected && (focused === document.body || dialog.contains(focused))) opener.focus({ preventScroll: true });
    };
  });

  // Every key stays with the modal: the surfaces behind it must not act on Esc or a shortcut meant for it.
  function handleKeydown(event: KeyboardEvent): void {
    event.stopPropagation();
    if (event.key === "Escape") {
      event.preventDefault();
      oncancel();
    } else if (event.key === "Enter" && event.metaKey && ondefault) {
      event.preventDefault();
      ondefault();
    } else if (event.key === "Tab") {
      const controls = [...dialog.querySelectorAll<HTMLElement>(FOCUSABLE)];
      if (controls.length === 0) return;
      event.preventDefault();
      const index = controls.indexOf(document.activeElement as HTMLElement);
      const next = index < 0 ? (event.shiftKey ? controls.length - 1 : 0) : (index + (event.shiftKey ? -1 : 1) + controls.length) % controls.length;
      controls[next].focus();
    }
  }
</script>

<dialog
  bind:this={dialog}
  class="ui-modal"
  data-modal={zone}
  class:window-modal={windowModal}
  class:sidebar-hidden={!isSidebarVisible()}
  aria-labelledby={titleId}
  oncancel={(event) => event.preventDefault()}
  onkeydown={handleKeydown}
  onclick={(event) => { if (event.target === dialog) onbackdrop?.(); }}
  out:fade|global={{ duration: prefersReducedMotion() ? 150 : 120 }}
  use:reportInteractiveZone={{ id: zone }}
>
  <section class="ui-modal-panel float-surface" class:scrolls class:headless={!header && !title} style:--ui-modal-width="{width}px">
    {#if header || title}
      <header class="ui-modal-head">
        {#if header}{@render header(titleId)}{:else}<h2 id={titleId} class="ui-modal-title">{title}</h2>{/if}
      </header>
    {/if}
    {#if children}
      <div class="ui-modal-body">{@render children(titleId)}</div>
    {/if}
    <footer class="ui-modal-foot">
      {@render leading?.()}
      <div class="ui-modal-actions" bind:this={actionsEl}>{@render actions()}</div>
    </footer>
  </section>
</dialog>

<style>
  .ui-modal {
    position: fixed;
    inset: var(--chrome-content-top) var(--chrome-content-right) var(--chrome-content-bottom) var(--chrome-content-left-visible);
    z-index: 60;
    width: auto;
    height: auto;
    max-width: none;
    max-height: none;
    margin: 0;
    padding: var(--space-24);
    border: 0;
    border-radius: var(--chrome-overlay-boundary-radius);
    background: var(--dialog-backdrop-tint);
    color: var(--text-primary);
    overflow: hidden;
    /* The chrome lets clicks through to the page by default: a modal takes them all. */
    pointer-events: auto;
    animation: ui-modal-fade var(--motion-duration-overlay) var(--motion-ease-spring) both;
  }

  .ui-modal[open] {
    display: grid;
    place-items: center;
  }

  .ui-modal.sidebar-hidden {
    left: var(--chrome-content-left-hidden);
  }

  /* Only the page area dims: the rest of the window stays as it is, though out of reach. */
  .ui-modal::backdrop {
    background: transparent;
  }

  .ui-modal-panel {
    display: flex;
    flex-direction: column;
    width: min(var(--ui-modal-width), 100%);
    max-height: 100%;
    min-height: 0;
    border-radius: var(--radius-lg);
    overflow: hidden;
    animation: ui-modal-in var(--motion-duration-overlay) var(--motion-ease-spring) both;
  }

  .ui-modal-head {
    padding: var(--space-20) var(--space-20) 0;
  }

  .ui-modal-title {
    margin: 0;
    font-size: var(--font-size-modal);
    font-weight: var(--font-weight-semibold);
    line-height: 1.3;
    overflow-wrap: anywhere;
  }

  .ui-modal-body {
    min-height: 0;
    padding: var(--space-12) var(--space-20) 0;
    font-size: var(--font-size-md);
    line-height: 1.45;
    overflow-y: auto;
    overscroll-behavior: contain;
  }

  .headless .ui-modal-body {
    padding-top: var(--space-20);
  }

  .scrolls .ui-modal-head {
    padding-bottom: var(--space-16);
    border-bottom: 1px solid var(--separator);
  }

  .scrolls .ui-modal-body {
    padding-bottom: var(--space-16);
  }

  .scrolls .ui-modal-foot {
    padding-top: var(--space-16);
    border-top: 1px solid var(--separator);
  }

  .ui-modal-foot {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-8);
    padding: var(--space-20);
    color: var(--text-secondary);
    font-size: var(--font-size-sm);
  }

  .ui-modal-actions {
    display: flex;
    flex-wrap: wrap;
    justify-content: flex-end;
    gap: var(--space-8);
    margin-left: auto;
  }

  @keyframes ui-modal-fade {
    from {
      opacity: 0;
    }
  }

  @keyframes ui-modal-in {
    from {
      opacity: 0;
      transform: scale(0.96);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .ui-modal,
    .ui-modal-panel {
      animation: ui-modal-fade 150ms linear both !important;
    }
  }

  @media (max-height: 520px) {
    .ui-modal {
      padding: var(--space-12);
    }
  }
</style>
