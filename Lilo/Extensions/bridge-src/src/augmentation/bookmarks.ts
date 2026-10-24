// Augments the native chrome.bookmarks with gap-bridged calls.
import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { createGapEventsFromNames, gapMethod } from '../shared/gap-event.ts';
import { createChromeEventsFromNames } from '../shared/chrome-event.ts';

export const bookmarksAugmentation = {
  get(idOrIdList: string | string[], callback?: (results: any[]) => void) {
    // Swift reads arrays from "ids" and a single id from "id".
    const params = Array.isArray(idOrIdList) ? { ids: idOrIdList } : { id: idOrIdList };
    return callbackify(() => gapCall<any[]>('bookmarks', 'get', params), callback);
  },
  getTree: gapMethod('bookmarks', 'getTree'),
  getChildren: gapMethod('bookmarks', 'getChildren', ['id']),
  getSubTree: gapMethod('bookmarks', 'getSubTree', ['id']),
  getRecent: gapMethod('bookmarks', 'getRecent', ['numberOfItems']),
  search(query: any, callback?: (results: any[]) => void) {
    // Swift reads url/title/query at the top level, so an object query passes through as-is.
    const params = typeof query === 'string' ? { query } : query;
    return callbackify(() => gapCall<any[]>('bookmarks', 'search', params), callback);
  },
  create: gapMethod('bookmarks', 'create'),
  move(id: string, destination: any, callback?: (node: any) => void) {
    return callbackify(() => gapCall('bookmarks', 'move', { id, ...destination }), callback);
  },
  update(id: string, changes: any, callback?: (node: any) => void) {
    // Swift reads title/url at the top level, not nested under "changes".
    return callbackify(() => gapCall('bookmarks', 'update', { id, ...changes }), callback);
  },
  remove: gapMethod('bookmarks', 'remove', ['id']),
  removeTree: gapMethod('bookmarks', 'removeTree', ['id']),
  ...createGapEventsFromNames('bookmarks', ['onCreated', 'onRemoved', 'onChanged', 'onMoved']),
  // Lilo's bookmarks change through this API only: nothing sorts or imports them.
  ...createChromeEventsFromNames(['onChildrenReordered', 'onImportBegan', 'onImportEnded']),
};
