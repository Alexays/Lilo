<script lang="ts">
  import { onMount } from "svelte";
  import type { ReleaseMedia } from "../../../../release-media/catalog";
  import { getLocale, t } from "../../lib/i18n/state.svelte";

  let { media, label }: { media: ReleaseMedia; label: string } = $props();
  const captionId = $props.id();
  const locale = $derived(getLocale());
  const caption = $derived(locale === "en" || locale === "fr" ? media.alt[locale] : label);
  let video: HTMLVideoElement | undefined = $state();

  onMount(() => {
    if (!video) return;
    const player = video;
    const pauseWhenHidden = () => { if (document.hidden) player.pause(); };
    const observer = new IntersectionObserver(([entry]) => { if (!entry.isIntersecting) player.pause(); });
    observer.observe(player);
    document.addEventListener("visibilitychange", pauseWhenHidden);
    return () => { player.pause(); observer.disconnect(); document.removeEventListener("visibilitychange", pauseWhenHidden); };
  });
</script>

<figure class="release-media" lang={getLocale()}>
  {#if media.kind === "video"}
    <video bind:this={video} controls playsinline preload="none" poster={media.poster} width={media.width} height={media.height} lang="en" aria-labelledby={captionId}>
      <source src={media.video} type="video/mp4" />
      <a href={media.video} lang={getLocale()}>{caption}</a>
    </video>
  {:else}
    <img src={media.poster} width={media.width} height={media.height} alt={media.alt.en} lang="en" aria-labelledby={captionId} decoding="async" />
  {/if}
  <figcaption id={captionId} lang={getLocale()}>
    <span>{caption}</span>
    <span class="media-language">{t("whatsNew.mediaLanguage")}</span>
  </figcaption>
</figure>

<style>
  .release-media { margin: 0 0 var(--space-24); }
  video, img { display: block; width: 100%; height: auto; aspect-ratio: 16 / 9; border-radius: var(--radius-lg); background: var(--bg-primary); }
  video:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
  figcaption { margin-top: var(--space-8); color: var(--text-secondary); font-size: var(--font-size-sm); line-height: 1.5; }
  .media-language { display: block; margin-top: var(--space-4); font-size: var(--font-size-xs); }
</style>
