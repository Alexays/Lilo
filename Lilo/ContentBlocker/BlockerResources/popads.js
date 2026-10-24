// PopAds reads its setup from these globals; held inert, its own assignments are ignored.
(function () {
  'use strict';
  var inert = Object.freeze({});
  ['PopAds', 'popns'].forEach(function (name) {
    try { Object.defineProperty(window, name, { get: function () { return inert; }, set: function () {} }); } catch (e) {}
  });
})();
