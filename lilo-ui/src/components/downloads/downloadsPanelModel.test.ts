import assert from "node:assert/strict";
import test from "node:test";

import {
  canOpen,
  fileIconURL,
  filterDownloads,
  groupDownloads,
  inlineAction,
  metaLine,
} from "./downloadsPanelModel";
import type { BridgeDownloadSnapshot } from "../../lib/bridge/protocol";
import { loadCatalog } from "../../lib/i18n/translate";

await loadCatalog("fr");

// 2026-06-12T12:00:00Z, in ms, injected clock for date grouping
const NOW_MS = Date.UTC(2026, 5, 12, 12, 0, 0);
const nowSec = NOW_MS / 1000;

function dl(overrides: Partial<BridgeDownloadSnapshot>): BridgeDownloadSnapshot {
  return {
    id: 1,
    url: "https://example.com/file.zip",
    filename: "file.zip",
    bytesReceived: 0,
    totalBytes: 0,
    state: "complete",
    startedAt: nowSec,
    fileMissing: false,
    source: "wk",
    ...overrides,
  };
}

test("filters on filename, url and source, case-insensitively", () => {
  const a = dl({ id: 1, filename: "report.pdf", url: "https://acme.io/report.pdf" });
  const b = dl({ id: 2, filename: "photo.jpg", url: "https://pics.example.com/p.jpg", source: "url" });
  const all = [a, b];

  assert.deepEqual(filterDownloads(all, ""), all);
  assert.deepEqual(filterDownloads(all, "REPORT"), [a]);
  assert.deepEqual(filterDownloads(all, "pics.example"), [b]);
  assert.deepEqual(filterDownloads(all, "url"), [b]);
  assert.deepEqual(filterDownloads(all, "zzz"), []);
});

test("groups active downloads apart, then history by day for a week and by month after", () => {
  const active = dl({ id: 1, state: "inProgress" });
  const pausedDl = dl({ id: 2, state: "paused" });
  const today = dl({ id: 3, startedAt: nowSec - 3600 });
  const yesterday = dl({ id: 4, startedAt: nowSec - 86400 });
  const fiveDaysAgo = dl({ id: 5, startedAt: nowSec - 5 * 86400 });
  const sameDay = dl({ id: 6, startedAt: nowSec - 5 * 86400 - 60 });
  const lastMonth = dl({ id: 7, startedAt: nowSec - 40 * 86400 });

  const grouped = groupDownloads(
    [active, today, pausedDl, yesterday, fiveDaysAgo, sameDay, lastMonth],
    NOW_MS,
    "fr",
  );

  assert.deepEqual(grouped.active.map((d) => d.id), [1, 2]);
  assert.deepEqual(
    grouped.history.map((g) => [g.labelKey ?? g.label, g.items.map((d) => d.id)]),
    [
      ["downloadsPanel.groupToday", [3]],
      ["downloadsPanel.groupYesterday", [4]],
      ["dimanche 7 juin", [5, 6]],
      ["mai 2026", [7]],
    ],
  );
});

test("metaLine for an in-progress download joins bytes, speed and eta", () => {
  const line = metaLine(
    dl({
      state: "inProgress",
      bytesReceived: 1.2 * 1024 ** 3,
      totalBytes: 2.7 * 1024 ** 3,
      speedBytesPerSec: 84 * 1024 ** 2,
      eta: 18,
    }),
    "fr",
    NOW_MS,
  );
  assert.deepEqual(line, {
    detail: "1,2 Go / 2,7 Go · 84,0 Mo/s · 18s",
    stateKey: null,
    errorText: null,
    tone: "neutral",
  });
});

test("metaLine omits unknown totals, speed and eta", () => {
  const line = metaLine(dl({ state: "inProgress", bytesReceived: 5 * 1024 ** 2 }), "fr", NOW_MS);
  assert.deepEqual(line, { detail: "5,0 Mo", stateKey: null, errorText: null, tone: "neutral" });
});

test("metaLine for paused shows percent and received bytes", () => {
  const line = metaLine(
    dl({ state: "paused", bytesReceived: 512 * 1024 ** 2, totalBytes: 1024 ** 3 }),
    "fr",
    NOW_MS,
  );
  assert.deepEqual(line, {
    detail: "50% · 512,0 Mo",
    stateKey: "downloadsPanel.statePaused",
    errorText: null,
    tone: "neutral",
  });
});

test("metaLine for complete shows size, end time and host, or File missing", () => {
  const endedAt = new Date(2026, 5, 12, 14, 2).getTime() / 1000;
  const saved = metaLine(
    dl({ url: "https://www.example.com/a.zip", totalBytes: 6041430000, endedAt }),
    "fr",
    NOW_MS,
  );
  assert.deepEqual(saved, {
    detail: "5,6 Go · 14:02 · example.com",
    stateKey: null,
    errorText: null,
    tone: "neutral",
  });

  const old = metaLine(dl({ totalBytes: 1024, endedAt: nowSec - 40 * 86400 }), "fr", NOW_MS);
  assert.equal(old.detail, "1,0 Ko · 3 mai · example.com");

  const missing = metaLine(dl({ totalBytes: 1024, fileMissing: true }), "fr", NOW_MS);
  assert.deepEqual(missing, {
    detail: "example.com",
    stateKey: "downloadsPanel.stateFileMissing",
    errorText: null,
    tone: "neutral",
  });
});

test("metaLine for failures carries the error text or Failed key", () => {
  const withMessage = metaLine(dl({ state: "interrupted", error: "Network lost" }), "fr", NOW_MS);
  assert.deepEqual(withMessage, {
    detail: null,
    stateKey: null,
    errorText: "Network lost",
    tone: "error",
  });

  const bare = metaLine(dl({ state: "interrupted" }), "fr", NOW_MS);
  assert.deepEqual(bare, {
    detail: null,
    stateKey: "downloadsPanel.stateFailed",
    errorText: null,
    tone: "error",
  });
});

test("inlineAction depends on state", () => {
  assert.equal(inlineAction(dl({ state: "inProgress" })), "pause");
  assert.equal(inlineAction(dl({ state: "paused" })), "resume");
  assert.equal(inlineAction(dl({ state: "interrupted" })), "retry");
  assert.equal(inlineAction(dl({ state: "complete" })), null);
});

test("canOpen requires complete, present, error-free", () => {
  assert.equal(canOpen(dl({})), true);
  assert.equal(canOpen(dl({ fileMissing: true })), false);
  assert.equal(canOpen(dl({ state: "inProgress" })), false);
  assert.equal(canOpen(dl({ error: "x" })), false);
});

test("fileIconURL keys the native icon on the lowercased extension", () => {
  assert.equal(fileIconURL(dl({ filename: "a.PDF" })), "lilo-chrome://ui/file-icon/pdf");
  assert.equal(fileIconURL(dl({ filename: "a.tar.gz" })), "lilo-chrome://ui/file-icon/gz");
  assert.equal(fileIconURL(dl({ filename: "README" })), "lilo-chrome://ui/file-icon/");
  assert.equal(fileIconURL(dl({ filename: ".env" })), "lilo-chrome://ui/file-icon/");
});
