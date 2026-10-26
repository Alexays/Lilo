// What RealExtensionSmokeTests reads of a page, and record-chrome-smoke.mjs of the same page in Chrome: an
// expression evaluating to the probes. Every result is a list of strings, compared as a set.
({
  // The words of the page's visible text (the first 150, in document order), then one token per visible
  // control (`button#1`, `button#2`, ...), across open shadow roots and same-origin frames.
  fingerprint() {
    const words = new Set();
    const controls = {};
    const shown = new Map();
    const visible = (element) => {
      if (!shown.has(element)) {
        const style = element.ownerDocument.defaultView.getComputedStyle(element);
        shown.set(element, element.getClientRects().length > 0 && style.visibility !== 'hidden');
      }
      return shown.get(element);
    };
    const control = (element) => {
      if (element.localName === 'input') return element.type === 'hidden' ? null : 'input';
      if (['button', 'select', 'textarea'].includes(element.localName)) return element.localName;
      if (element.localName === 'a' && element.hasAttribute('href')) return 'link';
      return element.getAttribute('role') === 'button' ? 'button' : null;
    };
    const walk = (root) => {
      const walker = (root.ownerDocument ?? root).createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        if (node.nodeType === Node.TEXT_NODE) {
          if (words.size < 150 && node.parentElement && visible(node.parentElement)) {
            for (const word of node.data.toLowerCase().match(/\p{L}{2,}/gu) ?? []) words.add(word);
          }
          continue;
        }
        if (node.shadowRoot) walk(node.shadowRoot);
        if (node.localName === 'iframe') {
          try { if (node.contentDocument) walk(node.contentDocument); } catch { /* cross-origin */ }
        }
        const kind = control(node);
        if (kind && (controls[kind] ?? 0) < 20 && visible(node)) controls[kind] = (controls[kind] ?? 0) + 1;
      }
    };
    walk(document);
    return [...[...words].slice(0, 150), ...Object.entries(controls).flatMap(([kind, count]) => Array.from({ length: count }, (_, i) => `${kind}#${i + 1}`))];
  },

  // What extensions changed on smoke-page.html, whose source is `original`: `added:tag` for each tag the
  // page has more of, `attribute:id@name` for each attribute an element with an id gained, `hidden:id` for each
  // element with an id hidden or removed. Hex runs with a digit, as ids an extension draws, read `#`.
  pageChanges(original) {
    const before = new DOMParser().parseFromString(original, 'text/html');
    const count = (root) => {
      const counts = {};
      for (const element of root.querySelectorAll('*')) counts[element.localName] = (counts[element.localName] ?? 0) + 1;
      return counts;
    };
    const was = count(before), now = count(document);
    const drawn = (name) => name.replace(/[\da-f]*\d[\da-f]*/gi, '#');
    const changes = Object.keys(now).filter((tag) => now[tag] > (was[tag] ?? 0)).map((tag) => `added:${drawn(tag)}`);
    for (const old of [before.documentElement, ...before.querySelectorAll('[id]')]) {
      const element = old === before.documentElement ? document.documentElement : document.getElementById(old.id);
      const name = old.id || 'html';
      const rect = element?.getBoundingClientRect();
      if (!element || !rect.width || !rect.height || getComputedStyle(element).visibility === 'hidden') {
        changes.push(`hidden:${name}`);
        continue;
      }
      for (const attribute of element.attributes) {
        if (!old.hasAttribute(attribute.name)) changes.push(`attribute:${name}@${drawn(attribute.name)}`);
      }
    }
    return [...new Set(changes)].sort();
  },
})
