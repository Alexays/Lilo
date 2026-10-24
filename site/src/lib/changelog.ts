import { marked } from "marked";

export const parseChangelog = (markdown: string) => {
  const headings = [
    ...markdown.matchAll(
      /^## \[(?<version>\d+\.\d+\.\d+)\] - (?<date>\d{4}-\d{2}-\d{2})[ \t]*$/gmu
    ),
  ];

  const references = markdown.match(/^\[[^\]]+\]: .+$/gmu)?.join("\n") ?? "";

  return headings
    .map((heading, index) => {
      const body = markdown
        .slice(heading.index + heading[0].length, headings[index + 1]?.index)
        .trim();

      return {
        date: heading[2],
        html: marked.parse(`${body}\n\n${references}`, { async: false }),
        version: heading[1],
      };
    })
    .toSorted((a, b) =>
      b.version.localeCompare(a.version, "en", { numeric: true })
    );
};
