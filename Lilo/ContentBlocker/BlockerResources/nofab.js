// FuckAdBlock and BlockAdBlock look-alikes: every check comes back "not detected".
(function () {
  'use strict';
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
    try { Object.defineProperty(window, name, { get: function () { return globals[name]; }, set: function () {} }); } catch (e) {}
  });
})();
