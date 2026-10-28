import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { parseChangelog } from "../src/lib/changelog.ts";
import { parseReleaseStories } from "../src/lib/release-stories.ts";

test("preserves every version in Changie’s imported release history", () => {
  const source = readFileSync(
    new URL("../../CHANGELOG.md", import.meta.url),
    "utf-8"
  );

  const releases = parseChangelog(source);

  const versions = [...source.matchAll(/^## \[(?<version>[^\]]+)\] - /gmu)].map(
    (match) => match[1]
  );

  assert.deepEqual(
    releases.map((release) => release.version),
    versions
  );
  assert.match(releases.at(-1)?.html ?? "", /First public release/u);
});

test("renders a new release, Markdown and shared reference links without showing unreleased notes", () => {
  const releases = parseChangelog(`# Changelog

## [Unreleased]

- Not published yet.

## [0.9.0] - 2026-10-20

### Fixed

- Read [the docs][guide] and use \`Command K\`.

## [0.10.0] - 2026-10-24

### Added

- A **new feature**.

[guide]: https://getlilo.app/moving/
`);

  assert.deepEqual(
    releases.map((release) => release.version),
    ["0.10.0", "0.9.0"]
  );
  assert.equal(releases[0].date, "2026-10-24");
  assert.match(releases[0].html, /<strong>new feature<\/strong>/u);
  assert.match(releases[1].html, /href="https:\/\/getlilo.app\/moving\/"/u);
  assert.match(releases[1].html, /<code>Command K<\/code>/u);
  assert.doesNotMatch(
    releases.map((release) => release.html).join(""),
    /Not published yet/u
  );
});

const storyHistory = `# Changelog

## [0.9.0] - 2026-10-28

### Added

- Try a link in Peek.

## [0.8.0] - 2026-10-27

### Fixed

- Keep the source tab selected.
`;

const exampleStory = () => ({
  capture: { highlight: "peek", scenario: "peek" },
  highlights: [
    {
      body: {
        en: "Open a link over the page.",
        fr: "Ouvrez un lien en aperçu.",
      },
      id: "peek",
      notes: ["Try a link in Peek."],
      title: { en: "Keep your place.", fr: "Gardez le fil." },
    },
  ],
  introduction: {
    en: "A quick look at a link.",
    fr: "Un coup d'œil à un lien.",
  },
  title: { en: "Peek", fr: "Aperçu" },
  version: "0.9.0",
});

test("release stories can use a recording from installed Lilo", () => {
  const story = exampleStory();

  const native = {
    ...story,
    capture: { ...story.capture, source: "native" },
  };

  assert.equal(
    parseReleaseStories(storyHistory, [native]).get(native.version)?.capture
      ?.source,
    "native"
  );
});

test("release stories can omit the recording", () => {
  const { capture: _capture, ...story } = exampleStory();

  assert.equal(
    parseReleaseStories(storyHistory, [story]).get(story.version)?.capture,
    undefined
  );
});

test("joins a story to its release while leaving ordinary releases available", () => {
  const stories = parseReleaseStories(storyHistory, [exampleStory()]);

  assert.equal(stories.get("0.9.0")?.highlights[0].title.fr, "Gardez le fil.");
  assert.equal(stories.has("0.8.0"), false);
  assert.equal(parseChangelog(storyHistory).length, 2);
  assert.equal(stories.get("0.9.0")?.highlights[0].action, undefined);
});

test("a highlight action is optional and requires both translated labels and destinations", () => {
  const base = exampleStory();

  const withAction = {
    ...base,
    highlights: [
      {
        ...base.highlights[0],
        action: {
          href: { en: "/#browser-demo", fr: "/fr/#browser-demo" },
          label: { en: "Try in the demo", fr: "Essayer dans la démo" },
        },
      },
    ],
  };

  assert.equal(
    parseReleaseStories(storyHistory, [withAction]).get("0.9.0")?.highlights[0]
      .action?.href.fr,
    "/fr/#browser-demo"
  );
  assert.throws(() =>
    parseReleaseStories(storyHistory, [
      {
        ...withAction,
        highlights: [
          {
            ...withAction.highlights[0],
            action: { href: { en: "/" }, label: { en: "Try", fr: "Essayer" } },
          },
        ],
      },
    ])
  );
});

test("rejects a story sourced from another release or an unpublished version", () => {
  const otherRelease = exampleStory();
  otherRelease.highlights[0].notes = ["Keep the source tab selected."];
  assert.throws(
    () => parseReleaseStories(storyHistory, [otherRelease]),
    /not sourced from release 0\.9\.0/u
  );
  assert.throws(
    () =>
      parseReleaseStories(storyHistory, [
        { ...exampleStory(), version: "0.10.0" },
      ]),
    /Missing or duplicate release/u
  );
});

test("rejects missing translations, duplicate releases and invalid capture references", () => {
  assert.throws(() =>
    parseReleaseStories(storyHistory, [
      { ...exampleStory(), title: { en: "Peek" } },
    ])
  );
  assert.throws(
    () => parseReleaseStories(storyHistory, [exampleStory(), exampleStory()]),
    /duplicate release/u
  );
  assert.throws(
    () =>
      parseReleaseStories(storyHistory, [
        {
          ...exampleStory(),
          capture: { highlight: "missing", scenario: "peek" },
        },
      ]),
    /Invalid highlight IDs/u
  );
  const duplicate = exampleStory();
  duplicate.highlights.push(duplicate.highlights[0]);
  assert.throws(
    () => parseReleaseStories(storyHistory, [duplicate]),
    /Invalid highlight IDs/u
  );
});
