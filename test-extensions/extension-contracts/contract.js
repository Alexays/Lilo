// Contract cases: the same chrome.* calls run here in Chrome (scripts/record-chrome-contracts.mjs
// records the results) and in Lilo (ChromeContractTests compares). Each case returns a value that
// must be identical in both: exact values where they are deterministic, otherwise the shape of the
// result (keys and types), and the exact message of an expected error.

// Keys sorted, values replaced by their type; an array keeps the shape of its first element.
function shape(value) {
  if (value === null) return 'null';
  if (Array.isArray(value)) return value.length ? [shape(value[0])] : [];
  if (typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, shape(value[key])]));
  }
  return typeof value;
}

async function errorOf(run) {
  try {
    await run();
    return 'no error';
  } catch (error) {
    return String(error && error.message);
  }
}

// The arguments of the first `event` firing during `run` that `matches` takes, or 'timeout'.
function nextEvent(event, run, timeoutMs = 3000, matches = () => true) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => { event.removeListener(listener); resolve('timeout'); }, timeoutMs);
    function listener(...args) {
      if (!matches(...args)) return;
      clearTimeout(timer);
      event.removeListener(listener);
      resolve(args);
    }
    event.addListener(listener);
    Promise.resolve().then(run).catch(() => {});
  });
}

// Writes { n: 1 } to a fresh database and reads it back; worker.js runs the same roundtrip.
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

const cases = {
  'storage.local roundtrip': async () => {
    await chrome.storage.local.set({ a: 1, b: { c: [true, null, 'x'] } });
    return chrome.storage.local.get(['a', 'b', 'missing']);
  },
  'storage.local.get invalid keys': () => errorOf(() => chrome.storage.local.get(42)),
  'storage.onChanged payload': async () => {
    // WebKit can deliver a write's event after the write resolves, an earlier case's included: each set waits for its own.
    const own = (value) => (changes) => changes.watched?.newValue === value;
    await nextEvent(chrome.storage.onChanged, () => chrome.storage.local.set({ watched: 1 }), 3000, own(1));
    return nextEvent(chrome.storage.onChanged, () => chrome.storage.local.set({ watched: 2 }), 3000, own(2));
  },
  'indexedDB in a page': () => indexedDBRoundtrip('contract-page'),
  // Asked through storage.session: a worker onMessage listener would answer the sendMessage cases.
  'indexedDB in the worker': () => new Promise((resolve) => {
    const timer = setTimeout(() => { chrome.storage.onChanged.removeListener(answered); resolve('timeout'); }, 10000);
    function answered(changes, area) {
      if (area !== 'session' || !changes.indexedDBAnswer) return;
      clearTimeout(timer);
      chrome.storage.onChanged.removeListener(answered);
      resolve(changes.indexedDBAnswer.newValue);
    }
    chrome.storage.onChanged.addListener(answered);
    chrome.storage.session.set({ indexedDBAsked: Date.now() });
  }),
  'storage.session quota constant': () => chrome.storage.session.QUOTA_BYTES,
  'runtime.getPlatformInfo': async () => (await chrome.runtime.getPlatformInfo()).os,
  'runtime.getManifest name': () => chrome.runtime.getManifest().name,
  'runtime.sendMessage without listener': () => errorOf(() => chrome.runtime.sendMessage({ ping: 1 })),
  'runtime.sendMessage callback without listener': () => new Promise((resolve) => chrome.runtime.sendMessage({ ping: 1 }, (response) => resolve(`${response} ${chrome.runtime.lastError?.message}`))),
  'runtime enums':() => [chrome.runtime.OnInstalledReason.UPDATE, chrome.runtime.PlatformOs.MAC],
  'alarms.create and get': async () => {
    await chrome.alarms.create('contract', { delayInMinutes: 5 });
    const alarm = await chrome.alarms.get('contract');
    await chrome.alarms.clear('contract');
    return shape(alarm);
  },
  'alarms.get missing': async () => String(await chrome.alarms.get('nope')),
  'tabs.query shape': async () => shape((await chrome.tabs.query({ currentWindow: true }))[0]),
  'tabs.get invalid id': () => errorOf(() => chrome.tabs.get(-5)),
  'tabs.create and remove events': async () => {
    const created = await nextEvent(chrome.tabs.onCreated, () => chrome.tabs.create({ url: 'about:blank', active: false }));
    const tab = created[0];
    const removed = await nextEvent(chrome.tabs.onRemoved, () => chrome.tabs.remove(tab.id));
    return { created: created.map(shape), removed: removed.map(shape) };
  },
  'tabs.TAB_ID_NONE': () => chrome.tabs.TAB_ID_NONE,
  'windows.getAll shape': async () => shape((await chrome.windows.getAll({ populate: false }))[0]),
  'windows.WINDOW_ID_CURRENT': () => chrome.windows.WINDOW_ID_CURRENT,
  'cookies.onChanged sequence': async () => {
    const url = 'https://contract.example/';
    const events = [];
    const listener = (info) => events.push([info.removed, info.cause, info.cookie.value]);
    chrome.cookies.onChanged.addListener(listener);
    await chrome.cookies.set({ url, name: 'c', value: '1' });
    await chrome.cookies.set({ url, name: 'c', value: '2' });
    await chrome.cookies.remove({ url, name: 'c' });
    await new Promise((resolve) => setTimeout(resolve, 1500));
    chrome.cookies.onChanged.removeListener(listener);
    return events;
  },
  'cookies.get shape': async () => {
    await chrome.cookies.set({ url: 'https://contract.example/', name: 'shape', value: 'v', secure: true });
    const cookie = await chrome.cookies.get({ url: 'https://contract.example/', name: 'shape' });
    await chrome.cookies.remove({ url: 'https://contract.example/', name: 'shape' });
    return shape(cookie);
  },
  'bookmarks.create and onCreated': async () => {
    const tree = await chrome.bookmarks.getTree();
    const parentId = tree[0].children[0].id;
    const args = await nextEvent(chrome.bookmarks.onCreated, () => chrome.bookmarks.create({ parentId, title: 'contract', url: 'https://contract.example/' }));
    await chrome.bookmarks.remove(args[0]);
    return args.map(shape);
  },
  'bookmarks.get missing': () => errorOf(() => chrome.bookmarks.get('999999')),
  'bookmarks.getTree root shape': async () => shape((await chrome.bookmarks.getTree())[0]),
  'history.addUrl and search': async () => {
    await chrome.history.addUrl({ url: 'https://contract.example/visited' });
    const items = await chrome.history.search({ text: 'contract.example/visited', startTime: 0 });
    return shape(items[0]);
  },
  'contextMenus duplicate id': async () => {
    await new Promise((resolve) => chrome.contextMenus.create({ id: 'dup', title: 'one' }, resolve));
    const message = await new Promise((resolve) => chrome.contextMenus.create({ id: 'dup', title: 'two' }, () => resolve(chrome.runtime.lastError?.message ?? 'no error')));
    await chrome.contextMenus.removeAll();
    return message;
  },
  'declarativeNetRequest invalid rule': () => errorOf(() => chrome.declarativeNetRequest.updateDynamicRules({ addRules: [{ id: 0, action: { type: 'block' }, condition: {} }] })),
  'declarativeNetRequest dynamic rules': async () => {
    await chrome.declarativeNetRequest.updateDynamicRules({ addRules: [{ id: 5, priority: 1, action: { type: 'block' }, condition: { urlFilter: 'contract-block' } }] });
    const rules = await chrome.declarativeNetRequest.getDynamicRules();
    await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: [5] });
    return rules;
  },
  'downloads.search empty': async () => chrome.downloads.search({ query: ['no-such-download-contract'] }),
  'management.getSelf shape': async () => shape(await chrome.management.getSelf()),
  'permissions.contains': async () => [await chrome.permissions.contains({ permissions: ['tabs'] }), await chrome.permissions.contains({ permissions: ['debugger'] })],
  'permissions.request outside a gesture': () => errorOf(() => chrome.permissions.request({ permissions: ['debugger'] })),
  'idle.queryState': async () => typeof (await chrome.idle.queryState(60)),
  'i18n.getUILanguage type': () => typeof chrome.i18n.getUILanguage(),
  'i18n.getMessage extension id': () => chrome.i18n.getMessage('@@extension_id') === chrome.runtime.id,
  'topSites.get shape': async () => Array.isArray(await chrome.topSites.get()),
  'sessions.MAX_SESSION_RESULTS': () => chrome.sessions.MAX_SESSION_RESULTS,
  'system.cpu.getInfo shape': async () => shape(await chrome.system.cpu.getInfo()),
  'system.memory.getInfo shape': async () => shape(await chrome.system.memory.getInfo()),
  'notifications.create missing fields': () => errorOf(() => chrome.notifications.create('n', { type: 'basic', title: 't' })),
  'action.setBadgeText and get': async () => {
    await chrome.action.setBadgeText({ text: '12' });
    const text = await chrome.action.getBadgeText({});
    await chrome.action.setBadgeText({ text: '' });
    return text;
  },
  'webNavigation on a missing tab': async () => [
    await chrome.webNavigation.getAllFrames({ tabId: 999999 }),
    await chrome.webNavigation.getFrame({ tabId: 999999, frameId: 0 }),
  ],
  'webNavigation on a tab before its first commit': async () => {
    const tab = await chrome.tabs.create({ url: 'https://contract.example/frames', active: false });
    const frames = [await chrome.webNavigation.getAllFrames({ tabId: tab.id }), await chrome.webNavigation.getFrame({ tabId: tab.id, frameId: 0 })];
    await chrome.tabs.remove(tab.id);
    return frames;
  },
  'webNavigation on a new tab': async () => {
    const tab = await chrome.tabs.create({ active: false });
    const frames = [await chrome.webNavigation.getAllFrames({ tabId: tab.id }), await chrome.webNavigation.getFrame({ tabId: tab.id, frameId: 0 })];
    await chrome.tabs.remove(tab.id);
    return frames;
  },
  'webNavigation on a discarded tab': async () => {
    const tab = await chrome.tabs.create({ url: 'https://contract.example/discarded', active: false });
    await new Promise((resolve) => {
      const listener = (id, change) => {
        if (id !== tab.id || change.status !== 'complete') return;
        chrome.tabs.onUpdated.removeListener(listener);
        resolve();
      };
      chrome.tabs.onUpdated.addListener(listener);
      chrome.tabs.get(tab.id).then((current) => listener(tab.id, current));
    });
    await chrome.tabs.discard(tab.id);
    const frames = await chrome.webNavigation.getAllFrames({ tabId: tab.id });
    const frame = await chrome.webNavigation.getFrame({ tabId: tab.id, frameId: 0 });
    await chrome.tabs.remove(tab.id);
    return [frames.map(({ frameId, parentFrameId, url }) => [frameId, parentFrameId, url]), frame && [frame.parentFrameId, frame.url]];
  },
  'scripting.executeScript on a missing tab': () => errorOf(() => chrome.scripting.executeScript({ target: { tabId: 999999 }, func: () => 1 })),
  'storage.local non-finite numbers': async () => {
    await chrome.storage.local.set({ nonFinite: { expires: Infinity, n: NaN, kept: 1, list: [-Infinity, 2] }, topInfinite: Infinity });
    const items = await chrome.storage.local.get(['nonFinite', 'topInfinite']);
    await chrome.storage.local.remove(['nonFinite', 'topInfinite']);
    return items;
  },
  'instanceID.getID': async () => {
    const id = await chrome.instanceID.getID();
    const time = await chrome.instanceID.getCreationTime();
    return [/^[A-Za-z0-9_-]{11}$/.test(id), id[0] >= 'c' && id[0] <= 'f', id === await chrome.instanceID.getID(), typeof time, time > 0];
  },
  'instanceID.deleteID': async () => {
    const id = await chrome.instanceID.getID();
    await chrome.instanceID.deleteID();
    const time = await chrome.instanceID.getCreationTime();
    return [time, id !== await chrome.instanceID.getID()];
  },
  'pageCapture.saveAsMHTML on a missing tab': () => errorOf(() => chrome.pageCapture.saveAsMHTML({ tabId: 999999 })),
  'pageCapture.saveAsMHTML on about:blank': async () => {
    const tab = await chrome.tabs.create({ url: 'about:blank', active: false });
    const error = await errorOf(() => chrome.pageCapture.saveAsMHTML({ tabId: tab.id }));
    await chrome.tabs.remove(tab.id);
    return error;
  },
  'pageCapture.saveAsMHTML on an extension page': async () => {
    const url = chrome.runtime.getURL('capture.html');
    const tab = await chrome.tabs.create({ url, active: false });
    await new Promise((resolve) => {
      const listener = (id, change) => {
        if (id !== tab.id || change.status !== 'complete') return;
        chrome.tabs.onUpdated.removeListener(listener);
        resolve();
      };
      chrome.tabs.onUpdated.addListener(listener);
      chrome.tabs.get(tab.id).then((current) => listener(tab.id, current));
    });
    const blob = await chrome.pageCapture.saveAsMHTML({ tabId: tab.id }).catch((error) => error.message);
    await chrome.tabs.remove(tab.id);
    if (typeof blob === 'string') return blob;
    const text = await blob.text();
    const [head] = text.split('\r\n\r\n');
    return {
      blob: blob instanceof Blob,
      type: blob.type,
      headers: head.match(/^[A-Za-z-]+(?=:)/gm),
      location: text.includes(`Snapshot-Content-Location: ${url}`) && text.includes(`Content-Location: ${url}`),
      captured: /captured/.test(text),
    };
  },
};

// Runs every case, each isolated, and returns { name: { result } | { threw } }.
window.runContracts = async () => {
  const results = {};
  for (const [name, run] of Object.entries(cases)) {
    try {
      results[name] = { result: await run() };
    } catch (error) {
      results[name] = { threw: String(error && error.message) };
    }
  }
  return results;
};
