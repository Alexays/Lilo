import type { BridgeHistoryDayRow } from "../../lib/bridge/protocol";

export interface HistoryDay {
  dayStart: number;
  labelKey: "historyPage.dayToday" | "historyPage.dayYesterday" | null;
  /** The full date, for every day: the label keys prefix it. */
  date: string;
  rows: BridgeHistoryDayRow[];
}

const DAY_MS = 86_400_000;
const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(locale: string, options: Intl.DateTimeFormatOptions): Intl.DateTimeFormat {
  const key = `${locale}|${JSON.stringify(options)}`;
  let cached = formatters.get(key);
  if (!cached) {
    cached = new Intl.DateTimeFormat(locale, options);
    formatters.set(key, cached);
  }
  return cached;
}

function startOfDay(ms: number): number {
  const date = new Date(ms);
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}

/** Selection key: a row is one page on one day. */
export function rowKey(row: BridgeHistoryDayRow): string {
  return `${row.pageId}:${row.dayStart}`;
}

/** Rows arrive newest first, a day's rows contiguous. */
export function groupHistoryDays(rows: BridgeHistoryDayRow[], nowMs: number, locale: string): HistoryDay[] {
  const today = startOfDay(nowMs);
  const days: HistoryDay[] = [];
  for (const row of rows) {
    const last = days[days.length - 1];
    if (last?.dayStart === row.dayStart) {
      last.rows.push(row);
      continue;
    }
    // Rounded: a day across a DST change is 23 or 25 hours long.
    const daysAgo = Math.round((today - row.dayStart) / DAY_MS);
    days.push({
      dayStart: row.dayStart,
      labelKey: daysAgo === 0 ? "historyPage.dayToday" : daysAgo === 1 ? "historyPage.dayYesterday" : null,
      date: formatter(locale, { weekday: "long", month: "long", day: "numeric", year: "numeric" }).format(row.dayStart),
      rows: [row],
    });
  }
  return days;
}

export function timeLabel(ms: number, locale: string): string {
  return formatter(locale, { hour: "numeric", minute: "2-digit" }).format(ms);
}

/** The keys from `fromKey` to `toKey`, both included, in list order; just `toKey` when `fromKey` is not listed. */
export function keysBetween(rows: BridgeHistoryDayRow[], fromKey: string, toKey: string): string[] {
  const keys = rows.map(rowKey);
  const from = keys.indexOf(fromKey);
  const to = keys.indexOf(toKey);
  if (from < 0 || to < 0) return [toKey];
  return keys.slice(Math.min(from, to), Math.max(from, to) + 1);
}
