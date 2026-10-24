// Fingerprint2 stand-in: the same anonymous fingerprint for everyone.
(function () {
  'use strict';
  var hash = '7a2f86d0bd4c5e3f9a1b2c3d4e5f6a7b';
  function Fingerprint2() {}
  Fingerprint2.prototype.get = function (done) { setTimeout(function () { done(hash, []); }, 1); };
  Fingerprint2.get = function (options, done) { if (typeof options === 'function') done = options; setTimeout(function () { done([]); }, 1); };
  Fingerprint2.getPromise = function () { return Promise.resolve([]); };
  Fingerprint2.getV18 = function (options, done) { if (typeof options === 'function') done = options; setTimeout(function () { done(hash, []); }, 1); };
  Fingerprint2.x64hash128 = function () { return hash; };
  window.Fingerprint2 = Fingerprint2;
})();
