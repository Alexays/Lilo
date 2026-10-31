/*lilo-generic-cosmetics*/
(function () {
  'use strict';

  // Generic selectors are injected only once their class/id token or link host shows up in the page, so the style
  // engine never matches thousands of irrelevant selectors against every element; site cosmetics go in at once.

  // An allowlisted site runs no filtering, as the rule list stands down for it (if-top-url); `www.`
  // is optional on the site, as in its rule. Main frame only, so the page is the top document.
  // A hostless document (about:blank, file:) must not match the empty list's "||".
  var ALLOWLIST = __LILO_ALLOWLIST__;
  var host = location.host;
  if (host && (ALLOWLIST.indexOf('|' + host + '|') >= 0 ||
      ALLOWLIST.indexOf('|' + host.replace(/^www\./, '') + '|') >= 0)) return;

  // Table entries spell `\`, `"`, line breaks and other special characters with Latin-1 marks
  // (see WKEngineFactory.hostTable), so the multi-MB literal stays on JSC's fast lexing path.
  function decodeEntry(s) {
    return /[\xa4\xac\xb5\xb6]/.test(s) ? s.replace(/\xb5([0-9a-f]{4})|[\xa4\xac\xb6]/g, function (m, hex) {
      return hex ? String.fromCharCode(parseInt(hex, 16)) : m === '\xa4' ? '\\' : m === '\xac' ? '"' : '\n';
    }) : s;
  }

  // Keyed tables (see WKEngineFactory.hostTable): sorted 12-character INDEX records (8-digit hash, 4-digit GROUPS offset),
  // GROUPS lists of base-36 TABLE offsets closed by `|`, entries closed by \xa7. Binary search avoids scanning megabytes per frame.
  var DIGITS = '+/0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  function keyHash(key) {
    var a = 2166136261, b = 0x9747b28c;
    for (var i = 0; i < key.length; i++) {
      var c = key.charCodeAt(i);
      a = Math.imul(a ^ c, 16777619) >>> 0;
      b = Math.imul(b ^ c, 16777619) >>> 0;
    }
    var value = a * 65536 + (b >>> 16), out = '';
    for (var d = 0; d < 8; d++) { out = DIGITS[value % 64] + out; value = Math.floor(value / 64); }
    return out;
  }
  function lookup(index, groups, table, key) {
    var hash = keyHash(key), lo = 0, hi = index.length / 12 - 1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1, record = index.substr(mid * 12, 8);
      if (record < hash) { lo = mid + 1; continue; }
      if (record > hash) { hi = mid - 1; continue; }
      var group = 0;
      for (var d = 8; d < 12; d++) group = group * 64 + DIGITS.indexOf(index.charAt(mid * 12 + d));
      return groups.slice(group, groups.indexOf('|', group)).split(',').map(function (offset) {
        var start = parseInt(offset, 36);
        return table.slice(start, table.indexOf('\xa7', start));
      });
    }
    return [];
  }

  var pending = [];
  var flushScheduled = false;
  var sheet = null;
  // CosmeticStyleSheets.swift, registered when WebKit can add a user style sheet to one page.
  var userSheets = self.webkit && self.webkit.messageHandlers && self.webkit.messageHandlers.liloCosmetics;
  // Leaving the page took its sheets away: back from the back/forward cache, every rule posted goes again.
  var posted = '';
  if (userSheets) self.addEventListener('pageshow', function (event) { if (event.persisted && posted) userSheets.postMessage(posted); });

  // Same host probe as Scriptlets.js. An entry is a selector to hide, "@selector" for one excepted on
  // the site, or "@@" when generic cosmetics are off there.
  var SITE_INDEX = __LILO_SITE_INDEX__;
  var SITE_GROUPS = __LILO_SITE_GROUPS__;
  var SITE_TABLE = __LILO_SITE_TABLE__;
  var excepted = new Set(), genericOff = false, siteSelectors = [];
  var parts = location.hostname.split('.');
  var n = parts.length, twoLabelSuffix = n > 2 && parts[n - 1].length === 2 && parts[n - 2].length <= 3;
  for (var h = 0; h < n - 1; h++) {
    var candidates = [parts.slice(h).join('.'), parts.slice(h, n - 1).join('.') + '.*'];
    if (twoLabelSuffix && h < n - 2) candidates.push(parts.slice(h, n - 2).join('.') + '.*');
    for (var c = 0; c < candidates.length; c++) {
      lookup(SITE_INDEX, SITE_GROUPS, SITE_TABLE, candidates[c]).map(decodeEntry).forEach(function (entry) {
        if (entry === '@@') genericOff = true;
        else if (entry[0] === '@') excepted.add(entry.slice(1));
        else siteSelectors.push(entry);
      });
    }
  }
  for (var s = 0; s < siteSelectors.length; s++) {
    if (!excepted.has(siteSelectors[s])) pending.push(siteSelectors[s]);
  }
  // Before the page paints anything: these selectors are few and known to apply here.
  if (pending.length) flush();
  if (genericOff) return;

  // Class and id tokens in hashed buckets (see WKEngineFactory.tokenBuckets): no set of thousands to
  // build on every page. Link selectors are keyed by the host they require, as the site table.
  var CLASS_BUCKETS = __LILO_COSMETIC_CLASSES__;
  var ID_BUCKETS = __LILO_COSMETIC_IDS__;
  var LINK_INDEX = __LILO_LINK_INDEX__;
  var LINK_GROUPS = __LILO_LINK_GROUPS__;
  var LINK_TABLE = __LILO_LINK_TABLE__;
  // Complex selectors keyed by a class or id the hidden element carries: buckets of those tokens, and
  // the selectors by `.class` or `#id`.
  var KEYED_CLASSES = __LILO_KEYED_CLASSES__;
  var KEYED_IDS = __LILO_KEYED_IDS__;
  var KEYED_INDEX = __LILO_KEYED_INDEX__;
  var KEYED_GROUPS = __LILO_KEYED_GROUPS__;
  var KEYED_TABLE = __LILO_KEYED_TABLE__;
  var classBuckets = CLASS_BUCKETS ? CLASS_BUCKETS.split(',') : null;
  var idBuckets = ID_BUCKETS ? ID_BUCKETS.split(',') : null;
  var keyedClassBuckets = KEYED_CLASSES ? KEYED_CLASSES.split(',') : null;
  var keyedIdBuckets = KEYED_IDS ? KEYED_IDS.split(',') : null;
  var hasLinks = LINK_INDEX.length > 0;
  if (!classBuckets && !idBuckets && !keyedClassBuckets && !keyedIdBuckets && !hasLinks) return;
  function inBuckets(buckets, token) {
    if (!buckets) return false;
    var hash = 2166136261;
    for (var i = 0; i < token.length; i++) hash = Math.imul(hash ^ token.charCodeAt(i), 16777619) >>> 0;
    return buckets[hash % buckets.length].indexOf('|' + token + '|') >= 0;
  }

  var esc = (self.CSS && self.CSS.escape) ? self.CSS.escape : function (s) { return s; };
  var checkedClasses = new Set();
  var checkedIds = new Set();
  var checkedHosts = new Set();
  var linkedHosts = new Set();

  function flush() {
    flushScheduled = false;
    if (!pending.length) return;
    var css = '';
    // A site entry with `{` is a whole `:style()` rule; a selector never holds one.
    for (var i = 0; i < pending.length; i++) css += pending[i] + (pending[i].indexOf('{') < 0 ? '{display:none!important}\n' : '\n');
    pending = [];
    try {
      // A user sheet, as uBO's on Chrome: out of the page's reach, and its !important outranks every one of the page's.
      if (userSheets) { posted += css; userSheets.postMessage(css); return; }
      // An adopted sheet is no node of the page's DOM nor an entry of its styleSheets; the page may drop it, so it is re-adopted.
      sheet = sheet || new CSSStyleSheet();
      if (document.adoptedStyleSheets.indexOf(sheet) < 0) document.adoptedStyleSheets = document.adoptedStyleSheets.concat(sheet);
      // uBO's cosmetics are user-origin CSS. A cascade layer ranks the same: its !important above every unlayered one of the
      // page (Didomi's later `body.didomi-popup-open{overflow:hidden!important}`), its plain declarations below.
      sheet.insertRule('@layer{' + css + '}', sheet.cssRules.length);
    } catch (e) {}
  }
  function scheduleFlush() {
    if (flushScheduled) return;
    flushScheduled = true;
    // Microtask: matched rules land before the next paint without forcing a sync recalc per match.
    Promise.resolve().then(flush);
  }
  function activate(selectors) {
    for (var i = 0; i < selectors.length; i++) { if (!excepted.has(selectors[i])) pending.push(selectors[i]); }
    if (selectors.length) scheduleFlush();
  }
  function checkClass(token) {
    if (checkedClasses.has(token)) return;
    if (checkedClasses.size > 50000) checkedClasses.clear();
    checkedClasses.add(token);
    if (inBuckets(classBuckets, token) && !excepted.has('.' + token)) { pending.push('.' + esc(token)); scheduleFlush(); }
    if (inBuckets(keyedClassBuckets, token)) activate(lookup(KEYED_INDEX, KEYED_GROUPS, KEYED_TABLE, '.' + token).map(decodeEntry));
  }
  function checkId(token) {
    if (checkedIds.has(token)) return;
    if (checkedIds.size > 50000) checkedIds.clear();
    checkedIds.add(token);
    if (inBuckets(idBuckets, token) && !excepted.has('#' + token)) { pending.push('#' + esc(token)); scheduleFlush(); }
    if (inBuckets(keyedIdBuckets, token)) activate(lookup(KEYED_INDEX, KEYED_GROUPS, KEYED_TABLE, '#' + token).map(decodeEntry));
  }
  // A link to a.b.example.com activates the selectors keyed by it and by each parent domain.
  function checkHost(host) {
    if (checkedHosts.has(host)) return;
    if (checkedHosts.size > 50000) checkedHosts.clear();
    checkedHosts.add(host);
    for (var h = host; h; h = h.slice(h.indexOf('.') + 1)) {
      if (!linkedHosts.has(h)) {
        linkedHosts.add(h);
        activate(lookup(LINK_INDEX, LINK_GROUPS, LINK_TABLE, h).map(decodeEntry));
      }
      if (h.indexOf('.') < 0) break;
    }
  }
  function scanElement(el) {
    if (el.id) checkId(el.id);
    var cl = el.classList;
    if (cl) { for (var i = 0; i < cl.length; i++) checkClass(cl[i]); }
    // Only <a> and <area> carry `hostname`.
    if (hasLinks && el.hostname) checkHost(el.hostname);
  }
  // `visited` spans one observer batch, whose first walk already covers the nested records of a subtree inserted node by
  // node: without it the cost grows with the depth. The full-document scan has no duplicates and queries only matches.
  function scanTree(root, visited) {
    if (!root || root.nodeType !== 1) return;
    if (visited) {
      if (visited.has(root)) return;
      visited.add(root);
    }
    scanElement(root);
    if (!root.querySelectorAll) return;
    var found = root.querySelectorAll(visited ? '*' : (hasLinks ? '[id],[class],a[href],area[href]' : '[id],[class]'));
    for (var i = 0; i < found.length; i++) {
      if (visited) {
        if (visited.has(found[i])) continue;
        visited.add(found[i]);
      }
      scanElement(found[i]);
    }
  }

  // Parser insertions are surveyed in batches before each frame, not through the observer: on a large
  // page, one mutation record and one query per inserted node cost more than the page's own parsing.
  // The observer takes over once the DOM is complete, for the changes scripts make afterwards.
  var observer = new MutationObserver(function (records) {
    var visited = new Set();
    for (var r = 0; r < records.length; r++) {
      var rec = records[r];
      if (rec.type === 'attributes') { scanElement(rec.target); continue; }
      var added = rec.addedNodes;
      if (added) { for (var i = 0; i < added.length; i++) scanTree(added[i], visited); }
    }
  });
  function observe() {
    scanTree(document.documentElement, null);
    try {
      observer.observe(document.documentElement, {
        childList: true, subtree: true, attributes: true, attributeFilter: hasLinks ? ['class', 'id', 'href'] : ['class', 'id']
      });
    } catch (e) {}
  }
  if (document.readyState === 'loading') {
    // Live and in document order: the parser appends, so a cursor finds each new element once.
    var all = document.getElementsByTagName('*'), cursor = 0;
    var survey = function () {
      for (var n = all.length; cursor < n; cursor++) scanElement(all[cursor]);
      if (document.readyState === 'loading') requestAnimationFrame(survey);
    };
    requestAnimationFrame(survey);
    document.addEventListener('DOMContentLoaded', observe);
  } else {
    observe();
  }
})();
