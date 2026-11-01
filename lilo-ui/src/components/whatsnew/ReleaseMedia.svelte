<script lang="ts">
  import { onMount } from "svelte";
  import type { ReleaseMedia } from "../../../../release-media/catalog";

  let { media, label }: { media: ReleaseMedia; label: string } = $props();
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

<figure class="release-media">
  {#if media.kind === "video"}
    <video bind:this={video} controls playsinline preload="none" poster={media.poster} width={media.width} height={media.height} aria-label={label}>
      <source src={media.video} type="video/mp4" />
      <a href={media.video}>{label}</a>
    </video>
  {:else}
    <img src={media.poster} width={media.width} height={media.height} alt={label} decoding="async" />
  {/if}
</figure>

<style>
  .release-media { margin: 0 0 var(--space-24); }
  video, img { display: block; width: 100%; height: auto; aspect-ratio: 16 / 9; border-radius: var(--radius-lg); background: var(--bg-primary); }
  video:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
</style>
