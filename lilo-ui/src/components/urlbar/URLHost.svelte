<script lang="ts">
  import { quintOut, cubicOut } from "svelte/easing";
  import { prefersReducedMotion } from "../../lib/motion/reducedMotion";
  import { springEase } from "../../lib/motion/spring";
  import { restingBlur, restingFly } from "../../lib/motion/restingTransitions";
  import type { URLVisual } from "../../lib/urlVisual";

  interface Props {
    visual: URLVisual;
    hostShiftActive: boolean;
  }

  let { visual, hostShiftActive }: Props = $props();

  // Leaves room for letter-spacing, which canvas measurement ignores.
  const MEASURE_SLACK_PX = 6;
  // The address gives up type size before it gives up characters, down to this floor.
  const MIN_LINE_FONT_PX = 11;
  // Mirrors the gap in `.url-text-shell`'s margin-right.
  const CLUSTER_GAP_PX = 4;

  let shellEl: HTMLElement | undefined = $state();
  let hostEl: HTMLElement | undefined = $state();
  let pathEl: HTMLElement | undefined = $state();
  let available = $state(0);
  let baseFontSize = 0;
  let measurer: CanvasRenderingContext2D | null = null;
  let measurerFont = "";

  // `face` (weight, family) is read once per layout pass: the binary search below measures
  // dozens of strings, and setting a canvas font parses it every time.
  function textWidth(text: string, face: [string, string], size: number): number {
    measurer ??= document.createElement("canvas").getContext("2d");
    if (!measurer) return 0;
    const font = `${face[0]} ${size}px ${face[1]}`;
    if (font !== measurerFont) {
      measurer.font = font;
      measurerFont = font;
    }
    return measurer.measureText(text).width;
  }

  // Faces by class list: the line is rebuilt on every address change, and a computed-style read
  // there forces a style pass over the chrome mid-update.
  // eslint-disable-next-line svelte/prefer-svelte-reactivity -- a plain cache, intentionally non-reactive
  const faces = new Map<string, [string, string]>();
  function fontFace(el: HTMLElement): [string, string] {
    let face = faces.get(el.className);
    if (!face) {
      const style = getComputedStyle(el);
      face = [style.fontWeight, style.fontFamily];
      faces.set(el.className, face);
    }
    return face;
  }

  // Degrades in order: everything fits, everything fits a notch smaller, the middle of the
  // path dropped whole ("/\u2026/<last segment>"), then the end of the path filling whatever room
  // is left. Host and path shrink together, so the line never mixes two type sizes.
  const layout = $derived.by(() => {
    const path = visual.path;
    if (!hostEl || available <= 0) return { text: path, fontSize: 0 };

    // Read off the shell, by the resize observer: the line carries an inline size once shrunk, which would drift.
    const base = baseFontSize;
    const sizes = [base, base - 1, MIN_LINE_FONT_PX].filter(
      (size, index, all) => size >= MIN_LINE_FONT_PX && all.indexOf(size) === index,
    );
    const hostFace = fontFace(hostEl);
    const rooms = new Map(
      sizes.map((size) => [size, available - textWidth(visual.displayHost, hostFace, size) - MEASURE_SLACK_PX]),
    );
    const roomAt = (size: number) => rooms.get(size)!;

    if (!path || !pathEl) {
      const size = sizes.find((candidate) => roomAt(candidate) >= 0) ?? base;
      return { text: path, fontSize: size === base ? 0 : size };
    }

    // Trailing slashes are set aside to find the segments, then put back: the address bar never
    // shows a URL that differs from the real one.
    const pathFace = fontFace(pathEl);
    const trailing = path.match(/\/+$/)?.[0] ?? "";
    const segments = path
      .slice(0, path.length - trailing.length)
      .split("/")
      .slice(1);
    const last = segments[segments.length - 1] ?? "";
    // Elision happens between whole segments, keeping as many leading ones as fit, so a word
    // is never cut in half: "/org/\u2026/home" before "/\u2026/home".
    const collapsed = segments
      .slice(0, -1)
      .map(
        (_, kept) =>
          `/${segments.slice(0, kept).join("/")}${kept > 0 ? "/" : ""}\u2026/${last}${trailing}`,
      )
      .reverse();

    for (const candidate of [path, ...collapsed]) {
      for (const size of sizes) {
        if (textWidth(candidate, pathFace, size) <= roomAt(size)) {
          return { text: candidate, fontSize: size === base ? 0 : size };
        }
      }
    }

    // Nothing structural fits: fill the room with the end of the path, where the meaning is,
    // rather than leave it empty behind a bare marker.
    const smallest = sizes[sizes.length - 1];
    const room = roomAt(smallest);
    let kept = 0;
    let high = path.length;
    while (kept < high) {
      const mid = Math.ceil((kept + high) / 2);
      if (textWidth(`\u2026${path.slice(-mid)}`, pathFace, smallest) <= room) {
        kept = mid;
      } else {
        high = mid - 1;
      }
    }
    return {
      text: kept > 0 ? `\u2026${path.slice(-kept)}` : "/\u2026",
      fontSize: smallest === base ? 0 : smallest,
    };
  });

  // The reserve slides when the extension cluster changes width: the address is laid out for
  // where the slide ends, right away, instead of being re-fitted once it settles (a visible
  // late jump in size and truncation, e.g. on a space switch that swaps the extension set).
  $effect(() => {
    if (!shellEl) return;
    const shell = shellEl;
    const observer = new ResizeObserver(([entry]) => {
      const style = getComputedStyle(shell);
      baseFontSize = Number.parseFloat(style.fontSize);
      const endMargin = (parseFloat(style.getPropertyValue("--url-cluster-width")) || 0) + CLUSTER_GAP_PX;
      available = entry.contentRect.width + (parseFloat(style.marginRight) || 0) - endMargin;
    });
    observer.observe(shell);
    return () => observer.disconnect();
  });
</script>

<span class="url-text-shell" bind:this={shellEl}>
  <span class="url-text-viewport">
    {#key visual.key}
      <span
        class="url-text-line"
        in:restingFly={{ x: -3, y: 8, duration: prefersReducedMotion() ? 0 : 380, easing: springEase }}
        out:restingFly={{ x: 5, y: -7, duration: prefersReducedMotion() ? 0 : 240, easing: cubicOut }}
      >
        <span
          class="url-text-content"
          class:feedback={visual.isFeedback}
          style={layout.fontSize ? `font-size: ${layout.fontSize}px` : ""}
          in:restingBlur={{
            amount: 6,
            duration: prefersReducedMotion() ? 0 : 320,
            opacity: 0.16,
            easing: quintOut,
          }}
          out:restingBlur={{ amount: 4, duration: prefersReducedMotion() ? 0 : 200, opacity: 0.08 }}
        >
          <span
            bind:this={hostEl}
            class="url-host"
            class:placeholder={visual.isPlaceholder}
            class:domain-shift={hostShiftActive &&
              !visual.isPlaceholder &&
              !visual.isFeedback}
            class:feedback={visual.isFeedback}
            class:feedback-zoom={visual.feedbackVariant === "zoom"}
          >
            {visual.displayHost}
          </span>
          {#if visual.path}
            <span class="url-path" bind:this={pathEl}>{layout.text}</span>
          {/if}
        </span>
      </span>
    {/key}
  </span>
</span>

<style>
  .url-text-shell {
    position: relative;
    z-index: 1;
    flex: 1;
    min-width: 0;
    overflow: visible;
    /* Keeps the address clear of the floating extension cluster. A margin, not padding: the
       line inside is absolutely positioned and would resolve against the padding box. It slides
       so a pinned icon appearing never snaps the address sideways. */
    margin-right: calc(var(--url-cluster-width, 0px) + 4px);
    /* A mask hides all that leaves its box: room around the address, given back by the margins, lets an
       address arriving from the left, blurred, show whole. */
    padding: 8px 0 8px 10px;
    margin-top: -8px;
    margin-bottom: -8px;
    margin-left: -10px;
    /* Under the URL bar's revealed buttons (URLToast sets --url-reveal-mask to 0) the address fades
       out on the buttons' own opacity curve. */
    mask-image: linear-gradient(
      to left,
      rgb(0 0 0 / var(--url-reveal-mask)) var(--url-reveal-width, 0px),
      #000 calc(var(--url-reveal-width, 0px) + 12px)
    );
    transition:
      margin-right 320ms var(--motion-ease-spring),
      --url-reveal-mask var(--motion-duration-normal) ease;
  }

  /* Registered so the mask's alpha can transition. */
  @property --url-reveal-mask {
    syntax: "<number>";
    inherits: false;
    initial-value: 1;
  }

  .url-text-viewport {
    position: relative;
    display: block;
    min-width: 0;
    height: 1.24em;
    overflow: visible;
  }

  .url-text-line {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: baseline;
    min-width: 0;
    width: 100%;
  }

  .url-text-content {
    display: flex;
    align-items: baseline;
    gap: 0;
    min-width: 0;
    width: 100%;
    max-width: 100%;
    transform-origin: 12% 50%;
    animation: url-text-settle 560ms var(--motion-ease-bounce);
  }

  .url-text-content.feedback {
    align-items: center;
  }

  .url-host {
    flex: 0 0 auto;
    min-width: 0;
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: var(--text-primary);
    font-weight: var(--font-weight-semibold);
    letter-spacing: 0.01em;
    transition: color var(--motion-duration-slow) ease;
  }

  .url-host.placeholder {
    flex: 1 1 auto;
    max-width: 100%;
    color: var(--text-muted);
    font-weight: var(--font-weight-medium);
  }

  .url-host.domain-shift {
    animation: url-host-domain-shift 620ms var(--motion-ease-organic);
  }

  /* Feedback keeps the text color: a Space's accent, green or red can sit too close to the bar's tint to read. */
  .url-host.feedback {
    font-weight: var(--font-weight-bold);
    letter-spacing: 0.02em;
  }

  .url-host.feedback-zoom {
    font-variant-numeric: tabular-nums;
  }

  /* The ellipsis is the backstop for a measurement that lands a pixel short. */
  .url-path {
    flex: 0 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    color: color-mix(in srgb, var(--text-secondary) 50%, var(--text-primary));
  }

  @keyframes url-text-settle {
    from {
      transform: translate3d(-6px, 8px, 0) scale(0.985) rotate(-1.1deg);
      filter: saturate(0.94);
    }
  }

  @keyframes url-host-domain-shift {
    0% {
      color: color-mix(in srgb, var(--accent) 42%, var(--text-primary));
    }

    46% {
      color: color-mix(in srgb, var(--accent) 22%, var(--text-primary));
    }

    100% {
      color: var(--text-primary);
    }
  }
</style>
