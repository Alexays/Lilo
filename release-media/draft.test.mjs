import assert from "node:assert/strict";
import { test } from "node:test";
import { parseNotes, storyFrom, whatsNewFrom, withReleaseCopy, worthAnEntry } from "./draft.mjs";

const notes = parseNotes(`## [1.2.0] - 2026-01-02

### Added

- Tabs gather into stacks.
- The sidebar folds to icons.

### Fixed

- A dropped link opens where you left it.
`);
const copy = { en: "Copy.", fr: "Texte." };
const draft = {
  title: copy,
  introduction: copy,
  highlights: [{ id: "tab-stacks", title: copy, body: copy, notes: [0], illustration: "stacks" }],
  groups: [{ title: copy, notes: [1, 2] }],
};

test("reads each note with its kind", () => {
  assert.deepEqual(notes[2], { kind: "Fixed", text: "A dropped link opens where you left it." });
});

test("a release of fixes alone gets no entry", () => {
  assert.equal(worthAnEntry(notes), true);
  assert.equal(worthAnEntry(notes.slice(2)), false);
});

test("a story quotes its notes exactly", () => {
  const story = storyFrom("1.2.0", draft, notes);
  assert.deepEqual(story.highlights[0].notes, ["Tabs gather into stacks."]);
  assert.deepEqual(story.groups[0].notes, [
    "The sidebar folds to icons.",
    "A dropped link opens where you left it.",
  ]);
});

for (const [name, change, message] of [
  ["leaves a note out", { groups: [{ title: copy, notes: [1] }] }, /without a place: 2/],
  ["repeats a grouped note", { groups: [{ title: copy, notes: [1, 1, 2] }] }, /single group/],
  ["cites a note that does not exist", { groups: [{ title: copy, notes: [1, 2, 9] }] }, /Note 9/],
  ["has no highlight", { highlights: [] }, /one to three/],
  ["has an id the site refuses", { highlights: [{ ...draft.highlights[0], id: "Tab" }] }, /kebab/],
]) {
  test(`a draft that ${name} is refused`, () => {
    assert.throws(() => storyFrom("1.2.0", { ...draft, ...change }, notes), message);
  });
}

test("What's New keys follow the highlight ids", () => {
  const whatsNew = whatsNewFrom("1.2.0", draft, storyFrom("1.2.0", draft, notes), ["stacks"]);
  assert.equal(whatsNew.key, "v120");
  assert.equal(whatsNew.entry.highlights[0].titleKey, "whatsNew.releases.v120.tabStacksTitle");
  assert.equal(whatsNew.entry.highlights[0].illustration, "stacks");
  assert.deepEqual(
    whatsNew.copy({
      headline: "H",
      description: "D",
      highlights: [{ title: "T", description: "B" }],
    }),
    { headline: "H", description: "D", tabStacksTitle: "T", tabStacksDescription: "B" },
  );
});

test("a highlight whose illustration WhatsNewArt does not draw is refused", () => {
  const story = storyFrom("1.2.0", draft, notes);
  assert.throws(() => whatsNewFrom("1.2.0", draft, story, ["calm"]), /does not draw/);
});

test("release copy goes in as text and leaves the rest of the catalog untouched", () => {
  const catalog = `{\n\t"whatsNew": {\n\t\t"releases": {\n\t\t\t"v110": { "headline": "Old" }\n\t\t}\n\t}\n}\n`;
  const updated = withReleaseCopy(catalog, "v120", { headline: 'A "new" one' });
  assert.equal(
    updated,
    `{\n\t"whatsNew": {\n\t\t"releases": {\n\t\t\t"v120": {\n\t\t\t\t"headline": "A \\"new\\" one"\n\t\t\t},\n\t\t\t"v110": { "headline": "Old" }\n\t\t}\n\t}\n}\n`,
  );
  assert.equal(JSON.parse(updated).whatsNew.releases.v120.headline, 'A "new" one');
});
