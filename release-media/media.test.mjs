import assert from "node:assert/strict";
import { test } from "node:test";
import { plansFrom } from "./draft.mjs";
import { withMedia } from "./media.mjs";
import { composition } from "./templates.mjs";

const shot = (file, click) => ({ file, width: 1200, height: 800, ...(click ? { click } : {}) });
const step = (fields) => ({ selector: null, text: null, value: null, name: null, ...fields });

test("each template plays over the shots it was given and loops back to its start", () => {
  for (const [template, shots] of [
    ["hero", [shot("a.png")]],
    ["compare", [shot("a.png"), shot("b.png")]],
    ["flow", [shot("a.png", [0.5, 0.5]), shot("b.png", [0.2, 0.2]), shot("c.png")]],
    ["image", [shot("a.png")]],
  ]) {
    const { html, duration, poster } = composition({ template, shots });
    for (const { file } of shots) assert.match(html, new RegExp(`assets/shots/${file}`));
    assert.ok(poster < duration, template);
  }
});

test("a template refuses a number of shots it cannot show", () => {
  assert.throws(() => composition({ template: "compare", shots: [shot("a.png")] }), /cannot show/);
  assert.throws(() => composition({ template: "flow", shots: [shot("a.png")] }), /cannot show/);
  assert.throws(() => composition({ template: "reel", shots: [] }), /Unknown template/);
});

test("a shot is never enlarged past its own pixels", () => {
  const { html } = composition({ template: "image", shots: [{ file: "a.png", width: 400, height: 200 }] });
  assert.match(html, /width:400px;height:200px/);
});

test("a flow's pointer lands where the shot was clicked", () => {
  const { html } = composition({
    template: "flow",
    shots: [shot("a.png", [0.5, 0.5]), shot("b.png")],
  });
  assert.match(html, /\{ x: 960, y: 540, opacity: 1,/);
});

const plan = (template, steps) => ({ highlights: [{ id: "tabs", plan: { template, steps } }] });

test("a plan keeps to its template's shots and to classes the interface has", () => {
  const shots = [step({ do: "shot", selector: ".sidebar-layout" })];
  const known = (name) => name === "sidebar-layout";
  assert.deepEqual(Object.keys(plansFrom(plan("hero", shots), known)), ["tabs"]);
  assert.throws(() => plansFrom(plan("compare", shots), known), /cannot show/);
  assert.throws(() => plansFrom(plan("hero", shots), () => false), /no source has/);
});

test("a highlight without a plan needs nothing", () => {
  assert.deepEqual(plansFrom({ highlights: [{ id: "tabs", plan: null }] }, () => false), {});
});

test("only rendered highlights gain media", () => {
  assert.deepEqual(withMedia([{ id: "tabs" }, { id: "calm" }], { tabs: "loop" }), [
    { id: "tabs", media: "loop" },
    { id: "calm" },
  ]);
});
