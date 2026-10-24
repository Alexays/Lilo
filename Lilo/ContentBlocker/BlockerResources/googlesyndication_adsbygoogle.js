// AdSense stand-in: pushes are accepted and the slots look filled.
(function () {
  'use strict';
  var queue = window.adsbygoogle;
  window.adsbygoogle = { loaded: true, push: function () {} };
  if (Array.isArray(queue)) queue.length = 0;
})();
