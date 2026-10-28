import assert from "node:assert/strict";
import test from "node:test";

import { groupHistoryDays, keysBetween, rowKey, timeRangeLabel } from "./historyPageModel";
import type { BridgeHistoryDayRow } from "../../lib/bridge/protocol";

const NOW = new Date(2026, 9, 28, 15, 0).getTime();
const day = (daysAgo: number): number => new Date(2026, 9, 28 - daysAgo).getTime();

function row(pageId: string, daysAgo: number, host = "example.com", minutes = 60): BridgeHistoryDayRow {
  return {
    pageId,
    url: `https://${host}/${pageId}`,
    title: pageId,
    host,
    lastVisitAt: day(daysAgo) + minutes * 60_000,
    visits: 1,
    dayStart: day(daysAgo),
  };
}

test("days are titled Today, Yesterday or their weekday, dated without the current year", () => {
  const days = groupHistoryDays([row("a", 0), row("b", 1), row("c", 5), row("d", 400)], NOW, "en-US", true);

  assert.deepEqual(days.map((d) => d.labelKey), ["historyPage.periodToday", "historyPage.periodYesterday", null, null]);
  assert.deepEqual(days.map((d) => d.date), ["Wednesday, October 28", "Tuesday, October 27", "October 23", "September 23, 2025"]);
  assert.equal(days[2].weekday, "Friday");
});

test("a site's consecutive pages fold into one cluster, the day counting its pages and sites", () => {
  const rows = [row("a", 0, "example.com"), row("b", 0, "example.com"), row("c", 0, "example.org"), row("d", 0, "example.com")];

  const [today] = groupHistoryDays(rows, NOW, "en-US", true);

  assert.deepEqual(today.clusters.map((c) => [c.host, c.rows.length]), [["example.com", 2], ["example.org", 1], ["example.com", 1]]);
  assert.equal(today.pages, 4);
  assert.equal(today.sites, 2);
  assert.equal(groupHistoryDays(rows, NOW, "en-US", false)[0].clusters.length, 4, "a flat list keeps a cluster per page");
});

test("a cluster's time range runs oldest to newest, one time when they share the minute", () => {
  assert.equal(timeRangeLabel([row("a", 0, "example.com", 90), row("b", 0, "example.com", 75)], "en-US"), "1:15 AM - 1:30 AM");
  assert.equal(timeRangeLabel([row("a", 0)], "en-US"), "1:00 AM");
});

test("a page on two days has a key per day", () => {
  assert.notEqual(rowKey(row("a", 0)), rowKey(row("a", 1)));
});

test("keysBetween spans both ways and falls back to the clicked row", () => {
  const rows = [row("a", 0), row("b", 0), row("c", 1), row("d", 2)];
  const keys = rows.map(rowKey);

  assert.deepEqual(keysBetween(rows, keys[1], keys[3]), keys.slice(1, 4));
  assert.deepEqual(keysBetween(rows, keys[3], keys[0]), keys);
  assert.deepEqual(keysBetween(rows, "gone", keys[2]), [keys[2]]);
});
