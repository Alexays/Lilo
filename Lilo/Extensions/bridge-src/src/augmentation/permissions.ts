// Lilo knows no documentIds, so a host access request names a tab. SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { tabPositions } from './tabGroups.ts';

interface HostAccessRequest {
  documentId?: string;
  tabId?: number;
  pattern?: string;
}

function hostAccessRequest(method: string) {
  return (request: HostAccessRequest, callback?: () => void) => callbackify(async () => {
    const { documentId, tabId, pattern } = request ?? {};
    if ((documentId === undefined) === (tabId === undefined)) throw new Error("Must specify either 'documentId' or 'tabId'.");
    if (documentId !== undefined) throw new Error(`No document with ID '${documentId}'.`);
    const [tab] = await tabPositions([tabId as number]);
    if (!tab || tab.windowPosition < 0) throw new Error(`No tab with id: ${tabId}.`);
    await gapCall<null>('permissions', method, { tab, tabId, pattern });
  }, callback);
}

export const permissionsAdditions = {
  addHostAccessRequest: hostAccessRequest('addHostAccessRequest'),
  removeHostAccessRequest: hostAccessRequest('removeHostAccessRequest'),
};
