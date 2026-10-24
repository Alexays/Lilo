// Amazon Publisher Services stand-in: bid requests answer with no bids.
(function () {
  'use strict';
  var noop = function () {};
  window.apstag = {
    _Q: [], init: noop, setDisplayBids: noop, targetingKeys: function () { return []; },
    fetchBids: function (config, callback) { if (typeof callback === 'function') setTimeout(function () { callback([]); }, 1); }
  };
})();
