import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mockGapAPI } from '../shared/ipc.testkit.ts';

describe('augmentation entry', () => {
  beforeEach(() => {
    delete (globalThis as any).__liloAugmentationInstalled;
    (globalThis as any).origin = 'chrome-extension://test';
    mockGapAPI(() => null);
    (globalThis as any).chrome = { tabs: {} };
  });

  it('adds Chrome tabs status constants when WK omits them', async () => {
    await import(`../augmentation-entry.ts?test=${Date.now()}`);

    assert.equal((globalThis as any).chrome.tabs.TabStatus.UNLOADED, 'unloaded');
    assert.equal((globalThis as any).chrome.tabs.TabStatus.LOADING, 'loading');
    assert.equal((globalThis as any).chrome.tabs.TabStatus.COMPLETE, 'complete');
  });
});

describe('augmentation entry permission gating', () => {
  beforeEach(() => {
    delete (globalThis as any).__liloAugmentationInstalled;
    (globalThis as any).origin = 'chrome-extension://test';
    mockGapAPI(() => null);
  });

  it('shows a namespace whose permission is optional once it is granted, as Chrome', async () => {
    let held: string[] = [];
    mockGapAPI(({ method }: any) => (method === 'held' ? held : null));
    (globalThis as any).chrome = { tabs: {}, runtime: { getManifest: () => ({ permissions: [], optional_permissions: ['offscreen'] }) } };

    await import(`../augmentation-entry.ts?test=${Date.now()}-optional`);

    const c = (globalThis as any).chrome;
    assert.equal(c.offscreen, undefined);
    held = ['offscreen'];
    // As a permissions.contains or getAll call learns it.
    await (await import('../shared/chrome-leniency.ts')).readHeldByLilo();
    assert.equal(typeof c.offscreen?.createDocument, 'function');
  });

  it('installs only the gap namespaces the manifest declares', async () => {
    (globalThis as any).chrome = { tabs: {}, runtime: { getManifest: () => ({ permissions: ['history'] }) } };

    await import(`../augmentation-entry.ts?test=${Date.now()}-perms`);

    const c = (globalThis as any).chrome;
    assert.equal(typeof c.history?.search, 'function');
    assert.equal(c.bookmarks, undefined);
    assert.equal(c.downloads, undefined);
    assert.equal(c.identity, undefined);
    assert.deepEqual(Object.keys(c.management).sort(), [
      'ExtensionDisabledReason', 'ExtensionInstallType', 'ExtensionType', 'LaunchType', 'getPermissionWarningsByManifest', 'getSelf', 'uninstallSelf',
    ], "Chrome's management without the permission, enums included");
  });
});

describe('augmentation entry missing-API shims', () => {
  beforeEach(() => {
    delete (globalThis as any).__liloAugmentationInstalled;
    (globalThis as any).origin = 'chrome-extension://test';
    mockGapAPI(() => null);
  });

  it('installs privacy, offscreen and search only when declared', async () => {
    (globalThis as any).chrome = {
      tabs: {},
      i18n: {},
      runtime: { getManifest: () => ({ permissions: ['privacy', 'offscreen'] }) },
    };

    await import(`../augmentation-entry.ts?test=${Date.now()}-shims`);

    const c = (globalThis as any).chrome;
    const setting = await c.privacy.services.passwordSavingEnabled.get({});
    assert.deepEqual(setting, { value: true, levelOfControl: 'not_controllable' });
    assert.equal(c.offscreen.Reason.DOM_PARSER, 'DOM_PARSER');
    assert.equal(c.search, undefined);
    assert.equal(typeof c.runtime.getContexts, 'function');
    assert.equal(typeof c.i18n.detectLanguage, 'function');
  });

  it('keeps a native offscreen namespace', async () => {
    const native = {};
    (globalThis as any).chrome = { tabs: {}, offscreen: native, runtime: { getManifest: () => ({ permissions: ['offscreen'] }) } };

    await import(`../augmentation-entry.ts?test=${Date.now()}-native-offscreen`);

    assert.equal((globalThis as any).chrome.offscreen, native);
  });
});

describe('augmentation entry in a web frame', () => {
  it('leaves a web page framed inside an extension page untouched', async () => {
    delete (globalThis as any).__liloAugmentationInstalled;
    (globalThis as any).origin = 'https://example.com';
    (globalThis as any).chrome = undefined;

    await import(`../augmentation-entry.ts?test=${Date.now()}-web-frame`);

    assert.equal((globalThis as any).chrome, undefined);
    assert.equal((globalThis as any).__liloAugmentationInstalled, undefined);
  });
});

describe('augmentation entry commands', () => {
  beforeEach(() => {
    delete (globalThis as any).__liloAugmentationInstalled;
    (globalThis as any).origin = 'chrome-extension://test';
  });

  it('resolves commands.getAll with the command list native wraps', async () => {
    mockGapAPI(() => ({ commands: [{ name: 'run' }] }));
    (globalThis as any).chrome = { tabs: {}, runtime: { getManifest: () => ({ permissions: [] }) } };

    await import(`../augmentation-entry.ts?test=${Date.now()}-commands`);

    assert.deepEqual(await (globalThis as any).chrome.commands.getAll(), [{ name: 'run' }]);
  });
});

describe('augmentation entry members added to WebKit namespaces', () => {
  beforeEach(() => {
    delete (globalThis as any).__liloAugmentationInstalled;
    (globalThis as any).origin = 'chrome-extension://test';
    mockGapAPI(() => null);
  });

  it('adds the missing members without replacing WebKit ones', async () => {
    const ownRestart = () => {};
    (globalThis as any).chrome = {
      tabs: {},
      windows: {},
      runtime: { restart: ownRestart, getManifest: () => ({ permissions: ['declarativeNetRequestFeedback'] }) },
      declarativeNetRequest: {},
      extension: {},
      webRequest: {},
      permissions: {},
      action: {},
    };

    await import(`../augmentation-entry.ts?test=${Date.now()}-members`);

    const c = (globalThis as any).chrome;
    assert.equal(c.runtime.restart, ownRestart);
    for (const member of ['onSuspend', 'onSuspendCanceled', 'onEnabled', 'onExtensionLoaded', 'onUpdateAvailable', 'onRestartRequired']) {
      assert.equal(typeof c.runtime[member]?.addListener, 'function', member);
    }
    assert.equal(c.runtime.onConnectNative, undefined, 'only with nativeMessaging');
    for (const member of ['highlight', 'getZoomSettings', 'setZoomSettings', 'createSplit', 'unsplit']) {
      assert.equal(typeof c.tabs[member], 'function', member);
    }
    assert.equal(typeof c.tabs.onZoomChange.addListener, 'function');
    assert.equal(typeof c.windows.onBoundsChanged.addListener, 'function');
    assert.equal(typeof c.declarativeNetRequest.onRuleMatchedDebug.addListener, 'function');
    assert.equal(typeof c.extension.setUpdateUrlData, 'function');
    await c.webRequest.handlerBehaviorChanged();
    assert.equal(typeof c.webRequest.onActionIgnored.addListener, 'function');
    assert.equal(typeof c.permissions.addHostAccessRequest, 'function');
    assert.equal(typeof c.action.onUserSettingsChanged.addListener, 'function');
  });

  it('adds runtime.onConnectNative with nativeMessaging', async () => {
    (globalThis as any).chrome = { tabs: {}, runtime: { getManifest: () => ({ permissions: ['nativeMessaging'] }) } };

    await import(`../augmentation-entry.ts?test=${Date.now()}-native`);

    assert.equal(typeof (globalThis as any).chrome.runtime.onConnectNative.addListener, 'function');
  });
});

