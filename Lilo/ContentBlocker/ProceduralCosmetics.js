/*lilo-procedural*/
(function () {
  'use strict';

  var OP_NAMES = ['has-text', 'contains', '-abp-contains',
                  'matches-css-before', 'matches-css-after', 'matches-css',
                  'style', 'upward', 'nth-ancestor', 'xpath', 'remove-attr', 'remove-class', 'remove',
                  'matches-attr', 'matches-path', 'others', '-abp-properties'];

  function toRegExp(arg) {
    var m = /^\/(.+)\/([a-z]*)$/.exec(arg);
    // g and y make test() stateful through lastIndex; the compiled regexps are cached and reused.
    if (m) { try { return new RegExp(m[1], m[2].replace(/[gy]/g, '')); } catch (e) {} }
    return new RegExp(String(arg).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  }

  // A name or value: a /regex/, or else the exact (quoted or bare) string.
  function exactOrRegExp(arg) {
    arg = arg.trim().replace(/^"(.*)"$/, '$1');
    if (/^\/.+\/[a-z]*$/.test(arg)) return toRegExp(arg);
    return new RegExp('^' + arg.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$');
  }

  function closingParen(sel, start) {
    for (var d = 1, j = start; j < sel.length; j++) {
      if (sel[j] === '(') d++;
      else if (sel[j] === ')' && --d === 0) return j;
    }
    return sel.length;
  }

  function parseSelector(sel) {
    // A leading :matches-path(), or its negation, conditions the whole selector on the page's path and query.
    var path = null, pathNegated = false, lead = /^(:not\()?:matches-path\(((?:[^()]|\([^()]*\))*)\)(\))?\s*/.exec(sel);
    if (lead && !lead[1] === !lead[3]) { path = toRegExp(lead[2]); pathNegated = !!lead[1]; sel = sel.slice(lead[0].length); }
    var ops = [], css = '', i = 0, n = sel.length, depth = 0, captured = false;
    while (i < n) {
      var c = sel[i];
      // A :has() or :not() is procedural when its argument is, and is then evaluated in the context of each element.
      var logical = c === ':' && depth === 0 && /^:(has|not)\(/.exec(sel.slice(i, i + 5));
      if (logical) {
        var subStart = i + logical[0].length, subEnd = closingParen(sel, subStart);
        var sub = parseSelector(sel.slice(subStart, subEnd));
        if (!sub) return null;
        if (sub.ops.length || sub.path) {
          if (!captured) { css = sel.slice(0, i).trim(); captured = true; }
          ops.push({ name: logical[1], sub: sub });
          i = subEnd + 1; continue;
        }
      }
      if (c === ':' && depth === 0) {
        var matched = null;
        for (var k = 0; k < OP_NAMES.length; k++) {
          var name = OP_NAMES[k];
          if (sel.substr(i + 1, name.length) === name && sel[i + 1 + name.length] === '(') { matched = name; break; }
        }
        if (matched) {
          if (!captured) { css = sel.slice(0, i).trim(); captured = true; }
          var argStart = i + 1 + matched.length + 1, j = closingParen(sel, argStart);
          var arg = sel.slice(argStart, j), op = { name: matched, arg: arg };
          if (matched === 'has-text' || matched === 'contains' || matched === '-abp-contains') {
            op.re = toRegExp(arg);
          } else if (matched === 'matches-path') {
            op.re = toRegExp(arg);
          } else if (matched === 'remove-attr' || matched === 'remove-class') {
            op.re = exactOrRegExp(arg);
          } else if (matched === 'matches-attr') {
            var pair = /^("[^"]*"|\/(?:\\.|[^/])+\/[a-z]*|[^=]+)(?:=(.*))?$/.exec(arg.trim());
            if (!pair) return null;
            op.attr = exactOrRegExp(pair[1]);
            op.value = pair[2] === undefined ? null : exactOrRegExp(pair[2]);
          } else if (matched === 'matches-css' || matched === 'matches-css-before' || matched === 'matches-css-after') {
            var colon = arg.indexOf(':');
            op.prop = arg.slice(0, colon).trim();
            op.re = toRegExp(arg.slice(colon + 1).trim());
          } else if (matched === '-abp-properties') {
            // ABP matches property names case-insensitively, `*` as a wildcard, spaces after `:` and `;` optional.
            op.compact = !/^\/.+\/[a-z]*$/.test(arg);
            op.re = !op.compact ? toRegExp(arg)
              : new RegExp(arg.replace(/([:;])\s+/g, '$1').trim().replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*'), 'i');
          }
          ops.push(op);
          i = j + 1; continue;
        }
      }
      // Plain CSS after an operator (`div:has-text(Ad) > span`) selects relative to the operator's
      // result, which is not implemented: dropping it would hide the ancestor, so the rule is skipped.
      if (captured && !/\s/.test(c)) return null;
      if (c === '(') depth++;
      else if (c === ')') depth--;
      i++;
    }
    if (!captured) css = sel.trim();
    return { css: css, ops: ops, path: path, pathNegated: pathNegated };
  }

  function upward(el, arg) {
    if (/^\d+$/.test(arg)) { var k = parseInt(arg, 10); while (k-- > 0 && el) el = el.parentElement; return el; }
    return (el && el.parentElement) ? el.parentElement.closest(arg) : null;
  }

  function xpathNodes(nodes, css, arg, root) {
    var out = [];
    function evalOn(ctx) {
      try {
        var r = document.evaluate(arg, ctx, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
        for (var k = 0; k < r.snapshotLength; k++) { var nd = r.snapshotItem(k); if (nd && nd.nodeType === 1) out.push(nd); }
      } catch (e) {}
    }
    if (!css) evalOn(root);
    else for (var i = 0; i < nodes.length; i++) evalOn(nodes[i]);
    return out;
  }

  // Table entries spell `\`, `"`, line breaks and other special characters with Latin-1 marks (see WKEngineFactory.hostTable).
  function decodeEntry(s) {
    return /[\xa4\xac\xb5\xb6]/.test(s) ? s.replace(/\xb5([0-9a-f]{4})|[\xa4\xac\xb6]/g, function (m, hex) {
      return hex ? String.fromCharCode(parseInt(hex, 16)) : m === '\xa4' ? '\\' : m === '\xac' ? '"' : '\n';
    }) : s;
  }

  var done = new WeakSet();
  function applyAction(el, action) {
    if (!el || el.nodeType !== 1) return;
    if (action.type === 'remove') { try { el.remove(); } catch (e) {} return; }
    // Attributes and classes can come back: these run on every pass.
    if (action.type === 'remove-attr') {
      Array.prototype.slice.call(el.attributes).forEach(function (a) { if (action.re.test(a.name)) el.removeAttribute(a.name); });
      return;
    }
    if (action.type === 'remove-class') {
      Array.prototype.slice.call(el.classList).forEach(function (c) { if (action.re.test(c)) el.classList.remove(c); });
      return;
    }
    if (done.has(el)) return;
    if (action.type === 'style') { try { el.style.cssText += ';' + action.css; } catch (e) {} }
    else { try { el.style.setProperty('display', 'none', 'important'); } catch (e) {} }
    done.add(el);
  }

  // Text read during the current pass: several selectors often test the same elements.
  var texts = null;
  function textOf(el) {
    var t = texts.get(el);
    if (t === undefined) { t = el.textContent || ''; texts.set(el, t); }
    return t;
  }

  // What :others() selects: every element but the subjects, their ancestors and their descendants. Hiding the outermost of
  // them, the children of the ancestors that are none of those, hides the rest.
  function others(subjects) {
    var kept = new Set(), isSubject = new Set(subjects), out = [];
    for (var s = 0; s < subjects.length; s++) {
      for (var p = subjects[s]; p && !kept.has(p); p = p.parentElement) kept.add(p);
    }
    kept.forEach(function (el) {
      for (var q = el; q; q = q.parentElement) { if (isSubject.has(q)) return; }
      for (var c = el.firstElementChild; c; c = c.nextElementSibling) { if (!kept.has(c)) out.push(c); }
    });
    return out;
  }

  // The selectors each :-abp-properties() operator found during the current pass: inside a :has(), it runs once per candidate.
  var propertySelectors = null;

  // The elements the selectors of the page's same-origin style rules match, for the rules whose declarations
  // :-abp-properties() matches. A rule styling a ::before or ::after selects the element that carries it.
  function abpProperties(op, nodes, css, root) {
    var joined = propertySelectors.get(op);
    if (joined === undefined) {
      var selectors = [];
      for (var s = 0; s < document.styleSheets.length; s++) {
        var rules;
        try { rules = document.styleSheets[s].cssRules; } catch (e) { continue; }
        for (var r = 0; r < rules.length; r++) {
          if (rules[r].type !== 1) continue;
          var style = rules[r].style;
          var text = '';
          for (var k = 0; k < style.length; k++) {
            var priority = style.getPropertyPriority(style[k]);
            text += (op.compact || !k ? '' : ' ') + style[k] + (op.compact ? ':' : ': ') + style.getPropertyValue(style[k]) +
              (priority ? ' !' + priority : '') + ';';
          }
          if (op.re.test(text)) selectors.push(rules[r].selectorText.replace(/::?(?:before|after)\b/gi, ''));
        }
      }
      joined = selectors.join(', ');
      propertySelectors.set(op, joined);
    }
    if (!joined) return [];
    try {
      if (css) return nodes.filter(function (el) { return el.matches(joined); });
      return Array.prototype.slice.call(root.querySelectorAll(joined));
    } catch (e) { return []; }
  }

  // The elements a parsed selector selects under `root`, the document or the element a :has() or :not() argument is evaluated
  // in, and what to do with them; null for none. A null scope is all of root. Otherwise only the scope's roots' subtrees and
  // their ancestors are tested: an insertion changes the text of its ancestors, not of the rest of the page.
  function select(parsed, root, scope) {
    if (parsed.path && parsed.path.test(location.pathname + location.search) === parsed.pathNegated) return null;
    var css = parsed.css, ops = parsed.ops, nodes = [];
    // An argument without a selector of its own starts from the element it is evaluated in.
    if (!css && root !== document) nodes = [root];
    else if (css) {
      try {
        if (root !== document) {
          nodes = Array.prototype.slice.call(root.querySelectorAll(':scope ' + css));
        } else if (!scope) {
          nodes = Array.prototype.slice.call(document.querySelectorAll(css));
        } else {
          for (var r = 0; r < scope.roots.length; r++) {
            var scopeRoot = scope.roots[r];
            if (scopeRoot.matches(css)) nodes.push(scopeRoot);
            var found = scopeRoot.querySelectorAll(css);
            for (var f = 0; f < found.length; f++) nodes.push(found[f]);
          }
          // A plain leading text condition: an ancestor's text grows only by the roots' text, so when no root's text matches,
          // the ancestor's whole text, often the page's, is not read again. A regex can match across the old and new text, and
          // :has(), :empty and :xpath() look at the new subtree, so those keep testing the ancestors.
          var first = ops[0];
          var textFirst = first && (first.name === 'has-text' || first.name === 'contains' || first.name === '-abp-contains') &&
            !/^\/.+\/[a-z]*$/.test(first.arg);
          if (!textFirst || parsed.path || /:has\(|:empty/.test(css) ||
              ops.some(function (op) { return op.name === 'has' || op.name === 'xpath'; }) ||
              scope.roots.some(function (el) { return first.re.test(textOf(el)); })) {
            for (var a = 0; a < scope.ancestors.length; a++) { if (scope.ancestors[a].matches(css)) nodes.push(scope.ancestors[a]); }
          }
        }
      } catch (e) { return null; }
    }
    var action = { type: 'hide' };
    for (var o = 0; o < ops.length; o++) {
      var op = ops[o], name = op.name, arg = op.arg;
      if (name === 'has-text' || name === 'contains' || name === '-abp-contains') {
        nodes = nodes.filter(function (el) { return op.re.test(textOf(el)); });
      } else if (name === 'has' || name === 'not') {
        nodes = nodes.filter(function (el) {
          var inner = select(op.sub, el, null);
          return (inner !== null && inner.nodes.length > 0) === (name === 'has');
        });
      } else if (name === 'matches-css' || name === 'matches-css-before' || name === 'matches-css-after') {
        var pseudo = name === 'matches-css-before' ? '::before' : (name === 'matches-css-after' ? '::after' : null);
        nodes = nodes.filter(function (el) {
          try { return op.re.test(getComputedStyle(el, pseudo).getPropertyValue(op.prop)); } catch (e) { return false; }
        });
      } else if (name === 'upward' || name === 'nth-ancestor') {
        nodes = nodes.map(function (el) { return upward(el, arg); }).filter(Boolean);
      } else if (name === 'xpath') {
        nodes = xpathNodes(nodes, css, arg, root);
      } else if (name === 'matches-path') {
        if (!op.re.test(location.pathname + location.search)) nodes = [];
      } else if (name === 'matches-attr') {
        nodes = nodes.filter(function (el) {
          return Array.prototype.some.call(el.attributes, function (a) {
            return op.attr.test(a.name) && (!op.value || op.value.test(a.value));
          });
        });
      } else if (name === 'others') {
        nodes = others(nodes);
      } else if (name === '-abp-properties') {
        nodes = abpProperties(op, nodes, css, root);
      } else if (name === 'remove-attr' || name === 'remove-class') {
        action = { type: name, re: op.re };
      } else if (name === 'remove') {
        action = { type: 'remove' };
      } else if (name === 'style') {
        action = { type: 'style', css: arg };
      }
    }
    return { nodes: nodes, action: action };
  }

  // :others() hides what lies outside its subjects anywhere on the page: it takes a full pass, and an element it hid that
  // a later pass finds an ancestor of a subject, or inside one, is shown again.
  function applySelector(parsed, scope) {
    var result = select(parsed, document, parsed.others ? null : scope);
    if (!result) return;
    if (parsed.others && result.action.type === 'hide') {
      var now = new Set(result.nodes);
      parsed.others.forEach(function (el) {
        if (now.has(el)) return;
        try { el.style.removeProperty('display'); } catch (e) {}
        done.delete(el);
      });
      parsed.others = now;
    }
    for (var m = 0; m < result.nodes.length; m++) applyAction(result.nodes[m], result.action);
  }

  function watch(selectors) {
    var parsed = selectors.map(function (s) { try { return parseSelector(s); } catch (e) { return null; } }).filter(Boolean);
    parsed.forEach(function (p) { if (p.ops.some(function (op) { return op.name === 'others'; })) p.others = new Set(); });
    var run = function (scope) {
      texts = new Map();
      propertySelectors = new Map();
      for (var i = 0; i < parsed.length; i++) { try { applySelector(parsed[i], scope); } catch (e) {} }
      texts = propertySelectors = null;
    };
    // Elements inserted since the last pass. The outermost connected ones are the roots; their
    // ancestors are collected once for all.
    var added = [], scheduled = false, missedWhileHidden = false;
    var runAdded = function () {
      scheduled = false;
      // A hidden page's insertions wait for its return.
      if (document.hidden) return;
      var pending = new Set(added), roots = [], ancestors = [], seen = new Set();
      added = [];
      pending.forEach(function (el) {
        if (!el.isConnected) return;
        for (var p = el.parentElement; p; p = p.parentElement) { if (pending.has(p)) return; }
        roots.push(el);
        for (p = el.parentElement; p && !seen.has(p); p = p.parentElement) { seen.add(p); ancestors.push(p); }
      });
      if (roots.length) run({ roots: roots, ancestors: ancestors });
    };
    var runAll = function () { added = []; run(null); };
    var onMutations = function (records) {
      for (var r = 0; r < records.length; r++) {
        var nodes = records[r].addedNodes;
        for (var k = 0; k < nodes.length; k++) {
          // Text lands in its parent, whose own text changed.
          var el = nodes[k].nodeType === 1 ? nodes[k] : records[r].target;
          if (el && el.nodeType === 1) added.push(el);
        }
      }
      // Past this many insertions in a hidden page, one full pass on return is cheaper than a scoped one, and observing
      // until then builds records for nothing.
      if (document.hidden && added.length > 2000) { missedWhileHidden = true; added = []; observer.disconnect(); }
      if (!added.length || scheduled || document.hidden) return;
      scheduled = true;
      setTimeout(runAdded, 200);
    };
    var observer = new MutationObserver(onMutations);
    // The parser's insertions are left to the full pass once the document is parsed: observed, each costs a record.
    var start = function () {
      runAll();
      try { observer.observe(document.documentElement || document, { childList: true, subtree: true }); } catch (e) {}
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
    else start();
    document.addEventListener('visibilitychange', function () {
      if (document.hidden) return;
      if (missedWhileHidden) { missedWhileHidden = false; start(); }
      else if (!scheduled) runAdded();
    });
  }

  // FilterLookup.js, in the bridge world, holds the table and sends this page's entries: at once when it ran first,
  // else as it runs, before any script of the page either way.
  var started = false;
  addEventListener('__LILO_FILTER_ENTRIES__', function (event) {
    if (started) return;
    started = true;
    // `@selector` excepts the selector on this host and its subdomains.
    var found = [], excepted = new Set();
    JSON.parse(event.detail).e.forEach(function (entry) {
      if (entry[0] === '@') excepted.add(decodeEntry(entry.slice(1))); else found.push(decodeEntry(entry));
    });
    var selectors = found.filter(function (s, k) { return !excepted.has(s) && found.indexOf(s) === k; });
    if (selectors.length) watch(selectors);
  });
  dispatchEvent(new Event('__LILO_FILTER_LOOKUP__'));
})();
