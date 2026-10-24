// Google Publisher Tag stand-in: the queued commands run against slots that never fill.
(function () {
  'use strict';
  var noop = function () {};
  function chain(target, names) { names.forEach(function (name) { target[name] = function () { return target; }; }); return target; }
  var slotMethods = ['addService', 'clearCategoryExclusions', 'clearTargeting', 'defineSizeMapping', 'setCategoryExclusion',
    'setClickUrl', 'setCollapseEmptyDiv', 'setConfig', 'setForceSafeFrame', 'setSafeFrameConfig', 'setTargeting', 'updateTargetingFromMap'];
  function Slot(path, sizes, id) {
    chain(this, slotMethods);
    this.getAdUnitPath = function () { return path || ''; };
    this.getSlotElementId = function () { return id || ''; };
    this.getSizes = function () { return sizes || []; };
    this.getTargeting = function () { return []; };
    this.getTargetingKeys = function () { return []; };
    this.getResponseInformation = function () { return null; };
  }
  var service = chain({}, ['addEventListener', 'clear', 'clearCategoryExclusions', 'clearTargeting', 'collapseEmptyDivs',
    'disableInitialLoad', 'display', 'enable', 'enableAsyncRendering', 'enableLazyLoad', 'enableSingleRequest',
    'enableSyncRendering', 'enableVideoAds', 'refresh', 'removeEventListener', 'set', 'setCategoryExclusion',
    'setCentering', 'setCookieOptions', 'setForceSafeFrame', 'setLocation', 'setPrivacySettings', 'setPublisherProvidedId',
    'setRequestNonPersonalizedAds', 'setSafeFrameConfig', 'setTagForChildDirectedTreatment', 'setTargeting',
    'setVideoContent', 'updateCorrelator']);
  service.getSlots = function () { return []; };
  service.getTargeting = function () { return []; };
  service.getTargetingKeys = function () { return []; };
  service.isInitialLoadDisabled = function () { return false; };
  var queue = (window.googletag && window.googletag.cmd) || [];
  var googletag = window.googletag = {
    apiReady: true, pubadsReady: true,
    cmd: { push: function (fn) { try { fn(); } catch (e) {} return 1; } },
    companionAds: function () { return service; }, content: function () { return service; }, pubads: function () { return service; },
    defineOutOfPageSlot: function (path, id) { return new Slot(path, [], id); },
    defineSlot: function (path, sizes, id) { return new Slot(path, sizes, id); },
    destroySlots: function () { return true; }, disablePublisherConsole: noop, display: noop, enableServices: noop,
    getVersion: function () { return ''; }, openConsole: noop, setAdIframeTitle: noop,
    sizeMapping: function () { var b = { addSize: function () { return b; }, build: function () { return []; } }; return b; }
  };
  for (var i = 0; i < queue.length; i++) googletag.cmd.push(queue[i]);
})();
