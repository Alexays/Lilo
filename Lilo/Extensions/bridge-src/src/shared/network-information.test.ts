import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { installNetworkInformation } from './network-information.ts';

function scope(onLine = true) {
  const global = new EventTarget() as EventTarget & { navigator: { onLine: boolean; connection?: any } };
  global.navigator = { onLine };
  installNetworkInformation(global as any);
  return global;
}

describe('installNetworkInformation', () => {
  it('reads as Chrome desktop on a fast network, with no speed offline', () => {
    const global = scope();
    const { connection } = global.navigator;
    assert.deepEqual(
      [connection.effectiveType, connection.rtt, connection.downlink, connection.saveData, String(connection)],
      ['4g', 50, 10, false, '[object NetworkInformation]'],
    );
    global.navigator.onLine = false;
    assert.deepEqual([connection.rtt, connection.downlink], [0, 0]);
  });

  it('fires change, to onchange and listeners, as the network comes and goes', () => {
    const global = scope();
    const { connection } = global.navigator;
    const heard: string[] = [];
    connection.onchange = function (this: unknown, event: Event) { heard.push(`onchange ${this === connection} ${event.type}`); };
    connection.addEventListener('change', () => heard.push('listener'));
    global.dispatchEvent(new Event('offline'));
    connection.onchange = null;
    global.dispatchEvent(new Event('online'));
    assert.deepEqual(heard, ['onchange true change', 'listener', 'listener']);
  });

  it('keeps a connection the engine has', () => {
    const connection = {};
    const global = new EventTarget() as any;
    global.navigator = { onLine: true, connection };
    installNetworkInformation(global);
    assert.equal(global.navigator.connection, connection);
  });
});
