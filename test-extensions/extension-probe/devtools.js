// Runs in the devtools page (manifest devtools_page). Creating a panel exercises the
// chrome.devtools.* surface; the panel itself reuses the shared dashboard.
try {
  chrome.devtools.panels.create("Lilo Probe", "", "devtools-panel.html", function () { /* panel created */ });
  if (chrome.storage && chrome.storage.local) {
    chrome.storage.local.set({ "liloProbe.devtools": { panelCreated: new Date().toISOString() } });
  }
} catch (e) { /* devtools API unavailable in this engine */ }
