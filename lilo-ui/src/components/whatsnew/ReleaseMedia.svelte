<script lang="ts">
  import { onMount } from "svelte";
  import type { ReleaseMedia } from "../../../../release-media/catalog";

  let { media, label }: { media: ReleaseMedia; label: string } = $props();
  let video: HTMLVideoElement | undefined = $state();

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
  <video bind:this={video} controls playsinline preload="none" poster={media.poster} width="1920" height="1080" aria-label={label} muted={media.kind === "loop"} loop={media.kind === "loop"}>
    <source src={media.video} type="video/mp4" />
  </video>
{/if}

<style>
  video, img { display: block; width: 100%; height: auto; aspect-ratio: 16 / 9; border-radius: var(--radius-sm); background: var(--bg-hover); }
  video:focus-visible { outline: var(--focus-outline); outline-offset: 2px; }
</style>
