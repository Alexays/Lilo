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
        body,
        date: heading[2],
        html: marked.parse(`${body}\n\n${references}`, { async: false }),
        version: heading[1],
      };
    })
    .toSorted((a, b) =>
      b.version.localeCompare(a.version, "en", { numeric: true })
    );
};

export const sourceReleaseNotes = (body: string): string[] => {
  const notes: string[] = [];
  let active = -1;

  for (const line of body.split(/\r?\n/u)) {
    if (line.startsWith("- ")) {
      notes.push(line.slice(2));
      active = notes.length - 1;
    } else if (active >= 0 && /^\s+\S/u.test(line)) {
      notes[active] += `\n${line.trim()}`;
    } else if (line.trim()) {
      active = -1;
    }
  }

  return notes;
};
