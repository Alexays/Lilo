// Google Tag Manager stand-in: pushed events still call their callbacks.
(function () {
  'use strict';
  var layer = window.dataLayer = window.dataLayer || [];
  function run(entry) {
    var callback = entry && entry.eventCallback;
    if (typeof callback === 'function') setTimeout(callback, 1);
  }
  layer.forEach(run);
  var push = layer.push;
  layer.push = function (entry) { run(entry); return push.apply(layer, arguments); };
  window.google_tag_manager = window.google_tag_manager || {};
})();
