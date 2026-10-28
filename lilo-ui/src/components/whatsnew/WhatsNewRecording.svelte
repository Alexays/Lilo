<script lang="ts">
  import { onMount } from "svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import type { ReleaseRecording } from "./releaseNotes";

  let { media, title }: { media: ReleaseRecording; title: string } = $props();
  let root: HTMLElement;
  let playing = $state(false);
  let played = $state(false);
  let timer: ReturnType<typeof setTimeout> | undefined;

  let movie: Blob | undefined;
  let request: AbortController | undefined;
  let movieURL = $state("");
  let generation = 0;

  function stop(): void {
    generation += 1;
    clearTimeout(timer);
    request?.abort(); request = undefined;
    playing = false;
    if (movieURL) URL.revokeObjectURL(movieURL);
    movieURL = "";
  }
  async function play(): Promise<void> {
    if (document.hidden) return;
    played = true; playing = true;
    const current = ++generation;
    let controller: AbortController | undefined;
    try {
      if (!movie) {
        controller = new AbortController(); request = controller;
        const response = await fetch(media.recording, { signal: controller.signal });
        if (!response.ok) throw new Error("Recording unavailable");
        const blob = await response.blob();
        if (current !== generation) return;
        movie = blob;
      }
      if (current !== generation) return;
      // A fresh URL resets animated-image decoder state on cached replay.
      movieURL = URL.createObjectURL(movie);
    } catch { if (current === generation) stop(); }
    finally { if (request === controller) request = undefined; }
  }

  onMount(() => {
    const motion = matchMedia("(prefers-reduced-motion: reduce)");
    const observer = new IntersectionObserver(([entry]) => {
      if (!entry.isIntersecting) stop();
      else if (entry.intersectionRatio >= 0.5 && !played && !motion.matches) play();
    }, { threshold: [0, 0.5] });
    observer.observe(root);
    const hidden = () => { if (document.hidden) stop(); };
    const reduced = () => { if (motion.matches) stop(); };
    document.addEventListener("visibilitychange", hidden);
    motion.addEventListener("change", reduced);
    return () => {
      stop(); observer.disconnect();
      document.removeEventListener("visibilitychange", hidden);
      motion.removeEventListener("change", reduced);
    };
  });
</script>

<figure bind:this={root} class="release-recording">
  {#key movieURL}
  <img
    src={movieURL || media.poster}
    alt={title}
    width={media.width}
    height={media.height}
    loading="lazy"
    onload={() => { if (playing && movieURL) { clearTimeout(timer); timer = setTimeout(stop, media.durationMs); } }}
    onerror={stop}
  />
  {/key}
  <button
    type="button"
    aria-label={t(playing ? "whatsNew.recordingStop" : played ? "whatsNew.recordingReplay" : "whatsNew.recordingPlay")}
    aria-pressed={playing}
    onclick={() => { if (playing) stop(); else play(); }}
  >
    <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      {#if playing}<rect x="6" y="6" width="12" height="12" rx="2" />
      {:else}<path d="m9 5 11 7-11 7Z" />{/if}
    </svg>
  </button>
</figure>

<style>
  .release-recording { position: relative; margin: var(--space-12) 0 0; overflow: hidden; border-radius: var(--radius-lg); border: 1px solid var(--separator); background: var(--bg-secondary); }
  img { display: block; width: 100%; height: auto; }
  button { position: absolute; right: 10px; bottom: 10px; display: grid; place-items: center; width: 36px; height: 36px; border: 1px solid var(--border); border-radius: var(--radius-chip); background: var(--bg-elevated); color: var(--text-primary); cursor: pointer; box-shadow: var(--shadow-control); }
  button:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
</style>
