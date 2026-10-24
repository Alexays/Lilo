// Google Analytics (analytics.js) stand-in: hits never leave, their callbacks still run.
(function () {
  'use strict';
  var noop = function () {};
  var tracker = { get: noop, set: noop, send: noop };
  var name = window.GoogleAnalyticsObject || 'ga';
  var queue = window[name] && window[name].q;
  function ga() {
    var last = arguments[arguments.length - 1];
    if (last && typeof last === 'object' && typeof last.hitCallback === 'function') setTimeout(last.hitCallback, 1);
    else if (typeof arguments[0] === 'function') arguments[0](tracker);
  }
  ga.create = function () { return tracker; };
  ga.getByName = function () { return tracker; };
  ga.getAll = function () { return [tracker]; };
  ga.remove = noop;
  ga.loaded = true;
  window[name] = ga;
  if (Array.isArray(queue)) queue.forEach(function (args) { ga.apply(null, args); });
})();
