// comScore beacon stand-in.
(function () {
  'use strict';
  window.COMSCORE = { beacon: function () {}, purge: function () { return []; } };
})();
