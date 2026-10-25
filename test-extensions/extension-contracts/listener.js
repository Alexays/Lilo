// The extension's page a contract case opens in a tab and messages with tabs.sendMessage.
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  sendResponse({ echo: message, sender });
});
