<script lang="ts">
  import { cubicOut } from "svelte/easing";
  import { springEase } from "../../lib/motion/spring";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { t } from "../../lib/i18n/state.svelte";
  import type { Snippet } from "svelte";
  import { MediaQuery } from "svelte/reactivity";

  interface Props {
    active: boolean;
    ariaLabel: string;
    interactiveZoneId: string;
    eyebrow?: string;
    title: string;
    description?: string;
    /** Shows a back control before the title (drill-in pages). */
    onback?: () => void;
    /** A navigation column on the card's left, told whether it is narrowed to icons; the content centers beside it. */
    nav?: Snippet<[boolean]>;
    children: Snippet;
  }

  let {
    active,
    ariaLabel,
    interactiveZoneId,
    eyebrow,
    title,
    description,
    onback,
    nav,
    children,
  }: Props = $props();

  const narrow = new MediaQuery("max-width: 720px");

  function shellTransition(
    _node: Element,
    _params: undefined,
    options: { direction: "in" | "out" | "both" },
  ) {
    return {
      duration: prefersReducedMotion() ? 1 : options.direction === "in" ? 280 : 130,
      // Settles in on the spring; leaves without one, an exit should not bounce.
      easing: options.direction === "in" ? springEase : cubicOut,
      css: (t: number, u: number) => `
        opacity: ${t};
        transform: translate3d(${u * 10}px, 0, 0) scale(${1 - u * 0.008});
      `,
    };
  }
</script>

{#if active}
  <section
    class="ui-shell-frame"
    class:with-nav={!!nav}
    class:nav-compact={narrow.current}
    aria-label={ariaLabel}
    transition:shellTransition
    use:reportInteractiveZone={{ id: interactiveZoneId, active }}
  >
    {#if nav}
      <div class="ui-shell-frame-nav">{@render nav(narrow.current)}</div>
    {/if}
    <div class="ui-shell-frame-scroll">
      <header class="ui-shell-frame-header">
        {#if onback}
          <button
            class="ui-shell-frame-back"
            type="button"
            aria-label={t("common.back")}
            onclick={onback}
          >
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden="true">
              <path d="M8.5 3 4.5 7l4 4" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" />
            </svg>
          </button>
        {/if}
        <div class="ui-shell-frame-copy">
          {#if eyebrow}<p class="ui-shell-frame-eyebrow">{eyebrow}</p>{/if}
          <h2 class="ui-shell-frame-title">{title}</h2>
          {#if description}<p class="ui-shell-frame-description">{description}</p>{/if}
        </div>
      </header>

      <main class="ui-shell-frame-main">
        {@render children()}
      </main>
    </div>
  </section>
{/if}

<style>
  .ui-shell-frame {
    position: fixed;
    top: var(--chrome-content-top);
    left: var(--chrome-content-left-visible);
    right: var(--chrome-content-right);
    bottom: var(--chrome-content-bottom);
    z-index: 62;
    pointer-events: auto;
    overflow: hidden;
    border-radius: var(--chrome-overlay-boundary-radius);
    background: color-mix(in srgb, var(--bg-primary) 96%, var(--sidebar-bg));
    color: var(--text-primary);
  }

  /* The card clips the column at its own corners: one shape, a hairline between nav and content. */
  .ui-shell-frame.with-nav {
    display: grid;
    grid-template-columns: 232px minmax(0, 1fr);
  }

  .ui-shell-frame.with-nav.nav-compact {
    grid-template-columns: 52px minmax(0, 1fr);
  }

  .ui-shell-frame-nav {
    display: flex;
    flex-direction: column;
    min-height: 0;
    /* Its first control lines up with the page title. */
    padding-top: calc(2 * var(--space-24));
    background: color-mix(in srgb, var(--bg-secondary) 35%, transparent);
    box-shadow: inset -1px 0 var(--separator);
  }

  /* The strip's pill already names and closes the page. */
  .ui-shell-frame-nav :global(.panel-header) {
    display: none;
  }

  .with-nav .ui-shell-frame-scroll {
    padding: var(--space-24) var(--space-32) var(--space-32);
  }

  .with-nav .ui-shell-frame-header {
    top: calc(-1 * var(--space-24));
    padding-top: var(--space-24);
  }

  .with-nav .ui-shell-frame-header,
  .with-nav .ui-shell-frame-main {
    max-width: 760px;
    margin-inline: auto;
  }

  .ui-shell-frame-scroll {
    height: 100%;
    overflow-y: auto;
    padding: 28px 34px 42px;
  }

  .ui-shell-frame-header,
  .ui-shell-frame-main {
    width: 100%;
  }

  .ui-shell-frame-header {
    position: sticky;
    top: -28px;
    z-index: 1;
    display: flex;
    align-items: center;
    gap: 6px;
    margin-bottom: 14px;
    padding: 28px 0 10px;
    background: color-mix(in srgb, var(--bg-primary) 96%, var(--sidebar-bg));
  }

  .ui-shell-frame-back {
    flex: none;
    display: grid;
    place-items: center;
    width: 26px;
    height: 26px;
    margin-left: -6px;
    border: 0;
    border-radius: var(--radius-sm);
    background: transparent;
    color: var(--text-secondary);
    cursor: pointer;
  }

  .ui-shell-frame-back:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .ui-shell-frame-back:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .ui-shell-frame-copy {
    display: grid;
    gap: 4px;
    min-width: 0;
  }

  .ui-shell-frame-eyebrow {
    margin: 0;
    color: var(--text-muted);
    font-size: var(--font-size-2xs);
    font-weight: var(--font-weight-semibold);
    letter-spacing: 0;
    text-transform: uppercase;
  }

  .ui-shell-frame-title {
    margin: 0;
    min-width: 0;
    overflow-wrap: anywhere;
    color: var(--text-primary);
    font-size: var(--font-size-2xl);
    line-height: 1.2;
    font-weight: var(--font-weight-semibold);
  }

  .ui-shell-frame-description {
    margin: 0;
    max-width: 58ch;
    color: var(--text-muted);
    font-size: var(--font-size-md);
    line-height: 1.45;
  }

  @media (max-width: 720px) {
    .ui-shell-frame-scroll {
      padding: 20px 18px 30px;
    }

    .ui-shell-frame-header {
      top: -20px;
      padding-top: 20px;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .ui-shell-frame {
      transform: none;
    }
  }
</style>
