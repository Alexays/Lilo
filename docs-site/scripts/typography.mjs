// French typography for the translated pages, run by `make docs-translate` after `blume translate`,
// which writes plain spaces whatever the locale style asks: a no-break space before `:` and inside
// « », a narrow one before `;` `?` `!`, and straight apostrophes. It only replaces an existing space,
// so it is idempotent, and leaves code, <kbd>, link targets and URLs alone.
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { GENERATOR_OWNED } from "./translations.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));
const PROTECTED = /```[\s\S]*?```|`[^`\n]*`|<kbd>[\s\S]*?<\/kbd>|\]\([^)]*\)|https?:\/\/\S+/g;

const fix = (text) =>
  text
    .replace(/ :(?=\s|$|\*)/gm, " :")
    .replace(/ ([;?!])(?=\s|$|\*|\)|»)/gm, " $1")
    .replaceAll("« ", "« ")
    .replaceAll(" »", " »")
    .replaceAll("’", "'");

/** The text with French typography outside its protected spans. */
export function typeset(text) {
  let out = "";
  let last = 0;
  for (const match of text.matchAll(PROTECTED)) {
    out += fix(text.slice(last, match.index)) + match[0];
    last = match.index + match[0].length;
  }
  return out + fix(text.slice(last));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const skip = new Set([...GENERATOR_OWNED].map((source) => source.replace("content/", "content/fr/")));
  for (const entry of readdirSync(`${root}content/fr`, { recursive: true })) {
    const path = `content/fr/${entry}`;
    if (!/\.mdx?$/.test(path) || skip.has(path)) continue;
    const text = readFileSync(root + path, "utf-8");
    const next = typeset(text);
    if (next !== text) {
      writeFileSync(root + path, next);
      console.log(`typography: ${path}`);
    }
  }
}
