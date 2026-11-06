<script lang="ts">
  import { onMount } from "svelte";
  import type { ReleaseMedia } from "../../../../release-media/catalog";
  import { t } from "../../lib/i18n/state.svelte";

  let { media, label }: { media: ReleaseMedia; label: string } = $props();
  let video: HTMLVideoElement | undefined = $state();
  let playing = $state(false);
  const toggle = () => (video?.paused ? void video.play().catch(() => undefined) : video?.pause());

  onMount(() => {
    if (!video) return;
    const player = video;
    const calm = matchMedia("(prefers-reduced-motion: reduce)");
    const observer = new IntersectionObserver(([entry]) => {
      if (!entry.isIntersecting) player.pause();
      else if (media.kind === "loop" && !calm.matches) void player.play().catch(() => undefined);
    }, { threshold: 0.5 });
    observer.observe(player);
    return () => { player.pause(); observer.disconnect(); };
  });
</script>

{#if media.kind === "image"}
  <img src={media.poster} width="1920" height="1080" alt={label} decoding="async" />
{:else}
  <video bind:this={video} playsinline preload="none" poster={media.poster} width="1920" height="1080" aria-label={label} muted={media.kind === "loop"} loop={media.kind === "loop"}
    onplay={() => (playing = true)} onpause={() => (playing = false)} onended={() => (playing = false)} onclick={media.kind === "film" ? toggle : undefined}>
    <source src={media.video} type="video/mp4" />
  </video>
  {#if media.kind === "film"}
    <button class="release-play" class:playing aria-label={t(playing ? "mediaCard.pause" : "mediaCard.play")}
      onclick={toggle}>
      <svg viewBox="0 0 20 20" aria-hidden="true">
        {#if playing}<path d="M6.5 4.5v11M13.5 4.5v11" />{:else}<path d="M7 4.6v10.8a.6.6 0 0 0 .9.5l8.4-5.4a.6.6 0 0 0 0-1L7.9 4.1a.6.6 0 0 0-.9.5z" />{/if}
      </svg>
    </button>
  {/if}
{/if}

<style>
  video, img { display: block; width: 100%; height: 100%; object-fit: cover; }
  /* Centered while paused; tucked into a corner once playing so it never covers the film. */
  .release-play { position: absolute; left: 50%; top: 50%; display: grid; place-items: center; width: 52px; height: 52px; padding: 0; border: 0; border-radius: var(--radius-chip); transform: translate(-50%, -50%); background: color-mix(in srgb, var(--bg-elevated) 78%, transparent); color: var(--text-primary); box-shadow: var(--shadow-sm); backdrop-filter: blur(12px); cursor: pointer; transition: opacity var(--motion-duration-normal) var(--motion-ease-standard), transform var(--motion-duration-normal) var(--motion-ease-standard); }
  .release-play svg { width: 20px; height: 20px; fill: currentColor; stroke: currentColor; stroke-width: 2.2; stroke-linecap: round; stroke-linejoin: round; }
  .release-play.playing { left: auto; top: auto; right: var(--space-12); bottom: var(--space-12); width: 32px; height: 32px; transform: none; opacity: 0; }
  .release-play.playing svg { width: 14px; height: 14px; }
  :global(.release-visual:hover) .release-play.playing, .release-play.playing:focus-visible { opacity: 1; }
  .release-play:focus-visible { outline: var(--focus-outline); outline-offset: 2px; }
  @media (prefers-reduced-motion: reduce) { .release-play { transition: none; } }
</style>
