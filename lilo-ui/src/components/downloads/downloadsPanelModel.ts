// Pure presentation logic for the downloads panel.

import type { BridgeDownloadSnapshot } from "../../lib/bridge/protocol";
import { formatEta, progress } from "../../lib/downloadFormat";
import { formatByteSize } from "../../lib/format";
import type { Locale } from "../../lib/i18n/translate";

export interface DownloadGroup {
  key: string;
  /** i18n key for Today and Yesterday; other groups carry a preformatted `label`. */
  labelKey: string | null;
  label: string;
  items: BridgeDownloadSnapshot[];
}

export interface GroupedDownloads {
  active: BridgeDownloadSnapshot[];
  history: DownloadGroup[];
}

interface MetaLine {
  detail: string | null;
  stateKey: string | null;
  errorText: string | null;
  tone: "neutral" | "error";
}

export type InlineAction = "pause" | "resume" | "retry";

// The Chrome InterruptReason codes native stores in `error`; any other error is a system message, already localized.
const ERROR_KEYS = new Map([
  ["USER_CANCELED", "downloadsPanel.errorCanceled"],
  ["SERVER_FAILED", "downloadsPanel.errorServer"],
  ["SERVER_BAD_CONTENT", "downloadsPanel.errorNotFound"],
  ["SERVER_UNAUTHORIZED", "downloadsPanel.errorUnauthorized"],
  ["SERVER_FORBIDDEN", "downloadsPanel.errorForbidden"],
  ["SERVER_NO_RANGE", "downloadsPanel.errorNoResume"],
  ["FILE_FAILED", "downloadsPanel.errorFile"],
  ["FILE_NO_SPACE", "downloadsPanel.errorNoSpace"],
  ["FILE_ACCESS_DENIED", "downloadsPanel.errorAccessDenied"],
]);

export function filterDownloads(
  downloads: BridgeDownloadSnapshot[],
  query: string,
): BridgeDownloadSnapshot[] {
  const trimmed = query.trim().toLowerCase();
  if (!trimmed) return downloads;
  return downloads.filter(
    (dl) =>
      dl.filename.toLowerCase().includes(trimmed) ||
      dl.url.toLowerCase().includes(trimmed) ||
      dl.source.toLowerCase().includes(trimmed),
  );
}

function isActive(dl: BridgeDownloadSnapshot): boolean {
  return dl.state === "inProgress" || dl.state === "paused";
}

const DAY_MS = 86400000;

interface Formatters {
  day: Intl.DateTimeFormat;
  month: Intl.DateTimeFormat;
  time: Intl.DateTimeFormat;
  date: Intl.DateTimeFormat;
}

// Every row and every progress tick formats dates: one fixed set per locale, looked up by the locale alone.
const formatterCache = new Map<string, Formatters>();

function formatters(locale: string): Formatters {
  let cached = formatterCache.get(locale);
  if (!cached) {
    cached = {
      day: new Intl.DateTimeFormat(locale, { weekday: "long", day: "numeric", month: "short" }),
      month: new Intl.DateTimeFormat(locale, { month: "long", year: "numeric" }),
      time: new Intl.DateTimeFormat(locale, { hour: "numeric", minute: "2-digit" }),
      date: new Intl.DateTimeFormat(locale, { day: "numeric", month: "short" }),
    };
    formatterCache.set(locale, cached);
  }
  return cached;
}

function startOfDay(ms: number): number {
  const date = new Date(ms);
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

// Today, Yesterday, then one group per day for the past week, then one per month.
function groupFor(startedAtSec: number, today: number, format: Formatters): Omit<DownloadGroup, "items"> {
  const dayStart = startOfDay(startedAtSec * 1000);
  const daysAgo = Math.round((today - dayStart) / DAY_MS);
  if (daysAgo <= 0) return { key: "today", labelKey: "downloadsPanel.groupToday", label: "" };
  if (daysAgo === 1) return { key: "yesterday", labelKey: "downloadsPanel.groupYesterday", label: "" };
  const date = new Date(dayStart);
  if (daysAgo < 7) {
    return {
      key: `day-${dayStart}`,
      labelKey: null,
      label: format.day.format(date),
    };
  }
  return {
    key: `month-${date.getFullYear()}-${date.getMonth()}`,
    labelKey: null,
    label: format.month.format(date),
  };
}

export function groupDownloads(
  downloads: BridgeDownloadSnapshot[],
  nowMs: number,
  locale: string,
): GroupedDownloads {
  const today = startOfDay(nowMs);
  const format = formatters(locale);
  const active: BridgeDownloadSnapshot[] = [];
  const history: DownloadGroup[] = [];
  // Input is sorted newest first, so a group's items are always contiguous.
  for (const dl of downloads) {
    if (isActive(dl)) {
      active.push(dl);
      continue;
    }
    const group = groupFor(dl.startedAt, today, format);
    const last = history[history.length - 1];
    if (last?.key === group.key) {
      last.items.push(dl);
    } else {
      history.push({ ...group, items: [dl] });
    }
  }
  return { active, history };
}

function sourceHost(url: string): string | null {
  try {
    const host = new URL(url).hostname;
    return host ? host.replace(/^www\./, "") : null;
  } catch {
    return null;
  }
}

export function metaLine(dl: BridgeDownloadSnapshot, locale: Locale, formatLocale: string, nowMs: number): MetaLine {
  if (dl.error || dl.state === "interrupted") {
    const errorKey = dl.error ? ERROR_KEYS.get(dl.error) : "downloadsPanel.stateFailed";
    return {
      detail: null,
      stateKey: errorKey ?? null,
      errorText: errorKey ? null : (dl.error ?? null),
      tone: "error",
    };
  }
  if (dl.state === "paused") {
    return {
      detail: `${Math.round(progress(dl))}% · ${formatByteSize(dl.bytesReceived, locale, true)}`,
      stateKey: "downloadsPanel.statePaused",
      errorText: null,
      tone: "neutral",
    };
  }
  if (dl.state === "inProgress") {
    const parts = [
      dl.totalBytes > 0
        ? `${formatByteSize(dl.bytesReceived, locale, true)} / ${formatByteSize(dl.totalBytes, locale, true)}`
        : formatByteSize(dl.bytesReceived, locale, true),
    ];
    if (dl.speedBytesPerSec && dl.speedBytesPerSec > 0) parts.push(`${formatByteSize(dl.speedBytesPerSec, locale, true)}/s`);
    if (dl.eta && dl.eta > 0) parts.push(formatEta(dl.eta));
    return { detail: parts.join(" · "), stateKey: null, errorText: null, tone: "neutral" };
  }
  const host = sourceHost(dl.url);
  if (dl.fileMissing) {
    return { detail: host, stateKey: "downloadsPanel.stateFileMissing", errorText: null, tone: "neutral" };
  }
  const size = dl.totalBytes > 0 ? dl.totalBytes : dl.bytesReceived;
  const finishedMs = (dl.endedAt ?? dl.startedAt) * 1000;
  // Within the past week the group header names the day, so the time is enough; older groups are months.
  const when =
    nowMs - finishedMs < 7 * DAY_MS
      ? formatters(formatLocale).time.format(finishedMs)
      : formatters(formatLocale).date.format(finishedMs);
  // Host last: it is the longest part, so truncation eats it rather than the size or time.
  const parts = [size > 0 ? formatByteSize(size, locale, true) : null, when, host].filter((part) => part !== null);
  return { detail: parts.join(" · "), stateKey: null, errorText: null, tone: "neutral" };
}

export function inlineAction(dl: BridgeDownloadSnapshot): InlineAction | null {
  if (dl.state === "inProgress") return "pause";
  if (dl.state === "paused") return "resume";
  // A blob's bytes came from the page itself: its URL would fetch the page, not the file.
  if (dl.state === "interrupted" && dl.source !== "blob") return "retry";
  return null;
}

export function canOpen(dl: BridgeDownloadSnapshot): boolean {
  return dl.state === "complete" && !dl.fileMissing && !dl.error;
}

export function fileIconURL(dl: BridgeDownloadSnapshot): string {
  const dot = dl.filename.lastIndexOf(".");
  const ext = dot > 0 ? dl.filename.slice(dot + 1).toLowerCase() : "";
  return `lilo-chrome://ui/file-icon/${encodeURIComponent(ext)}`;
}
