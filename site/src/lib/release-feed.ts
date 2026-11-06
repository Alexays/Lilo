import rss from "@astrojs/rss";

import { copy, localizedPath } from "./i18n";
import type { Locale } from "./i18n";
import { releases, stories } from "./release-entries";

export const releaseFeed = (lang: Locale, site: URL | undefined) =>
  rss({
    customData: `<language>${lang}</language>`,
    description: copy[lang].changelogDescription,
    items: releases.slice(0, 30).map((release) => {
      const story = stories.get(release.version);

      return {
        content: release.html,
        description: story?.introduction[lang],
        link: localizedPath(lang, `changelog/${release.version}/`),
        pubDate: new Date(`${release.date}T00:00:00Z`),
        title: story?.title[lang] ?? `Lilo ${release.version}`,
      };
    }),
    site: site ?? "https://getlilo.app",
    title: copy[lang].changelogTitle,
  });
