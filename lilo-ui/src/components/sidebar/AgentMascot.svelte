<script lang="ts">
  import type { BridgeAgentMood } from "../../lib/bridge/protocol";

  // A ghost for the private space an agent opens: like its tabs, it leaves nothing behind.
  let { mood, ghost = false }: { mood?: BridgeAgentMood; ghost?: boolean } = $props();

  // Blinks on a timer: a repeating CSS blink would keep the compositor busy while the agents are idle.
  function blink(eyes: HTMLElement) {
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    let timer: ReturnType<typeof setInterval> | undefined;
    // Only in the key window (a hidden one never is): App sets window-unfocused from the native focus, as the DOM
    // blur also fires on every tab activation.
    const root = document.documentElement;
    const run = () => {
      // Other classes change on the root too: only a focus change restarts the timer.
      if (root.classList.contains("window-unfocused") === (timer === undefined)) return;
      clearInterval(timer);
      timer = root.classList.contains("window-unfocused")
        ? undefined
        : setInterval(() => eyes.animate([{ transform: "scaleY(1)" }, { transform: "scaleY(0.15)" }, { transform: "scaleY(1)" }], { duration: 140 }), 3000);
    };
    run();
    const focus = new MutationObserver(run);
    focus.observe(root, { attributeFilter: ["class"] });
    return () => {
      clearInterval(timer);
      focus.disconnect();
    };
  }
</script>

<!-- The cursor's mascot (AgentCursorView) in swapped colors, drawn at its 22 pt and scaled. Only transform
     and opacity animate, and only while a call runs, so moods stay on the compositor. -->
<span class="mascot" data-mood={mood} aria-hidden="true">
  {#if mood === "waitingForUser"}<span class="halo"></span>{/if}
  <span class="body" class:ghost>
    {#if ghost}<svg viewBox="0 0 22 22"><path d="M3 10.5a8 8 0 0 1 16 0V20l-2.67-1.8-2.67 1.8-2.66-1.8-2.67 1.8-2.66-1.8L3 20Z" /></svg>{/if}
    <span class="eyes"><span class="blink" {@attach blink}><i></i><i></i></span></span>
  </span>
  {#if mood === "scripting"}
    <span class="dots"><i></i><i></i><i></i></span>
  {:else if mood === "capturing"}
    <span class="ring"></span>
  {:else if mood === "loading"}
    <span class="orbit"><i></i></span>
  {/if}
</span>

<style>
  .mascot {
    position: relative;
    width: 22px;
    height: 22px;
    margin: -2px;
    flex: none;
    transform: scale(calc(18 / 22));
  }

  .body,
  .eyes,
  .blink,
  .halo,
  .ring {
    position: absolute;
    inset: 0;
  }

  .body {
    border-radius: 50%;
    background: white;
    border: 1.5px solid var(--agents);
  }

  /* The eyes span the body's 22 pt, not its content box, so they turn around its center. */
  .eyes {
    inset: -1.5px;
  }

  .ghost {
    border: none;
    border-radius: 0;
    background: none;
  }

  .ghost svg {
    position: absolute;
    inset: 0;
    overflow: visible;
  }

  .ghost path {
    fill: white;
    stroke: var(--agents);
    stroke-width: 1.5;
    stroke-linejoin: round;
  }

  .ghost .eyes {
    inset: 0;
  }

  .blink i {
    position: absolute;
    top: 7.5px;
    left: 5px;
    width: 4px;
    height: 5px;
    border-radius: 50% / 40%;
    background: var(--agents);
  }

  .blink i + i {
    left: 13px;
  }

  .halo {
    z-index: -1;
    border-radius: 50%;
    background: var(--agents);
    border: 1px solid white;
    opacity: 0;
  }

  .ring {
    border-radius: 50%;
    border: 1.2px solid var(--agents);
    opacity: 0;
  }

  .dots i {
    position: absolute;
    top: -6.25px;
    left: 5.75px;
    width: 2.5px;
    height: 2.5px;
    border-radius: 50%;
    background: var(--agents);
    opacity: 0.25;
  }

  .dots i:nth-child(2) {
    left: 9.75px;
  }

  .dots i:nth-child(3) {
    left: 13.75px;
  }

  .orbit {
    position: absolute;
    inset: -5px;
  }

  .orbit i {
    position: absolute;
    top: 14px;
    left: 26px;
    width: 4px;
    height: 4px;
    border-radius: 50%;
    background: var(--agents);
    border: 0.7px solid white;
  }

  @media (prefers-reduced-motion: reduce) {
    .halo,
    .ring,
    .dots,
    .orbit {
      display: none;
    }
  }

  @media (prefers-reduced-motion: no-preference) {
    [data-mood="working"] .body {
      animation: mascot-bob 0.7s ease-in-out infinite;
    }

    [data-mood="working"] .eyes {
      animation: mascot-look 2.4s linear infinite;
    }

    [data-mood="reading"] .eyes {
      animation: mascot-read 2.4s linear infinite;
    }

    [data-mood="scripting"] .body {
      animation: mascot-jitter 0.18s linear infinite;
    }

    [data-mood="scripting"] .eyes {
      animation: mascot-squint 1.2s linear infinite;
    }

    .dots i {
      animation: mascot-dot 0.9s linear infinite;
    }

    .dots i:nth-child(2) {
      animation-delay: 0.3s;
    }

    .dots i:nth-child(3) {
      animation-delay: 0.6s;
    }

    [data-mood="typing"] .body {
      animation: mascot-tap 0.6s linear infinite;
    }

    [data-mood="typing"] .eyes {
      translate: 0 1.7px;
    }

    [data-mood="capturing"] .eyes {
      animation: mascot-snap 1.4s linear infinite;
    }

    .ring {
      animation: mascot-flash 1.4s linear infinite;
    }

    [data-mood="loading"] .body {
      animation: mascot-rock 1.1s ease-in-out infinite;
    }

    .orbit {
      animation: mascot-orbit 1.1s linear infinite;
    }

    [data-mood="waitingForUser"] .eyes {
      animation: mascot-up 1.8s ease-in-out infinite;
    }

    .halo {
      animation: mascot-halo 1.8s ease-out infinite;
    }
  }

  @keyframes mascot-bob {
    50% { transform: translateY(-2.5px); }
  }

  @keyframes mascot-look {
    0%, 100% { transform: none; }
    15%, 40% { transform: translateX(-2px); }
    55%, 85% { transform: translateX(2px); }
  }

  /* Line by line: across, then back to the start of the next one down. */
  @keyframes mascot-read {
    0%, 100% { transform: translate(-2px, -0.7px); }
    30% { transform: translate(2px, -0.7px); }
    33% { transform: translate(-2px, 0.3px); }
    63% { transform: translate(2px, 0.3px); }
    66% { transform: translate(-2px, 1.3px); }
    96% { transform: translate(2px, 1.3px); }
  }

  @keyframes mascot-jitter {
    25% { transform: translateX(-0.5px); }
    75% { transform: translateX(0.5px); }
  }

  @keyframes mascot-squint {
    0%, 100% { transform: scaleY(0.45); }
    50% { transform: scaleY(0.6); }
  }

  @keyframes mascot-dot {
    0%, 100% { opacity: 0.25; }
    50% { opacity: 1; }
  }

  @keyframes mascot-tap {
    0%, 20%, 45%, 100% { transform: none; }
    10%, 35% { transform: translateY(1px); }
  }

  @keyframes mascot-snap {
    0%, 70%, 86%, 100% { transform: none; }
    78% { transform: scaleY(0.1); }
  }

  @keyframes mascot-flash {
    0%, 74% { opacity: 0; transform: none; }
    78% { opacity: 1; transform: none; }
    100% { opacity: 0; transform: scale(1.8); }
  }

  @keyframes mascot-rock {
    0%, 100% { transform: rotate(-5.7deg); }
    50% { transform: rotate(5.7deg); }
  }

  @keyframes mascot-orbit {
    to { transform: rotate(360deg); }
  }

  @keyframes mascot-up {
    0%, 100% { transform: translateY(-2px); }
    50% { transform: translateY(-2.7px); }
  }

  @keyframes mascot-halo {
    from { opacity: 0.6; transform: none; }
    to { opacity: 0; transform: scale(1.6); }
  }
</style>
