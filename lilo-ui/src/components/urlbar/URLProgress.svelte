<script lang="ts">
  interface Props {
    progress: number;
    visible: boolean;
    completing: boolean;
    stalled: boolean;
    capped: boolean;
  }

  let { progress, visible, completing, stalled, capped }: Props = $props();

  const shimmerDuration = $derived(progress < 0.18 ? 0.98 : progress < 0.46 ? 1.12 : progress < 0.78 ? 1.28 : 1.48);
</script>

{#if visible}
  <div
    class="url-progress-track"
    class:complete={completing}
    class:stalled={stalled && !completing}
    class:capped
    aria-hidden="true"
  >
    <div
      class="url-progress-fill"
      style={`transform: scaleX(${progress}); --url-progress-shimmer-duration: ${shimmerDuration}s;`}
    ></div>
  </div>
{/if}

<style>
  .url-progress-track {
    position: absolute;
    left: 0;
    right: 0;
    bottom: 0;
    height: 3px;
    background: color-mix(in srgb, var(--bg-primary) 60%, transparent);
    overflow: hidden;
    pointer-events: none;
    opacity: 0.96;
    transition: opacity var(--motion-duration-normal) ease;
  }

  .url-progress-track.complete {
    opacity: 0;
  }

  .url-progress-fill {
    position: absolute;
    inset: 0;
    transform-origin: left center;
    border-radius: 0 var(--radius-chip) var(--radius-chip) 0;
    overflow: hidden;
    background: var(--accent);
    transition: transform 320ms var(--motion-ease-spring);
  }

  /* The shimmer slides a strip of two gradient tiles by one tile. A transform runs on the
     compositor; animating background-position would repaint the bar every frame of every load. */
  .url-progress-fill::after {
    content: "";
    position: absolute;
    top: 0;
    bottom: 0;
    left: 0;
    width: 360%;
    background: linear-gradient(
        90deg,
        var(--accent),
        color-mix(in srgb, var(--accent) 64%, white 36%),
        var(--accent)
      )
      0 0 / 50% 100% repeat-x;
    animation: url-progress-shimmer var(--url-progress-shimmer-duration, 1.28s)
      linear infinite;
  }

  /* A load that stopped progressing long ago freezes the bar: a looping shimmer would keep
     WebKit's display link running for as long as the tab stays stuck. */
  .url-progress-track.capped .url-progress-fill::after {
    animation: none;
  }

  @keyframes url-progress-shimmer {
    from {
      transform: translateX(-50%);
    }

    to {
      transform: translateX(0);
    }
  }

  /* Indeterminate sweep for stalled navigations */
  .url-progress-track.stalled .url-progress-fill {
    inset: 0 auto 0 0;
    width: 32%;
    transform: none;
    animation: url-progress-sweep 1.5s cubic-bezier(0.4, 0, 0.6, 1) infinite;
    background: linear-gradient(
      90deg,
      transparent,
      color-mix(in srgb, var(--accent) 72%, transparent),
      color-mix(in srgb, var(--accent) 90%, white),
      color-mix(in srgb, var(--accent) 72%, transparent),
      transparent
    );
    background-size: 100% 100%;
    transition: none;
  }

  .url-progress-track.stalled .url-progress-fill::after {
    content: none;
  }

  @keyframes url-progress-sweep {
    from {
      transform: translateX(-100%);
    }
    to {
      transform: translateX(315%);
    }
  }
</style>
