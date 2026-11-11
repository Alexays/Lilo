import assert from "node:assert/strict";
import { test } from "node:test";

import { classify } from "../scripts/translations.mjs";

const report = (fr, diagnostics = []) => ({ diagnostics, translate: { locales: { fr: { missing: [], stale: [], untracked: [], ...fr } } } });

test("a missing or stale page fails", () => {
  const { errors, warnings } = classify(report({ missing: ["content/guides/a.mdx"], stale: ["content/guides/b.mdx"] }));
  assert.deepEqual(errors, ["content/guides/a.mdx → fr: missing", "content/guides/b.mdx → fr: stale"]);
  assert.deepEqual(warnings, []);
});

test("a stale folder title fails", () => {
  assert.equal(classify(report({ stale: ["content/guides/meta.ts"] })).errors.length, 1);
});

test("a translated partial fails when missing and warns when stale", () => {
  const { errors, warnings } = classify(
    report({
      missing: ["content/reference/_generated/mcp-tools.md"],
      stale: ["content/reference/_generated/web-compatibility.md"],
    })
  );
  assert.deepEqual(errors, ["content/reference/_generated/mcp-tools.md → fr: missing"]);
  assert.deepEqual(warnings, ["content/reference/_generated/web-compatibility.md → fr: stale"]);
});

test("the generator-owned partials are never Blume's to translate", () => {
  const owned = ["content/reference/_generated/shortcuts.md", "content/reference/_generated/settings.md"];
  assert.deepEqual(classify(report({ missing: owned, stale: owned })), { errors: [], warnings: [] });
});

test("an untracked translation passes", () => {
  assert.deepEqual(classify(report({ untracked: ["content/guides/a.mdx"] })), { errors: [], warnings: [] });
});

test("an error diagnostic other than drift fails", () => {
  const diagnostics = [
    { code: "BLUME_TRANSLATE_MISSING", message: "drift", severity: "error" },
    { code: "BLUME_CONFIG", message: "broken", severity: "error" },
    { code: "BLUME_META", message: "note", severity: "warning" },
  ];
  assert.deepEqual(classify(report({}, diagnostics)).errors, ["BLUME_CONFIG: broken"]);
});
