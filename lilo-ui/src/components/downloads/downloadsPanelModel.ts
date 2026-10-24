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

const formatterCache = new Map<string, Intl.DateTimeFormat>();

function formatter(locale: string, options: Intl.DateTimeFormatOptions): Intl.DateTimeFormat {
  const key = `${locale}|${JSON.stringify(options)}`;
  let format = formatterCache.get(key);
  if (!format) {
    format = new Intl.DateTimeFormat(locale, options);
    formatterCache.set(key, format);
  }
  return format;
}

function startOfDay(ms: number): number {
  const date = new Date(ms);
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

// Today, Yesterday, then one group per day for the past week, then one per month.
function groupFor(startedAtSec: number, nowMs: number, locale: string): Omit<DownloadGroup, "items"> {
  const dayStart = startOfDay(startedAtSec * 1000);
  const daysAgo = Math.round((startOfDay(nowMs) - dayStart) / DAY_MS);
  if (daysAgo <= 0) return { key: "today", labelKey: "downloadsPanel.groupToday", label: "" };
  if (daysAgo === 1) return { key: "yesterday", labelKey: "downloadsPanel.groupYesterday", label: "" };
  const date = new Date(dayStart);
  if (daysAgo < 7) {
    return {
      key: `day-${dayStart}`,
      labelKey: null,
      label: formatter(locale, { weekday: "long", day: "numeric", month: "short" }).format(date),
    };
  }
  return {
    key: `month-${date.getFullYear()}-${date.getMonth()}`,
    labelKey: null,
    label: formatter(locale, { month: "long", year: "numeric" }).format(date),
  };
}

export function groupDownloads(
  downloads: BridgeDownloadSnapshot[],
  nowMs: number,
  locale: string,
): GroupedDownloads {
  const active: BridgeDownloadSnapshot[] = [];
  const history: DownloadGroup[] = [];
  // Input is sorted newest first, so a group's items are always contiguous.
  for (const dl of downloads) {
    if (isActive(dl)) {
      active.push(dl);
      continue;
    }
    const group = groupFor(dl.startedAt, nowMs, locale);
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

export function metaLine(dl: BridgeDownloadSnapshot, locale: Locale, nowMs: number): MetaLine {
  if (dl.error || dl.state === "interrupted") {
    return {
      detail: null,
      stateKey: dl.error ? null : "downloadsPanel.stateFailed",
      errorText: dl.error ?? null,
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
      ? formatter(locale, { hour: "numeric", minute: "2-digit" }).format(finishedMs)
      : formatter(locale, { day: "numeric", month: "short" }).format(finishedMs);
  // Host last: it is the longest part, so truncation eats it rather than the size or time.
  const parts = [size > 0 ? formatByteSize(size, locale, true) : null, when, host].filter((part) => part !== null);
  return { detail: parts.join(" · "), stateKey: null, errorText: null, tone: "neutral" };
}

export function inlineAction(dl: BridgeDownloadSnapshot): InlineAction | null {
  if (dl.state === "inProgress") return "pause";
  if (dl.state === "paused") return "resume";
  if (dl.state === "interrupted") return "retry";
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
