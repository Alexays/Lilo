export interface TitleUnread {
  /** The page's unread count, 0 when it gives none. */
  count: number;
  /** Unread without a count, as Slack's leading "* " says. */
  marked: boolean;
  /** The title without the unread mark, which the badge shows instead. */
  title: string;
}

const LEADING_COUNT = /^\((\d{1,5})\+?\)\s+/;
const LEADING_MARK = /^[*!]\s+/;
// "Inbox (3) - Mail", "Chat (2)": also how a film year reads ("Film (2021) - Reviews"), so only saved tabs trust it.
const FIRST_SEGMENT_COUNT = /^(.{1,60}?)\s\((\d{1,5})\+?\)(?=\s[-|·]\s|$)/;

/** Reads the unread mark messaging apps put in their title, the one signal every such site shares. */
export function titleUnread(title: string, isSaved: boolean): TitleUnread {
  let match = LEADING_COUNT.exec(title);
  if (match) return { count: Number(match[1]), marked: false, title: title.slice(match[0].length) };
  match = LEADING_MARK.exec(title);
  if (match) return { count: 0, marked: true, title: title.slice(match[0].length) };
  if (isSaved) {
    match = FIRST_SEGMENT_COUNT.exec(title);
    if (match) return { count: Number(match[2]), marked: false, title: match[1] + title.slice(match[0].length) };
  }
  return { count: 0, marked: false, title };
}

/** A count as a badge shows it. */
export function unreadBadgeText(count: number): string {
  return count > 99 ? "99+" : String(count);
}
