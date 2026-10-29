import assert from "node:assert/strict";
import test from "node:test";

import { z } from "zod";

import type {
  AuthoredScenario,
  Selection,
} from "../captures/authored-model.ts";
import {
  scenarioSchema,
  validateSelection,
  validateRepairContract,
  validateScenario,
  validateEditorial,
} from "../captures/authored-model.ts";
import { sourceReleaseNotes } from "../src/lib/changelog.ts";

const notes = ["Tabs show unread counts.", "Improves background storage."];

const selection = (): Selection => ({
  decisions: notes.map((note, i) => ({
    mode: i === 0 ? "capture" : "text",
    note,
    reason:
      i === 0
        ? "The count is a visible new feature."
        : "Internal storage has no honest visual demonstration.",
  })),
  description: "See what changed.",
  headline: "Keep up.",
  highlights: [
    {
      description: "Unread counts stay by your tabs.",
      id: "unread-counts",
      notes: [notes[0]],
      reason: "This is the release's main visible browsing improvement.",
      title: "Catch up.",
    },
  ],
  noMediaReason: "",
  version: "0.9.0",
});

const scenario = (): AuthoredScenario => ({
  evidence: ["Lilo/Window/MainWindowController.swift"],
  fixtures: [
    {
      html: "<!doctype html><title>Studio inbox</title><h1>Inbox</h1>",
      name: "inbox.html",
    },
  ],
  goal: "Show a real native unread badge appearing and clearing.",
  id: "unread-counts",
  posterCheckpoint: "badge-shown",
  settings: [],
  steps: [
    { durationMs: 600, type: "hold" },
    {
      id: "badge-shown",
      predicate: {
        kind: "visible",
        target: { selector: ".unread-badge", surface: "chrome", text: "" },
      },
      type: "assert",
    },
    { durationMs: 2100, type: "hold" },
    {
      id: "badge-cleared",
      predicate: {
        kind: "absent",
        target: { selector: ".unread-badge", surface: "chrome", text: "" },
      },
      type: "assert",
    },
    { durationMs: 2100, type: "hold" },
  ],
  tabs: [{ id: "inbox", page: "inbox.html" }],
});

test("ranking rationale cannot freeze an exhaustive execution inventory", () => {
  const plan = selection();
  plan.highlights[0].reason =
    "Highest-impact visible improvement: choosing and steering a presentation without returning to the call. One 12-second silent WebP: start in a real local call harness with a visible receiving preview, search the picker for a generic page, select it with the keyboard, show another tab, click Share this tab, then stop. Use readable holds after selection, replacement and stopping. Native assertions must confirm the first shared tab identity, the replacement identity with the same active share token, and the share ending while the call remains active. The receiving preview must visibly follow both real pages. Do not fabricate call state or claim measured frame rates.";

  assert.throws(() => validateSelection(plan, "0.9.0", notes), z.ZodError);
});

test("selection accepts previously unknown features but accounts for every exact release note", () => {
  assert.equal(
    validateSelection(selection(), "0.9.0", notes).highlights[0].id,
    "unread-counts"
  );
  assert.throws(
    () =>
      validateSelection(
        { ...selection(), decisions: selection().decisions.slice(0, 1) },
        "0.9.0",
        notes
      ),
    /coverage/u
  );
  assert.throws(
    () =>
      validateSelection(
        {
          ...selection(),
          highlights: [
            { ...selection().highlights[0], notes: ["Invented feature."] },
          ],
        },
        "0.9.0",
        notes
      ),
    /notes|coverage/u
  );
  assert.throws(
    () => validateSelection(selection(), "0.8.0", notes),
    /version/u
  );
});

test("no-media decisions need an explicit reason and cannot hide selected notes", () => {
  assert.throws(
    () => validateSelection({ ...selection(), highlights: [] }, "0.9.0", notes),
    /maintenance|coverage/u
  );

  const maintenance: Selection = {
    ...selection(),
    decisions: notes.map((note) => ({
      mode: "text",
      note,
      reason: "No visible interface or demonstrable flow changed.",
    })),
    highlights: [],
    noMediaReason: "Only nonvisual storage maintenance was shipped.",
  };

  assert.equal(
    validateSelection(maintenance, "0.9.0", notes).highlights.length,
    0
  );
});

test("authored scenarios require real observable checkpoints and safe fixture references", () => {
  assert.equal(
    validateScenario(scenario(), "unread-counts").id,
    "unread-counts"
  );
  assert.throws(() => scenarioSchema.parse({ ...scenario(), id: "../escape" }));
  assert.throws(() =>
    validateScenario(
      { ...scenario(), fixtures: [{ html: "fake", name: "../inbox.html" }] },
      "unread-counts"
    )
  );
  assert.throws(() =>
    scenarioSchema.parse({
      ...scenario(),
      steps: [
        { code: "document.body.innerHTML='fake chrome'", type: "script" },
      ],
    })
  );
  assert.throws(
    () =>
      validateScenario(
        { ...scenario(), posterCheckpoint: "unknown" },
        "unread-counts"
      ),
    /checkpoint/u
  );
  assert.throws(
    () =>
      validateScenario(
        { ...scenario(), tabs: [{ id: "inbox", page: "missing.html" }] },
        "unread-counts"
      ),
    /fixture/u
  );
  assert.throws(
    () =>
      validateScenario(
        {
          ...scenario(),
          steps: Array.from({ length: 4 }, () => ({
            durationMs: 600,
            type: "hold",
          })),
        },
        "unread-counts"
      ),
    /checkpoint/u
  );
});

test("generated copy covers every app locale and retains the frozen feature IDs", () => {
  const copy = {
    description: "The latest changes.",
    headline: "Keep up.",
    highlights: [
      {
        description: "See unread counts.",
        id: "unread-counts",
        title: "Catch up.",
      },
    ],
  };

  const content = { en: copy, fr: { ...copy, headline: "Gardez le fil." } };
  assert.equal(
    validateEditorial(content, selection(), ["en", "fr"]).fr.headline,
    "Gardez le fil."
  );
  assert.throws(() =>
    validateEditorial({ en: copy }, selection(), ["en", "fr"])
  );
  assert.throws(
    () =>
      validateEditorial(
        { en: copy, fr: { ...copy, highlights: [] } },
        selection(),
        ["en", "fr"]
      ),
    /highlights|features/u
  );
});

test("repairs may fix selectors but cannot replace semantic assertions or drop their expected results", () => {
  const original = scenario();
  const repaired = scenario();
  const [, first] = repaired.steps;

  if (first.type !== "assert" || first.predicate.kind !== "visible") {
    throw new Error("Invalid test fixture");
  }

  first.predicate.target.selector = ".real-unread-badge";
  assert.doesNotThrow(() => validateRepairContract(original, repaired));
  repaired.steps.splice(1, 1);
  assert.throws(
    () => validateRepairContract(original, repaired),
    /semantic|contract/u
  );
  const weakened = scenario();
  weakened.steps[1] = {
    id: "badge-shown",
    predicate: { kind: "selected-tab", tab: "inbox" },
    type: "assert",
  };
  assert.throws(
    () => validateRepairContract(original, weakened),
    /semantic|contract/u
  );
});

test("native scenario structured output uses unions accepted by the strict authoring API", () => {
  const schema = JSON.stringify(z.toJSONSchema(scenarioSchema));
  assert.doesNotMatch(schema, /"oneOf":/u);
  assert.match(schema, /"anyOf":/u);
});

test("a scenario must hold after its final semantic checkpoint", () => {
  const input = scenario();
  input.steps.pop();
  assert.throws(() => validateScenario(input, "unread-counts"), /final|hold/u);
});

test("authored menu actions cannot launch shells or inspect host processes", () => {
  for (const selector of ["newTerminalTab:", "openProcessManager:"]) {
    const input = scenario();
    assert.throws(
      () =>
        scenarioSchema.parse({
          ...input,
          steps: [...input.steps, { selector, type: "menu" }],
        }),
      /menu|action|Invalid/u
    );
  }
});

test("authored keys cannot trigger global app or terminal shortcuts", () => {
  for (const chord of ["cmd+q", "ctrl+shift+t", "cmd+v"]) {
    assert.throws(() =>
      scenarioSchema.parse({
        ...scenario(),
        steps: [...scenario().steps, { chord, surface: "chrome", type: "key" }],
      })
    );
  }
});

test("selection coverage includes every continuation of a release note", () => {
  assert.deepEqual(
    sourceReleaseNotes(
      "### Added\n\n- A visible improvement.\n  Including its important second detail.\n\n- Another feature.\n\n### Fixed\n\n- A reliability fix.\n"
    ),
    [
      "A visible improvement.\nIncluding its important second detail.",
      "Another feature.",
      "A reliability fix.",
    ]
  );
});
