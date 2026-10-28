import assert from "node:assert/strict";
import test from "node:test";

import { dayPart, effectiveSpaceColor, lightForDayPart, msUntilNextDayPart } from "./spaceColor";

const base = "#5865f2";

test("the day splits at 6, 11, 17 and 21", () => {
  assert.deepEqual(
    [0, 5, 6, 10, 11, 16, 17, 20, 21, 23].map(dayPart),
    ["night", "night", "morning", "morning", "day", "day", "evening", "evening", "night", "night"],
  );
});

test("the next change of day part is the next start hour, tomorrow morning after 21", () => {
  assert.equal(msUntilNextDayPart(new Date(2026, 0, 15, 16, 30)), 30 * 60 * 1000);
  assert.equal(msUntilNextDayPart(new Date(2026, 0, 15, 22, 0)), 8 * 3600 * 1000);
  assert.equal(msUntilNextDayPart(new Date(2026, 0, 15, 3, 0)), 3 * 3600 * 1000);
});

test("the next day-part boundary accounts for a clock change", () => {
  const now = new Date(2026, 9, 25, 3, 0);
  const morning = new Date(2026, 9, 25, 6, 0);
  const clockChange = (morning.getTimezoneOffset() - now.getTimezoneOffset()) * 60 * 1000;
  assert.equal(msUntilNextDayPart(now), 3 * 3600 * 1000 + clockChange);
});

test("a fixed Space keeps its color whatever the context", () => {
  assert.equal(effectiveSpaceColor("fixed", base, { dayPart: "night", pageColor: "#ff0000", wallpaperColor: "#00ff00" }), base);
  assert.equal(effectiveSpaceColor(undefined, base, { dayPart: "night" }), base);
});

test("the time of day lights the base color, midday leaves it as is", () => {
  assert.equal(effectiveSpaceColor("time", base, { dayPart: "day" }), base);
  assert.equal(effectiveSpaceColor("time", base, { dayPart: "evening" }), lightForDayPart(base, "evening"));
  assert.notEqual(lightForDayPart(base, "evening"), base);
  assert.notEqual(lightForDayPart(base, "night"), lightForDayPart(base, "morning"));
});

test("a chromatic favicon gives its color, a grey one leaves the base", () => {
  assert.equal(effectiveSpaceColor("page", base, { dayPart: "day", pageColor: "#e5484d" }), "#e5484d");
  assert.equal(effectiveSpaceColor("page", base, { dayPart: "day", pageColor: "#333333" }), base);
  assert.equal(effectiveSpaceColor("page", base, { dayPart: "day" }), base);
});

test("the wallpaper color replaces the base, which stands in when it is unknown", () => {
  assert.equal(effectiveSpaceColor("wallpaper", base, { dayPart: "day", wallpaperColor: "#7cc4c0" }), "#7cc4c0");
  assert.equal(effectiveSpaceColor("wallpaper", base, { dayPart: "day", wallpaperColor: "" }), base);
});
