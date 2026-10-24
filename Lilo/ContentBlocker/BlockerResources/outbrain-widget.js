// Outbrain widget stand-in.
(function () {
  'use strict';
  var noop = function () {};
  window.OBR = window.OBR || {};
  window.OBR.extern = { refreshWidget: noop, renderSpaWidgets: noop, researchWidget: noop, returnedHtmlData: noop,
    returnedIrdData: noop, returnedJsonData: noop, scrollLoad: noop, video: { getVideoRecs: noop, videoClicked: noop } };
})();
