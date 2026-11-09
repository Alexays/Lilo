// What the conversation view draws from the thread: light markdown, line diffs, and when an item changed.

import { IMAGE_FILE, type ThreadItem } from "./conversationModel";

export type Inline =
  | { type: "text" | "code" | "path" | "color" | "kbd" | "ref"; text: string }
  | { type: "strong"; inline: Inline[] }
  | { type: "em"; inline: Inline[] }
  | { type: "del"; inline: Inline[] }
  | { type: "link"; text: string; href: string }
  | { type: "image"; alt: string; src: string }
  | { type: "task"; checked: boolean };

export type Block =
  | { type: "p" | "quote"; inline: Inline[] }
  | { type: "heading"; level: number; inline: Inline[] }
  | { type: "code"; lang: string; text: string; nested?: true }
  | { type: "rule" }
  | { type: "note"; id: string; inline: Inline[] }
  | ListBlock
  | { type: "table"; align: ("left" | "center" | "right" | null)[]; head: Inline[][]; rows: Inline[][][] };

export type ListBlock = { type: "list"; ordered: boolean; start?: number; items: { inline: Inline[]; lists: ListBlock[] }[] };

const INLINE =
  /`([^`\n]+)`|\*\*([^*\n]+)\*\*|__([^_\n]+)__|(?<![\w*])\*([^*\s][^*\n]*)\*(?![\w*])|(?<![\w_])_([^_\s][^_\n]*)_(?![\w_])|!\[([^\]\n]*)\]\(([^)\s]+)\)|\[([^\]\n]+)\]\(([^)\s]+)\)|(https?:\/\/[^\s<>()]*[^\s<>().,;:!?'"])|(?<![\w/.:@-])((?:\.{1,2}\/|\/)?(?:[\w.@-]+\/)+[\w.-]*\.[A-Za-z][\w]*(?::\d+(?::\d+)?)?|[\w-][\w.-]*\.[A-Za-z]\w*:\d+(?::\d+)?)(?![\w/])|(?<![\w#&])(#(?=[\da-fA-F]*[a-fA-F])(?:[\da-fA-F]{8}|[\da-fA-F]{6}))(?!\w)|~~([^~\n]+)~~|<kbd>([^<\n]+)<\/kbd>|\[\^([^\]\s]+)\]/g;

/** A hex colour a code span may hold whole; prose takes only 6 or 8 digits with a letter, never an issue number. */
export const HEX_COLOR = /^#(?:[\da-f]{3,4}|[\da-f]{6}|[\da-f]{8})$/i;

const SAFE_LINK = /^(https?:|mailto:)/i;

export function parseInline(text: string): Inline[] {
  const out: Inline[] = [];
  let last = 0;
  for (const match of text.matchAll(INLINE)) {
    const index = match.index;
    if (index > last) out.push({ type: "text", text: text.slice(last, index) });
    last = index + match[0].length;
    if (match[1] !== undefined) out.push({ type: "code", text: match[1] });
    else if (match[2] !== undefined || match[3] !== undefined) out.push({ type: "strong", inline: parseInline(match[2] ?? match[3]) });
    else if (match[4] !== undefined || match[5] !== undefined) out.push({ type: "em", inline: parseInline(match[4] ?? match[5]) });
    else if (match[7] !== undefined) out.push({ type: "image", alt: match[6], src: match[7] });
    else if (match[8] !== undefined) {
      out.push(SAFE_LINK.test(match[9]) ? { type: "link", text: match[8], href: match[9] } : { type: "text", text: match[8] });
    } else if (match[10] !== undefined) out.push({ type: "link", text: match[10], href: match[10] });
    else if (match[11] !== undefined) out.push({ type: "path", text: match[11] });
    else if (match[12] !== undefined) out.push({ type: "color", text: match[12] });
    else if (match[13] !== undefined) out.push({ type: "del", inline: parseInline(match[13]) });
    else if (match[14] !== undefined) out.push({ type: "kbd", text: match[14] });
    else out.push({ type: "ref", text: match[15] });
  }
  if (last < text.length) out.push({ type: "text", text: text.slice(last) });
  return out;
}

const LIST_ITEM = /^([ \t]*)([-*+]|\d{1,9}[.)])\s+(.*)$/;
const HEADING = /^(#{1,6})\s+(.*)$/;
const RULE = /^ {0,3}([-*_])(?:\s*\1){2,}\s*$/;
const TABLE_DELIMITER = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;

/** A table row's cells, its outer pipes dropped; `\|` is a pipe inside a cell. */
function tableCells(row: string): string[] {
  return row
    .trim()
    .replace(/^\|/, "")
    .replace(/(?<!\\)\|$/, "")
    .split(/(?<!\\)\|/)
    .map((cell) => cell.trim().replaceAll("\\|", "|"));
}

/** A parse a longer text can resume: the first `settled` blocks end at `end`, a blank line outside any fence. */
export interface MarkdownParse {
  text: string;
  blocks: Block[];
  end: number;
  settled: number;
}

/**
 * Paragraphs, headings, quotes, lists, tables and fenced code; an unclosed fence (still streaming) runs to the end.
 * Given the parse of a prefix, only the text after its settled blocks is parsed again, and those keep their identity.
 */
export function parseMarkdown(text: string, prev?: MarkdownParse): MarkdownParse {
  const resume = prev !== undefined && text.startsWith(prev.text);
  const start = resume ? prev.end : 0;
  const blocks: Block[] = resume ? prev.blocks.slice(0, prev.settled) : [];
  let settled = blocks.length;
  let settledLine = -1;
  const lines = text.slice(start).split("\n");
  let paragraph: string[] = [];
  let quote: string[] = [];
  let list: { indent: number; ordered: boolean; number: number; text: string }[] | null = null;
  // A list from its item at `at`: deeper items nest under the item above them, a shallower one or a change of kind ends it.
  const buildList = (entries: NonNullable<typeof list>, at: number): { block: ListBlock; next: number } => {
    const { indent, ordered, number } = entries[at];
    // An ordered list counts on from its first number, so steps split by code blocks read 1, 2, 3.
    const block: ListBlock = ordered && number !== 1 ? { type: "list", ordered, start: number, items: [] } : { type: "list", ordered, items: [] };
    while (at < entries.length && entries[at].indent >= indent) {
      const entry = entries[at];
      if (entry.indent > indent && block.items.length) {
        const sub = buildList(entries, at);
        block.items[block.items.length - 1].lists.push(sub.block);
        at = sub.next;
        continue;
      }
      if (entry.ordered !== ordered) break;
      const task = /^\[([ xX])\]\s+/.exec(entry.text);
      const inline: Inline[] = task
        ? [{ type: "task", checked: task[1] !== " " }, ...parseInline(entry.text.slice(task[0].length))]
        : parseInline(entry.text);
      block.items.push({ inline, lists: [] });
      at++;
    }
    return { block, next: at };
  };
  const flush = () => {
    if (paragraph.length) blocks.push({ type: "p", inline: parseInline(paragraph.join("\n")) });
    if (quote.length) blocks.push({ type: "quote", inline: parseInline(quote.join("\n")) });
    for (let at = 0; list && at < list.length; ) {
      const built = buildList(list, at);
      blocks.push(built.block);
      at = built.next;
    }
    paragraph = [];
    quote = [];
    list = null;
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const fence = /^(\s*)(`{3,}|~{3,})\s*([\w+-]*)/.exec(line);
    if (fence) {
      flush();
      const code: string[] = [];
      // A fence indented into a list item takes its indent off every line it holds.
      const indent = new RegExp(`^ {0,${fence[1].length}}`);
      for (i++; i < lines.length && !lines[i].trimStart().startsWith(fence[2]); i++) code.push(lines[i].replace(indent, ""));
      const nested = fence[1].length > 0 && blocks.at(-1)?.type === "list";
      blocks.push({ type: "code", lang: fence[3], text: code.join("\n"), ...(nested && { nested: true as const }) });
      continue;
    }
    if (!line.trim()) {
      flush();
      // Everything is flushed here, so what follows parses alone; the last line may still grow.
      if (i < lines.length - 1) {
        settled = blocks.length;
        settledLine = i;
      }
      continue;
    }
    // A table is a header row over a delimiter row; its body runs to a line with no pipe.
    if (line.includes("|") && i + 1 < lines.length && lines[i + 1].includes("|") && TABLE_DELIMITER.test(lines[i + 1])) {
      flush();
      const align = tableCells(lines[i + 1]).map((cell) =>
        cell.endsWith(":") ? (cell.startsWith(":") ? "center" : "right") : cell.startsWith(":") ? "left" : null,
      );
      const head = tableCells(line).map(parseInline);
      const rows: Inline[][][] = [];
      for (i += 2; i < lines.length && lines[i].includes("|") && lines[i].trim(); i++) rows.push(tableCells(lines[i]).map(parseInline));
      i--;
      blocks.push({ type: "table", align, head, rows });
      continue;
    }
    const heading = HEADING.exec(line);
    if (heading) {
      flush();
      blocks.push({ type: "heading", level: heading[1].length, inline: parseInline(heading[2]) });
      continue;
    }
    const note = /^\[\^([^\]\s]+)\]:\s*(.*)$/.exec(line);
    if (note) {
      flush();
      blocks.push({ type: "note", id: note[1], inline: parseInline(note[2]) });
      continue;
    }
    if (RULE.test(line)) {
      flush();
      blocks.push({ type: "rule" });
      continue;
    }
    const item = LIST_ITEM.exec(line);
    if (item) {
      if (!list) {
        flush();
        list = [];
      }
      list.push({ indent: item[1].replaceAll("\t", "    ").length, ordered: /\d/.test(item[2]), number: parseInt(item[2]), text: item[3] });
      continue;
    }
    if (line.startsWith(">")) {
      if (!quote.length) flush();
      quote.push(line.replace(/^>\s?/, ""));
      continue;
    }
    // A wrapped line continues the list item above it.
    if (list && /^\s/.test(line)) {
      list[list.length - 1].text += ` ${line.trim()}`;
      continue;
    }
    if (list || quote.length) flush();
    paragraph.push(line);
  }
  flush();
  let end = start;
  for (let i = 0; i <= settledLine; i++) end += lines[i].length + 1;
  return { text, blocks, end, settled };
}

/**
 * Where the chrome loads a picture from. Local files go through Lilo's `conversation-file/`, which
 * serves only images inside the project; remote ones stay links, since the chrome's CSP blocks them.
 */
export function imageSource(src: string, cwd: string): { type: "image"; src: string } | { type: "remote"; href: string; host: string } | null {
  if (/^data:image\//i.test(src)) return { type: "image", src };
  if (/^https?:/i.test(src)) {
    try {
      return { type: "remote", href: src, host: new URL(src).host };
    } catch {
      return null;
    }
  }
  let path: string;
  if (/^file:/i.test(src)) {
    try {
      path = decodeURIComponent(new URL(src).pathname);
    } catch {
      return null;
    }
  } else if (src.startsWith("/")) path = src;
  else if (!/^[a-z][\w+.-]*:/i.test(src) && cwd) path = `${cwd.replace(/\/$/, "")}/${src.replace(/^\.\//, "")}`;
  else return null;
  path = path.replace(/[?#].*$/, "");
  return IMAGE_FILE.test(path) ? { type: "image", src: `lilo-chrome://ui/conversation-file/${encodeURIComponent(path)}` } : null;
}

export interface DiffLine {
  type: "context" | "added" | "removed";
  line: number;
  text: string;
}

function splitLines(text: string): string[] {
  if (!text) return [];
  const lines = text.split("\n");
  if (text.endsWith("\n")) lines.pop();
  return lines;
}

/**
 * The changed span between the first and last differing lines, with `context` lines around it.
 * Linear rather than a minimal diff: an agent's edit is usually one region, and files can be large.
 */
export function lineDiff(oldText: string | null, newText: string, context = 3): DiffLine[] {
  const before = splitLines(oldText ?? "");
  const after = splitLines(newText);
  let start = 0;
  while (start < before.length && start < after.length && before[start] === after[start]) start++;
  let endBefore = before.length;
  let endAfter = after.length;
  while (endBefore > start && endAfter > start && before[endBefore - 1] === after[endAfter - 1]) {
    endBefore--;
    endAfter--;
  }
  const out: DiffLine[] = [];
  for (let i = Math.max(0, start - context); i < start; i++) out.push({ type: "context", line: i + 1, text: after[i] });
  for (let i = start; i < endBefore; i++) out.push({ type: "removed", line: i + 1, text: before[i] });
  for (let i = start; i < endAfter; i++) out.push({ type: "added", line: i + 1, text: after[i] });
  const tail = Math.min(after.length, endAfter + context);
  for (let i = endAfter; i < tail; i++) out.push({ type: "context", line: i + 1, text: after[i] });
  return out;
}

/**
 * Changes whenever what the item draws changes. Items are mutated in place, so this is what tells
 * the view which rows to redraw on a frame, without touching the rest of the thread.
 */
export function itemSignature(item: ThreadItem, undone: Set<string>): string {
  switch (item.kind) {
    case "user":
      return `${item.text.length}:${item.context.length}`;
    case "agent":
    case "thought":
      return String(item.text.length);
    case "image":
      return `${item.src.length}:${item.alt}`;
    case "toolCall": {
      const own = `${item.revision}:${item.diffs.map((diff) => undone.has(diff.path)).join()}`;
      return item.children.length ? `${own}[${item.children.map((child) => itemSignature(child, undone)).join("|")}]` : own;
    }
    case "turnEnd":
      return item.stopReason;
    case "plan":
      return item.entries.map((entry) => `${entry.status}${entry.content.length}`).join();
    case "permission":
      return item.answer ?? "";
    case "question":
      return item.answer?.action ?? "";
    case "notice":
      return item.text;
  }
}

/** "8s", "1m 05s", "2h 03m": whole seconds, for elapsed and worked times. */
export function formatDuration(ms: number): string {
  const seconds = Math.max(0, Math.round(ms / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ${String(seconds % 60).padStart(2, "0")}s`;
  return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, "0")}m`;
}

export type CodeToken = { text: string; kind: "" | "keyword" | "string" | "comment" | "number" | "type" };

// Each family: its line comment, whether it has /* */ comments, and its keywords.
const CODE_FAMILIES: Record<string, { line: string; block: boolean; keywords: string }> = {
  js: { line: "//", block: true, keywords: "as async await break case catch class const continue debugger default delete do else enum export extends false finally for from function if implements import in instanceof interface let new null of private protected public readonly return satisfies static super switch this throw true try type typeof undefined var void while yield" },
  swift: { line: "//", block: true, keywords: "actor any as associatedtype async await break case catch class continue default defer do else enum extension fallthrough false fileprivate final for func guard if import in init inout internal is lazy let mutating nil open override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try var weak where while" },
  go: { line: "//", block: true, keywords: "break case chan const continue default defer else fallthrough false for func go goto if import interface map nil package range return select struct switch true type var" },
  rust: { line: "//", block: true, keywords: "as async await break const continue crate dyn else enum false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while" },
  c: { line: "//", block: true, keywords: "abstract auto bool boolean break case catch char class const continue default do double else enum extends extern false final float for fun if implements import int interface long namespace new null nullptr object override package private protected public return short signed sizeof static struct super switch template this throw true try typedef union unsigned using val var virtual void volatile when while" },
  python: { line: "#", block: false, keywords: "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return self True try while with yield" },
  shell: { line: "#", block: false, keywords: "case do done elif else esac export fi for function if in local return then until while" },
  sql: { line: "--", block: true, keywords: "and as asc by create delete desc distinct drop from group having in inner insert into is join left limit not null on or order outer right select set table update values where with" },
  data: { line: "", block: true, keywords: "true false null" },
};
const CODE_LANGS: Record<string, string> = {
  js: "js", jsx: "js", ts: "js", tsx: "js", javascript: "js", typescript: "js", mjs: "js", cjs: "js",
  swift: "swift", go: "go", rust: "rust", rs: "rust",
  c: "c", h: "c", cpp: "c", "c++": "c", hpp: "c", cs: "c", csharp: "c", java: "c", kotlin: "c", kt: "c", dart: "c", php: "c", scala: "c",
  py: "python", python: "python", sh: "shell", bash: "shell", zsh: "shell", shell: "shell", fish: "shell",
  sql: "sql", json: "data", jsonc: "data", css: "data", scss: "data", less: "data",
};
const keywordSets = new Map<string, Set<string>>();

/** A fenced block's code in colored runs, or null for a language it does not know: that code stays plain. */
export function codeTokens(code: string, lang: string): CodeToken[] | null {
  const name = CODE_LANGS[lang.toLowerCase()];
  // A huge block is not worth a frame's work on every streamed chunk.
  if (!name || code.length > 50_000) return null;
  const family = CODE_FAMILIES[name];
  let keywords = keywordSets.get(name);
  if (!keywords) keywordSets.set(name, (keywords = new Set(family.keywords.split(" "))));
  const lineComment = family.line === "#" ? "(?<!\\S)#.*" : family.line ? `${family.line}.*` : "(?!)";
  const pattern = new RegExp(
    [
      `(${lineComment}${family.block ? "|\\/\\*[\\s\\S]*?(?:\\*\\/|$)" : ""})`,
      // A quote left open on its line is no string: an apostrophe or a string still streaming.
      // Rust's single quote holds one char, so a lifetime is no string either.
      `("""[\\s\\S]*?(?:"""|$)|\`(?:\\\\[\\s\\S]|[^\`\\\\])*\`?|"(?:\\\\.|[^"\\\\\\n])*"|'(?:\\\\.|[^'\\\\\\n])${name === "rust" ? "" : "*"}')`,
      "(\\b0x[\\da-fA-F_]+\\b|\\b\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b)",
      "([A-Za-z_$][\\w$]*)",
    ].join("|"),
    "g",
  );
  const tokens: CodeToken[] = [];
  let plain = "";
  let at = 0;
  const push = (text: string, kind: CodeToken["kind"]) => {
    if (plain) tokens.push({ text: plain, kind: "" });
    plain = "";
    tokens.push({ text, kind });
  };
  for (const match of code.matchAll(pattern)) {
    plain += code.slice(at, match.index);
    at = match.index + match[0].length;
    const [text, comment, string, number, word] = match;
    if (comment) push(text, "comment");
    else if (string) push(text, "string");
    else if (number) push(text, "number");
    else if (word && keywords.has(name === "sql" ? word.toLowerCase() : word)) push(text, "keyword");
    else if (word && name !== "sql" && name !== "shell" && /^[A-Z][A-Z]*[a-z]/.test(word)) push(text, "type");
    else plain += text;
  }
  plain += code.slice(at);
  if (plain) tokens.push({ text: plain, kind: "" });
  return tokens;
}
