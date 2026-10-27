import assert from "node:assert/strict";
import test from "node:test";

import { titleUnread, unreadBadgeText } from "./titleUnread";

test("a leading count is read on every tab and leaves the title", () => {
  assert.deepEqual(titleUnread("(3) Team Chat", false), { count: 3, marked: false, title: "Team Chat" });
  assert.deepEqual(titleUnread("(99+) Feed", false), { count: 99, marked: false, title: "Feed" });
});

test("a leading mark is unread without a count", () => {
  assert.deepEqual(titleUnread("* general - Acme - Chat", false), { count: 0, marked: true, title: "general - Acme - Chat" });
  assert.deepEqual(titleUnread("! general - Acme - Chat", true), { count: 0, marked: true, title: "general - Acme - Chat" });
});

test("a count after the first words is trusted only on saved tabs", () => {
  assert.deepEqual(titleUnread("Inbox (12) - me@example.com - Mail", true), { count: 12, marked: false, title: "Inbox - me@example.com - Mail" });
  assert.deepEqual(titleUnread("Chat (2)", true), { count: 2, marked: false, title: "Chat" });
  assert.equal(titleUnread("Film (2021) - Reviews", false).count, 0);
});

test("titles without a mark are left alone", () => {
  for (const title of ["Docs", "general (Channel) - Acme", "Report (draft) - Docs", "(3)", "*bold* notes", ""]) {
    assert.deepEqual(titleUnread(title, true), { count: 0, marked: false, title });
  }
});

test("a badge caps its count", () => {
  assert.equal(unreadBadgeText(7), "7");
  assert.equal(unreadBadgeText(120), "99+");
});
