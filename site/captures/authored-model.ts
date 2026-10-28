import { z } from "zod";

export const featureID = z.string().regex(/^[a-z][a-z0-9-]{0,47}$/u);
const copy = z.string().trim().min(1).max(600);
const sourceNote = z.string().trim().min(1).max(8000);
const reason = z.string().trim().min(20).max(1200);

export const selectionSchema = z.strictObject({
  decisions: z.array(
    z.strictObject({
      mode: z.enum(["capture", "text"]),
      note: sourceNote,
      reason,
    })
  ),
  description: copy,
  headline: copy,
  highlights: z
    .array(
      z.strictObject({
        description: copy,
        id: featureID,
        notes: z.array(sourceNote).min(1),
        reason,
        title: copy,
      })
    )
    .max(3),
  noMediaReason: z.string().max(1200),
  version: z.string().regex(/^\d+\.\d+\.\d+$/u),
});

export type Selection = z.infer<typeof selectionSchema>;

export const validateSelection = (
  input: Selection,
  version: string,
  notes: string[]
) => {
  const plan = selectionSchema.parse(input);

  if (plan.version !== version) {
    throw new Error("Selection version does not match the release");
  }

  const decisions = new Map(plan.decisions.map((d) => [d.note, d.mode]));
  const selected = plan.highlights.flatMap((h) => h.notes);

  if (
    decisions.size !== notes.length ||
    decisions.size !== plan.decisions.length ||
    notes.some((n) => !decisions.has(n)) ||
    plan.decisions.some((d) => !notes.includes(d.note)) ||
    new Set(plan.highlights.map((h) => h.id)).size !== plan.highlights.length ||
    new Set(selected).size !== selected.length ||
    selected.some((n) => decisions.get(n) !== "capture") ||
    plan.decisions.some(
      (d) => d.mode === "capture" && !selected.includes(d.note)
    )
  ) {
    throw new Error(
      "Selection coverage must account for every exact release note once"
    );
  }

  if (!plan.highlights.length && plan.noMediaReason.trim().length < 20) {
    throw new Error("A maintenance release needs an explicit no-media reason");
  }

  return plan;
};

const target = z.strictObject({
  selector: z.string().min(1).max(500),
  surface: z.enum(["chrome", "page", "peek", "native"]),
  text: z.string().max(300),
});

const predicate = z.union([
  z.strictObject({ kind: z.enum(["visible", "absent"]), target }),
  z.strictObject({ includes: copy, kind: z.literal("text"), target }),
  z.strictObject({
    equals: z.number().int().nonnegative().max(100),
    kind: z.literal("count"),
    target,
  }),
  z.strictObject({
    kind: z.literal("attribute"),
    name: z.string().regex(/^[a-zA-Z][a-zA-Z0-9-]*$/u),
    target,
    value: z.string().max(500),
  }),
  z.strictObject({
    comparison: z.enum(["equals", "greater"]),
    kind: z.literal("property"),
    name: z.enum([
      "value",
      "checked",
      "selectedIndex",
      "open",
      "videoWidth",
      "videoHeight",
      "naturalWidth",
      "paused",
    ]),
    target,
    value: z.union([z.string().max(500), z.number(), z.boolean()]),
  }),
  z.strictObject({ kind: z.literal("selected-tab"), tab: featureID }),
  z.strictObject({
    kind: z.literal("shared-tab"),
    tab: z.string().regex(/^(?:[a-z][a-z0-9-]{0,47})?$/u),
  }),
  z.strictObject({
    equals: z.number().int().nonnegative().max(5),
    kind: z.literal("peek-count"),
  }),
  z.strictObject({
    key: z.string().min(1).max(100),
    kind: z.literal("setting"),
    value: z.string().max(300),
  }),
]);

export const stepSchema = z.union([
  z.strictObject({
    durationMs: z.number().int().min(300).max(3000),
    type: z.literal("hold"),
  }),
  z.strictObject({
    button: z.enum(["left", "right"]),
    count: z.number().int().min(1).max(2),
    modifiers: z.array(z.enum(["shift", "command", "option", "control"])),
    target,
    type: z.literal("click"),
  }),
  z.strictObject({
    replace: z.boolean(),
    target,
    text: z.string().min(1).max(1000),
    type: z.literal("type"),
  }),
  z.strictObject({
    chord: z.enum([
      "Return",
      "Enter",
      "Escape",
      "Tab",
      "Shift+Tab",
      "ArrowUp",
      "ArrowDown",
      "ArrowLeft",
      "ArrowRight",
      "Backspace",
      "Delete",
      "Space",
      "Home",
      "End",
      "PageUp",
      "PageDown",
      "cmd+a",
    ]),
    surface: z.enum(["chrome", "page", "peek"]),
    type: z.literal("key"),
  }),
  z.strictObject({
    selector: z.enum([
      "openSettings:",
      "openLocation:",
      "showWhatsNew:",
      "toggleSidebarVisibility:",
      "toggleToolbarVisibility:",
      "showFindBar:",
      "newTab:",
      "closeCurrentTab:",
      "pinCurrentTab:",
      "bookmarkCurrentTab:",
      "toggleReader:",
      "newSplitView:",
      "closeSplitView:",
      "showNextTab:",
      "showPreviousTab:",
    ]),
    type: z.literal("menu"),
  }),
  z.strictObject({
    durationMs: z.number().int().min(650).max(1400),
    from: target,
    to: target,
    type: z.literal("drag"),
  }),
  z.strictObject({ id: featureID, predicate, type: z.literal("assert") }),
]);

export const scenarioSchema = z.strictObject({
  evidence: z
    .array(z.string().regex(/^(?:Lilo|lilo-ui)\/[a-zA-Z0-9_./+ -]+$/u))
    .min(1)
    .max(8),
  fixtures: z
    .array(
      z.strictObject({
        html: z.string().min(20).max(64_000),
        name: z.string().regex(/^[a-z][a-z0-9-]{0,47}\.html$/u),
      })
    )
    .min(1)
    .max(6),
  goal: reason,
  id: featureID,
  posterCheckpoint: featureID,
  settings: z
    .array(
      z.strictObject({
        key: z.string().min(1).max(100),
        value: z.string().max(300),
      })
    )
    .max(6),
  steps: z.array(stepSchema).min(4).max(28),
  tabs: z
    .array(z.strictObject({ id: featureID, page: z.string() }))
    .min(1)
    .max(8),
});

export type AuthoredScenario = z.infer<typeof scenarioSchema>;

export const scenarioCheckpoints = (scenario: AuthoredScenario) =>
  scenario.steps.filter((s) => s.type === "assert").map((s) => s.id);

const semanticContract = (scenario: AuthoredScenario) =>
  JSON.stringify({
    assertions: scenario.steps
      .filter((step) => step.type === "assert")
      .map((step) => ({
        id: step.id,
        predicate: Object.fromEntries(
          Object.entries(step.predicate).filter(([key]) => key !== "target")
        ),
        surface:
          "target" in step.predicate ? step.predicate.target.surface : "",
      })),
    goal: scenario.goal,
    id: scenario.id,
    poster: scenario.posterCheckpoint,
  });

export const validateRepairContract = (
  original: AuthoredScenario,
  repaired: AuthoredScenario
) => {
  if (semanticContract(original) !== semanticContract(repaired)) {
    throw new Error(
      "A repair changed the frozen semantic contract; retain goal, checkpoints, expected results and poster state"
    );
  }
};

const validateScenarioReferences = (scenario: AuthoredScenario) => {
  const pages = new Set(scenario.fixtures.map((fixture) => fixture.name));
  const tabs = new Set(scenario.tabs.map((tab) => tab.id));

  for (const match of JSON.stringify(scenario).matchAll(
    /\{\{(?<kind>tab|fixture):(?<reference>[^}]+)\}\}/gu
  )) {
    if (
      !(match.groups?.kind === "tab" ? tabs : pages).has(
        match.groups?.reference ?? ""
      )
    ) {
      throw new Error("Unknown authored template reference");
    }
  }

  for (const step of scenario.steps) {
    if (
      step.type === "assert" &&
      (step.predicate.kind === "selected-tab" ||
        step.predicate.kind === "shared-tab") &&
      step.predicate.tab &&
      !tabs.has(step.predicate.tab)
    ) {
      throw new Error("Unknown authored tab reference");
    }

    if (
      (step.type === "type" && step.target.surface === "native") ||
      (step.type === "assert" &&
        "target" in step.predicate &&
        step.predicate.target.surface === "native" &&
        !["visible", "absent"].includes(step.predicate.kind))
    ) {
      throw new Error("Unsupported native action or predicate");
    }
  }
};

const validateScenarioHolds = (scenario: AuthoredScenario) => {
  const finalPresentation = scenario.steps.at(-1);

  const posterIndex = scenario.steps.findIndex(
    (step) => step.type === "assert" && step.id === scenario.posterCheckpoint
  );

  const posterHold = scenario.steps
    .slice(posterIndex + 1)
    .find((step) => step.type !== "assert");

  if (
    finalPresentation?.type !== "hold" ||
    finalPresentation.durationMs < 2000 ||
    posterHold?.type !== "hold" ||
    posterHold.durationMs < 2000
  ) {
    throw new Error(
      "Poster and final states require a readable two-second hold"
    );
  }
};

export const validateScenario = (input: AuthoredScenario, id: string) => {
  const scenario = scenarioSchema.parse(input);
  const checkpoints = scenarioCheckpoints(scenario);
  const pages = new Set(scenario.fixtures.map((f) => f.name));

  if (scenario.id !== id) {
    throw new Error("Authored scenario changed the selected feature ID");
  }

  if (
    checkpoints.length < 2 ||
    new Set(checkpoints).size !== checkpoints.length ||
    !checkpoints.includes(scenario.posterCheckpoint)
  ) {
    throw new Error(
      "A scenario needs distinct semantic checkpoints and a valid poster checkpoint"
    );
  }

  if (
    pages.size !== scenario.fixtures.length ||
    scenario.tabs.some((t) => !pages.has(t.page)) ||
    new Set(scenario.tabs.map((t) => t.id)).size !== scenario.tabs.length
  ) {
    throw new Error("Invalid or duplicate fixture/tab reference");
  }

  if (scenario.evidence.some((p) => p.split("/").includes(".."))) {
    throw new Error("Source evidence must stay inside the repository");
  }

  validateScenarioReferences(scenario);
  validateScenarioHolds(scenario);
  let holds = 0;

  for (const step of scenario.steps) {
    if (step.type === "hold" || step.type === "drag") {
      holds += step.durationMs;
    } else if (step.type === "click" || step.type === "type") {
      holds += 1100;
    }
  }

  if (
    holds > 14_500 ||
    !scenario.steps.some((s) => s.type === "hold" && s.durationMs >= 2000)
  ) {
    throw new Error(
      "Scenario pacing must include a readable hold and fit the native movie budget"
    );
  }

  return scenario;
};

export const editorialCopySchema = z.strictObject({
  description: copy,
  headline: copy,
  highlights: z
    .array(z.strictObject({ description: copy, id: featureID, title: copy }))
    .max(3),
});

export type EditorialCopy = z.infer<typeof editorialCopySchema>;

export const editorialSchema = (locales: string[]) =>
  z.strictObject(
    Object.fromEntries(locales.map((locale) => [locale, editorialCopySchema]))
  );

export const validateEditorial = (
  input: Record<string, EditorialCopy>,
  plan: Selection,
  locales: string[]
) => {
  const content = editorialSchema(locales).parse(input);

  for (const value of Object.values(content)) {
    if (
      value.highlights.map((h) => h.id).join("\0") !==
      plan.highlights.map((h) => h.id).join("\0")
    ) {
      throw new Error(
        "Translated highlights must retain the frozen selected features and order"
      );
    }
  }

  return content;
};

export const reviewSchema = z.strictObject({
  passed: z.boolean(),
  problems: z.array(z.string().max(2000)).max(12),
});

export type Review = z.infer<typeof reviewSchema>;

export const requireReview = (review: Review, stage: string) => {
  if (!review.passed || review.problems.length) {
    throw new Error(
      `${stage} failed quality: ${review.problems.join("; ")}; release blocked`
    );
  }
};
