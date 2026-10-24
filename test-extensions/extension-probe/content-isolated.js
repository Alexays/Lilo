// Default ISOLATED world at document_idle. Has chrome.runtime, so it reports
// to the SW: whether MAIN-world injection ran, that world isolation holds, the getURL scheme, etc.
(function () {
  function probe() {
    const report = {
      pageUrl: location.href,
      at: new Date().toISOString(),
      mainWorldInjected: document.documentElement.getAttribute("data-lilo-probe-main") === "1",
      mainWorldChromeType: document.documentElement.getAttribute("data-lilo-probe-main-chrome"),
      isolationHolds: typeof window.__liloProbeMainWorldFlag === "undefined",
      isolatedChromeNamespaces: Object.keys(window.chrome || {}),
      runtimeGetURLScheme: (function () { try { return new URL(chrome.runtime.getURL("war.js")).protocol; } catch (e) { return "error: " + String(e); } })(),
      i18nGetMessage: (function () { try { return chrome.i18n.getMessage("appName"); } catch (e) { return "error: " + String(e); } })(),
    };
    try { chrome.runtime.sendMessage({ type: "contentReport", data: report }); } catch (e) { /* */ }
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", probe, { once: true });
  else probe();
})();
