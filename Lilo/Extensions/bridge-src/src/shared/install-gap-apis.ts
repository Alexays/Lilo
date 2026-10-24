// Shared by both bundles: extension pages and the service worker reach native over the same channel (ipc.ts).
// SW-safe: no window/document/webkit.
import { managementAugmentation } from '../augmentation/management.ts';
import { commandsAugmentation } from '../augmentation/commands.ts';
import { tabGroupsAugmentation, manifestPermissions } from '../augmentation/tabGroups.ts';
import { offscreenAugmentation } from '../augmentation/offscreen.ts';
import { userScriptsAugmentation, userScriptsAllowed } from '../augmentation/userScripts.ts';
import { gapModules as m } from './gap-modules.ts';
import { heldByLilo } from './chrome-leniency.ts';

/**
 * Each namespace only with its permission, as Chrome exposes them (native rejects calls without it too; this
 * keeps feature detection honest), and never over one WebKit provides. One whose permission is optional shows
 * once this context learns it is granted, from a permissions call (a worker's getAll once its top-level code ran).
 */
export function installGapAPIs(c: any): void {
  const required = manifestPermissions(c);
  installWith(c, required);
  const listed = c.runtime?.getManifest?.()?.optional_permissions;
  const optional = new Set<string>((Array.isArray(listed) ? listed : []).filter((name: string) => !required.has(name)));
  if (optional.size === 0) return;
  const later: any = { runtime: c.runtime };
  installWith(later, optional);
  const keys = Object.keys(later).filter((key) => key !== 'runtime' && !(key in c));
  for (const key of keys) {
    // Chrome gives chrome.instanceID with the gcm permission.
    const permission = key === 'instanceID' ? 'gcm' : key;
    Object.defineProperty(c, key, {
      configurable: true,
      enumerable: true,
      get: () => (heldByLilo.has(permission) ? later[key] : undefined),
      set: (value) => Object.defineProperty(c, key, { value, writable: true, configurable: true, enumerable: true }),
    });
  }
}

/** True when the extension declared a manifest omnibox keyword (Chrome only exposes the API then). */
function omniboxPermitted(chromeObj: any): boolean {
  try {
    return typeof chromeObj?.runtime?.getManifest?.()?.omnibox?.keyword === 'string';
  } catch {
    return false;
  }
}

function installWith(c: any, perms: Set<string>): void {
  if (perms.has('bookmarks')) Object.assign(c, { bookmarks: m.bookmarks.bookmarksAugmentation });
  if (perms.has('history')) Object.assign(c, { history: m.history.historyAugmentation });
  if (perms.has('idle') && !c.idle) c.idle = m.idle.idleAugmentation;
  if (perms.has('downloads')) Object.assign(c, { downloads: m.downloads.downloadsAugmentation });
  // getSelf, getPermissionWarningsByManifest and uninstallSelf need no permission in Chrome.
  if (!c.management) {
    const { getSelf, getPermissionWarningsByManifest, uninstallSelf } = managementAugmentation;
    c.management = perms.has('management') ? managementAugmentation : { getSelf, getPermissionWarningsByManifest, uninstallSelf };
  }
  if (perms.has('identity') && !c.identity) c.identity = m.identity.identityAugmentation;
  if (!c.commands) c.commands = commandsAugmentation;
  if (perms.has('notifications') && !c.notifications) c.notifications = m.notifications.notificationsAugmentation;
  if (perms.has('sessions') && !c.sessions) c.sessions = m.sessions.sessionsAugmentation;
  if (perms.has('topSites') && !c.topSites) c.topSites = m.topSites.topSitesAugmentation;
  if (perms.has('sidePanel') && !c.sidePanel) c.sidePanel = m.sidePanel.sidePanelAugmentation;
  // WebKit has no tab groups: chrome.tabGroups maps onto Lilo folders (tabs gets its part in chrome-compat.ts).
  if (perms.has('tabGroups') && !c.tabGroups) c.tabGroups = tabGroupsAugmentation;
  // WebKit drops the privacy permission from requested permissions; the manifest still names it.
  if (perms.has('privacy') && !c.privacy) c.privacy = m.privacy.privacyAugmentation;
  if (perms.has('offscreen') && !c.offscreen) c.offscreen = offscreenAugmentation;
  if (perms.has('search') && !c.search) c.search = m.search.searchAugmentation;
  // Chrome leaves chrome.userScripts undefined while "Allow user scripts" is off, which Tampermonkey tests.
  if (perms.has('userScripts') && !c.userScripts && userScriptsAllowed() !== false) c.userScripts = userScriptsAugmentation;
  if (omniboxPermitted(c) && !c.omnibox) c.omnibox = m.omnibox.omniboxAugmentation;
  if (perms.has('browsingData') && !c.browsingData) c.browsingData = m.browsingData.browsingDataAugmentation;
  if (perms.has('contentSettings') && !c.contentSettings) c.contentSettings = m.contentSettings.contentSettingsAugmentation;
  if (perms.has('fontSettings') && !c.fontSettings) c.fontSettings = m.fontSettings.fontSettingsAugmentation;
  if (perms.has('proxy') && !c.proxy) c.proxy = m.proxy.proxyAugmentation;
  if (perms.has('power') && !c.power) c.power = m.power.powerAugmentation;
  if (perms.has('tts') && !c.tts) c.tts = m.tts.ttsAugmentation;
  if (perms.has('publicSuffix') && !c.publicSuffix) c.publicSuffix = m.publicSuffix.publicSuffixAugmentation;
  if (perms.has('debugger') && !c.debugger) c.debugger = m.debugger.debuggerAugmentation;
  if (perms.has('gcm') && !c.gcm) c.gcm = m.gcm.gcmAugmentation;
  // Chrome gives chrome.instanceID with the gcm permission.
  if (perms.has('gcm') && !c.instanceID) c.instanceID = m.instanceID.instanceIDAugmentation;
  if (perms.has('pageCapture') && !c.pageCapture) c.pageCapture = m.pageCapture.pageCaptureAugmentation;
  if (perms.has('declarativeContent') && !c.declarativeContent) c.declarativeContent = m.declarativeContent.declarativeContentAugmentation;
  if (perms.has('printerProvider') && !c.printerProvider) c.printerProvider = m.printerProvider.printerProviderAugmentation;
  // Each chrome.system.* namespace comes with its own permission.
  const system: Record<string, unknown> = {};
  if (perms.has('system.cpu')) system.cpu = m.system.systemCpuAugmentation;
  if (perms.has('system.memory')) system.memory = m.system.systemMemoryAugmentation;
  if (perms.has('system.storage')) system.storage = m.system.systemStorageAugmentation;
  if (perms.has('system.display')) system.display = m.system.systemDisplayAugmentation;
  if (Object.keys(system).length > 0 && !c.system) c.system = system;
  if (perms.has('tabCapture') && !c.tabCapture) c.tabCapture = m.tabCapture.tabCaptureAugmentation;
  if (perms.has('desktopCapture') && !c.desktopCapture) c.desktopCapture = m.desktopCapture.desktopCaptureAugmentation;
}
