import type { AuthoredArchive } from "../../captures/authored-archive.ts";
import type { ReleaseStory } from "./release-stories.ts";

export const storyFromArchive = (
  archive: AuthoredArchive
): ReleaseStory | null => {
  if (!archive.plan.highlights.length) {
    return null;
  }

  const { en, fr } = archive.content;

  if (!en || !fr) {
    throw new Error("Approved release stories require English and French");
  }

  return {
    highlights: archive.plan.highlights.map((highlight, index) => ({
      body: {
        en: en.highlights[index].description,
        fr: fr.highlights[index].description,
      },
      capture: {
        highlight: highlight.id,
        scenario: highlight.id,
        source: "native",
      },
      id: highlight.id,
      notes: highlight.notes,
      title: { en: en.highlights[index].title, fr: fr.highlights[index].title },
    })),
    introduction: { en: en.description, fr: fr.description },
    title: { en: en.headline, fr: fr.headline },
    version: archive.release,
  };
};
