// Writes the reference partials that the reference pages include, from the files that define them,
// so the tables cannot drift from the app. Runs before every Blume command. Its output must be
// deterministic: the translation ledger compares a hash of each English partial. It never writes the
// French partials that `blume translate` produces (MCP tools, compatibility).
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const docs = fileURLToPath(new URL("..", import.meta.url));

/** Partial path, relative to docs-site/, to its Markdown. Filled in by the reference package. */
export const partials = () => ({
  "content/reference/_generated/shortcuts.md": "",
  "content/fr/reference/_generated/shortcuts.md": "",
  "content/reference/_generated/settings.md": "",
  "content/fr/reference/_generated/settings.md": "",
  "content/reference/_generated/mcp-tools.md": "",
  "content/reference/_generated/extension-compatibility.md": "",
  "content/reference/_generated/web-compatibility.md": "",
});

function write(path, text) {
  const file = `${docs}${path}`;
  let current;
  try {
    current = readFileSync(file, "utf-8");
  } catch {
    current = undefined;
  }
  if (current !== text) {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, text);
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  for (const [path, text] of Object.entries(partials())) {
    write(path, text);
  }
}
