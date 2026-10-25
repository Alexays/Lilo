// The cases run in contract.html; the worker answers the ones that need a worker context.
chrome.runtime.onInstalled.addListener(() => {});

// Writes { n: 1 } to a fresh database and reads it back, as contract.js does in a page.
function indexedDBRoundtrip(name) {
  return new Promise((resolve) => {
    const open = indexedDB.open(name, 1);
    open.onupgradeneeded = () => open.result.createObjectStore('items');
    open.onerror = () => resolve(`open failed: ${open.error && open.error.message}`);
    open.onsuccess = () => {
      const db = open.result;
      const write = db.transaction('items', 'readwrite');
      write.objectStore('items').put({ n: 1 }, 'key');
      write.oncomplete = () => {
        const read = db.transaction('items').objectStore('items').get('key');
        read.onsuccess = () => { db.close(); resolve(read.result); };
        read.onerror = () => resolve(`read failed: ${read.error && read.error.message}`);
      };
      write.onerror = () => resolve(`write failed: ${write.error && write.error.message}`);
    };
  });
}

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== 'session' || !changes.indexedDBAsked) return;
  indexedDBRoundtrip('contract-worker').then((answer) => chrome.storage.session.set({ indexedDBAnswer: answer }));
});

// The worker listens to messages only while the popup case asks: the sendMessage cases need it without a listener.
function answer(message, sender, sendResponse) {
  sendResponse({ echo: message, sender });
}
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== 'session' || !changes.workerListens) return;
  if (changes.workerListens.newValue) chrome.runtime.onMessage.addListener(answer);
  else chrome.runtime.onMessage.removeListener(answer);
  chrome.storage.session.set({ workerListening: Boolean(changes.workerListens.newValue) });
});
