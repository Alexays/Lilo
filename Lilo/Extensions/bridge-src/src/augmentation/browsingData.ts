// `settings` reports Chrome's default selection, as Lilo keeps no "clear browsing data" choices of its own.
// SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';

type RemovalOptions = { since?: number; originTypes?: Record<string, boolean>; origins?: string[]; excludeOrigins?: string[] };

function remove(options: RemovalOptions, dataToRemove: Record<string, boolean>, callback?: () => void) {
  return callbackify(async () => { await gapCall('browsingData', 'remove', { options, dataToRemove }); }, callback);
}

// Each remove* call clears one data type; appcache, pluginData and webSQL are gone from Chrome and clear nothing.
const removers = Object.fromEntries(Object.entries({
  removeAppcache: 'appcache', removeCache: 'cache', removeCacheStorage: 'cacheStorage', removeCookies: 'cookies',
  removeDownloads: 'downloads', removeFileSystems: 'fileSystems', removeFormData: 'formData', removeHistory: 'history',
  removeIndexedDB: 'indexedDB', removeLocalStorage: 'localStorage', removePluginData: 'pluginData',
  removeServiceWorkers: 'serviceWorkers', removeWebSQL: 'webSQL',
}).map(([name, type]) => [name, (options: RemovalOptions, callback?: () => void) => remove(options, { [type]: true }, callback)]));

const siteData = ['cookies', 'fileSystems', 'indexedDB', 'localStorage', 'serviceWorkers', 'cacheStorage'];
const selectable = [...siteData, 'pluginData', 'history', 'downloads', 'cache', 'formData', 'passwords'];
const selected = new Set([...siteData, 'history', 'downloads', 'cache']);

export const browsingDataAugmentation = {
  settings(callback?: (result: unknown) => void) {
    return callbackify(async () => ({
      options: { originTypes: { unprotectedWeb: true, protectedWeb: false, extension: false }, since: 0 },
      dataToRemove: Object.fromEntries(selectable.map((type) => [type, selected.has(type)])),
      dataRemovalPermitted: Object.fromEntries(selectable.map((type) => [type, true])),
    }), callback);
  },
  remove,
  removePasswords(_options: RemovalOptions, callback?: () => void) {
    return callbackify(async () => { throw new Error('Requested data type is deprecated.'); }, callback);
  },
  ...removers,
};
