// Opened by the popup contract case: reports what the popup's calls answer, then closes.
(async () => {
  const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  const answer = await chrome.runtime.sendMessage({ ping: 'popup' }).catch((error) => error.message);
  await chrome.storage.session.set({ popupReport: { tabs, answer } });
  window.close();
})();
