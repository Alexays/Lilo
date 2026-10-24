import { marked } from 'marked';

/** @param {string} markdown */
export function parseChangelog(markdown) {
  const headings = [...markdown.matchAll(/^## \[(\d+\.\d+\.\d+)\] - (\d{4}-\d{2}-\d{2})[ \t]*$/gm)];
  const references = markdown.match(/^\[[^\]]+\]: .+$/gm)?.join('\n') ?? '';
  return headings.map((heading, index) => {
    const body = markdown.slice(heading.index + heading[0].length, headings[index + 1]?.index).trim();
    return {
      version: heading[1],
      date: heading[2],
      html: marked.parse(`${body}\n\n${references}`, { async: false }),
    };
  }).sort((a, b) => b.version.localeCompare(a.version, 'en', { numeric: true }));
}
