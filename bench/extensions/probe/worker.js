// Times chrome.tabs.query and chrome.storage.local.get as an extension sees them, each time the worker starts, and
// reports to the server scripts/bench_extensions.sh runs (it writes the port in).
const REPORT = 'http://127.0.0.1:__PORT__/report';
const CALLS = 200;

// A listener keeps the worker starting with every launch.
chrome.runtime.onStartup.addListener(() => {});

async function timings(call) {
  const times = [];
  for (let i = 0; i < CALLS; i++) {
    const start = performance.now();
    await call();
    times.push((performance.now() - start).toFixed(2));
  }
  return times.join(',');
}

(async () => {
  await chrome.storage.local.set({ bench: 'x'.repeat(1024) });
  const tabs = await timings(() => chrome.tabs.query({}));
  const storage = await timings(() => chrome.storage.local.get('bench'));
  await fetch(`${REPORT}?tabs=${tabs}&storage=${storage}`);
})();
