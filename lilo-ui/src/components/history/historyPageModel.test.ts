import assert from "node:assert/strict";
import test from "node:test";

import { groupHistoryDays, keysBetween, rowKey } from "./historyPageModel";
import type { BridgeHistoryDayRow } from "../../lib/bridge/protocol";

const NOW = new Date(2026, 9, 28, 15, 0).getTime();
const day = (daysAgo: number): number => new Date(2026, 9, 28 - daysAgo).getTime();

function row(pageId: string, daysAgo: number): BridgeHistoryDayRow {
  return {
    pageId,
    url: `https://example.com/${pageId}`,
    title: pageId,
    host: "example.com",
    lastVisitAt: day(daysAgo) + 3_600_000,
    visits: 1,
    dayStart: day(daysAgo),
  };
}

test("rows group by day, today and yesterday by name, every day with its date", () => {
  const days = groupHistoryDays([row("a", 0), row("b", 0), row("a", 1), row("c", 5)], NOW, "en-US");

  assert.deepEqual(days.map((d) => d.labelKey), ["historyPage.dayToday", "historyPage.dayYesterday", null]);
  assert.deepEqual(days.map((d) => d.rows.map((r) => r.pageId)), [["a", "b"], ["a"], ["c"]]);
  assert.equal(days[0].date, "Wednesday, October 28, 2026");
  assert.equal(days[2].date, "Friday, October 23, 2026");
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
