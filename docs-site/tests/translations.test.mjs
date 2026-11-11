import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { classify, readLedger, warningLine } from "../scripts/translations.mjs";

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

test("a French file the ledger does not record fails, except the generator-owned partials", () => {
  const owned = ["content/reference/_generated/shortcuts.md", "content/reference/_generated/settings.md"];
  const { errors } = classify(report({ untracked: ["content/guides/a.mdx", ...owned] }));
  assert.equal(errors.length, 1);
  // make docs-translate would adopt the file as it is: the remedy is to delete it or restore its entry.
  assert.match(errors[0], /^content\/guides\/a\.mdx → fr: untracked \(delete the French file .+ or restore its ledger entry from git\)$/u);
});

test("a ledger that is missing, does not parse or tracks nothing fails", () => {
  assert.throws(() => readLedger(undefined), /blume\.translations\.json is missing/u);
  assert.throws(() => readLedger("{"), /blume\.translations\.json does not parse/u);
  assert.throws(() => readLedger('{"files": {}}'), /blume\.translations\.json tracks no file/u);
  assert.equal(Object.keys(readLedger('{"files": {"content/index.mdx": {"fr": "0"}}}').files).length, 1);
});

test("a stale partial warning is a GitHub annotation in Actions", () => {
  assert.equal(warningLine("x → fr: stale", {}), "warning: x → fr: stale (refresh it with make docs-translate)");
  assert.equal(warningLine("x → fr: stale", { GITHUB_ACTIONS: "true" }), "::warning::x → fr: stale (refresh it with make docs-translate)");
});

test("an error diagnostic other than drift fails", () => {
  const diagnostics = [
    { code: "BLUME_TRANSLATE_MISSING", message: "drift", severity: "error" },
    { code: "BLUME_CONFIG", message: "broken", severity: "error" },
    { code: "BLUME_META", message: "note", severity: "warning" },
  ];
  assert.deepEqual(classify(report({}, diagnostics)).errors, ["BLUME_CONFIG: broken"]);
});

test("make docs-translate checks the ledger before blume translate can read a broken one as empty", () => {
  const { scripts } = JSON.parse(readFileSync(fileURLToPath(new URL("../package.json", import.meta.url)), "utf-8"));
  assert.match(scripts.translate, /^node scripts\/translations\.mjs --ledger && .*blume translate /u);
  // zsh, which some contributors' npm runs scripts with, has a read-only `status`.
  assert.doesNotMatch(scripts.translate, /\bstatus=/u);
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "docs-ledger-")));
  mkdirSync(join(dir, "scripts"));
  copyFileSync(fileURLToPath(new URL("../scripts/translations.mjs", import.meta.url)), join(dir, "scripts/translations.mjs"));
  const run = () => spawnSync(process.execPath, [join(dir, "scripts/translations.mjs"), "--ledger"], { encoding: "utf-8" });
  assert.match(run().stderr, /is missing/u);
  writeFileSync(join(dir, "blume.translations.json"), "{");
  assert.equal(run().status, 1);
  assert.match(run().stderr, /does not parse/u);
  writeFileSync(join(dir, "blume.translations.json"), '{"files": {"content/index.mdx": {"fr": "0"}}}');
  assert.equal(run().status, 0);
  rmSync(dir, { recursive: true });
});
