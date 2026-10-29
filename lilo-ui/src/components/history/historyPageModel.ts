import type { BridgeHistoryDayRow } from "../../lib/bridge/protocol";

/** Consecutive rows of one site in a day; a lone page is a cluster of one. */
export interface HistoryCluster {
  key: string;
  host: string;
  rows: BridgeHistoryDayRow[];
}

export interface HistoryDay {
  dayStart: number;
  /** Today and Yesterday by name; null for the others, titled by their weekday. */
  labelKey: "historyPage.periodToday" | "historyPage.periodYesterday" | null;
  weekday: string;
  /** The date under the title: no weekday when the weekday is the title, no year in the current one. */
  date: string;
  clusters: HistoryCluster[];
  pages: number;
  sites: number;
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

/** Rows arrive newest first, a day's rows contiguous. `bySite` folds a site's consecutive rows into one cluster. */
export function groupHistoryDays(rows: BridgeHistoryDayRow[], nowMs: number, locale: string, bySite: boolean): HistoryDay[] {
  const today = startOfDay(nowMs);
  const thisYear = new Date(nowMs).getFullYear();
  const days: HistoryDay[] = [];
  let hosts = new Set<string>();
  for (const row of rows) {
    let day = days[days.length - 1];
    if (day?.dayStart !== row.dayStart) {
      // Rounded: a day across a DST change is 23 or 25 hours long.
      const daysAgo = Math.round((today - row.dayStart) / DAY_MS);
      const labelKey = daysAgo === 0 ? "historyPage.periodToday" : daysAgo === 1 ? "historyPage.periodYesterday" : null;
      const year = new Date(row.dayStart).getFullYear() === thisYear ? undefined : "numeric";
      day = {
        dayStart: row.dayStart,
        labelKey,
        weekday: formatter(locale, { weekday: "long" }).format(row.dayStart),
        date: formatter(locale, { weekday: labelKey ? "long" : undefined, month: "long", day: "numeric", year }).format(row.dayStart),
        clusters: [],
        pages: 0,
        sites: 0,
      };
      days.push(day);
      hosts = new Set();
    }
    day.pages += 1;
    hosts.add(row.host);
    day.sites = hosts.size;
    const last = day.clusters[day.clusters.length - 1];
    if (bySite && last?.host === row.host) last.rows.push(row);
    else day.clusters.push({ key: rowKey(row), host: row.host, rows: [row] });
  }
  return days;
}

export function timeLabel(ms: number, locale: string): string {
  return formatter(locale, { hour: "numeric", minute: "2-digit" }).format(ms);
}

/** A cluster's span, oldest to newest visit; one time when they share the minute. */
export function timeRangeLabel(rows: BridgeHistoryDayRow[], locale: string): string {
  const newest = timeLabel(rows[0].lastVisitAt, locale);
  const oldest = timeLabel(rows[rows.length - 1].lastVisitAt, locale);
  return newest === oldest ? newest : `${oldest} - ${newest}`;
}

/** The keys from `fromKey` to `toKey`, both included, in list order; just `toKey` when `fromKey` is not listed. */
export function keysBetween(rows: BridgeHistoryDayRow[], fromKey: string, toKey: string): string[] {
  const keys = rows.map(rowKey);
  const from = keys.indexOf(fromKey);
  const to = keys.indexOf(toKey);
  if (from < 0 || to < 0) return [toKey];
  return keys.slice(Math.min(from, to), Math.max(from, to) + 1);
}
