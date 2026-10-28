import { createChromeEventsFromNames } from './chrome-event.ts';
import { callbackify } from './callbackify.ts';

const GUARANTEED_MINIMUM_STATIC_RULES = 30000;

const RUNTIME_ENUMS: Record<string, Record<string, string>> = {
  PlatformOs: { MAC: 'mac', WIN: 'win', ANDROID: 'android', CROS: 'cros', LINUX: 'linux', OPENBSD: 'openbsd' },
  PlatformArch: { ARM: 'arm', ARM64: 'arm64', X86_32: 'x86-32', X86_64: 'x86-64', MIPS: 'mips', MIPS64: 'mips64', RISCV64: 'riscv64' },
  PlatformNaclArch: { ARM: 'arm', X86_32: 'x86-32', X86_64: 'x86-64', MIPS: 'mips', MIPS64: 'mips64' },
  OnInstalledReason: { INSTALL: 'install', UPDATE: 'update', CHROME_UPDATE: 'chrome_update', SHARED_MODULE_UPDATE: 'shared_module_update' },
  OnRestartRequiredReason: { APP_UPDATE: 'app_update', OS_UPDATE: 'os_update', PERIODIC: 'periodic' },
  ContextType: {
    TAB: 'TAB', POPUP: 'POPUP', BACKGROUND: 'BACKGROUND', OFFSCREEN_DOCUMENT: 'OFFSCREEN_DOCUMENT',
    SIDE_PANEL: 'SIDE_PANEL', DEVELOPER_TOOLS: 'DEVELOPER_TOOLS',
  },
  RequestUpdateCheckStatus: { THROTTLED: 'throttled', NO_UPDATE: 'no_update', UPDATE_AVAILABLE: 'update_available' },
};

// Chrome's values, except the dynamic and session caps: WebKit enforces one shared 30000-rule cap.
const DNR_CONSTANTS: Record<string, unknown> = {
  RuleActionType: {
    BLOCK: 'block', REDIRECT: 'redirect', ALLOW: 'allow', UPGRADE_SCHEME: 'upgradeScheme',
    MODIFY_HEADERS: 'modifyHeaders', ALLOW_ALL_REQUESTS: 'allowAllRequests',
  },
  ResourceType: {
    MAIN_FRAME: 'main_frame', SUB_FRAME: 'sub_frame', STYLESHEET: 'stylesheet', SCRIPT: 'script', IMAGE: 'image',
    FONT: 'font', OBJECT: 'object', XMLHTTPREQUEST: 'xmlhttprequest', PING: 'ping', CSP_REPORT: 'csp_report',
    MEDIA: 'media', WEBSOCKET: 'websocket', WEBTRANSPORT: 'webtransport', WEBBUNDLE: 'webbundle', OTHER: 'other',
  },
  RequestMethod: {
    CONNECT: 'connect', DELETE: 'delete', GET: 'get', HEAD: 'head', OPTIONS: 'options',
    PATCH: 'patch', POST: 'post', PUT: 'put', OTHER: 'other',
  },
  DomainType: { FIRST_PARTY: 'firstParty', THIRD_PARTY: 'thirdParty' },
  HeaderOperation: { APPEND: 'append', SET: 'set', REMOVE: 'remove' },
  UnsupportedRegexReason: { SYNTAX_ERROR: 'syntaxError', MEMORY_LIMIT_EXCEEDED: 'memoryLimitExceeded' },
  MAX_NUMBER_OF_RULES: GUARANTEED_MINIMUM_STATIC_RULES,
  GUARANTEED_MINIMUM_STATIC_RULES,
  MAX_NUMBER_OF_DYNAMIC_RULES: 30000,
  MAX_NUMBER_OF_SESSION_RULES: 30000,
  MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: 5000,
  MAX_NUMBER_OF_UNSAFE_SESSION_RULES: 5000,
  MAX_NUMBER_OF_REGEX_RULES: 1000,
  MAX_NUMBER_OF_STATIC_RULESETS: 100,
  MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
  DYNAMIC_RULESET_ID: '_dynamic',
  SESSION_RULESET_ID: '_session',
  GETMATCHEDRULES_QUOTA_INTERVAL: 10,
  MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20,
  getAvailableStaticRuleCount(callback?: (count: number) => void) {
    return callbackify(async () => GUARANTEED_MINIMUM_STATIC_RULES, callback);
  },
};

/**
 * Chrome's constants WebKit lacks, by namespace, where WebKit's limits differ from Chrome's or the
 * generated table (chrome-constants.gen.ts) has none; they win over that table.
 */
export const STATIC_CONSTANTS: Record<string, Record<string, unknown>> = {
  tabs: { TabStatus: { UNLOADED: 'unloaded', LOADING: 'loading', COMPLETE: 'complete' } },
  runtime: RUNTIME_ENUMS,
  declarativeNetRequest: DNR_CONSTANTS,
  storage: {
    // The enterprise-policy store: Chrome's is empty on a non-managed install, so extensions see no policy.
    managed: {
      get(keys?: unknown, callback?: (items: Record<string, unknown>) => void) {
        if (typeof keys === 'function') { (keys as (i: Record<string, unknown>) => void)({}); return undefined; }
        // Keys given with defaults read their defaults, as from any empty storage area (Lightspeed reads its Env so).
        const items = keys !== null && typeof keys === 'object' && !Array.isArray(keys) ? { ...keys } : {};
        if (callback) { Promise.resolve(items).then(callback); return undefined; }
        return Promise.resolve(items);
      },
      getBytesInUse(keys?: unknown, callback?: (bytes: number) => void) {
        if (typeof keys === 'function') { (keys as (n: number) => void)(0); return undefined; }
        if (callback) { callback(0); return undefined; }
        return Promise.resolve(0);
      },
      QUOTA_BYTES: 0,
      ...createChromeEventsFromNames(['onChanged']),
    },
  },
};

/**
 * On the prototype of a WebKit namespace, as WebKit's `browser` (which webextension-polyfill hands out) reads it
 * without going through Lilo's `chrome`; Lilo's own namespaces are plain objects and take them directly.
 */
/** The compat ExtensionBackgroundPreparer writes into every extension, which each isolated-world script runs first. */
export const contentCompat = '_lilo/lilo-content-compat.js';

export const withoutContentCompat = (script: any) => (Array.isArray(script?.js) && script.js.includes(contentCompat)
  ? { ...script, js: script.js.filter((file: string) => file !== contentCompat) }
  : script);

/**
 * The manifest as the extension wrote it: ExtensionBackgroundPreparer names Lilo's wrapper as the worker, keeping the
 * extension's own in `lilo_service_worker` (webext-detect-page compares it with the worker's location), and leads each
 * content script entry with the compat (Lightning Autofill derives a key from its content scripts).
 */
export function chromeManifest(manifest: any): any {
  const background = manifest?.background;
  if (typeof background?.lilo_service_worker === 'string') {
    background.service_worker = background.lilo_service_worker;
    delete background.lilo_service_worker;
  }
  if (Array.isArray(manifest?.content_scripts)) manifest.content_scripts = manifest.content_scripts.map(withoutContentCompat);
  return manifest;
}

export function home(namespace: object): any {
  const prototype = Object.getPrototypeOf(namespace);
  return prototype && prototype !== Object.prototype ? prototype : namespace;
}

/** Defines each of `members` that `namespace` lacks, never replacing WebKit's own. */
export function addMissing(namespace: any, members: Record<string, unknown> | undefined): void {
  if (namespace === null || typeof namespace !== 'object' || !members) return;
  const target = home(namespace);
  for (const name in members) {
    if (namespace[name] !== undefined) continue;
    try {
      Object.defineProperty(target, name, { value: members[name], enumerable: true, configurable: true, writable: true });
    } catch { /* a sealed native namespace keeps what it has */ }
  }
}

// WebKit recreates a collected namespace object without the constants: the ones given them stay alive.
const namespaces: unknown[] = [];

/** The hand-written constants alone, for content scripts, which never see Lilo's `chrome` proxy. */
export function installStaticChromeCompat(target: { chrome?: Record<string, unknown> }): void {
  for (const name in STATIC_CONSTANTS) {
    const namespace = target.chrome?.[name];
    namespaces.push(namespace);
    addMissing(namespace, STATIC_CONSTANTS[name]);
  }
}
