import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI, pushGapEvent } from '../shared/ipc.testkit.ts';

const calls: any[] = [];
mockGapAPI(async (msg: any) => { calls.push(msg); return msg.method === 'getNetworkInterfaces' ? [{ name: 'en0', address: '192.0.2.4', prefixLength: 24 }] : null; });
(globalThis as any).chrome = {
  runtime: { getManifest: () => ({ permissions: ['mdns', 'system.network'] }) },
};

const { installGapAPIs } = await import('../shared/install-gap-apis.ts');
installGapAPIs((globalThis as any).chrome);
const chrome = (globalThis as any).chrome;
const settle = () => new Promise((resolve) => setTimeout(resolve, 5));
const printer = { serviceName: 'Printer._ipp._tcp.local', serviceHostPort: 'printer.local:631', ipAddress: '192.0.2.7', serviceData: ['rp=ipp/print'] };

describe('chrome.mdns', () => {
  it('names each filtered service type for Lilo to browse, once, until its last listener goes', async () => {
    const first = () => {};
    const second = () => {};
    chrome.mdns.onServiceList.addListener(first, { serviceType: '_ipp._tcp.local' });
    chrome.mdns.onServiceList.addListener(second, { serviceType: '_ipp._tcp.local' });
    chrome.mdns.onServiceList.addListener(() => {});
    await settle();
    chrome.mdns.onServiceList.removeListener(first);
    chrome.mdns.onServiceList.removeListener(second);
    await settle();
    assert.deepEqual(calls.splice(0), [
      { namespace: 'mdns', method: 'watch', params: { serviceType: '_ipp._tcp.local' } },
      { namespace: 'events', method: 'listen', params: { events: ['mdns.onServiceList/_ipp._tcp.local'] } },
      { namespace: 'events', method: 'unlisten', params: { events: ['mdns.onServiceList/_ipp._tcp.local'] } },
    ]);
  });

  it('gives a type\'s list to the listeners filtering on it and to those without a filter', async () => {
    const heard: string[] = [];
    chrome.mdns.onServiceList.addListener((services: any[]) => heard.push(`ipp ${services.length}`), { serviceType: '_ipp._tcp.local' });
    chrome.mdns.onServiceList.addListener(() => heard.push('scanner'), { serviceType: '_uscan._tcp.local' });
    const all = (services: any[]) => heard.push(`all ${services[0].serviceName}`);
    chrome.mdns.onServiceList.addListener(all);
    await settle();
    pushGapEvent({ namespace: 'mdns', event: 'onServiceList/_ipp._tcp.local', args: [[printer]] });
    assert.deepEqual(heard, ['ipp 1', `all ${printer.serviceName}`]);
    assert.equal(chrome.mdns.onServiceList.hasListener(all), true);
  });

  it('forceDiscovery calls Lilo, with a promise or a callback', async () => {
    calls.length = 0;
    await chrome.mdns.forceDiscovery();
    await new Promise((resolve) => chrome.mdns.forceDiscovery(resolve));
    assert.equal(calls.filter((c) => c.namespace === 'mdns' && c.method === 'forceDiscovery').length, 2);
    assert.equal(chrome.mdns.MAX_SERVICE_INSTANCES_PER_EVENT, 2048);
  });
});

describe('chrome.system.network', () => {
  it('lists the network interfaces Lilo reads', async () => {
    assert.deepEqual(Object.keys(chrome.system), ['network']);
    assert.deepEqual(await chrome.system.network.getNetworkInterfaces(), [{ name: 'en0', address: '192.0.2.4', prefixLength: 24 }]);
    const viaCallback = await new Promise((resolve) => chrome.system.network.getNetworkInterfaces(resolve));
    assert.equal((viaCallback as any[]).length, 1);
  });
});
