// Injected with "world": "MAIN" at document_start. If MAIN-world injection works
// it runs in the page's JS world (no chrome.*) and leaves a beacon the ISOLATED script reads back.
(function () {
  try {
    document.documentElement.setAttribute("data-lilo-probe-main", "1");
    document.documentElement.setAttribute("data-lilo-probe-main-chrome", typeof chrome);
    window.__liloProbeMainWorldFlag = true;
  } catch (e) { /* no chrome.* available in MAIN world */ }
})();
