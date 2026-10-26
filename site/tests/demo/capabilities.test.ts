import assert from "node:assert/strict";
import { test } from "node:test";

import {
  buildImportSelections,
  defaultImportChoices,
  profileKey,
} from "../../../lilo-ui/src/components/onboarding/onboardingModel.ts";
import type { AnyBridgeEventEnvelope } from "../../../lilo-ui/src/lib/bridge/protocol";
import { createDemoHost } from "../../src/demo/host.ts";

const createDemo = () => {
  const events: AnyBridgeEventEnvelope[] = [];
  const host = createDemoHost("en", (event) => events.push(event));

  return {
    archive: () => {
      host.dispatch("loadArchivedTabs", {});

      const event = events.findLast(
        (candidate) => candidate.event === "archivedTabs"
      );

      assert.ok(event?.event === "archivedTabs");

      return event.tabs;
    },
    events,
    host,
    scan: () => {
      host.dispatch("scanImportSources", {});

      const event = events.findLast(
        (candidate) => candidate.event === "importSourcesLoaded"
      );

      assert.ok(event?.event === "importSourcesLoaded");

      return event.sources;
    },
  };
};

test("locked content cannot be exposed by deleting, regrouping or moving its folder", () => {
  const { host } = createDemo();
  host.dispatch("setTabFolderLock", {
    allowsBiometrics: false,
    id: "trips",
    password: "sample-password",
  });
  host.dispatch("deleteTabFolder", { id: "trips" });
  host.dispatch("commitSidebarDrop", {
    fallbackIndex: 0,
    id: "travel",
    kind: "tab",
    parentFolderId: null,
    section: "pinned",
    type: "insert",
  });
  host.dispatch("commitSidebarDrop", {
    sourceTabId: "travel",
    targetTabId: "notes",
    type: "group",
  });
  host.dispatch("moveTabToSpace", { spaceId: "work", tabId: "travel" });
  assert.ok(
    host.snapshot().folders.find((folder) => folder.id === "trips")?.isLocked
  );
  assert.equal(
    host.snapshot().treeItems.find((item) => item.itemId === "travel")
      ?.parentFolderId,
    "trips"
  );
  assert.equal(
    host.snapshot().tabs.find((tab) => tab.id === "travel")?.spaceId,
    "home"
  );
  host.dispatch("moveTabToSpace", { spaceId: "work", tabId: "lilo" });
  assert.notEqual(host.snapshot().activeTabId, "travel");
  assert.equal(host.activeTab()?.id, "notes");
});

test("Clear archives background web tabs and Undo restores the archive rather than a closed tab", () => {
  const { archive, events, host } = createDemo();
  const selected = host.snapshot().activeTabId;
  host.dispatch("clearUnpinnedTabs", {});
  const entries = archive();
  assert.equal(entries.length, 1);
  assert.equal(entries[0].url, "https://notes.example.com");
  assert.equal(host.snapshot().activeTabId, selected);
  assert.ok(host.snapshot().tabs.some((tab) => tab.id === "travel"));
  assert.ok(!host.snapshot().tabs.some((tab) => tab.id === "notes"));
  const undo = events.findLast((event) => event.event === "tabClosedUndoable");
  assert.ok(undo?.event === "tabClosedUndoable");
  assert.deepEqual(
    undo.archivedIds,
    entries.map((entry) => entry.id)
  );
  assert.equal(undo.count, 1);
  host.dispatch("restoreClosedTab", {});
  assert.equal(host.snapshot().activeTabId, selected);
  assert.ok(!host.snapshot().tabs.some((tab) => tab.url === entries[0].url));
  host.dispatch("restoreArchivedTabs", { ids: undo.archivedIds ?? [] });
  assert.equal(host.activeTab()?.url, entries[0].url);
  assert.equal(archive().length, 0);
  assert.equal(
    host
      .snapshot()
      .treeItems.filter((item) => item.itemId === host.snapshot().activeTabId)
      .length,
    1
  );
});

test("the production import planner completes a local sample import and skips repeated URLs", () => {
  const { events, host, scan } = createDemo();
  const sources = scan();
  assert.deepEqual(scan(), sources);
  assert.equal(sources.length, 1);
  assert.match(sources[0].name, /Sample data/u);
  assert.equal(sources[0].needsFullDiskAccess, false);
  assert.deepEqual(sources[0].profiles[0].kinds, ["bookmarks", "tabs"]);
  const choices = defaultImportChoices(sources);
  const selections = buildImportSelections(sources, choices);
  const selected = host.snapshot().activeTabId;
  const previous = host.snapshot().tabs.length;
  host.dispatch("runImport", { selections });
  const finished = events.findLast((event) => event.event === "importFinished");
  assert.ok(finished?.event === "importFinished");
  assert.deepEqual(
    finished.summary.map(({ imported, kind }) => ({ imported, kind })),
    [
      { imported: 2, kind: "bookmarks" },
      { imported: 2, kind: "tabs" },
    ]
  );
  assert.equal(host.snapshot().activeTabId, selected);
  assert.equal(host.snapshot().tabs.length, previous + 4);
  assert.equal(
    host
      .snapshot()
      .tabs.filter(
        (tab) =>
          tab.isPinned &&
          (tab.url.includes("imported=") || tab.url.includes("/imported/"))
      ).length,
    2
  );
  assert.ok(
    events.some(
      (event) => event.event === "importProgress" && event.done === event.total
    )
  );
  scan();
  host.dispatch("runImport", { selections });
  const repeated = events.findLast((event) => event.event === "importFinished");
  assert.ok(repeated?.event === "importFinished");
  assert.ok(repeated.summary.every((item) => item.imported === 0));
  assert.equal(host.snapshot().tabs.length, previous + 4);
  assert.equal(host.snapshot().notice, "");
});

test("additional sample import profiles get their own Space and closing clears the scan", () => {
  const { events, host, scan } = createDemo();
  const sources = scan();
  const [source] = sources;
  const choices = defaultImportChoices(sources);
  choices.profiles = source.profiles.map((profile) =>
    profileKey(source.id, profile.id)
  );
  choices.kinds = ["tabs"];
  const selections = buildImportSelections(sources, choices);
  const initial = host.snapshot();
  host.dispatch("closeImport", {});
  host.dispatch("runImport", { selections });
  const closed = events.findLast((event) => event.event === "importFinished");
  assert.ok(closed?.event === "importFinished");
  assert.deepEqual(closed.summary, []);
  assert.equal(host.snapshot().tabs.length, initial.tabs.length);
  scan();
  host.dispatch("runImport", { selections });
  const snapshot = host.snapshot();

  const added = snapshot.spaces.find(
    (space) => !initial.spaces.some((existing) => existing.id === space.id)
  );

  assert.ok(added);
  assert.equal(snapshot.spaces.length, initial.spaces.length + 1);
  assert.equal(snapshot.profiles.length, initial.profiles.length + 1);
  assert.equal(snapshot.activeSpaceId, initial.activeSpaceId);
  assert.equal(snapshot.activeTabId, initial.activeTabId);
  assert.equal(snapshot.tabs.length, initial.tabs.length + 2);
  host.dispatch("switchSpace", { id: added.id });
  assert.equal(host.snapshot().tabs.length, 2);
  assert.ok(
    host
      .snapshot()
      .tabs.every((tab) => tab.url.endsWith("/work") && !tab.isPinned)
  );
});

test("archive browsing and clearing are scoped to a Space and preserve terminals and split panes", () => {
  const { archive, host } = createDemo();
  host.dispatch("clearUnpinnedTabs", {});
  const homeEntries = archive();
  host.dispatch("switchSpace", { id: "work" });
  assert.equal(archive().length, 0);
  host.dispatch("switchTab", { id: "work-notes" });
  host.dispatch("splitTab", { side: "right", tabId: "terminal" });
  host.dispatch("clearUnpinnedTabs", {});
  assert.equal(archive().length, 0);
  assert.ok(host.snapshot().tabs.some((tab) => tab.id === "work-notes"));
  host.dispatch("closeSplitView", {});
  host.dispatch("clearUnpinnedTabs", {});
  assert.equal(archive().length, 1);
  assert.ok(host.snapshot().tabs.some((tab) => tab.id === "terminal"));
  host.dispatch("clearArchivedTabs", {});
  assert.equal(archive().length, 0);
  host.dispatch("switchSpace", { id: "home" });
  assert.deepEqual(archive(), homeEntries);
  host.dispatch("switchSpace", { id: "work" });
  host.dispatch("restoreArchivedTabs", {
    ids: homeEntries.map((entry) => entry.id),
  });
  assert.equal(host.snapshot().activeSpaceId, "home");
  assert.equal(host.activeTab()?.url, homeEntries[0].url);
});

test("Space editor creates its requested profile and preserves archive delays when editing", () => {
  const { host } = createDemo();
  host.dispatch("createSpace", {
    name: "Research",
    newProfileColor: "#5278dd",
    newProfileName: " Research profile ",
    profileId: "profile-personal",
  });
  const id = host.snapshot().activeSpaceId;
  let space = host.snapshot().spaces.find((candidate) => candidate.id === id);
  assert.ok(space);
  assert.equal(space.archiveAfterHours, 12);
  assert.notEqual(space.profileId, "profile-personal");
  assert.deepEqual(
    host.snapshot().profiles.find((profile) => profile.id === space?.profileId),
    {
      color: "#5278dd",
      id: space.profileId,
      isDefault: false,
      name: "Research profile",
    }
  );
  host.dispatch("updateSpace", {
    archiveAfterHours: 0,
    id,
    newProfileColor: "#aabbcc",
    newProfileName: "Another profile",
  });
  space = host.snapshot().spaces.find((candidate) => candidate.id === id);
  assert.equal(space?.archiveAfterHours, 0);
  assert.equal(
    host.snapshot().profiles.find((profile) => profile.id === space?.profileId)
      ?.name,
    "Another profile"
  );
  const count = host.snapshot().profiles.length;
  host.dispatch("updateSpace", {
    id: "missing-space",
    newProfileName: "Orphan",
  });
  assert.equal(host.snapshot().profiles.length, count);
});

test("deleting a profile moves its Spaces and default role while retaining the last user profile", () => {
  const { events, host } = createDemo();
  host.dispatch("deleteProfile", {
    id: "profile-personal",
    moveTo: "profile-work",
  });
  assert.equal(host.snapshot().profiles.length, 1);
  assert.ok(host.snapshot().profiles[0].isDefault);
  assert.ok(
    host.snapshot().spaces.every((space) => space.profileId === "profile-work")
  );
  assert.equal(host.initialState().activeProfileId, "profile-work");
  assert.ok(
    events.some(
      (event) =>
        event.event === "profileDeleted" && event.id === "profile-personal"
    )
  );
  host.dispatch("createSpace", { name: "Default profile" });
  assert.equal(
    host
      .snapshot()
      .spaces.find((space) => space.id === host.snapshot().activeSpaceId)
      ?.profileId,
    "profile-work"
  );
  host.openPlayground("mcp");
  host.dispatch("deleteProfile", {
    id: "profile-work",
    moveTo: "profile-agents",
  });
  host.dispatch("deleteProfile", {
    id: "profile-agents",
    moveTo: "profile-work",
  });
  assert.equal(host.snapshot().profiles.length, 2);
});

test("folder password controls lock nested content and reject device authentication in the demo", () => {
  const { events, host } = createDemo();
  const nested = host.createFolder("Nested");
  host.dispatch("commitSidebarDrop", {
    fallbackIndex: 0,
    id: nested,
    kind: "folder",
    parentFolderId: "trips",
    section: "pinned",
    type: "insert",
  });
  host.dispatch("commitSidebarDrop", {
    fallbackIndex: 0,
    id: "notes",
    kind: "tab",
    parentFolderId: nested,
    section: "pinned",
    type: "insert",
  });
  host.dispatch("switchTab", { id: "notes" });
  host.dispatch("beginTabFolderLockSetup", { id: "trips" });
  assert.ok(
    events.some(
      (event) =>
        event.event === "beginFolderLockSetup" && !event.biometricsAvailable
    )
  );
  host.dispatch("setTabFolderLock", {
    allowsBiometrics: true,
    id: "trips",
    password: "sample-password",
  });
  assert.notEqual(host.snapshot().activeTabId, "notes");

  let folder = host
    .snapshot()
    .folders.find((candidate) => candidate.id === "trips");

  assert.ok(folder?.isLocked);
  assert.deepEqual(folder?.lock, {
    allowsBiometrics: false,
    biometricsAvailable: false,
  });
  host.dispatch("switchTab", { id: "notes" });
  assert.notEqual(host.snapshot().activeTabId, "notes");
  assert.ok(
    events.some(
      (event) => event.event === "beginFolderUnlock" && event.id === "trips"
    )
  );
  host.dispatch("unlockTabFolder", { id: "trips", method: "deviceOwner" });
  host.dispatch("unlockTabFolder", { id: "trips", password: "wrong-password" });
  assert.equal(
    events.filter((event) => event.event === "folderUnlockFailed").length,
    2
  );
  host.dispatch("unlockTabFolder", {
    id: "trips",
    password: "sample-password",
  });
  host.dispatch("switchTab", { id: "notes" });
  assert.equal(host.snapshot().activeTabId, "notes");
  host.dispatch("changeTabFolderPassword", { id: "trips" });
  host.dispatch("setTabFolderLock", {
    allowsBiometrics: false,
    id: "trips",
    password: "replacement-password",
  });
  host.dispatch("unlockTabFolder", {
    id: "trips",
    password: "sample-password",
  });
  folder = host
    .snapshot()
    .folders.find((candidate) => candidate.id === "trips");
  assert.ok(folder?.isLocked);
  host.dispatch("unlockTabFolder", {
    id: "trips",
    password: "replacement-password",
  });
  host.dispatch("removeTabFolderLock", { id: "trips" });
  host.dispatch("lockTabFolder", { id: "trips" });
  folder = host
    .snapshot()
    .folders.find((candidate) => candidate.id === "trips");
  assert.equal(folder?.lock, null);
  assert.equal(folder?.isLocked, false);
});
