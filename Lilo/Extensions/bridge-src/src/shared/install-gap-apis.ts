// Shared by both bundles: extension pages and the service worker reach native over the same channel (ipc.ts).
// SW-safe: no window/document/webkit.
import { bookmarksAugmentation } from '../augmentation/bookmarks.ts';
import { historyAugmentation } from '../augmentation/history.ts';
import { idleAugmentation } from '../augmentation/idle.ts';
import { downloadsAugmentation } from '../augmentation/downloads.ts';
import { managementAugmentation } from '../augmentation/management.ts';
import { identityAugmentation } from '../augmentation/identity.ts';
import { commandsAugmentation } from '../augmentation/commands.ts';
import { notificationsAugmentation } from '../augmentation/notifications.ts';
import { sessionsAugmentation } from '../augmentation/sessions.ts';
import { topSitesAugmentation } from '../augmentation/topSites.ts';
import { sidePanelAugmentation } from '../augmentation/sidePanel.ts';
import { tabGroupsAugmentation, manifestPermissions } from '../augmentation/tabGroups.ts';
import { omniboxAugmentation, omniboxPermitted } from '../augmentation/omnibox.ts';
import { privacyAugmentation } from '../augmentation/privacy.ts';
import { offscreenAugmentation } from '../augmentation/offscreen.ts';
import { searchAugmentation } from '../augmentation/search.ts';
import { browsingDataAugmentation } from '../augmentation/browsingData.ts';
import { contentSettingsAugmentation } from '../augmentation/contentSettings.ts';
import { fontSettingsAugmentation } from '../augmentation/fontSettings.ts';
import { proxyAugmentation } from '../augmentation/proxy.ts';
import { tabCaptureAugmentation } from '../augmentation/tabCapture.ts';
import { desktopCaptureAugmentation } from '../augmentation/desktopCapture.ts';
import { userScriptsAugmentation, userScriptsAllowed } from '../augmentation/userScripts.ts';
import { powerAugmentation } from '../augmentation/power.ts';
import { systemCpuAugmentation, systemMemoryAugmentation, systemStorageAugmentation, systemDisplayAugmentation } from '../augmentation/system.ts';
import { ttsAugmentation } from '../augmentation/tts.ts';
import { publicSuffixAugmentation } from '../augmentation/publicSuffix.ts';
import { debuggerAugmentation } from '../augmentation/debugger.ts';
import { gcmAugmentation } from '../augmentation/gcm.ts';
import { declarativeContentAugmentation } from '../augmentation/declarativeContent.ts';
import { printerProviderAugmentation } from '../augmentation/printerProvider.ts';
import { pageCaptureAugmentation } from '../augmentation/pageCapture.ts';
import { instanceIDAugmentation } from '../augmentation/instanceID.ts';
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

function installWith(c: any, perms: Set<string>): void {
  if (perms.has('bookmarks')) Object.assign(c, { bookmarks: bookmarksAugmentation });
  if (perms.has('history')) Object.assign(c, { history: historyAugmentation });
  if (perms.has('idle') && !c.idle) c.idle = idleAugmentation;
  if (perms.has('downloads')) Object.assign(c, { downloads: downloadsAugmentation });
  // getSelf, getPermissionWarningsByManifest and uninstallSelf need no permission in Chrome.
  if (!c.management) {
    const { getSelf, getPermissionWarningsByManifest, uninstallSelf } = managementAugmentation;
    c.management = perms.has('management') ? managementAugmentation : { getSelf, getPermissionWarningsByManifest, uninstallSelf };
  }
  if (perms.has('identity') && !c.identity) c.identity = identityAugmentation;
  if (!c.commands) c.commands = commandsAugmentation;
  if (perms.has('notifications') && !c.notifications) c.notifications = notificationsAugmentation;
  if (perms.has('sessions') && !c.sessions) c.sessions = sessionsAugmentation;
  if (perms.has('topSites') && !c.topSites) c.topSites = topSitesAugmentation;
  if (perms.has('sidePanel') && !c.sidePanel) c.sidePanel = sidePanelAugmentation;
  // WebKit has no tab groups: chrome.tabGroups maps onto Lilo folders (tabs gets its part in chrome-compat.ts).
  if (perms.has('tabGroups') && !c.tabGroups) c.tabGroups = tabGroupsAugmentation;
  // WebKit drops the privacy permission from requested permissions; the manifest still names it.
  if (perms.has('privacy') && !c.privacy) c.privacy = privacyAugmentation;
  if (perms.has('offscreen') && !c.offscreen) c.offscreen = offscreenAugmentation;
  if (perms.has('search') && !c.search) c.search = searchAugmentation;
  // Chrome leaves chrome.userScripts undefined while "Allow user scripts" is off, which Tampermonkey tests.
  if (perms.has('userScripts') && !c.userScripts && userScriptsAllowed() !== false) c.userScripts = userScriptsAugmentation;
  if (omniboxPermitted(c) && !c.omnibox) c.omnibox = omniboxAugmentation;
  if (perms.has('browsingData') && !c.browsingData) c.browsingData = browsingDataAugmentation;
  if (perms.has('contentSettings') && !c.contentSettings) c.contentSettings = contentSettingsAugmentation;
  if (perms.has('fontSettings') && !c.fontSettings) c.fontSettings = fontSettingsAugmentation;
  if (perms.has('proxy') && !c.proxy) c.proxy = proxyAugmentation;
  if (perms.has('power') && !c.power) c.power = powerAugmentation;
  if (perms.has('tts') && !c.tts) c.tts = ttsAugmentation;
  if (perms.has('publicSuffix') && !c.publicSuffix) c.publicSuffix = publicSuffixAugmentation;
  if (perms.has('debugger') && !c.debugger) c.debugger = debuggerAugmentation;
  if (perms.has('gcm') && !c.gcm) c.gcm = gcmAugmentation;
  // Chrome gives chrome.instanceID with the gcm permission.
  if (perms.has('gcm') && !c.instanceID) c.instanceID = instanceIDAugmentation;
  if (perms.has('pageCapture') && !c.pageCapture) c.pageCapture = pageCaptureAugmentation;
  if (perms.has('declarativeContent') && !c.declarativeContent) c.declarativeContent = declarativeContentAugmentation;
  if (perms.has('printerProvider') && !c.printerProvider) c.printerProvider = printerProviderAugmentation;
  // Each chrome.system.* namespace comes with its own permission.
  const system: Record<string, unknown> = {};
  if (perms.has('system.cpu')) system.cpu = systemCpuAugmentation;
  if (perms.has('system.memory')) system.memory = systemMemoryAugmentation;
  if (perms.has('system.storage')) system.storage = systemStorageAugmentation;
  if (perms.has('system.display')) system.display = systemDisplayAugmentation;
  if (Object.keys(system).length > 0 && !c.system) c.system = system;
  if (perms.has('tabCapture') && !c.tabCapture) c.tabCapture = tabCaptureAugmentation;
  if (perms.has('desktopCapture') && !c.desktopCapture) c.desktopCapture = desktopCaptureAugmentation;
}
