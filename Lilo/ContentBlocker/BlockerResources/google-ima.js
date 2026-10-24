// Google IMA SDK stand-in: every ad request fails at once, so players start the content.
(function () {
  'use strict';
  if (window.google && window.google.ima && window.google.ima.AdsLoader) return;
  var noop = function () {};
  function Events() { this.listeners = {}; }
  Events.prototype.addEventListener = function (type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); };
  Events.prototype.removeEventListener = function (type, fn) {
    this.listeners[type] = (this.listeners[type] || []).filter(function (f) { return f !== fn; });
  };
  Events.prototype.emit = function (type, event) {
    (this.listeners[type] || []).slice().forEach(function (fn) { try { fn(event); } catch (e) {} });
  };
  function AdError(message) { this.message = message; }
  AdError.prototype.getErrorCode = function () { return 1009; };
  AdError.prototype.getVastErrorCode = function () { return 303; };
  AdError.prototype.getMessage = function () { return this.message; };
  AdError.prototype.getInnerError = function () { return null; };
  AdError.prototype.getType = function () { return 'adLoadError'; };
  AdError.prototype.toString = function () { return 'AdError 1009: ' + this.message; };
  AdError.ErrorCode = { VAST_EMPTY_RESPONSE: 1009 };
  AdError.Type = { AD_LOAD: 'adLoadError', AD_PLAY: 'adPlayError' };
  function AdErrorEvent(error, userRequestContext) { this.error = error; this.ctx = userRequestContext; }
  AdErrorEvent.prototype.getError = function () { return this.error; };
  AdErrorEvent.prototype.getUserRequestContext = function () { return this.ctx || {}; };
  AdErrorEvent.Type = { AD_ERROR: 'adError' };
  function ImaSdkSettings() {}
  ['setAutoPlayAdBreaks', 'setCompanionBackfill', 'setCookiesEnabled', 'setDisableCustomPlaybackForIOS10Plus',
    'setFeatureFlags', 'setLocale', 'setNumRedirects', 'setPlayerType', 'setPlayerVersion', 'setPpid',
    'setSessionId', 'setVpaidAllowed', 'setVpaidMode'].forEach(function (name) { ImaSdkSettings.prototype[name] = noop; });
  ImaSdkSettings.prototype.getLocale = function () { return 'en'; };
  ImaSdkSettings.VpaidMode = { DISABLED: 0, ENABLED: 1, INSECURE: 2 };
  function AdsLoader() { Events.call(this); this.settings = new ImaSdkSettings(); }
  AdsLoader.prototype = Object.create(Events.prototype);
  AdsLoader.prototype.contentComplete = noop;
  AdsLoader.prototype.destroy = noop;
  AdsLoader.prototype.getSettings = function () { return this.settings; };
  AdsLoader.prototype.getVersion = function () { return '3.0.0'; };
  AdsLoader.prototype.requestAds = function (request, userRequestContext) {
    var self = this;
    setTimeout(function () {
      self.emit(AdErrorEvent.Type.AD_ERROR, new AdErrorEvent(new AdError('No ads'), userRequestContext));
    }, 0);
  };
  function AdDisplayContainer() {}
  AdDisplayContainer.prototype.initialize = noop;
  AdDisplayContainer.prototype.destroy = noop;
  function AdsRequest() {}
  AdsRequest.prototype.setAdWillAutoPlay = noop;
  AdsRequest.prototype.setAdWillPlayMuted = noop;
  AdsRequest.prototype.setContinuousPlayback = noop;
  function AdsRenderingSettings() {}
  function AdsManagerLoadedEvent() {}
  AdsManagerLoadedEvent.Type = { ADS_MANAGER_LOADED: 'adsManagerLoaded' };
  function AdEvent() {}
  AdEvent.Type = {
    ALL_ADS_COMPLETED: 'allAdsCompleted', CLICK: 'click', COMPLETE: 'complete', CONTENT_PAUSE_REQUESTED: 'contentPauseRequested',
    CONTENT_RESUME_REQUESTED: 'contentResumeRequested', LOADED: 'loaded', PAUSED: 'pause', RESUMED: 'resume',
    SKIPPED: 'skip', STARTED: 'start', USER_CLOSE: 'userClose'
  };
  window.google = window.google || {};
  window.google.ima = {
    AdDisplayContainer: AdDisplayContainer, AdError: AdError, AdErrorEvent: AdErrorEvent, AdEvent: AdEvent,
    AdsLoader: AdsLoader, AdsManagerLoadedEvent: AdsManagerLoadedEvent, AdsRenderingSettings: AdsRenderingSettings,
    AdsRequest: AdsRequest, ImaSdkSettings: ImaSdkSettings, settings: new ImaSdkSettings(),
    UiElements: { AD_ATTRIBUTION: 'adAttribution', COUNTDOWN: 'countdown' },
    ViewMode: { FULLSCREEN: 'fullscreen', NORMAL: 'normal' },
    VERSION: '3.0.0'
  };
})();
