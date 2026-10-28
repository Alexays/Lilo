// WebKit has no user-scripts API: native keeps the registrations and installs them once the user turns on
// "Allow user scripts" for the extension; until then every call rejects. SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { bridgeChrome, callbackify } from '../shared/callbackify.ts';
import { ChromeEvent } from '../shared/chrome-event.ts';
import { GapChromeEvent } from '../shared/gap-event.ts';
import { tabPositions } from './tabGroups.ts';

interface ScriptFilter {
  ids?: string[];
}

/**
 * "Allow user scripts" for this extension: workers carry their own switch, pages the profile's allowed list. Undefined
 * without either, where native still rejects.
 */
export function userScriptsAllowed(): boolean | undefined {
  const g = globalThis as any;
  const allowedIds = g.__liloUserScriptsAllowedIds;
  return g.__liloUserScriptsAllowed ?? (Array.isArray(allowedIds) ? allowedIds.includes(bridgeChrome()?.runtime?.id) : undefined);
}

/** Chrome hides chrome.userScripts while the switch is off: a page that got it before the switch went off throws at once. */
function assertAvailable(): void {
  if (userScriptsAllowed() === false) {
    throw new Error('The userScripts API is unavailable: turn on "Allow user scripts" for this extension');
  }
}

/** Chrome's optional-argument shapes: `(filter?, callback?)`. */
function filterAndCallback<T>(filter?: ScriptFilter | ((result: T) => void), callback?: (result: T) => void) {
  return typeof filter === 'function' ? { filter: undefined, callback: filter } : { filter, callback };
}

export const userScriptsAugmentation = {
  ExecutionWorld: { MAIN: 'MAIN', USER_SCRIPT: 'USER_SCRIPT' },

  register(scripts: unknown[], callback?: () => void) {
    assertAvailable();
    return callbackify(async () => { await gapCall<null>('userScripts', 'register', { scripts }); }, callback);
  },

  update(scripts: unknown[], callback?: () => void) {
    assertAvailable();
    return callbackify(async () => { await gapCall<null>('userScripts', 'update', { scripts }); }, callback);
  },

  unregister(filter?: ScriptFilter | (() => void), callback?: () => void) {
    assertAvailable();
    const args = filterAndCallback(filter, callback);
    return callbackify(async () => { await gapCall<null>('userScripts', 'unregister', { filter: args.filter }); }, args.callback);
  },

  getScripts(filter?: ScriptFilter | ((scripts: unknown[]) => void), callback?: (scripts: unknown[]) => void) {
    assertAvailable();
    const args = filterAndCallback(filter, callback);
    return callbackify(() => gapCall<unknown[]>('userScripts', 'getScripts', { filter: args.filter }), args.callback);
  },

  configureWorld(properties: { worldId?: string; csp?: string; messaging?: boolean }, callback?: () => void) {
    assertAvailable();
    return callbackify(async () => { await gapCall<null>('userScripts', 'configureWorld', { properties }); }, callback);
  },

  getWorldConfigurations(callback?: (worlds: unknown[]) => void) {
    assertAvailable();
    return callbackify(() => gapCall<unknown[]>('userScripts', 'getWorldConfigurations'), callback);
  },

  /** WebKit owns the integer tab ids: native finds the tab by its position. */
  execute(injection: { target?: { tabId?: number } }, callback?: (results: unknown[]) => void) {
    assertAvailable();
    return callbackify(async () => {
      const tabs = await tabPositions(typeof injection?.target?.tabId === 'number' ? [injection.target.tabId] : []);
      return gapCall<unknown[]>('userScripts', 'execute', { injection, tabs });
    }, callback);
  },

  resetWorldConfiguration(worldId?: string | (() => void), callback?: () => void) {
    assertAvailable();
    const [id, cb] = typeof worldId === 'function' ? [undefined, worldId] : [worldId, callback];
    return callbackify(async () => { await gapCall<null>('userScripts', 'resetWorldConfiguration', { worldId: id }); }, cb);
  },
};

interface TabPosition {
  windowPosition: number;
  index: number;
}

/**
 * A context without listeners stays silent so another can answer; listeners that neither answer nor return true
 * reply undefined, as Chrome closes the channel.
 */
class UserScriptMessageEvent extends GapChromeEvent<any[]> {
  override dispatch(message?: unknown, sender?: Record<string, unknown>, replyId?: unknown): void {
    if (!this.hasListeners() || typeof replyId !== 'string') return;
    void this.deliver(message, sender ?? {}, replyId);
  }

  private async deliver(message: unknown, sender: Record<string, unknown>, replyId: string): Promise<void> {
    await resolveSenderTab(sender);
    let answered = false;
    const sendResponse = (response?: unknown) => {
      if (answered) return;
      answered = true;
      gapCall<null>('userScripts', 'reply', { replyId, response }).catch(() => {});
    };
    let keepsChannelOpen = false;
    for (const listener of this.snapshot()) {
      try {
        if ((listener as (...args: unknown[]) => unknown)(message, sender, sendResponse) === true) keepsChannelOpen = true;
      } catch (err) {
        console.error(`Error in event handler: ${String(err)}`);
      }
    }
    if (!keepsChannelOpen) sendResponse(undefined);
  }
}

export const onUserScriptMessage = new UserScriptMessageEvent('runtime', 'onUserScriptMessage');

/** WebKit owns the integer tab ids: native sends where the tab sits, resolved here to its tabs.Tab. */
async function resolveSenderTab(sender: Record<string, unknown>): Promise<void> {
  const position = sender.tabPosition as TabPosition | undefined;
  delete sender.tabPosition;
  if (!position) return;
  try {
    const c = bridgeChrome();
    const windowId = (await c.windows.getAll())[position.windowPosition]?.id;
    if (windowId !== undefined) sender.tab = (await c.tabs.query({ windowId })).find((t: any) => t.index === position.index);
  } catch { /* sender keeps no tab */ }
}

/** This context's end of a port a user script opened with runtime.connect. */
class UserScriptPort {
  readonly onMessage = new ChromeEvent<[unknown, UserScriptPort]>();
  readonly onDisconnect = new ChromeEvent<[UserScriptPort]>();
  connected = true;
  /** Traffic that arrives while the sender tab resolves, relayed once the connect listeners have run. */
  pending: Array<[unknown, unknown]> | undefined = [];
  readonly portId: string;
  readonly name: string;
  readonly sender: Record<string, unknown>;

  constructor(portId: string, name: string, sender: Record<string, unknown>) {
    this.portId = portId;
    this.name = name;
    this.sender = sender;
  }

  postMessage(message: unknown): void {
    if (!this.connected) throw new Error('Attempting to use a disconnected port object');
    gapCall<null>('userScripts', 'portPost', { portId: this.portId, message: message === undefined ? null : message }).catch(() => {});
  }

  disconnect(): void {
    if (!this.connected) return;
    this.connected = false;
    openPorts.delete(this.portId);
    gapCall<null>('userScripts', 'portDisconnect', { portId: this.portId }).catch(() => {});
  }
}

const openPorts = new Map<string, UserScriptPort>();

/**
 * Native relays a port's whole life here: "connect" hands listeners a new port, then "message" and "disconnect"
 * reach it. A context without listeners opens no port and ignores its traffic.
 */
class UserScriptConnectEvent extends GapChromeEvent<[UserScriptPort]> {
  override dispatch(...args: unknown[]): void {
    const [kind, portId] = args;
    if (typeof portId !== 'string') return;
    if (kind === 'connect') {
      if (!this.hasListeners()) return;
      const port = new UserScriptPort(portId, String(args[2] ?? ''), (args[3] ?? {}) as Record<string, unknown>);
      openPorts.set(portId, port);
      void this.open(port);
      return;
    }
    const port = openPorts.get(portId);
    if (port?.pending) port.pending.push([kind, args[2]]);
    else if (port) this.relay(port, kind, args[2]);
  }

  private relay(port: UserScriptPort, kind: unknown, message: unknown): void {
    if (!port.connected) return;
    if (kind === 'message') {
      port.onMessage.dispatch(message, port);
    } else if (kind === 'disconnect') {
      port.connected = false;
      openPorts.delete(port.portId);
      port.onDisconnect.dispatch(port);
    }
  }

  private async open(port: UserScriptPort): Promise<void> {
    await resolveSenderTab(port.sender);
    super.dispatch(port);
    const pending = port.pending!;
    port.pending = undefined;
    for (const [kind, message] of pending) this.relay(port, kind, message);
  }
}

export const onUserScriptConnect = new UserScriptConnectEvent('runtime', 'onUserScriptConnect');
