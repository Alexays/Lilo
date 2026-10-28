import { z } from "zod";

import { parseChangelog, sourceReleaseNotes } from "./changelog.ts";

const translatedText = z.strictObject({
  en: z.string().trim().min(1),
  fr: z.string().trim().min(1),
});

const storySchema = z.strictObject({
  capture: z
    .strictObject({
      highlight: z.string().min(1),
      scenario: z.string().regex(/^[a-z][a-z0-9-]{0,47}$/u),
      source: z.enum(["demo", "native"]).default("demo"),
    })
    .optional(),
  highlights: z
    .array(
      z.strictObject({
        action: z
          .strictObject({
            href: translatedText,
            label: translatedText,
          })
          .optional(),
        body: translatedText,
        capture: z
          .strictObject({
            highlight: z.string().min(1),
            scenario: z.string().regex(/^[a-z][a-z0-9-]{0,47}$/u),
            source: z.literal("native"),
          })
          .optional(),
        id: z.string().regex(/^[a-z][a-z0-9-]*$/u),
        notes: z.array(z.string().min(1)).min(1),
        title: translatedText,
      })
    )
    .min(1)
    .max(3),
  introduction: translatedText,
  title: translatedText,
  version: z.string().regex(/^\d+\.\d+\.\d+$/u),
});

export type ReleaseStory = z.infer<typeof storySchema>;

export const parseReleaseStories = (markdown: string, entries: unknown[]) => {
  const releases = parseChangelog(markdown);
  const stories = new Map<string, ReleaseStory>();

  for (const entry of entries) {
    const story = storySchema.parse(entry);
    const release = releases.find((item) => item.version === story.version);

    if (!release || stories.has(story.version)) {
      throw new Error(
        `Missing or duplicate release for story ${story.version}`
      );
    }

    const notes = new Set(sourceReleaseNotes(release.body));

    const ids = new Set(story.highlights.map((highlight) => highlight.id));

    if (
      ids.size !== story.highlights.length ||
      (story.capture && !ids.has(story.capture.highlight))
    ) {
      throw new Error(`Invalid highlight IDs in story ${story.version}`);
    }

    for (const highlight of story.highlights) {
      if (highlight.capture && highlight.capture.highlight !== highlight.id) {
        throw new Error(`Recording must belong to highlight ${highlight.id}`);
      }

      if (!highlight.notes.every((note) => notes.has(note))) {
        throw new Error(
          `Highlight ${highlight.id} is not sourced from release ${story.version}`
        );
      }
    }

    stories.set(story.version, story);
  }

  return stories;
};
