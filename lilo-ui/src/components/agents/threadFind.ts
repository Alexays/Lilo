// A conversation is drawn by the chrome itself, not a web view: the find bar searches its thread here.

/** The thread of each conversation on screen, by tab id. */
export const threadRoots = new Map<string, HTMLElement>();

/**
 * Highlights every visible match of `query` in `root` and makes the `index`th the current one,
 * wrapping at either end. Highlights leave the DOM untouched, so the thread never re-renders.
 */
export function findInThread(root: HTMLElement, query: string, caseSensitive: boolean, index: number): { index: number; count: number } {
  const needle = caseSensitive ? query : query.toLowerCase();
  const ranges: Range[] = [];
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const value = node.nodeValue ?? "";
    // A folded block or a hidden label still holds its text: only what can be seen is a match.
    if (value.length < needle.length || node.parentElement?.checkVisibility() === false) continue;
    const text = caseSensitive ? value : value.toLowerCase();
    for (let at = text.indexOf(needle); at !== -1; at = text.indexOf(needle, at + needle.length)) {
      const range = new Range();
      range.setStart(node, at);
      range.setEnd(node, at + needle.length);
      ranges.push(range);
    }
  }
  if (!ranges.length) {
    clearThreadFind();
    return { index: 0, count: 0 };
  }
  const current = ((index % ranges.length) + ranges.length) % ranges.length;
  CSS.highlights.set("thread-find", new Highlight(...ranges));
  CSS.highlights.set("thread-find-current", new Highlight(ranges[current]));
  ranges[current].startContainer.parentElement?.scrollIntoView({ block: "center" });
  return { index: current, count: ranges.length };
}

export function clearThreadFind(): void {
  CSS.highlights.delete("thread-find");
  CSS.highlights.delete("thread-find-current");
}
