<script lang="ts" module>
  // Natural sizes already decoded: a row drawn again reserves its picture's exact box before it loads.
  // eslint-disable-next-line svelte/prefer-svelte-reactivity -- a cache, never read reactively
  const sizes = new Map<string, { width: number; height: number }>();
</script>

<script lang="ts">
  import { t } from "../../lib/i18n/state.svelte";
  import Icon from "./Icon.svelte";

  interface Props {
    /** A data: URL or a `conversation-file/` URL; ConversationView's lightbox opens it on click. */
    src: string;
    alt: string;
    /** A thumbnail under a tool call rather than a picture in the reply. */
    small?: boolean;
  }

  let { src, alt, small = false }: Props = $props();

  let loaded = $state<{ src: string; width: number; height: number } | null>(null);
  let failed = $state("");
  const size = $derived(loaded?.src === src ? loaded : (sizes.get(src) ?? null));
</script>

{#if failed === src}
  <span class="unavailable" class:small><Icon name="image" size={12} />{t("agents.image.unavailable")}</span>
{:else}
  <!-- Once the size is known the box is the contained picture itself: no letterbox, no jump. -->
  <button
    type="button"
    class="thumb"
    class:small
    class:pending={!size}
    class:sized={size !== null}
    data-lightbox
    aria-label={alt || t("agents.image.open")}
    style:width={size ? `min(100%, ${size.width}px, calc(var(--thumb-max) * ${size.width / size.height}))` : undefined}
  >
    <img
      {src}
      {alt}
      width={size?.width}
      height={size?.height}
      style:aspect-ratio={size ? `${size.width} / ${size.height}` : undefined}
      loading="lazy"
      decoding="async"
      onload={(event) => {
        const img = event.currentTarget as HTMLImageElement;
        if (!img.naturalWidth || !img.naturalHeight) return;
        const natural = { width: img.naturalWidth, height: img.naturalHeight };
        sizes.set(src, natural);
        loaded = { src, ...natural };
      }}
      onerror={() => (failed = src)}
    />
  </button>
{/if}

<style>
  .thumb {
    --thumb-max: 360px;
    display: block;
    width: fit-content;
    max-width: 100%;
    padding: 0;
    border: 1px solid var(--separator);
    border-radius: var(--radius-md);
    background: var(--bg-secondary);
    overflow: hidden;
    cursor: zoom-in;
  }

  .thumb.small {
    --thumb-max: 72px;
    border-radius: var(--radius-sm);
  }

  /* Holds the place while the picture decodes, so the thread below does not move twice. */
  .thumb.pending {
    min-width: min(240px, 100%);
    min-height: 160px;
  }

  .thumb.small.pending {
    min-width: 96px;
    min-height: var(--thumb-max);
  }

  img {
    display: block;
    width: auto;
    height: auto;
    max-width: 100%;
    max-height: var(--thumb-max);
    object-fit: contain;
  }

  .sized img {
    width: 100%;
  }

  .thumb:hover {
    border-color: var(--border);
  }

  .thumb:focus-visible {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .unavailable {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    height: 22px;
    padding: 0 var(--space-8);
    border: 1px solid var(--separator);
    border-radius: var(--radius-chip);
    color: var(--text-muted);
    font-size: var(--font-size-xs);
    white-space: nowrap;
  }
</style>
