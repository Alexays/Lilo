// Web-accessible resource. A page (or content script) can fetch chrome.runtime.getURL(
// "war.js"); successful load proves web_accessible_resources + the extension URL scheme resolve.
(function () {
  try { window.__liloProbeWarLoaded = true; } catch (e) { /* */ }
})();
