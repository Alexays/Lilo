// Legacy Google Analytics (ga.js) stand-in: queued functions run, nothing is tracked.
(function () {
  'use strict';
  var noop = function () {};
  var tracker = new Proxy({}, { get: function (target, key) { return key === '_getLinkerUrl' ? function (u) { return u; } : noop; } });
  window._gat = { _createTracker: function () { return tracker; }, _getTracker: function () { return tracker; }, _getTrackerByName: function () { return tracker; } };
  var queue = window._gaq;
  window._gaq = { push: function () { for (var i = 0; i < arguments.length; i++) { if (typeof arguments[i] === 'function') arguments[i](); } return 0; } };
  if (Array.isArray(queue)) window._gaq.push.apply(null, queue);
})();
