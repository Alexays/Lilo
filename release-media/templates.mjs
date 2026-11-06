const WIDTH = 1920;
const HEIGHT = 1080;
const MARGIN = { x: 140, y: 80 };
const STEP = 2.6;

/** Never above the capture's own pixels: an enlarged screenshot reads as blurry. */
function fit({ width, height }) {
  const scale = Math.min(
    (WIDTH - MARGIN.x * 2) / width,
    (HEIGHT - MARGIN.y * 2) / height,
    1,
  );
  const size = { width: Math.round(width * scale), height: Math.round(height * scale) };
  return { ...size, left: (WIDTH - size.width) / 2, top: (HEIGHT - size.height) / 2 };
}

/** A flow's shots share their top edge, so a row keeps its place when a shot grows. */
function frames(template, shots) {
  const fitted = shots.map(fit);
  const top = Math.min(...fitted.map((frame) => frame.top));
  return template === "flow" ? fitted.map((frame) => ({ ...frame, top })) : fitted;
}

const seconds = (value) => Number(value.toFixed(2));

/** The timeline each template plays. Every film ends as it starts, so it loops without a cut. */
const timelines = {
  hero: () => ({
    duration: 6,
    poster: 3,
    steps: [
      `tl.fromTo("#shot-0", { scale: 1 }, { scale: 1.035, duration: 3, ease: "sine.inOut" }, 0);`,
      `tl.to("#shot-0", { scale: 1, duration: 3, ease: "sine.inOut" }, 3);`,
    ],
  }),
  compare: () => ({
    duration: 7,
    poster: 4.5,
    steps: [
      `tl.to("#shot-1", { opacity: 1, duration: 0.7, ease: "sine.inOut" }, 2.4);`,
      `tl.to("#shot-1", { opacity: 0, duration: 0.7, ease: "sine.inOut" }, 5.9);`,
    ],
  }),
  flow: (shots) => {
    const last = shots.length - 1;
    const steps = [];
    let pointed = false;
    const placed = frames("flow", shots);
    shots.slice(0, last).forEach((shot, index) => {
      const start = index * STEP;
      if (shot.click) {
        const frame = placed[index];
        const x = frame.left + shot.click[0] * frame.width;
        const y = frame.top + shot.click[1] * frame.height;
        const move = `{ x: ${seconds(x)}, y: ${seconds(y)}, opacity: 1, duration: 1, ease: "power2.inOut" }, ${seconds(start + 0.4)}`;
        steps.push(
          pointed
            ? `tl.to("#pointer", ${move});`
            : `tl.fromTo("#pointer", { x: ${WIDTH + 80}, y: ${HEIGHT - 120}, opacity: 1 }, ${move});`,
          `tl.to("#pointer", { scale: 0.86, duration: 0.08, ease: "power2.out" }, ${seconds(start + 1.5)});`,
          `tl.to("#pointer", { scale: 1, duration: 0.16, ease: "power2.out" }, ${seconds(start + 1.58)});`,
        );
        pointed = true;
      }
      steps.push(
        `tl.to("#shot-${index + 1}", { opacity: 1, duration: 0.35, ease: "sine.inOut" }, ${seconds(start + 1.7)});`,
      );
    });
    const end = last * STEP + 2;
    steps.push(`tl.to("#pointer", { opacity: 0, duration: 0.3 }, ${seconds(end - 0.6)});`);
    for (let index = 1; index <= last; index += 1)
      steps.push(`tl.to("#shot-${index}", { opacity: 0, duration: 0.5, ease: "sine.inOut" }, ${seconds(end)});`);
    return { duration: seconds(end + 0.5), poster: seconds(last * STEP + 1), steps };
  },
  image: () => ({ duration: 1, poster: 0, steps: [] }),
};

export const templates = Object.keys(timelines);

const pointer = (duration) =>
  `<svg id="pointer" class="clip" data-start="0" data-duration="${duration}" data-track-index="20" width="46" height="62" viewBox="0 0 26 36"><path d="M3 2v26l7-6 5 11 5-2-5-11h9z" fill="#111" stroke="#fff" stroke-width="2" stroke-linejoin="round"/></svg>`;

/** A literal HyperFrames project page: the shots over Lilo's backdrop, on one paused GSAP timeline. */
export function composition({ template, shots }) {
  const timeline = timelines[template]?.(shots);
  if (!timeline) throw Error(`Unknown template: ${template}`);
  const wanted = { hero: 1, compare: 2, image: 1 }[template];
  if (wanted ? shots.length !== wanted : shots.length < 2)
    throw Error(`The ${template} template cannot show ${shots.length} shot(s)`);
  const placed = frames(template, shots);
  const pictures = shots.map((shot, index) => {
    const { left, top, width, height } = placed[index];
    return `<img id="shot-${index}" class="clip shot" src="assets/shots/${shot.file}" alt="" data-start="0" data-duration="${timeline.duration}" data-track-index="${index + 1}" style="left:${left}px;top:${top}px;width:${width}px;height:${height}px;opacity:${index ? 0 : 1}" />`;
  });
  return {
    duration: timeline.duration,
    poster: timeline.poster,
    html: `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=${WIDTH}, initial-scale=1" />
    <title>Lilo release media</title>
    <script src="assets/gsap.min.js"></script>
    <style>
      html, body { margin: 0; width: ${WIDTH}px; height: ${HEIGHT}px; overflow: hidden; }
      #main { position: relative; width: ${WIDTH}px; height: ${HEIGHT}px; overflow: hidden; background: linear-gradient(115deg, #607ea8, #b8a1c4 55%, #c6a686); }
      .shot { position: absolute; border-radius: 18px; box-shadow: 0 36px 110px rgba(24, 18, 44, 0.42); }
      #pointer { position: absolute; left: 0; top: 0; opacity: 0; transform-origin: 6px 6px; }
    </style>
  </head>
  <body>
    <main id="main" data-composition-id="main" data-start="0" data-duration="${timeline.duration}" data-width="${WIDTH}" data-height="${HEIGHT}" data-fps="30" aria-label="Lilo release media">
      ${[...pictures, template === "flow" ? pointer(timeline.duration) : ""].join("\n      ")}
    </main>
    <script>
      const tl = gsap.timeline({ paused: true });
      ${timeline.steps.join("\n      ")}
      tl.to({}, { duration: ${timeline.duration} }, 0);
      window.__timelines = { main: tl };
    </script>
  </body>
</html>
`,
  };
}
