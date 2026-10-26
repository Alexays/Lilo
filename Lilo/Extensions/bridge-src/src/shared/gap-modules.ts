// The gap namespaces a manifest may leave out, one module each, named after the file. The bundles swap this file
// for one that evaluates a module only on first read, and a worker's prelude carries only the modules its manifest
// may use (esbuild.mjs). A module here imports none of the others.
import * as bookmarks from '../augmentation/bookmarks.ts';
import * as browsingData from '../augmentation/browsingData.ts';
import * as contentSettings from '../augmentation/contentSettings.ts';
import * as debuggerModule from '../augmentation/debugger.ts';
import * as declarativeContent from '../augmentation/declarativeContent.ts';
import * as declarativeNetRequest from '../augmentation/declarativeNetRequest.ts';
import * as desktopCapture from '../augmentation/desktopCapture.ts';
import * as downloads from '../augmentation/downloads.ts';
import * as fontSettings from '../augmentation/fontSettings.ts';
import * as gcm from '../augmentation/gcm.ts';
import * as history from '../augmentation/history.ts';
import * as identity from '../augmentation/identity.ts';
import * as idle from '../augmentation/idle.ts';
import * as instanceID from '../augmentation/instanceID.ts';
import * as mdns from '../augmentation/mdns.ts';
import * as notifications from '../augmentation/notifications.ts';
import * as omnibox from '../augmentation/omnibox.ts';
import * as pageCapture from '../augmentation/pageCapture.ts';
import * as power from '../augmentation/power.ts';
import * as printerProvider from '../augmentation/printerProvider.ts';
import * as privacy from '../augmentation/privacy.ts';
import * as proxy from '../augmentation/proxy.ts';
import * as publicSuffix from '../augmentation/publicSuffix.ts';
import * as search from '../augmentation/search.ts';
import * as sessions from '../augmentation/sessions.ts';
import * as sidePanel from '../augmentation/sidePanel.ts';
import * as system from '../augmentation/system.ts';
import * as tabCapture from '../augmentation/tabCapture.ts';
import * as topSites from '../augmentation/topSites.ts';
import * as tts from '../augmentation/tts.ts';

export const gapModules = {
  bookmarks, browsingData, contentSettings, debugger: debuggerModule, declarativeContent, declarativeNetRequest, desktopCapture, downloads,
  fontSettings, gcm, history, identity, idle, instanceID, mdns, notifications, omnibox, pageCapture, power, printerProvider,
  privacy, proxy, publicSuffix, search, sessions, sidePanel, system, tabCapture, topSites, tts,
};
