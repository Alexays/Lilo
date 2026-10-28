<script lang="ts" module>
  import { contrastRatio, parseHexColor, relativeLuminance, toOklab, type RGB } from "../../lib/sidebarTheme";

  const SAMPLE_SIZE = 16;
  // A glyph on transparency under this contrast with a dark sidebar, and close to its hue, gets help.
  const GLYPH_CONTRAST = 2;
  // OKLab (a, b) distance from which a glyph's hue alone sets it apart from the sidebar.
  const HUE_SEPARATION = 0.15;
  // OKLab chroma under which a glyph is monochrome: it takes the text color, a colored one keeps its brand on a chip.
  const MONOCHROME_CHROMA = 0.04;
  // The luminance under which a sidebar counts as dark, as in ensureContrast.
  const DARK_SIDEBAR_LUMINANCE = 0.18;
  // Per source: the average color of a glyph on transparency, null for an icon with its own background.
  // eslint-disable-next-line svelte/prefer-svelte-reactivity -- a cache filled before loadedSource changes
  const glyphColors = new Map<string, RGB | null>();
  let sampler: CanvasRenderingContext2D | null = null;

  function glyphColor(image: HTMLImageElement): RGB | null {
    sampler ??= Object.assign(document.createElement("canvas"), { width: SAMPLE_SIZE, height: SAMPLE_SIZE }).getContext("2d", {
      willReadFrequently: true,
    });
    if (!sampler) return null;
    sampler.clearRect(0, 0, SAMPLE_SIZE, SAMPLE_SIZE);
    sampler.drawImage(image, 0, 0, SAMPLE_SIZE, SAMPLE_SIZE);
    let pixels: Uint8ClampedArray;
    try {
      pixels = sampler.getImageData(0, 0, SAMPLE_SIZE, SAMPLE_SIZE).data;
    } catch {
      return null;
    }
    let r = 0, g = 0, b = 0, coverage = 0, opaque = 0;
    for (let i = 0; i < pixels.length; i += 4) {
      const alpha = pixels[i + 3];
      r += pixels[i] * alpha;
      g += pixels[i + 1] * alpha;
      b += pixels[i + 2] * alpha;
      coverage += alpha;
      if (alpha >= 250) opaque++;
    }
    // A mostly opaque icon brings its own background.
    if (coverage === 0 || opaque > SAMPLE_SIZE * SAMPLE_SIZE * 0.85) return null;
    return { r: r / coverage, g: g / coverage, b: b / coverage };
  }
</script>

<script lang="ts">
  import { themeSidebarBackground } from "../../stores/theme.svelte";

  interface Props {
    src?: string;
    title?: string;
    url?: string;
    size?: number;
    radius?: number;
    asleep?: boolean;
  }

  let { src, title = "", url = "", size = 16, radius = 4, asleep = false }: Props = $props();

  // Which source failed to decode, rather than a boolean reset by an effect: a new src clears
  // the fallback on its own, and every favicon in the sidebar saves an effect.
  let failedSource = $state("");

  const imageSource = $derived(src?.trim() || "");
  const imageFailed = $derived(failedSource !== "" && failedSource === imageSource);
  let loadedSource = $state("");
  const glyph = $derived(loadedSource === imageSource ? glyphColors.get(imageSource) ?? null : null);
  const treatment = $derived.by((): "none" | "chip" | "recolor" => {
    const background = parseHexColor(themeSidebarBackground());
    if (asleep || !glyph || !background) return "none";
    if (relativeLuminance(background) >= DARK_SIDEBAR_LUMINANCE || contrastRatio(glyph, background) >= GLYPH_CONTRAST) return "none";
    const [, glyphA, glyphB] = toOklab(glyph);
    const [, sidebarA, sidebarB] = toOklab(background);
    if (Math.hypot(glyphA - sidebarA, glyphB - sidebarB) >= HUE_SEPARATION) return "none";
    return Math.hypot(glyphA, glyphB) < MONOCHROME_CHROMA ? "recolor" : "chip";
  });
  // A glyph on transparency sleeps as a silhouette in the muted text color; an opaque icon greys out.
  const silhouette = $derived(asleep && glyph !== null);
  const maskColor = $derived(silhouette ? "var(--text-muted)" : treatment === "recolor" ? "var(--text-primary)" : "");

  const fallbackGlyph = $derived.by((): string => {
    for (const candidate of [url, title, imageSource]) {
      let text = candidate.trim();
      if (!text) continue;
      try {
        text = new URL(text).hostname.replace(/^www\./, "");
      } catch {
        // Not a URL: its own first letter or digit stands in.
      }
      const firstCharacter = [...text].find((character) => /[A-Za-z0-9]/.test(character));
      if (firstCharacter) return firstCharacter.toUpperCase();
    }
    return "•";
  });

  const fallbackHue = $derived.by((): number => {
    const seed = url || title || imageSource || "lilo";
    let hash = 0;
    for (const character of seed) {
      hash = (hash * 31 + character.charCodeAt(0)) % 360;
    }
    return (hash + 360) % 360;
  });
</script>

<div
  class="site-favicon"
  class:is-fallback={!imageSource || imageFailed}
  class:has-chip={treatment === "chip"}
  class:is-masked={maskColor !== ""}
  class:is-asleep={asleep && !silhouette}
  style={`--favicon-size:${size}px; --favicon-radius:${radius}px; --favicon-hue:${fallbackHue};` +
    (maskColor ? ` --favicon-mask:url(${JSON.stringify(imageSource)}); --favicon-mask-color:${maskColor};` : "")}
  aria-hidden="true"
>
  {#if imageSource && !imageFailed}
    <img
      class="site-favicon-image"
      src={imageSource}
      alt=""
      width={size}
      height={size}
      draggable="false"
      ondragstart={(event) => event.preventDefault()}
      onload={(event) => {
        if (!glyphColors.has(imageSource)) {
          if (glyphColors.size >= 512) glyphColors.clear();
          glyphColors.set(imageSource, glyphColor(event.currentTarget as HTMLImageElement));
        }
        loadedSource = imageSource;
      }}
      onerror={() => {
        failedSource = imageSource;
      }}
    />
  {:else}
    <span class="site-favicon-fallback">{fallbackGlyph}</span>
  {/if}
</div>

<style>
  .site-favicon {
    width: var(--favicon-size);
    height: var(--favicon-size);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    overflow: hidden;
    border-radius: var(--favicon-radius);
  }

  .site-favicon.is-fallback {
    background: linear-gradient(
      145deg,
      hsl(var(--favicon-hue) 76% 86%),
      hsl(calc(var(--favicon-hue) + 26) 62% 72%)
    );
    box-shadow:
      inset 0 0 0 1px
        color-mix(in srgb, hsl(var(--favicon-hue) 28% 40%) 12%, white 76%),
      0 1px 1px color-mix(in srgb, black 8%, transparent);
  }

  .site-favicon.has-chip {
    padding: calc(var(--favicon-size) / 10);
    background: color-mix(in srgb, var(--sidebar-contrast) 14%, transparent);
  }

  /* The glyph's own shape filled with one color; the image stays in place for its load events. */
  .site-favicon.is-masked {
    background: var(--favicon-mask-color);
    mask: var(--favicon-mask) center / contain no-repeat;
  }

  .site-favicon.is-masked .site-favicon-image {
    visibility: hidden;
  }

  /* An opaque icon greys out darker than the sidebar's tiles, so its own marks (LinkedIn's "in") stay legible on it. */
  .site-favicon.is-asleep {
    filter: grayscale(1) brightness(0.7) contrast(1.3);
    opacity: 0.8;
  }

  .site-favicon-image {
    width: 100%;
    height: 100%;
    display: block;
    object-fit: contain;
    border-radius: inherit;
  }

  .site-favicon-fallback {
    color: hsl(calc(var(--favicon-hue) - 18) 42% 28%);
    font-size: clamp(10px, calc(var(--favicon-size) * 0.56), 13px);
    font-weight: var(--font-weight-bold);
    line-height: 1;
    text-transform: uppercase;
    letter-spacing: 0.01em;
  }
</style>
