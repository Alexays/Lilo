// Registered by the tabs.sendMessage contract case: answers a message and a port with what it received.
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  sendResponse({ echo: message, sender });
});
chrome.runtime.onConnect.addListener((port) => {
  port.onMessage.addListener((message) => port.postMessage({ echo: message, name: port.name, sender: port.sender }));
});
