// Every chrome.* and browser.* member the calling world sees, three levels deep, with its kind. Loaded by
// contract.html, which injects it with chrome.scripting, and as the content script of /surface pages,
// which leaves its own on the page for contract.js to read.
function worldSurface() {
  const kind = (value) => {
    if (value === null) return 'null';
    if (typeof value === 'object' && typeof value.addListener === 'function') return 'event';
    return typeof value;
  };
  const found = {};
  const walk = (object, path, depth) => {
    const names = new Set();
    for (let level = object; level && level !== Object.prototype && level !== Function.prototype; level = Object.getPrototypeOf(level)) {
      for (const name of Object.getOwnPropertyNames(level)) if (name !== 'constructor') names.add(name);
    }
    for (const name of names) {
      let value;
      try {
        value = object[name];
      } catch {
        found[`${path}.${name}`] = 'throws';
        continue;
      }
      found[`${path}.${name}`] = kind(value);
      if (kind(value) === 'object' && depth < 3) walk(value, `${path}.${name}`, depth + 1);
    }
  };
  for (const root of ['chrome', 'browser']) {
    if (globalThis[root] === undefined) continue;
    found[root] = kind(globalThis[root]);
    walk(globalThis[root], root, 1);
  }
  return found;
}

if (globalThis.location?.pathname.startsWith('/surface')) {
  document.documentElement.setAttribute('data-surface', JSON.stringify(worldSurface()));
}
