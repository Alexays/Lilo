import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { runInNewContext } from "node:vm";

const source = readFileSync(
  new URL("../dist/header.js", import.meta.url),
  "utf-8"
);

const browser = (
  stored: string | null,
  systemDark = false,
  storageBlocked = false
) => {
  const dataset: Record<string, string> = {};
  const listeners = new Map<string, (event: { target: unknown }) => void>();
  let saved = stored;

  class Toggle {
    closest(selector: string) {
      return selector === ".theme-toggle" ? this : null;
    }
  }

  runInNewContext(source, {
    Element: Toggle,
    document: {
      addEventListener: (
        name: string,
        listener: (event: { target: unknown }) => void
      ) => listeners.set(name, listener),
      documentElement: { dataset },
      querySelector: () => null,
    },
    localStorage: {
      getItem: () => {
        if (storageBlocked) {
          throw new Error("Storage is unavailable");
        }

        return saved;
      },
      setItem: (_key: string, value: string) => {
        if (storageBlocked) {
          throw new Error("Storage is unavailable");
        }

        saved = value;
      },
    },
    matchMedia: () => ({ matches: systemDark }),
  });

  return {
    click: () => listeners.get("click")?.({ target: new Toggle() }),
    dataset,
    saved: () => saved,
  };
};

test("restores either saved theme before the body loads, regardless of system appearance", () => {
  assert.equal(browser("light", true).dataset.theme, "light");
  assert.equal(browser("dark").dataset.theme, "dark");
});

test("follows the system until toggled, then keeps the choice across page loads", () => {
  for (const systemDark of [false, true]) {
    const page = browser(null, systemDark);
    assert.equal(page.dataset.theme, undefined);
    page.click();
    assert.equal(page.dataset.theme, systemDark ? "light" : "dark");
    const nextPage = browser(page.saved(), !systemDark);
    assert.equal(nextPage.dataset.theme, page.dataset.theme);
    nextPage.click();
    assert.equal(nextPage.dataset.theme, systemDark ? "dark" : "light");
  }
});

test("ignores invalid saved values", () => {
  assert.equal(browser("invalid").dataset.theme, undefined);
});

test("can toggle both ways when reading and writing storage is blocked", () => {
  const page = browser(null, false, true);
  page.click();
  assert.equal(page.dataset.theme, "dark");
  page.click();
  assert.equal(page.dataset.theme, "light");
});
