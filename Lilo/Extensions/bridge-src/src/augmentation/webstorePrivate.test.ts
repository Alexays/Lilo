import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { installWebstorePrivate } from './webstorePrivate.ts';

describe('webstorePrivate shim', () => {
  it('does NOT install off the store origin', () => {
    const win: any = { location: { hostname: 'example.com' }, navigator: {} };
    installWebstorePrivate(win);
    assert.equal(win.chrome?.webstorePrivate, undefined);
  });

  it('installs on the store origin', () => {
    const win: any = { location: { hostname: 'chromewebstore.google.com' }, navigator: {},
      webkit: { messageHandlers: { liloWebstore: { postMessage: async () => '' } } } };
    installWebstorePrivate(win);
    assert.equal(typeof win.chrome.webstorePrivate.beginInstallWithManifest3, 'function');
    assert.ok((win.navigator.userAgentData?.brands?.length ?? 0) > 0);
  });

  // A store window whose native handler reports `installedIds` as installed.
  function storeWin(installedIds: string[]): { win: any; calls: any[] } {
    const calls: any[] = [];
    const win: any = {
      location: { hostname: 'chromewebstore.google.com' }, navigator: {}, addEventListener() {},
      webkit: { messageHandlers: { liloWebstore: { postMessage: async (p: any) => {
        calls.push(p);
        if (p.action === 'list') return installedIds.map((id) => ({ id, name: id, version: '1', enabled: true }));
        return '';
      } } } },
    };
    installWebstorePrivate(win);
    return { win, calls };
  }

  const call = (fn: (...a: any[]) => void, ...args: any[]) =>
    new Promise((resolve) => fn(...args, resolve));

  it('getExtensionStatus reflects the native installed list', async () => {
    const { win } = storeWin(['aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa']);
    assert.equal(await call(win.chrome.webstorePrivate.getExtensionStatus, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', {}), 'enabled');
    assert.equal(await call(win.chrome.webstorePrivate.getExtensionStatus, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', {}), 'installable');
  });

  it('management.getAll maps the native list to ExtensionInfo', async () => {
    const { win } = storeWin(['aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa']);
    const all: any = await call(win.chrome.management.getAll);
    assert.equal(all.length, 1);
    assert.equal(all[0].id, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
    assert.equal(all[0].enabled, true);
  });

  it('management.uninstall calls native with the uninstall action', async () => {
    const { win, calls } = storeWin(['aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa']);
    await call(win.chrome.management.uninstall, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
    assert.ok(calls.some((c) => c.action === 'uninstall' && c.id === 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'));
  });

  it('beginInstallWithManifest3 posts the install action and reports success', async () => {
    const { win, calls } = storeWin([]);
    const result = await call(win.chrome.webstorePrivate.beginInstallWithManifest3, { id: 'cccccccccccccccccccccccccccccccc' });
    assert.equal(result, '');
    assert.ok(calls.some((c) => c.action === 'install' && c.id === 'cccccccccccccccccccccccccccccccc'));
  });

  it('beginInstallWithManifest3 passes a native result code through', async () => {
    const win: any = { location: { hostname: 'chromewebstore.google.com' }, navigator: {},
      webkit: { messageHandlers: { liloWebstore: { postMessage: async () => 'already_installed' } } } };
    installWebstorePrivate(win);
    const result = await call(win.chrome.webstorePrivate.beginInstallWithManifest3, { id: 'cccccccccccccccccccccccccccccccc' });
    assert.equal(result, 'already_installed');
  });

  it('beginInstallWithManifest3 exposes a native failure on runtime.lastError during the callback', async () => {
    const win: any = { location: { hostname: 'chromewebstore.google.com' }, navigator: {},
      webkit: { messageHandlers: { liloWebstore: { postMessage: async () => { throw new Error('download failed'); } } } } };
    installWebstorePrivate(win);
    let seen: any;
    const result = await new Promise((resolve) => {
      win.chrome.webstorePrivate.beginInstallWithManifest3({ id: 'cccccccccccccccccccccccccccccccc' }, (r: string) => {
        seen = win.chrome.runtime.lastError?.message;
        resolve(r);
      });
    });
    assert.equal(result, 'installError');
    assert.equal(seen, 'download failed');
    assert.equal(win.chrome.runtime.lastError, undefined);
  });

  // Minimal DOM: elements with attributes and children, text nodes, and the one selector the
  // relabeling queries (a [jsname="V67aGc"] label that is a direct child of a button).
  function h(tag: string, attrs: Record<string, string>, ...children: any[]): any {
    const el: any = {
      tag, attrs, parentElement: null,
      childNodes: children.map((c) => (typeof c === 'string' ? { nodeType: 3, data: c } : c)),
      getAttribute: (name: string) => el.attrs[name] ?? null,
      setAttribute: (name: string, value: string) => { el.attrs[name] = value; },
    };
    for (const c of el.childNodes) if (c.nodeType !== 3) c.parentElement = el;
    return el;
  }
  const text = (el: any): string => el.childNodes.map((c: any) => (c.nodeType === 3 ? c.data : text(c))).join('');

  // The store's action area as it renders: install button, Share button, and text outside them.
  const actionArea = (label: string) => h('div', { jscontroller: 'ri2s0b' },
    h('button', { class: 'UywwFc-LgbsSe' },
      h('span', { class: 'UywwFc-RLmnJb' }),
      h('span', { jsname: 'V67aGc', class: 'UywwFc-vQzf8d' }, label)),
    h('button', { class: 'mUIrbf-LgbsSe' }, h('span', { jsname: 'V67aGc', class: 'mUIrbf-vQzf8d' }, 'Share')),
    h('span', { class: 'description' }, 'Works with Chrome'));

  function storePage(root: any): { win: any; mutate: () => void; frame: () => void; observed: any } {
    let onMutation = () => {};
    let frame = () => {};
    const observed: any = { frames: 0 };
    const labels = (el: any): any[] => el.childNodes.filter((c: any) => c.nodeType !== 3).flatMap((c: any) =>
      [...(c.attrs.jsname === 'V67aGc' && el.tag === 'button' ? [c] : []), ...labels(c)]);
    const win: any = {
      location: { hostname: 'chromewebstore.google.com' }, navigator: {},
      document: { querySelectorAll: (sel: string) => (sel === 'button > [jsname="V67aGc"]' ? labels(root) : []) },
      MutationObserver: class {
        constructor(cb: () => void) { onMutation = cb; }
        observe(target: any) { observed.target = target; }
      },
      requestAnimationFrame: (cb: () => void) => { observed.frames++; frame = cb; },
    };
    installWebstorePrivate(win);
    return { win, mutate: () => onMutation(), frame: () => frame(), observed };
  }

  it('labels the install button with Lilo in each locale, nothing else', () => {
    for (const [label, want] of [['Ajouter à Google Chrome', 'Ajouter à Lilo'], ['Añadir a Chrome', 'Añadir a Lilo']]) {
      const root = actionArea(label);
      const page = storePage(root);
      page.mutate();
      page.frame();
      const [install, share, description] = root.childNodes;
      assert.equal(text(install), want);
      assert.equal(text(share), 'Share');
      assert.equal(text(description), 'Works with Chrome');
    }
  });

  it('relabels the remove button and its aria-label when the store re-renders it', () => {
    const root = actionArea('Add to Chrome');
    const page = storePage(root);
    assert.equal(page.observed.target, page.win.document);
    page.mutate();
    page.frame();
    const install = root.childNodes[0];
    install.childNodes[1].childNodes[0].data = 'Remove from Chrome';
    install.setAttribute('aria-label', 'Remove uBlock Origin Lite from Chrome');
    page.mutate();
    page.mutate();
    assert.equal(page.observed.frames, 2, 'one pass per frame');
    page.frame();
    assert.equal(text(install), 'Remove from Lilo');
    assert.equal(install.getAttribute('aria-label'), 'Remove uBlock Origin Lite from Lilo');
  });
});
