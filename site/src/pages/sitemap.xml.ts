import { localizedPath } from "../lib/i18n";
import type { Locale } from "../lib/i18n";

export const GET = () => {
  const site = "https://getlilo.app";
  const pages = ["", "moving/", "changelog/"];
  const languages: Locale[] = ["en", "fr"];

  const urls = pages.flatMap((page) =>
    languages.map(
      (lang) => `
  <url>
    <loc>${site}${localizedPath(lang, page)}</loc>
    <xhtml:link rel="alternate" hreflang="en" href="${site}${localizedPath("en", page)}"/>
    <xhtml:link rel="alternate" hreflang="fr" href="${site}${localizedPath("fr", page)}"/>
    <xhtml:link rel="alternate" hreflang="x-default" href="${site}${localizedPath("en", page)}"/>
  </url>`
    )
  );

  return new Response(
    `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">${urls.join("")}
</urlset>`,
    { headers: { "Content-Type": "application/xml; charset=utf-8" } }
  );
};
