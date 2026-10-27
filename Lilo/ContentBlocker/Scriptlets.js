/*lilo-scriptlets*/
(function () {
  'use strict';

  // Captured before any hook lands on JSON, so response rewriting stays on the native paths.
  var nativeJSONParse = JSON.parse.bind(JSON);
  var nativeJSONStringify = JSON.stringify.bind(JSON);

  // ---------- shared helpers ----------
  // `flags` applies to a plain-string pattern; a /regex/ literal keeps its own.
  function toRegExp(s, flags) {
    if (s === undefined || s === null || s === '' || s === '*') return /[\s\S]/;
    var m = /^\/(.+)\/([a-z]*)$/.exec(s);
    if (m) { try { return new RegExp(m[1], m[2]); } catch (e) {} }
    return new RegExp(s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), flags);
  }
  function coerce(v) {
    switch (v) {
      case 'undefined': return undefined;
      case 'null': return null;
      case 'true': return true;
      case 'false': return false;
      case '': case "''": case '""': case 'emptyStr': return '';
      case 'emptyObj': return {};
      case 'emptyArr': return [];
      case 'noopFunc': return function () {};
      case 'trueFunc': return function () { return true; };
      case 'falseFunc': return function () { return false; };
    }
    if (/^-?\d+$/.test(v)) return parseInt(v, 10);
    return v;
  }
  var hasOwn = Object.prototype.hasOwnProperty;
  // Path walking stays on own data properties: prototype segments would reach shared objects.
  function isUnsafeKey(k) { return k === '__proto__' || k === 'constructor' || k === 'prototype'; }
  function forEach(obj, seg, cb) {
    if (seg === '[]' || seg === '[-]' || seg === '{-}' || seg === '*') {
      if (Array.isArray(obj)) { for (var i = 0; i < obj.length; i++) cb(obj, i); }
      else if (obj && typeof obj === 'object') { for (var k in obj) { if (hasOwn.call(obj, k) && !isUnsafeKey(k)) cb(obj, k); } }
    } else if (obj && typeof obj === 'object' && !isUnsafeKey(seg)) { cb(obj, seg); }
  }
  function deletePath(obj, segs) {
    if (!obj || typeof obj !== 'object') return false;
    var changed = false;
    // `[-]` removes the array items, `{-}` the properties, that the rest of the path matches in.
    if (segs[0] === (Array.isArray(obj) ? '[-]' : '{-}')) {
      var tail = segs.slice(1), keys = Object.keys(obj);
      for (var j = keys.length - 1; j >= 0; j--) {
        if (isUnsafeKey(keys[j]) || !hasPath(obj[keys[j]], tail)) continue;
        if (Array.isArray(obj)) obj.splice(+keys[j], 1); else delete obj[keys[j]];
        changed = true;
      }
      return changed;
    }
    if (segs.length === 1) {
      forEach(obj, segs[0], function (o, k) { if (hasOwn.call(o, k)) { try { delete o[k]; changed = true; } catch (e) {} } });
      return changed;
    }
    var rest = segs.slice(1);
    forEach(obj, segs[0], function (o, k) { if (hasOwn.call(o, k) && deletePath(o[k], rest)) changed = true; });
    return changed;
  }
  function hasPath(obj, segs) {
    if (segs.length === 0) return true;
    var ok = false;
    forEach(obj, segs[0], function (o, k) { if (!ok && hasOwn.call(o, k)) ok = hasPath(o[k], segs.slice(1)); });
    return ok;
  }
  // Prunes in place; true only when something was actually deleted.
  function pruneObject(obj, paths, needed) {
    if (!obj || typeof obj !== 'object') return false;
    if (needed.length && !needed.every(function (p) { return hasPath(obj, p.split('.')); })) return false;
    var changed = false;
    for (var i = 0; i < paths.length; i++) { if (deletePath(obj, paths[i].split('.'))) changed = true; }
    return changed;
  }
  // Absolute URL for matching: URL/Request instances stringify to their href, relative URLs
  // resolve against the page so host patterns can match them.
  function resolveURL(u) {
    try { return new URL(String(u), location.href).href; } catch (e) { return String(u || ''); }
  }
  // uBO's propsToMatch: space-separated `prop:value` tests a request must all pass, a bare value testing
  // its URL. A request is `{ url, method }`, so any other property never matches. null means match-all;
  // compiled once at registration, not per request.
  function compileMatch(propsToMatch) {
    if (!propsToMatch || propsToMatch === '*') return null;
    var tests = propsToMatch.split(/\s+/).filter(Boolean).map(function (token) {
      // `https://...` is a URL, not a property named https.
      var m = /^(\w+):(?!\/\/)([\s\S]+)$/.exec(token);
      return { prop: m ? m[1] : 'url', re: toRegExp(m ? m[2] : token) };
    });
    if (!tests.length) return null;
    return function (request) {
      return tests.every(function (t) { return hasOwn.call(request, t.prop) && t.re.test(request[t.prop]); });
    };
  }
  // A page can shadow a Request's url and method with its own properties (YouTube fetches a data: URL
  // dressed as a /player call, then checks its body came back intact): only the native getters are true.
  var requestURL = typeof Request === 'function' && Object.getOwnPropertyDescriptor(Request.prototype, 'url');
  var requestMethod = typeof Request === 'function' && Object.getOwnPropertyDescriptor(Request.prototype, 'method');
  function fetchRequest(args) {
    var input = args[0], init = args[1], url = input, method = 'GET';
    // A Proxy passes instanceof but not the getters: native fetch reads it as a string too.
    if (requestURL && input instanceof Request) {
      try { url = requestURL.get.call(input); method = requestMethod.get.call(input); } catch (e) {}
    }
    return { url: resolveURL(url), method: String((init && init.method) || method).toUpperCase() };
  }
  // uBO passes extra scriptlet args either positionally or as named pairs ("propsToMatch", value).
  function propsToMatchArg(a, b) {
    return a === 'propsToMatch' ? b : a;
  }
  function defineChain(root, chain, value) {
    var parts = chain.split('.');
    (function bind(owner, i) {
      var key = parts[i];
      if (i === parts.length - 1) {
        try {
          Object.defineProperty(owner, key, { get: function () { return value; }, set: function () {}, configurable: false });
        } catch (e) {}
        return;
      }
      var stored = owner[key];
      if (stored && typeof stored === 'object') { bind(stored, i + 1); return; }
      // Another chain trapping the same property keeps its setter, so `a.x` and `a.y` both apply.
      var previous = Object.getOwnPropertyDescriptor(owner, key);
      var previousSet = previous && previous.set;
      try {
        Object.defineProperty(owner, key, {
          get: function () { return stored; },
          set: function (nv) {
            if (previousSet) previousSet.call(this, nv);
            stored = nv;
            if (nv && typeof nv === 'object') bind(nv, i + 1);
          },
          configurable: true
        });
      } catch (e) {}
    })(root, 0);
  }
  function always() { return true; }
  // Throws on reading (or writing) the chain's last property whenever `onRead` (or `onWrite`) says so.
  // A trap another rule already set on a property is chained to, so every rule on it applies.
  function abortOnProperty(owner, parts, onRead, onWrite) {
    var key = parts[0], previous = Object.getOwnPropertyDescriptor(owner, key) || {};
    if (parts.length > 1) {
      var stored = owner[key];
      try {
        Object.defineProperty(owner, key, {
          get: function () { return stored; },
          set: function (nv) {
            if (previous.set) previous.set.call(this, nv);
            stored = nv;
            if (nv && typeof nv === 'object') abortOnProperty(nv, parts.slice(1), onRead, onWrite);
          },
          configurable: true
        });
      } catch (e) {}
      if (stored && typeof stored === 'object') abortOnProperty(stored, parts.slice(1), onRead, onWrite);
      return;
    }
    var val = previous.get ? undefined : owner[key];
    try {
      Object.defineProperty(owner, key, {
        get: function () {
          if (onRead && onRead()) throw new ReferenceError('lilo');
          return previous.get ? previous.get.call(this) : val;
        },
        set: function (nv) {
          if (onWrite && onWrite()) throw new ReferenceError('lilo');
          if (previous.set) previous.set.call(this, nv); else val = nv;
        },
        configurable: true
      });
    } catch (e) {}
  }
  // uBO's normalized stack: one " fn url:line:1" per frame, the page's inline code as `inlineScript`,
  // and the scriptlet's own frame replaced by the depth.
  function stackMatches(re, negate) {
    var lines = String(new Error().stack).split(/[\n\r]+/), out = [];
    var doc = location.href.replace(/#.*$/, '');
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim(), m = /(.*?@)?(\S+)(:\d+):\d+\)?$/.exec(line);
      if (!m) continue;
      var url = m[2].replace(/^\(/, '');
      if (url === doc) url = 'inlineScript';
      else if (url.indexOf('<anonymous>') === 0) url = 'injectedScript';
      var fn = m[1] !== undefined ? m[1].slice(0, -1) : line.slice(0, m.index).trim();
      if (fn.indexOf('at') === 0) fn = fn.slice(2).trim();
      out.push(' ' + (fn + ' ' + url + m[3] + ':1').trim());
    }
    out[0] = 'stackDepth:' + (out.length - 1);
    return re.test(out.join('\t')) !== negate;
  }
  function neutralizeTimer(which, search, delay) {
    var re = search ? toRegExp(search) : null;
    var wantDelay = (delay !== undefined && delay !== '') ? parseInt(delay, 10) : null;
    var _fn = self[which];
    if (typeof _fn !== 'function') return;
    self[which] = function (cb, t) {
      try {
        // Stringify the callback only when the delay matches and a pattern needs it: this wraps
        // every timer the page sets.
        if (wantDelay === null || wantDelay === (t | 0)) {
          if (!re || re.test((typeof cb === 'function') ? cb.toString() : String(cb))) return 0;
        }
      } catch (e) {}
      return _fn.apply(this, arguments);
    };
  }
  // A Proxy over a native function, which prints as that function: JSC prints any Proxy as
  // `function ProxyObject()`, so Function.prototype.toString maps a wrapper to what it wraps.
  var nativeOf = null;
  function wrapNative(fn, apply) {
    if (!nativeOf) {
      nativeOf = new WeakMap();
      var toString = Function.prototype.toString;
      var patched = new Proxy(toString, { apply: function (f, thisArg, args) { return Reflect.apply(f, nativeOf.get(thisArg) || thisArg, args); } });
      nativeOf.set(patched, toString);
      Function.prototype.toString = patched;
    }
    var proxy = new Proxy(fn, { apply: apply });
    nativeOf.set(proxy, nativeOf.get(fn) || fn);
    return proxy;
  }
  // Wraps the method a dotted chain names from self (`Node.prototype.appendChild`).
  function proxyApply(chain, apply) {
    var parts = chain.split('.'), owner = self;
    for (var i = 0; i < parts.length - 1 && owner; i++) owner = owner[parts[i]];
    var key = parts[parts.length - 1];
    if (!owner || typeof owner[key] !== 'function') return;
    owner[key] = wrapNative(owner[key], apply);
  }
  var scriptPolicy = null;
  // uBO's replace-node-text: rewrites matching nodes as the parser inserts them, so a script runs
  // edited. Observes until the document is interactive, unless `stay` is set.
  function replaceNodeText(nodeName, pattern, replacement, options) {
    var name = (nodeName || '').toUpperCase();
    var re = pattern ? toRegExp(pattern, 'gms') : null;
    var cond = options.condition || options.includes;
    var reIn = cond ? toRegExp(cond, 'ms') : null;
    var reOut = options.excludes ? toRegExp(options.excludes, 'ms') : null;
    var count = parseInt(options.sedCount, 10) || 0;
    function edit(node) {
      if (node.nodeName.toUpperCase() !== name) return true;
      var before = node.textContent;
      if (reIn) { reIn.lastIndex = 0; if (!reIn.test(before)) return true; }
      if (reOut) { reOut.lastIndex = 0; if (reOut.test(before)) return true; }
      if (re) { re.lastIndex = 0; if (!re.test(before)) return true; re.lastIndex = 0; }
      var after = re ? before.replace(re, replacement || '') : (replacement || '');
      // A page enforcing Trusted Types (YouTube) throws on a plain string written into a script.
      if (name === 'SCRIPT' && self.trustedTypes) {
        try {
          scriptPolicy = scriptPolicy || self.trustedTypes.createPolicy('lilo-scriptlets', { createScript: function (s) { return s; } });
          after = scriptPolicy.createScript(after);
        } catch (e) {}
      }
      try { node.textContent = after; } catch (e) { return true; }
      return count === 0 || --count !== 0;
    }
    function handle(mutations) {
      for (var i = 0; i < mutations.length; i++) {
        var added = mutations[i].addedNodes;
        for (var j = 0; j < added.length; j++) {
          if (!edit(added[j])) { observer.disconnect(); return; }
        }
      }
    }
    var observer = new MutationObserver(handle);
    observer.observe(document, { childList: true, subtree: true });
    if (options.stay) return;
    var quitAfter = parseInt(options.quitAfter, 10) || 0;
    function stop() { handle(observer.takeRecords()); observer.disconnect(); }
    whenReady('interactive', function () { if (quitAfter) setTimeout(stop, quitAfter); else stop(); });
  }
  // ---------- JSONPath (uBO subset) ----------
  // Steps `.key`, `.*`, `..key`, `[?filter]` (relative path, optionally compared or `!`-negated); `=value` sets, `+=value`
  // merges, nothing removes (an array element is spliced out). Matches are [owner, key] pairs.
  var STEP_KEY = /^(\*|[^.[\]=!*^$+]+)/;
  function closingBracket(q, i) {
    var depth = 0;
    for (; i < q.length; i++) {
      var c = q[i];
      if (c === '"') { for (i++; i < q.length && q[i] !== '"'; i++) if (q[i] === '\\') i++; }
      else if (c === '/' && q[i - 1] === '=') { for (i++; i < q.length && q[i] !== '/'; i++) if (q[i] === '\\') i++; }
      else if (c === '[') depth++;
      else if (c === ']' && --depth === 0) return i;
    }
    return -1;
  }
  function parseSteps(q, i) {
    var steps = [];
    while (i < q.length) {
      if (q.slice(i, i + 2) === '[?') {
        var end = closingBracket(q, i);
        var filter = end > 0 && compileFilter(q.slice(i + 2, end));
        if (!filter) return null;
        steps.push({ filter: filter });
        i = end + 1;
      } else if (q[i] === '.') {
        var deep = q[i + 1] === '.';
        var m = STEP_KEY.exec(q.slice(i + (deep ? 2 : 1)));
        if (!m) return null;
        steps.push({ key: m[1], deep: deep });
        i += (deep ? 2 : 1) + m[1].length;
      } else break;
    }
    return { steps: steps, end: i };
  }
  function descendants(v, key, out) {
    forEach(v, '*', function (o, k) {
      if (key === '*' || String(k) === key) out.push([o, k]);
      var child = o[k];
      if (child && typeof child === 'object') descendants(child, key, out);
    });
  }
  function evalSteps(steps, nodes) {
    for (var s = 0; s < steps.length && nodes.length; s++) {
      var step = steps[s], next = [];
      for (var n = 0; n < nodes.length; n++) {
        var v = nodes[n][0][nodes[n][1]];
        if (step.filter) { if (step.filter(v)) next.push(nodes[n]); }
        else if (!v || typeof v !== 'object') continue;
        else if (step.deep) descendants(v, step.key, next);
        else forEach(v, step.key, function (o, k) { next.push([o, k]); });
      }
      nodes = next;
    }
    return nodes;
  }
  function compileFilter(expr) {
    var negate = expr[0] === '!';
    if (negate) expr = expr.slice(1);
    var parsed = parseSteps(expr, 0);
    if (!parsed || !parsed.steps.length) return null;
    var rest = expr.slice(parsed.end), m = /^(==|!=|\*=|\^=|\$=|=)(.*)$/.exec(rest), test;
    if (!rest) test = function (v) { return v !== undefined; };
    else if (!m) return null;
    else if (m[1] === '=') {
      var re = toRegExp(m[2]);
      test = function (v) { return typeof v === 'string' && re.test(v); };
    } else {
      var want;
      try { want = nativeJSONParse(m[2]); } catch (e) { return null; }
      test = {
        '==': function (v) { return v === want; },
        '!=': function (v) { return v !== want; },
        '*=': function (v) { return typeof v === 'string' && v.indexOf(want) >= 0; },
        '^=': function (v) { return typeof v === 'string' && v.indexOf(want) === 0; },
        '$=': function (v) { return typeof v === 'string' && v.slice(-String(want).length) === String(want); }
      }[m[1]];
    }
    var steps = parsed.steps;
    return function (node) {
      var found = evalSteps(steps, [[{ $: node }, '$']]), hit = false;
      for (var i = 0; i < found.length && !hit; i++) hit = test(found[i][0][found[i][1]]);
      return hit !== negate;
    };
  }
  // A JSONPath query for a scriptlet; an untrusted one may only remove.
  function compileJSONPath(q, trusted) {
    var parsed = q ? parseSteps(q, 0) : null;
    if (!parsed || !parsed.steps.length) return null;
    var rest = q.slice(parsed.end), merge = rest.slice(0, 2) === '+=', remove = rest === '', value, repl;
    if (!remove) {
      if (!trusted || (!merge && rest[0] !== '=')) return null;
      var raw = rest.slice(merge ? 2 : 1);
      try {
        var r = /^repl\((.*)\)$/.exec(raw);
        if (r) { repl = nativeJSONParse(r[1]); repl.re = new RegExp(repl.regex, repl.flags); }
        else value = nativeJSONParse(raw);
      } catch (e) { return null; }
      if (merge && (!value || typeof value !== 'object')) return null;
    }
    var steps = parsed.steps;
    return {
      matches: function (root) { return evalSteps(steps, [[{ $: root }, '$']]).length > 0; },
      // The edited root, undefined once removed itself.
      apply: function (root) {
        var holder = { $: root }, nodes = evalSteps(steps, [[holder, '$']]);
        // Backwards: splicing an element keeps the indices still to visit in place.
        for (var n = nodes.length - 1; n >= 0; n--) {
          var owner = nodes[n][0], key = nodes[n][1];
          if (remove) {
            if (!hasOwn.call(owner, key)) continue;
            if (Array.isArray(owner)) owner.splice(key, 1); else delete owner[key];
          } else if (repl) {
            if (typeof owner[key] === 'string') owner[key] = owner[key].replace(repl.re, repl.replacement);
          } else {
            var v = nativeJSONParse(nativeJSONStringify(value).replace(/\$\{now\}/g, String(Date.now())));
            if (!merge) owner[key] = v;
            else if (owner[key] && typeof owner[key] === 'object') Object.assign(owner[key], v);
          }
        }
        return holder.$;
      }
    };
  }
  // A response rewriter running the query on a JSON body.
  function jsonEditEntry(path) {
    return {
      fn: function (txt) {
        var obj = nativeJSONParse(txt);
        return path.matches(obj) ? nativeJSONStringify(path.apply(obj)) : null;
      }
    };
  }
  // The same on JSON Lines, one document per line; a line that is not JSON stays as it is.
  function jsonlEditEntry(path) {
    return {
      fn: function (txt) {
        var changed = false;
        var lines = txt.split('\n').map(function (line) {
          var obj;
          try { obj = nativeJSONParse(line); } catch (e) { return line; }
          if (!path.matches(obj)) return line;
          changed = true;
          return nativeJSONStringify(path.apply(obj));
        });
        return changed ? lines.join('\n') : null;
      }
    };
  }
  // uBO's nano-stb and nano-sib: scales the delay of matching timers by `boost` (0.001 to 50).
  function adjustTimer(which, needle, delayArg, boostArg) {
    var re = toRegExp(needle);
    var delay = delayArg === '*' ? -1 : parseInt(delayArg, 10);
    if (!isFinite(delay)) delay = 1000;
    var boost = parseFloat(boostArg);
    boost = isFinite(boost) ? Math.min(Math.max(boost, 0.001), 50) : 0.05;
    proxyApply(which, function (target, thisArg, args) {
      if ((delay === -1 || args[1] === delay) && re.test(String(args[0]))) args[1] *= boost;
      return Reflect.apply(target, thisArg, args);
    });
  }
  // Runs fn once the document reaches `state`: loading (now), interactive or complete.
  function whenReady(state, fn) {
    var order = ['loading', 'interactive', 'complete'];
    if (order.indexOf(document.readyState) >= order.indexOf(state)) { fn(); return; }
    document.addEventListener('readystatechange', function on() {
      if (order.indexOf(document.readyState) < order.indexOf(state)) return;
      document.removeEventListener('readystatechange', on);
      fn();
    });
  }
  // uBO's remove-attr and remove-class: applies `strip` to what `selector` matches once the document is
  // interactive (`asap`: at once, `complete`: once loaded), and to later changes with `stay`.
  function stripNodes(selector, attrs, strip, behavior) {
    behavior = behavior || '';
    var timer = 0;
    function run() {
      timer = 0;
      try {
        var nodes = document.querySelectorAll(selector);
        for (var i = 0; i < nodes.length; i++) strip(nodes[i]);
      } catch (e) {}
    }
    whenReady(/\bcomplete\b/.test(behavior) ? 'complete' : /\basap\b/.test(behavior) ? 'loading' : 'interactive', function () {
      run();
      if (!/\bstay\b/.test(behavior)) return;
      new MutationObserver(function () { if (!timer) timer = setTimeout(run, 67); })
        .observe(document, { attributes: true, attributeFilter: attrs, childList: true, subtree: true });
    });
  }
  // uBO's set-attr: an untrusted value is a number, true, false, empty, or `[other-attr]` to copy.
  function setAttr(selector, attr, value, trusted) {
    if (!selector || !attr) return;
    value = value || '';
    var copy = /^\[.+\]$/.test(value) ? value.slice(1, -1) : null;
    if (!trusted && copy === null && !/^(?:-?\d{1,5}|true|false)?$/.test(value)) return;
    stripNodes(selector, [attr], function (el) {
      var v = copy === null ? value : el.getAttribute(copy);
      if (v !== null && el.getAttribute(attr) !== v) el.setAttribute(attr, v);
    }, 'stay');
  }
  function cssEscape(s) { return self.CSS && self.CSS.escape ? self.CSS.escape(s) : s; }
  // uBO's generated bodies: `emptyObj`, `emptyArr`, `true` (a random token), `length:n` or `length:n-m`
  // (random text that long); a trusted scriptlet may also give the body itself.
  function responseBody(spec, trusted) {
    if (!spec || spec === 'emptyStr') return '';
    if (spec === 'emptyObj') return '{}';
    if (spec === 'emptyArr') return '[]';
    var m = /^length:(\d+)(?:-(\d+))?$/.exec(spec);
    var length = spec === 'true' ? 10 : m ? +m[1] + Math.floor(Math.random() * ((m[2] ? +m[2] : +m[1]) - m[1] + 1)) : -1;
    if (length < 0) return trusted ? spec : '';
    var text = '';
    while (text.length < Math.min(length, 500000)) text += Math.random().toString(36).slice(2);
    return text.slice(0, length);
  }
  // `/pattern/replacement/flags`, as uBO's `repl:` arguments write it.
  function parseReplace(s) {
    var parts = [], cur = '';
    if (s[0] !== '/') return null;
    for (var i = 1; i < s.length; i++) {
      if (s[i] === '\\' && s[i + 1] === '/') { cur += '/'; i++; }
      else if (s[i] === '/' && parts.length < 2) { parts.push(cur); cur = ''; }
      else cur += s[i];
    }
    if (parts.length < 2 || !parts[0]) return null;
    try { return { re: new RegExp(parts[0], cur), replacement: parts[1] }; } catch (e) { return null; }
  }
  // ---------- consent state ----------
  function expandDates(v, currentDate) {
    return v.replace(/\$now\$/g, String(Date.now())).replace(/\$currentDate\$/g, currentDate)
      .replace(/\$currentISODate\$/g, new Date().toISOString());
  }
  // Trailing scriptlet args are option pairs: "reload", "1", "domain", "site.test".
  function optionPairs(args, from) {
    var o = {};
    for (var i = from; i + 1 < args.length; i += 2) o[args[i]] = args[i + 1];
    return o;
  }
  function getCookie(name) {
    var all = document.cookie.split(/\s*;\s*/);
    for (var i = 0; i < all.length; i++) {
      var at = all[i].indexOf('=');
      if (at > 0 && all[i].slice(0, at) === name) return all[i].slice(at + 1);
    }
  }
  // uBO's cookie writer: only path / (or none), a value outside the cookie-octet range URI-encoded,
  // and a reload only once the cookie actually changed.
  function setCookie(trusted, name, value, expires, path, options) {
    if (!name) return;
    if (/[^ -:<-[\]-~]/.test(value)) value = encodeURIComponent(value);
    if (options.reload && getCookie(name) === value) return;
    if (path === 'none') path = '';
    else if (!path) path = '/';
    if (path !== '' && path !== '/') return;
    var cookie = name + '=' + value + (expires ? '; expires=' + expires : '') + (path ? '; path=/' : '');
    if (trusted) cookie += (options.domain ? '; domain=' + options.domain : '') + '; Secure';
    try { document.cookie = cookie; } catch (e) { return; }
    if (options.reload && getCookie(name) === value) location.reload();
  }
  function setStorageItem(name, key, value) {
    if (!key) return;
    if (value === 'emptyArr') value = '[]';
    else if (value === 'emptyObj') value = '{}';
    try {
      var storage = name === 'sessionStorage' ? sessionStorage : localStorage;
      if (value === '$remove$') storage.removeItem(key);
      else if (storage.getItem(key) !== value) storage.setItem(key, value);
    } catch (e) {}
  }
  // `host >>> inner` looks for inner in host's open shadow root.
  function querySelectorEx(selector, root) {
    var at = selector.indexOf('>>>');
    if (at < 0) return root.querySelector(selector);
    var host = root.querySelector(selector.slice(0, at).trim());
    return host && host.shadowRoot ? querySelectorEx(selector.slice(at + 3).trim(), host.shadowRoot) : null;
  }

  // ---------- response rewriting ----------
  // One wrapper per API however many scriptlets register; JSON prunes on a response share one parse/stringify,
  // and a body no transformation changed keeps the original response object.
  var fetchRewriters = [];
  var xhrRewriters = [];

  function activeRewriters(list, request) {
    var active = [];
    for (var i = 0; i < list.length; i++) {
      if (!list[i].match || list[i].match(request)) active.push(list[i]);
    }
    return active;
  }
  // Returns the rewritten body, or null when nothing changed.
  function applyRewriters(entries, txt) {
    var out = txt, changed = false, obj = null, hasObj = false, dirty = false;
    function flush() {
      if (hasObj && dirty) { try { out = nativeJSONStringify(obj); changed = true; } catch (e) {} }
      hasObj = false; dirty = false; obj = null;
    }
    for (var i = 0; i < entries.length; i++) {
      var en = entries[i];
      if (en.fn) {
        flush();
        var r;
        try { r = en.fn(out); } catch (e) { continue; }
        if (r != null && r !== out) { out = r; changed = true; }
      } else {
        if (!hasObj) {
          try { obj = nativeJSONParse(out); hasObj = true; } catch (e) { continue; }
        }
        try { if (pruneObject(obj, en.paths, en.needed)) dirty = true; } catch (e) {}
      }
    }
    flush();
    return changed ? out : null;
  }
  function addFetchRewriter(propsToMatch, entry) {
    if (typeof self.fetch !== 'function' || typeof Response !== 'function') return;
    entry.match = compileMatch(propsToMatch);
    fetchRewriters.push(entry);
    if (fetchRewriters.length > 1) return;
    self.fetch = wrapNative(self.fetch, function (fn, thisArg, args) {
      var p = Reflect.apply(fn, thisArg, args);
      var active = activeRewriters(fetchRewriters, fetchRequest(args));
      if (!active.length) return p;
      return p.then(function (resp) {
        return resp.clone().text().then(function (txt) {
          var out = applyRewriters(active, txt);
          if (out === null) return resp;
          return new Response(out, { status: resp.status, statusText: resp.statusText, headers: resp.headers });
        }).catch(function () { return resp; });
      });
    });
  }
  function addXHRRewriter(propsToMatch, entry) {
    var Native = self.XMLHttpRequest;
    if (typeof Native !== 'function' || !Native.prototype) return;
    entry.match = compileMatch(propsToMatch);
    xhrRewriters.push(entry);
    if (xhrRewriters.length > 1) return;
    var proto = Native.prototype;
    var nativeGetters = {};
    ['responseText', 'response', 'responseXML'].forEach(function (k) {
      var d = Object.getOwnPropertyDescriptor(proto, k);
      if (d && d.get) nativeGetters[k] = d.get;
    });
    proto.open = wrapNative(proto.open, function (fn, xhr, args) {
      // A reused object must not keep the previous response's rewritten getters.
      try { delete xhr.responseText; delete xhr.response; delete xhr.responseXML; } catch (e) {}
      var active = activeRewriters(xhrRewriters, { url: resolveURL(args[1]), method: String(args[0]).toUpperCase() });
      if (active.length) {
        // The getters go on at open, not at load: a handler set before open runs ahead of any listener added here.
        var done = false, out = null, doc = null;
        var rewritten = function () {
          if (!done && xhr.readyState === 4) {
            done = true;
            try { out = applyRewriters(active, nativeGetters.responseText.call(xhr)); } catch (e) {}
          }
          return xhr.responseType === '' || xhr.responseType === 'text' ? out : null;
        };
        var define = function (k, get) {
          if (!nativeGetters[k]) return;
          try {
            Object.defineProperty(xhr, k, {
              configurable: true,
              get: function () { var v = get(); return v === null ? nativeGetters[k].call(xhr) : v; }
            });
          } catch (e) {}
        };
        define('responseText', rewritten);
        define('response', rewritten);
        // An XML reply is read as a document as often as text.
        define('responseXML', function () {
          if (rewritten() === null || xhr.responseType !== '' || !nativeGetters.responseXML.call(xhr)) return null;
          return doc || (doc = new DOMParser().parseFromString(out, 'text/xml'));
        });
      }
      return Reflect.apply(fn, xhr, args);
    });
  }
  var parsePrunes = [];
  function addParsePrune(paths, needed) {
    parsePrunes.push({ paths: paths, needed: needed });
    if (parsePrunes.length > 1) return;
    function prune(r) {
      for (var i = 0; i < parsePrunes.length; i++) {
        try { pruneObject(r, parsePrunes[i].paths, parsePrunes[i].needed); } catch (e) {}
      }
      return r;
    }
    JSON.parse = wrapNative(JSON.parse, function (fn, thisArg, args) { return prune(Reflect.apply(fn, thisArg, args)); });
    // uBO's json-prune covers Response.json() too, which never goes through JSON.parse.
    var proto = typeof Response === 'function' && Response.prototype;
    if (proto && typeof proto.json === 'function') {
      proto.json = wrapNative(proto.json, function (fn, thisArg, args) { return Reflect.apply(fn, thisArg, args).then(prune); });
    }
  }

  function jsonEditParse(path) {
    if (!path) return;
    proxyApply('JSON.parse', function (fn, thisArg, args) {
      var r = Reflect.apply(fn, thisArg, args);
      try { if (r && typeof r === 'object' && path.matches(r)) r = path.apply(r); } catch (e) {}
      return r;
    });
  }
  // A matching fetch is never sent and resolves to a 200 with the body uBO would generate.
  function preventFetch(propsToMatch, body, trusted) {
    if (typeof self.fetch !== 'function' || typeof Response !== 'function') return;
    var match = compileMatch(propsToMatch);
    self.fetch = wrapNative(self.fetch, function (fn, thisArg, args) {
      if (!match || match(fetchRequest(args))) return Promise.resolve(new Response(responseBody(body, trusted), { status: 200, statusText: 'OK' }));
      return Reflect.apply(fn, thisArg, args);
    });
  }
  // A matching XHR is never sent: it completes as a 200 with the generated body. Left to the network,
  // the content blocker would fail it, and the page would see the error.
  function preventXHR(propsToMatch, body, trusted) {
    var Native = self.XMLHttpRequest;
    if (typeof Native !== 'function' || !Native.prototype) return;
    var match = compileMatch(propsToMatch);
    var proto = Native.prototype;
    var prevented = new WeakMap();
    proto.open = wrapNative(proto.open, function (fn, xhr, args) {
      prevented.delete(xhr);
      var request = { url: resolveURL(args[1]), method: String(args[0]).toUpperCase() };
      if (!match || match(request)) prevented.set(xhr, { url: request.url, sync: args.length > 2 && !args[2] });
      return Reflect.apply(fn, xhr, args);
    });
    proto.send = wrapNative(proto.send, function (fn, xhr, args) {
      var details = prevented.get(xhr);
      if (!details) return Reflect.apply(fn, xhr, args);
      var type = xhr.responseType, text = responseBody(body, trusted), response = text;
      if (type === 'json') { try { response = nativeJSONParse(text || '{}'); } catch (e) { response = null; } }
      else if (type === 'arraybuffer') response = new ArrayBuffer(0);
      else if (type === 'blob') response = new Blob([]);
      else if (type === 'document') response = null;
      function complete() {
        var props = { readyState: 4, status: 200, statusText: 'OK', responseURL: details.url, response: response,
          responseText: type === '' || type === 'text' ? text : '' };
        for (var k in props) Object.defineProperty(xhr, k, { value: props[k], configurable: true });
        var Progress = self.ProgressEvent || Event;
        xhr.dispatchEvent(new Event('readystatechange'));
        if (details.sync) return;
        xhr.dispatchEvent(new Progress('load'));
        xhr.dispatchEvent(new Progress('loadend'));
      }
      if (details.sync) complete(); else Promise.resolve().then(complete);
    });
  }

  // Runs `transform` on every value assigned to the chain's last property. Another rule's trap on the
  // property keeps running first, and what it stores is what this one edits.
  function onAssign(owner, parts, transform) {
    var key = parts[0], stored = owner[key];
    if (parts.length > 1 && stored && typeof stored === 'object') { onAssign(stored, parts.slice(1), transform); return; }
    if (parts.length === 1 && stored !== undefined) stored = transform(stored);
    var previous = Object.getOwnPropertyDescriptor(owner, key) || {};
    try {
      Object.defineProperty(owner, key, {
        get: function () { return stored; },
        set: function (nv) {
          if (previous.set) { previous.set.call(this, nv); if (previous.get) nv = previous.get.call(this); }
          if (parts.length > 1) { stored = nv; if (nv && typeof nv === 'object') onAssign(nv, parts.slice(1), transform); }
          else stored = transform(nv);
        },
        configurable: true
      });
    } catch (e) {}
  }
  // uBO's xml-prune: drops what `selector` (CSS, or `xpath(...)`) finds in an XML reply, when
  // `check` finds something there first.
  function pruneXML(text, selector, check) {
    if (!/^\s*</.test(text) || !/>\s*$/.test(text)) return null;
    var doc = new DOMParser().parseFromString(text, 'text/xml');
    if (check && !doc.querySelector(check)) return null;
    var items = [];
    if (/^xpath\(.+\)$/.test(selector)) {
      var r = doc.evaluate(selector.slice(6, -1), doc, null, XPathResult.UNORDERED_NODE_SNAPSHOT_TYPE, null);
      for (var i = 0; i < r.snapshotLength; i++) items.push(r.snapshotItem(i));
    } else items = Array.prototype.slice.call(doc.querySelectorAll(selector));
    if (!items.length) return null;
    for (var j = 0; j < items.length; j++) {
      if (items[j].nodeType === 1) items[j].remove();
      else if (items[j].nodeType === 2) items[j].ownerElement.removeAttribute(items[j].nodeName);
    }
    return new XMLSerializer().serializeToString(doc);
  }
  // uBO's m3u-prune: a multiline pattern removes the lines it spans; any other drops each
  // #EXTINF segment whose URI line matches, with the discontinuity after it.
  function pruneM3U(text, re) {
    if (!/^\s*#EXTM3U/.test(text)) return null;
    if (re.multiline) return text.replace(re.global ? re : new RegExp(re.source, re.flags + 'g'), '').replace(/\n{2,}/g, '\n');
    var lines = text.split(/\r\n|\n|\r/), out = [];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].indexOf('#EXTINF') === 0 && i + 1 < lines.length && re.test(lines[i + 1])) {
        i++;
        if (i + 1 < lines.length && lines[i + 1].indexOf('#EXT-X-DISCONTINUITY') === 0) i++;
        continue;
      }
      out.push(lines[i]);
    }
    return out.length === lines.length ? null : out.join('\n');
  }

  // ---------- scriptlet registry ----------
  var S = {
    'json-prune': function (rawPaths, rawNeeded) {
      var paths = (rawPaths || '').split(/\s+/).filter(Boolean);
      var needed = (rawNeeded || '').split(/\s+/).filter(Boolean);
      if (paths.length) addParsePrune(paths, needed);
    },
    'json-prune-fetch-response': function (rawPaths, rawNeeded, a, b) {
      var paths = (rawPaths || '').split(/\s+/).filter(Boolean);
      var needed = (rawNeeded || '').split(/\s+/).filter(Boolean);
      if (paths.length) addFetchRewriter(propsToMatchArg(a, b), { paths: paths, needed: needed });
    },
    'json-prune-xhr-response': function (rawPaths, rawNeeded, a, b) {
      var paths = (rawPaths || '').split(/\s+/).filter(Boolean);
      var needed = (rawNeeded || '').split(/\s+/).filter(Boolean);
      if (paths.length) addXHRRewriter(propsToMatchArg(a, b), { paths: paths, needed: needed });
    },
    'set-constant': function (chain, value) { if (chain) defineChain(self, chain, coerce(value)); },
    'trusted-set-constant': function (chain, value) {
      if (!chain) return;
      var v = value;
      if ((value || '').indexOf('json:') === 0) { try { v = nativeJSONParse(value.slice(5)); } catch (e) { return; } }
      else v = coerce(value);
      defineChain(self, chain, v);
    },
    'edit-object-on-setter': function (chain, query) {
      var path = chain ? compileJSONPath(query, false) : null;
      if (path) onAssign(self, chain.split('.'), function (v) { return v && typeof v === 'object' && path.matches(v) ? path.apply(v) : v; });
    },
    // Arguments match by position: "" any, a JSON value by equality, a "/regex/" against the text.
    'trusted-suppress-native-method': function (method, signature, how, stack) {
      if (!method) return;
      var parts = (signature || '').split('|').map(function (p) {
        if (p === '') return null;
        var v = p;
        try { v = nativeJSONParse(p); } catch (e) {}
        return typeof v === 'string' && /^\/.+\/[a-z]*$/.test(v) ? { re: toRegExp(v) } : { eq: v };
      });
      var negate = !!stack && stack[0] === '!';
      var stackRe = stack ? toRegExp(negate ? stack.slice(1) : stack) : null;
      proxyApply(method, function (fn, thisArg, args) {
        var hit = parts.every(function (p, i) { return !p || (p.re ? p.re.test(String(args[i])) : args[i] === p.eq); });
        if (hit && stackRe) hit = stackMatches(stackRe, negate);
        if (!hit) return Reflect.apply(fn, thisArg, args);
        if (how !== 'prevent') throw new ReferenceError('lilo');
      });
    },
    'prevent-innerHTML': function (selector, pattern) {
      var proto = self.Element && self.Element.prototype;
      var desc = proto && Object.getOwnPropertyDescriptor(proto, 'innerHTML');
      if (!desc || !desc.set) return;
      var negate = !!pattern && pattern[0] === '!';
      var re = toRegExp(negate ? pattern.slice(1) : pattern);
      Object.defineProperty(proto, 'innerHTML', {
        configurable: true, enumerable: desc.enumerable, get: desc.get,
        set: function (v) {
          var matches = !selector || (typeof this.matches === 'function' && this.matches(selector));
          if (matches && re.test(String(v)) !== negate) return;
          desc.set.call(this, v);
        }
      });
    },
    'xml-prune': function (selector, check, urlPattern) {
      if (!selector) return;
      var entry = { fn: function (txt) { return pruneXML(txt, selector, check); } };
      addFetchRewriter(urlPattern, entry);
      addXHRRewriter(urlPattern, { fn: entry.fn });
    },
    'm3u-prune': function (pattern, urlPattern) {
      if (!pattern) return;
      var re = toRegExp(pattern);
      var entry = { fn: function (txt) { return pruneM3U(txt, re); } };
      addFetchRewriter(urlPattern, entry);
      addXHRRewriter(urlPattern, { fn: entry.fn });
    },
    // Rewrites tracking links to the destination they carry: their text, an attribute (`[attr]`),
    // or a query parameter (`?param`).
    'href-sanitizer': function (selector, source) {
      if (!selector) return;
      source = source || 'text';
      stripNodes(selector, ['href'], function (el) {
        if (el.localName !== 'a' || !el.hasAttribute('href')) return;
        var target = '';
        if (source === 'text') target = (el.textContent || '').trim();
        else if (/^\[.+\]$/.test(source)) target = el.getAttribute(source.slice(1, -1).trim()) || '';
        else if (source[0] === '?') { try { target = new URL(el.href).searchParams.get(source.slice(1)) || ''; } catch (e) {} }
        if (!/^https?:\/\//.test(target)) return;
        try { target = new URL(target).href; } catch (e) { return; }
        if (el.getAttribute('href') !== target) el.setAttribute('href', target);
      }, 'stay');
    },
    'set-attr': function (selector, attr, value) { setAttr(selector, attr, value, false); },
    'trusted-set-attr': function (selector, attr, value) { setAttr(selector, attr, value, true); },
    'trusted-create-html': function (parentSelector, html, duration) {
      if (!parentSelector || !html) return;
      var ms = parseInt(duration, 10) || 0;
      var parsed = new DOMParser().parseFromString(html, 'text/html'), nodes = [];
      while (parsed.body.firstChild) nodes.push(document.adoptNode(parsed.body.firstChild));
      if (!nodes.length) return;
      function append() {
        var parent = document.querySelector(parentSelector);
        if (!parent) return false;
        parent.append.apply(parent, nodes);
        if (ms > 0) setTimeout(function () { nodes.forEach(function (node) { node.remove(); }); }, ms);
        return true;
      }
      if (append()) return;
      var observer = new MutationObserver(function () { if (append()) observer.disconnect(); });
      observer.observe(document, { childList: true, subtree: true });
    },
    // PopAds reads its setup from these globals; held inert, its own assignments are ignored.
    'popads-dummy': function () {
      var inert = Object.freeze({});
      ['PopAds', 'popns'].forEach(function (name) {
        try { Object.defineProperty(self, name, { get: function () { return inert; }, set: function () {} }); } catch (e) {}
      });
    },
    // FuckAdBlock and BlockAdBlock look-alikes: every check comes back "not detected", and the
    // page's own copies, assigned later, are ignored.
    'fuckadblock-defuser': function () {
      var detector = {};
      var chain = function () { return detector; };
      detector.check = detector.emitEvent = detector.clearEvent = detector.setOption = detector.onDetected = chain;
      detector.onNotDetected = function (fn) { if (typeof fn === 'function') fn(); return detector; };
      detector.on = function (detected, fn) { return detected ? detector : detector.onNotDetected(fn); };
      // Called with `new`, it still hands back the one shared detector.
      var Detector = function () { return detector; };
      Detector.prototype = detector;
      var globals = { FuckAdBlock: Detector, BlockAdBlock: Detector, fuckAdBlock: detector, blockAdBlock: detector };
      Object.keys(globals).forEach(function (name) {
        try { Object.defineProperty(self, name, { get: function () { return globals[name]; }, set: function () {} }); } catch (e) {}
      });
    },
    // BlockAdBlock's loader arrives as one large eval'd string naming its own markers; skipping it
    // means no check runs. Short eval strings skip the regex, so ordinary eval stays cheap.
    'bab-defuser': function () {
      var marker = /blockadblock|babasbm|getItem\(['"]babn['"]\)/i;
      var restored = false;
      function restorePage() {
        if (restored) return;
        restored = true;
        whenReady('interactive', function () {
          if (document.body) document.body.style.removeProperty('visibility');
          var notice = document.getElementById('babasbmsgx');
          if (notice) notice.remove();
        });
      }
      proxyApply('eval', function (fn, thisArg, args) {
        var code = args[0];
        if (typeof code === 'string' && code.length > 512 && marker.test(code)) { restorePage(); return; }
        return Reflect.apply(fn, thisArg, args);
      });
      // Its later re-check is a string timer probing the bait element.
      proxyApply('setTimeout', function (fn, thisArg, args) {
        if (typeof args[0] === 'string' && args[0].indexOf('bab_elementid') >= 0) return;
        return Reflect.apply(fn, thisArg, args);
      });
    },
    // Stops a <meta http-equiv="refresh"> once its delay (or the given one) runs out.
    'refresh-defuser': function (delay) {
      whenReady('interactive', function () {
        var meta = document.querySelector('meta[http-equiv="refresh" i][content]');
        if (!meta) return;
        var seconds = Math.max(parseFloat(delay || meta.getAttribute('content')) || 0, 0);
        setTimeout(function () { self.stop(); }, seconds * 1000);
      });
    },
    // A call of the method on an element matching `selector` does nothing, throws, or returns a constant.
    'trusted-override-element-method': function (method, selector, disposition) {
      if (!method) return;
      var value = coerce(disposition || 'undefined');
      if (disposition !== 'throw' && typeof value === 'string' && value !== '') return;
      proxyApply(method, function (fn, thisArg, args) {
        var matches = false;
        try { matches = thisArg instanceof self.Element && (!selector || thisArg.matches(selector)); } catch (e) {}
        if (!matches) return Reflect.apply(fn, thisArg, args);
        if (disposition === 'throw') throw new ReferenceError('lilo');
        return value;
      });
    },
    // What getComputedStyle() and getBoundingClientRect() report of the elements `selector` matches: property, value pairs
    // (dashed or camel-cased), `_rectx`, `_recty`, `_rectw` and `_recth` for the rectangle, which `width` and `height` set too.
    'spoof-css': function (selector) {
      if (!selector) return;
      var spoofed = {}, count = 0;
      for (var i = 1; i + 1 < arguments.length; i += 2) {
        var name = arguments[i].replace(/[A-Z]/g, function (c) { return '-' + c.toLowerCase(); });
        if (name !== '_debug') { spoofed[name] = arguments[i + 1]; count++; }
      }
      if (!count) return;
      function matches(el) {
        try { return el instanceof self.Element && el.matches(selector); } catch (e) { return false; }
      }
      function spoofedValue(prop) {
        if (typeof prop !== 'string') return undefined;
        var name = prop.replace(/[A-Z]/g, function (c) { return '-' + c.toLowerCase(); });
        return name[0] !== '_' && hasOwn.call(spoofed, name) ? spoofed[name] : undefined;
      }
      proxyApply('getComputedStyle', function (fn, thisArg, args) {
        var style = Reflect.apply(fn, thisArg, args);
        if (!matches(args[0])) return style;
        return new Proxy(style, {
          get: function (target, prop) {
            var v = spoofedValue(prop);
            if (v !== undefined) return v;
            if (prop === 'getPropertyValue') {
              return function (name) { var s = spoofedValue(name); return s !== undefined ? s : target.getPropertyValue(name); };
            }
            v = Reflect.get(target, prop, target);
            return typeof v === 'function' ? v.bind(target) : v;
          }
        });
      });
      var rect = { x: spoofed._rectx, y: spoofed._recty, width: spoofed._rectw || spoofed.width, height: spoofed._recth || spoofed.height };
      if (rect.x === undefined && rect.y === undefined && rect.width === undefined && rect.height === undefined) return;
      proxyApply('Element.prototype.getBoundingClientRect', function (fn, thisArg, args) {
        var r = Reflect.apply(fn, thisArg, args);
        if (!matches(thisArg) || typeof self.DOMRect !== 'function') return r;
        function pick(k) { var v = parseFloat(rect[k]); return isNaN(v) ? r[k] : v; }
        return new self.DOMRect(pick('x'), pick('y'), pick('width'), pick('height'));
      });
    },
    // A click on a link with a `target` (or inside one) does not open it.
    'disable-newtab-links': function () {
      document.addEventListener('click', function (event) {
        for (var el = event.target; el; el = el.parentElement) {
          if (el.localName === 'a' && el.hasAttribute('target')) { event.preventDefault(); event.stopPropagation(); return; }
        }
      }, true);
    },
    'no-requestAnimationFrame-if': function (needle) {
      var negate = !!needle && needle[0] === '!';
      var re = toRegExp(negate ? needle.slice(1) : needle);
      proxyApply('requestAnimationFrame', function (fn, thisArg, args) {
        if (re.test(String(args[0])) !== negate) return 0;
        return Reflect.apply(fn, thisArg, args);
      });
    },
    'abort-on-property-read': function (chain) { if (chain) abortOnProperty(self, chain.split('.'), always, null); },
    'abort-on-property-write': function (chain) { if (chain) abortOnProperty(self, chain.split('.'), null, always); },
    'abort-on-stack-trace': function (chain, needle) {
      if (!chain) return;
      var negate = !!needle && needle[0] === '!';
      var re = toRegExp(negate ? needle.slice(1) : needle);
      var check = function () { return stackMatches(re, negate); };
      abortOnProperty(self, chain.split('.'), check, check);
    },
    'abort-current-script': function (prop, search) {
      if (!prop) return;
      var re = search ? toRegExp(search) : null;
      // A hot property (`EventTarget.prototype.addEventListener`) is read thousands of times by one
      // script: its verdict is kept, so a large inline script is not copied and searched on every read.
      var verdicts = new WeakMap();
      // uBO semantics: abort only reads made by a <script> whose text (or src) matches the needle;
      // with no needle, any inline script.
      abortOnProperty(self, prop.split('.'), function () {
        var script = document.currentScript;
        if (!(script instanceof HTMLScriptElement)) return false;
        if (!re) return !script.src;
        var verdict = verdicts.get(script);
        if (verdict === undefined) {
          verdict = re.test(script.textContent) || (!!script.src && re.test(script.src));
          verdicts.set(script, verdict);
        }
        return verdict;
      }, null);
    },
    'no-setTimeout-if': function (search, delay) { neutralizeTimer('setTimeout', search, delay); },
    'no-setInterval-if': function (search, delay) { neutralizeTimer('setInterval', search, delay); },
    'no-fetch-if': function (propsToMatch, body) { preventFetch(propsToMatch, body, false); },
    'trusted-prevent-fetch': function (propsToMatch, body) { preventFetch(propsToMatch, body, true); },
    'no-xhr-if': function (propsToMatch, body) { preventXHR(propsToMatch, body, false); },
    'trusted-prevent-xhr': function (propsToMatch, body) { preventXHR(propsToMatch, body, true); },
    'noeval': function () { proxyApply('eval', function () {}); },
    'noeval-if': function (needle) {
      if (!needle) return;
      var re = toRegExp(needle);
      proxyApply('eval', function (fn, thisArg, args) {
        if (re.test(String(args[0]))) return;
        return Reflect.apply(fn, thisArg, args);
      });
    },
    'json-edit': function (query) { jsonEditParse(compileJSONPath(query, false)); },
    'trusted-json-edit': function (query) { jsonEditParse(compileJSONPath(query, true)); },
    'json-edit-fetch-response': function (query, a, b) {
      var path = compileJSONPath(query, false);
      if (path) addFetchRewriter(propsToMatchArg(a, b), jsonEditEntry(path));
    },
    'trusted-json-edit-fetch-response': function (query, a, b) {
      var path = compileJSONPath(query, true);
      if (path) addFetchRewriter(propsToMatchArg(a, b), jsonEditEntry(path));
    },
    'json-edit-xhr-response': function (query, a, b) {
      var path = compileJSONPath(query, false);
      if (path) addXHRRewriter(propsToMatchArg(a, b), jsonEditEntry(path));
    },
    'trusted-json-edit-xhr-response': function (query, a, b) {
      var path = compileJSONPath(query, true);
      if (path) addXHRRewriter(propsToMatchArg(a, b), jsonEditEntry(path));
    },
    'jsonl-edit-xhr-response': function (query, a, b) {
      var path = compileJSONPath(query, false);
      if (path) addXHRRewriter(propsToMatchArg(a, b), jsonlEditEntry(path));
    },
    'trusted-replace-argument': function (chain, argPos, argRaw) {
      if (!chain || !argPos) return;
      var options = optionPairs(arguments, 3);
      var cond = options.condition !== undefined ? toRegExp(options.condition) : null;
      var replacer = null, delta = NaN, value;
      argRaw = argRaw || '';
      if (argRaw.indexOf('repl:') === 0) { replacer = parseReplace(argRaw.slice(5)); if (!replacer) return; }
      else if (argRaw.indexOf('add:') === 0) { delta = parseFloat(argRaw.slice(4)); if (isNaN(delta)) return; }
      else if (argRaw.indexOf('json:') === 0) { try { value = nativeJSONParse(argRaw.slice(5)); } catch (e) { return; } }
      else value = coerce(argRaw);
      var offset = parseInt(argPos, 10) || 0;
      proxyApply(chain, function (fn, thisArg, args) {
        var i = argPos === 'this' ? -1 : offset >= 0 ? offset : args.length + offset;
        if (argPos !== 'this' && (i < 0 || i >= args.length)) return Reflect.apply(fn, thisArg, args);
        var before = i < 0 ? thisArg : args[i];
        if (!cond || cond.test(String(before))) {
          var after = replacer ? (typeof before === 'string' ? before.replace(replacer.re, replacer.replacement) : before)
            : !isNaN(delta) ? (typeof before === 'number' ? before + delta : before) : value;
          if (i < 0) thisArg = after; else args[i] = after;
        }
        return Reflect.apply(fn, thisArg, args);
      });
    },
    'trusted-replace-outbound-text': function (chain, pattern, replacement) {
      if (!chain || !pattern) return;
      var options = optionPairs(arguments, 3);
      var re = toRegExp(pattern), cond = toRegExp(options.condition || '');
      var rep = replacement || '';
      if (rep.indexOf('json:') === 0) { try { rep = nativeJSONParse(rep.slice(5)); } catch (e) { return; } }
      var base64 = options.encoding === 'base64';
      proxyApply(chain, function (fn, thisArg, args) {
        var encoded = Reflect.apply(fn, thisArg, args);
        if (typeof encoded !== 'string') return encoded;
        try {
          var text = base64 ? self.atob(encoded) : encoded;
          if (!cond.test(text)) return encoded;
          var after = text.replace(re, rep);
          return after === text ? encoded : base64 ? self.btoa(after) : after;
        } catch (e) { return encoded; }
      });
    },
    'remove-attr': function (rawTokens, selector, behavior) {
      if (!rawTokens) return;
      var tokens = rawTokens.split(/\s*\|\s*/);
      var sel = tokens.map(function (t) { return (selector || '') + '[' + cssEscape(t) + ']'; }).join(',');
      stripNodes(sel, tokens, function (node) {
        for (var i = 0; i < tokens.length; i++) node.removeAttribute(tokens[i]);
      }, behavior);
    },
    'remove-class': function (rawTokens, selector, behavior) {
      if (!rawTokens) return;
      var tokens = rawTokens.split(/\s*\|\s*/);
      var sel = selector || '.' + tokens.map(cssEscape).join(',.');
      stripNodes(sel, ['class'], function (node) { node.classList.remove.apply(node.classList, tokens); }, behavior);
    },
    'remove-cookie': function (needle) {
      var re = toRegExp(needle);
      function remove() {
        var cookies = document.cookie.split(';'), parts = location.hostname.split('.');
        for (var c = 0; c < cookies.length; c++) {
          var name = cookies[c].split('=')[0].trim();
          if (!name || !re.test(name)) continue;
          var expired = name + '=; expires=Thu, 01 Jan 1970 00:00:00 GMT';
          var domains = [''];
          for (var i = 0; i < parts.length - 1; i++) {
            var d = parts.slice(i).join('.');
            domains.push('; domain=' + d, '; domain=.' + d);
          }
          for (var j = 0; j < domains.length; j++) {
            document.cookie = expired + domains[j];
            document.cookie = expired + domains[j] + '; path=/';
          }
        }
      }
      remove();
      self.addEventListener('beforeunload', remove);
    },
    // Peer connections can still be built, but never negotiate, gather ICE candidates or open a
    // channel, so a page cannot read local addresses through WebRTC. The native class is left untouched.
    'nowebrtc': function () {
      var names = ['RTCPeerConnection', 'webkitRTCPeerConnection'].filter(function (n) { return typeof self[n] === 'function'; });
      if (!names.length) return;
      function refuse() { return Promise.reject(new DOMException('WebRTC is disabled', 'NotAllowedError')); }
      function nothing() { return []; }
      function PeerConnection() { return Reflect.construct(EventTarget, [], PeerConnection); }
      var proto = PeerConnection.prototype = Object.create(EventTarget.prototype);
      proto.constructor = PeerConnection;
      ['createOffer', 'createAnswer', 'setLocalDescription', 'setRemoteDescription', 'addIceCandidate'].forEach(function (m) { proto[m] = refuse; });
      ['getSenders', 'getReceivers', 'getTransceivers'].forEach(function (m) { proto[m] = nothing; });
      ['connectionState', 'iceConnectionState', 'signalingState'].forEach(function (k) {
        Object.defineProperty(proto, k, { get: function () { return 'closed'; } });
      });
      proto.getStats = function () { return Promise.resolve(new Map()); };
      proto.createDataChannel = function (label) {
        var channel = new EventTarget();
        channel.label = String(label);
        channel.readyState = 'closed';
        channel.send = channel.close = function () {};
        return channel;
      };
      proto.close = function () {};
      PeerConnection.generateCertificate = refuse;
      names.forEach(function (n) { self[n] = PeerConnection; });
    },
    'no-window-open-if': function (pattern) {
      var re = toRegExp(pattern);
      var _open = self.open;
      self.open = function (url) { if (re.test(String(url || ''))) return null; return _open.apply(this, arguments); };
    },
    'prevent-addEventListener': function (type, pattern) {
      var reType = type ? toRegExp(type) : null, rePat = pattern ? toRegExp(pattern) : null;
      var proto = self.EventTarget && self.EventTarget.prototype;
      if (!proto || !proto.addEventListener) return;
      var _add = proto.addEventListener;
      proto.addEventListener = function (t, listener) {
        try {
          // Same as the timers: every listener the page adds passes here, so stringify only when
          // the type matches and a pattern needs it.
          if (!reType || reType.test(String(t))) {
            if (!rePat || rePat.test((typeof listener === 'function') ? listener.toString() : String(listener))) return;
          }
        } catch (e) {}
        return _add.apply(this, arguments);
      };
    },
    'trusted-replace-fetch-response': function (pattern, replacement, propsToMatch) {
      var re = toRegExp(pattern), rep = (replacement === undefined) ? '' : replacement;
      addFetchRewriter(propsToMatch, { fn: function (txt) { return txt.replace(re, rep); } });
    },
    'trusted-replace-xhr-response': function (pattern, replacement, propsToMatch) {
      var re = toRegExp(pattern), rep = (replacement === undefined) ? '' : replacement;
      addXHRRewriter(propsToMatch, { fn: function (txt) { return txt.replace(re, rep); } });
    },
    'set-cookie': function (name, value, path) {
      setCookie(false, name, value || '', '', path, optionPairs(arguments, 3));
    },
    'set-cookie-reload': function (name, value, path) {
      setCookie(false, name, value || '', '', path, { reload: '1' });
    },
    'trusted-set-cookie-reload': function (name, value, offsetExpiresSec, path) {
      var seconds = offsetExpiresSec === '1day' ? 86400 : offsetExpiresSec === '1year' ? 31536000 : parseInt(offsetExpiresSec, 10);
      var expires = seconds > 0 ? new Date(Date.now() + seconds * 1000).toUTCString() : '';
      setCookie(true, name, expandDates(value || '', new Date().toUTCString()), expires, path, { reload: '1' });
    },
    'trusted-set-cookie': function (name, value, offsetExpiresSec, path) {
      var seconds = offsetExpiresSec === '1day' ? 86400 : offsetExpiresSec === '1year' ? 31536000 : parseInt(offsetExpiresSec, 10);
      var expires = seconds > 0 ? new Date(Date.now() + seconds * 1000).toUTCString() : '';
      setCookie(true, name, expandDates(value || '', new Date().toUTCString()), expires, path, optionPairs(arguments, 4));
    },
    'set-local-storage-item': function (key, value) { setStorageItem('localStorage', key, value || ''); },
    'trusted-set-local-storage-item': function (key, value) {
      setStorageItem('localStorage', key, expandDates(value || '', String(new Date())));
    },
    'set-session-storage-item': function (key, value) { setStorageItem('sessionStorage', key, value || ''); },
    'trusted-set-session-storage-item': function (key, value) {
      setStorageItem('sessionStorage', key, expandDates(value || '', String(new Date())));
    },
    'replace-node-text': function (nodeName, pattern, replacement) {
      replaceNodeText(nodeName, pattern, replacement, optionPairs(arguments, 3));
    },
    'remove-node-text': function (nodeName, includes) {
      var options = optionPairs(arguments, 2);
      options.includes = includes;
      replaceNodeText(nodeName, '', '', options);
    },
    'adjust-setTimeout': function (needle, delay, boost) { adjustTimer('setTimeout', needle, delay, boost); },
    'adjust-setInterval': function (needle, delay, boost) { adjustTimer('setInterval', needle, delay, boost); },
    // A same-origin frame the method inserts gets the page's (filtered) `target`, or the page's whole
    // window, so its pristine copy cannot bypass the scriptlets.
    'trusted-prevent-dom-bypass': function (method, target) {
      if (!method) return;
      proxyApply(method, function (fn, thisArg, args) {
        var r = Reflect.apply(fn, thisArg, args);
        for (var i = 0; i < args.length; i++) {
          try {
            var el = args[i], win = el && el.contentWindow;
            if (!win || String(win) !== '[object Window]') continue;
            var href = win.location.href;
            if (href !== 'about:blank' && href !== location.href) continue;
            if (!target) { Object.defineProperty(el, 'contentWindow', { value: self }); continue; }
            var parts = target.split('.'), mine = self, theirs = win, j = 0;
            for (; j < parts.length - 1; j++) { mine = mine[parts[j]]; theirs = theirs[parts[j]]; }
            theirs[parts[j]] = mine[parts[j]];
          } catch (e) {}
        }
        return r;
      });
    },
    // Edits a copy of the object passed as argument `argPos` of the method, when the JSONPath matches.
    'trusted-edit-inbound-object': function (method, argPos, query) {
      var path = method ? compileJSONPath(query, true) : null;
      var pos = parseInt(argPos, 10);
      if (!path || isNaN(pos)) return;
      proxyApply(method, function (fn, thisArg, args) {
        var i = pos >= 0 ? pos : args.length + pos;
        var obj = args[i];
        if (i >= 0 && i < args.length && obj && typeof obj === 'object') {
          try {
            if (path.matches(obj)) args[i] = path.apply(nativeJSONParse(nativeJSONStringify(obj)));
          } catch (e) {}
        }
        return Reflect.apply(fn, thisArg, args);
      });
    },
    // Clicks each comma-separated selector in turn: a single one after `delay` ms, a sequence its first
    // at once and the next ones `delay` apart. Polls for each element until a 10 s deadline, without the
    // cost of observing every mutation of a loading page.
    'trusted-click-element': function (selectors, extraMatch, delay) {
      // Cookie and storage preconditions are not implemented: such a rule does not run.
      if (extraMatch) return;
      var list = (selectors || '').split(/\s*,\s*/).filter(Boolean);
      if (!list.length) return;
      var step = parseInt(delay, 10) || 1;
      var deadline = Date.now() + 10000;
      var next = list.length > 1 ? 0 : Date.now() + step;
      (function poll() {
        var now = Date.now();
        if (now >= deadline) return;
        if (now >= next) {
          var el;
          try { el = querySelectorEx(list[0], document); } catch (e) { return; }
          if (el) {
            el.click();
            list.shift();
            if (!list.length) return;
            next = now + step;
          }
        }
        setTimeout(poll, Math.max(next - now, 100));
      })();
    }
  };

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

  // ---------- dispatch ----------
  var ancestors = location.ancestorOrigins;
  // A frame without a host of its own (about:blank, srcdoc) runs its parent's scriptlets, as uBO does:
  // a page creating one to reach pristine fetch or JSON.parse finds them patched too. WebKit injects
  // the script there synchronously, before the page can read the new frame.
  var hostname = location.hostname ||
    (ancestors && ancestors.length ? ancestors[0].replace(/^[^:]+:\/\//, '').replace(/:\d+$/, '') : '');
  if (!hostname) return;
  // An allowlisted site runs no filtering, as the rule list stands down for it (if-top-url). A frame
  // goes by its top document, like the rule list; `www.` is optional on the site, as in its rule.
  var ALLOWLIST = __LILO_ALLOWLIST__;
  var topHost = ancestors && ancestors.length
    ? ancestors[ancestors.length - 1].replace(/^[^:]+:\/\//, '')
    : location.host;
  // A hostless top document (about:blank, file:) must not match the empty list's "||".
  if (topHost && (ALLOWLIST.indexOf('|' + topHost + '|') >= 0 ||
      ALLOWLIST.indexOf('|' + topHost.replace(/^www\./, '') + '|') >= 0)) return;
  // The table covers thousands of hosts and is injected into every frame. An entry is a scriptlet's
  // base-36 index into NAMES and its args, joined by \xa6.
  var INDEX = __LILO_SCRIPTLET_INDEX__;
  var GROUPS = __LILO_SCRIPTLET_GROUPS__;
  var TABLE = __LILO_SCRIPTLET_TABLE__;
  var NAMES = __LILO_SCRIPTLET_NAMES__.split(' ');
  // A uBO `example.*` entry names the site under any public suffix: try the host with its last label,
  // and with a likely two-label suffix (co.uk, com.br), replaced by `*`.
  var parts = hostname.split('.');
  var n = parts.length, twoLabelSuffix = n > 2 && parts[n - 1].length === 2 && parts[n - 2].length <= 3;
  var hosts = [];
  for (var h = 0; h < n - 1; h++) {
    hosts.push(parts.slice(h).join('.'), parts.slice(h, n - 1).join('.') + '.*');
    if (twoLabelSuffix && h < n - 2) hosts.push(parts.slice(h, n - 2).join('.') + '.*');
  }
  // An entry starting with `@` excepts the same entry on this host and its subdomains, `@` alone every scriptlet. A rule
  // naming both the host and its entity runs once.
  var entries = new Set(), excepted = new Set();
  for (var i = 0; i < hosts.length; i++) {
    var found = lookup(INDEX, GROUPS, TABLE, hosts[i]);
    for (var f = 0; f < found.length; f++) {
      if (found[f][0] === '@') excepted.add(found[f].slice(1)); else entries.add(found[f]);
    }
  }
  if (excepted.has('')) return;
  entries.forEach(function (raw) {
    if (excepted.has(raw)) return;
    var entry = raw.split('\xa6').map(decodeEntry);
    var fn = S[NAMES[parseInt(entry[0], 36)]];
    if (fn) { try { fn.apply(null, entry.slice(1)); } catch (err) {} }
  });
})();
