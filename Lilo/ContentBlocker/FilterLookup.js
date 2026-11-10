/*lilo-filter-lookup*/
(function () {
  'use strict';

  // Looks this frame's entries up in a filter table and hands them to the table's script in the page world, which
  // cannot hold a table every web process shares: Scriptlets.js in every frame, ProceduralCosmetics.js in the main one.

  var ancestors = location.ancestorOrigins;
  // A frame without a host of its own (about:blank, srcdoc) runs its parent's scriptlets, as uBO does:
  // a page creating one to reach pristine fetch or JSON.parse finds them patched too. WebKit injects
  // the scripts there synchronously, before the page can read the new frame.
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

  var INDEX = __LILO_LOOKUP_INDEX__;
  var GROUPS = __LILO_LOOKUP_GROUPS__;
  var TABLE = __LILO_LOOKUP_TABLE__;
  // The scriptlets' names, which their entries refer to by index; empty for another table.
  var NAMES = __LILO_LOOKUP_NAMES__;
  // A uBO `example.*` entry names the site under any public suffix: try the host with its last label,
  // and with a likely two-label suffix (co.uk, com.br), replaced by `*`.
  var parts = hostname.split('.');
  var n = parts.length, twoLabelSuffix = n > 2 && parts[n - 1].length === 2 && parts[n - 2].length <= 3;
  var hosts = [];
  for (var h = 0; h < n - 1; h++) {
    hosts.push(parts.slice(h).join('.'), parts.slice(h, n - 1).join('.') + '.*');
    if (twoLabelSuffix && h < n - 2) hosts.push(parts.slice(h, n - 2).join('.') + '.*');
  }
  // `*` lists the scriptlets every site runs.
  if (NAMES) hosts.push('*');
  var found = [];
  for (var i = 0; i < hosts.length; i++) found = found.concat(lookup(INDEX, GROUPS, TABLE, hosts[i]));
  if (!found.length) return;

  // WebKit runs the two worlds' scripts in no set order: the page script asks when it runs after this one, and is
  // already listening when it ran first.
  var detail = JSON.stringify({ n: NAMES, e: found });
  function send() { dispatchEvent(new CustomEvent('__LILO_FILTER_ENTRIES__', { detail: detail })); }
  addEventListener('__LILO_FILTER_LOOKUP__', send);
  send();
})();
