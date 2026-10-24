<script lang="ts">
  interface Props {
    src?: string;
    title?: string;
    url?: string;
    size?: number;
    radius?: number;
  }

  let { src, title = "", url = "", size = 16, radius = 4 }: Props = $props();

  // Which source failed to decode, rather than a boolean reset by an effect: a new src clears
  // the fallback on its own, and every favicon in the sidebar saves an effect.
  let failedSource = $state("");

  const imageSource = $derived(src?.trim() || "");
  const imageFailed = $derived(failedSource !== "" && failedSource === imageSource);

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
  style={`--favicon-size:${size}px; --favicon-radius:${radius}px; --favicon-hue:${fallbackHue};`}
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
