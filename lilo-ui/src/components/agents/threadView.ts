// What the conversation view draws from the thread: light markdown, line diffs, and when an item changed.

import { IMAGE_FILE, type ThreadItem } from "./conversationModel";

export type Inline =
  | { type: "text" | "code" | "path" | "strong" | "em"; text: string }
  | { type: "link"; text: string; href: string }
  | { type: "image"; alt: string; src: string };

export type Block =
  | { type: "p" | "quote"; inline: Inline[] }
  | { type: "heading"; level: number; inline: Inline[] }
  | { type: "code"; lang: string; text: string }
  | { type: "list"; ordered: boolean; items: Inline[][] };

const INLINE =
  /`([^`\n]+)`|\*\*([^*\n]+)\*\*|__([^_\n]+)__|(?<![\w*])\*([^*\s][^*\n]*)\*(?![\w*])|(?<![\w_])_([^_\s][^_\n]*)_(?![\w_])|!\[([^\]\n]*)\]\(([^)\s]+)\)|\[([^\]\n]+)\]\(([^)\s]+)\)|(https?:\/\/[^\s<>()]*[^\s<>().,;:!?'"])|(?<![\w/.:@-])((?:\.{1,2}\/|\/)?(?:[\w.@-]+\/)+[\w.-]*\.[A-Za-z][\w]*(?::\d+(?::\d+)?)?)(?![\w/])/g;

const SAFE_LINK = /^(https?:|mailto:)/i;

export function parseInline(text: string): Inline[] {
  const out: Inline[] = [];
  let last = 0;
  for (const match of text.matchAll(INLINE)) {
    const index = match.index;
    if (index > last) out.push({ type: "text", text: text.slice(last, index) });
    last = index + match[0].length;
    if (match[1] !== undefined) out.push({ type: "code", text: match[1] });
    else if (match[2] !== undefined || match[3] !== undefined) out.push({ type: "strong", text: match[2] ?? match[3] });
    else if (match[4] !== undefined || match[5] !== undefined) out.push({ type: "em", text: match[4] ?? match[5] });
    else if (match[7] !== undefined) out.push({ type: "image", alt: match[6], src: match[7] });
    else if (match[8] !== undefined) {
      out.push(SAFE_LINK.test(match[9]) ? { type: "link", text: match[8], href: match[9] } : { type: "text", text: match[8] });
    } else if (match[10] !== undefined) out.push({ type: "link", text: match[10], href: match[10] });
    else out.push({ type: "path", text: match[11] });
  }
  if (last < text.length) out.push({ type: "text", text: text.slice(last) });
  return out;
}

const LIST_ITEM = /^\s{0,3}([-*+]|\d{1,9}[.)])\s+(.*)$/;
const HEADING = /^(#{1,6})\s+(.*)$/;

/** Paragraphs, headings, quotes, lists and fenced code; an unclosed fence (still streaming) runs to the end. */
export function parseMarkdown(text: string): Block[] {
  const blocks: Block[] = [];
  const lines = text.split("\n");
  let paragraph: string[] = [];
  let quote: string[] = [];
  let list: { ordered: boolean; items: string[] } | null = null;
  const flush = () => {
    if (paragraph.length) blocks.push({ type: "p", inline: parseInline(paragraph.join("\n")) });
    if (quote.length) blocks.push({ type: "quote", inline: parseInline(quote.join("\n")) });
    if (list) blocks.push({ type: "list", ordered: list.ordered, items: list.items.map(parseInline) });
    paragraph = [];
    quote = [];
    list = null;
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const fence = /^\s*(`{3,}|~{3,})\s*([\w+-]*)/.exec(line);
    if (fence) {
      flush();
      const code: string[] = [];
      for (i++; i < lines.length && !lines[i].trimStart().startsWith(fence[1]); i++) code.push(lines[i]);
      blocks.push({ type: "code", lang: fence[2], text: code.join("\n") });
      continue;
    }
    if (!line.trim()) {
      flush();
      continue;
    }
    const heading = HEADING.exec(line);
    if (heading) {
      flush();
      blocks.push({ type: "heading", level: heading[1].length, inline: parseInline(heading[2]) });
      continue;
    }
    const item = LIST_ITEM.exec(line);
    if (item) {
      const ordered = /\d/.test(item[1]);
      if (!list || list.ordered !== ordered) {
        flush();
        list = { ordered, items: [] };
      }
      list.items.push(item[2]);
      continue;
    }
    if (line.startsWith(">")) {
      if (!quote.length) flush();
      quote.push(line.replace(/^>\s?/, ""));
      continue;
    }
    // A wrapped line continues the list item above it.
    if (list && /^\s/.test(line)) {
      list.items[list.items.length - 1] += ` ${line.trim()}`;
      continue;
    }
    if (list || quote.length) flush();
    paragraph.push(line);
  }
  flush();
  return blocks;
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
    case "toolCall":
      return `${item.status}:${item.title}:${item.output.length}:${item.images.length}:${item.rawInput ? 1 : 0}:${item.diffs.map((diff) => `${diff.added}/${diff.removed}/${undone.has(diff.path)}`).join()}`;
    case "turnEnd":
      return item.stopReason;
    case "plan":
      return item.entries.map((entry) => `${entry.status}${entry.content.length}`).join();
    case "permission":
      return item.answer ?? "";
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
