import { copy, localizedPath } from "./i18n";
import type { Locale } from "./i18n";
import { releases, stories } from "./release-entries";

const site = "https://getlilo.app";

const escaped = (text: string) =>
  text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");

export const releaseFeed = (lang: Locale) => {
  const text = copy[lang];

  const items = releases.slice(0, 30).map((release) => {
    const story = stories.get(release.version);
    const url = `${site}${localizedPath(lang, `changelog/${release.version}/`)}`;
    const title = story?.title[lang] ?? `Lilo ${release.version}`;
    const body = story?.introduction[lang] ?? release.html;

    return `
    <item>
      <title>${escaped(title)}</title>
      <link>${url}</link>
      <guid>${url}</guid>
      <pubDate>${new Date(`${release.date}T00:00:00Z`).toUTCString()}</pubDate>
      <description>${escaped(body)}</description>
    </item>`;
  });

  return new Response(
    `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>${escaped(text.changelogTitle)}</title>
    <link>${site}${localizedPath(lang, "changelog/")}</link>
    <description>${escaped(text.changelogDescription)}</description>
    <language>${lang}</language>${items.join("")}
  </channel>
</rss>
`,
    { headers: { "Content-Type": "application/rss+xml; charset=utf-8" } }
  );
};
