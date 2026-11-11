// The French translation gate, run by `make docs-check`. Wraps `blume translate --check --json`:
// a missing or stale French page or folder title fails, and so does a French file the ledger does
// not record (copied by hand, or its entry deleted), which Blume would never call stale. A
// translated reference partial fails when missing and only warns when stale, since its sources
// (COMPATIBILITY.md, the agent tool definitions) are edited by app contributors who may have no
// agent CLI. The shortcut and settings partials get their French from the app's catalog, so they are
// never Blume's to translate. `--prune` removes those two from the ledger after `blume translate`
// adopted them.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const LEDGER = `${root}blume.translations.json`;
const GENERATED = "content/reference/_generated/";
export const GENERATOR_OWNED = new Set([`${GENERATED}shortcuts.md`, `${GENERATED}settings.md`]);
const DRIFT_CODES = new Set(["BLUME_TRANSLATE_MISSING", "BLUME_TRANSLATE_STALE"]);

/** The ledger parsed from its text (undefined when absent). Blume reads a missing or broken ledger as empty and passes. */
export function readLedger(text) {
  if (text === undefined) throw new Error("blume.translations.json is missing");
  let ledger;
  try {
    ledger = JSON.parse(text);
  } catch (error) {
    throw new Error(`blume.translations.json does not parse: ${error.message}`);
  }
  if (Object.keys(ledger?.files ?? {}).length === 0) throw new Error("blume.translations.json tracks no file");
  return ledger;
}

/** Splits a `blume translate --check --json` report into the errors that fail the gate and warnings. */
export function classify(report) {
  const errors = [];
  const warnings = [];
  for (const diagnostic of report.diagnostics ?? []) {
    if (diagnostic.severity === "error" && !DRIFT_CODES.has(diagnostic.code)) {
      errors.push(`${diagnostic.code}: ${diagnostic.message}`);
    }
  }
  for (const [locale, { missing = [], stale = [], untracked = [] }] of Object.entries(report.translate?.locales ?? {})) {
    for (const [status, sources] of [
      ["missing", missing],
      ["stale", stale],
      ["untracked", untracked],
    ]) {
      for (const source of sources) {
        if (GENERATOR_OWNED.has(source)) {
          continue;
        }
        const line = `${source} → ${locale}: ${status}`;
        if (status === "stale" && source.startsWith(GENERATED)) {
          warnings.push(line);
        } else {
          errors.push(line);
        }
      }
    }
  }
  return { errors, warnings };
}

/** A warning line; in GitHub Actions an annotation, so it shows on the run and not only in the log. */
export const warningLine = (line, env = process.env) =>
  `${env.GITHUB_ACTIONS ? "::warning::" : "warning: "}${line} (refresh it with make docs-translate)`;

function readLedgerFile() {
  let text;
  try {
    text = readFileSync(LEDGER, "utf-8");
  } catch {
    text = undefined;
  }
  try {
    return readLedger(text);
  } catch (error) {
    console.error(`French translation gate: ${error.message}. Restore it from git: only make docs-translate writes it.`);
    process.exit(1);
  }
}

function check() {
  readLedgerFile();
  let stdout;
  try {
    stdout = execFileSync("blume", ["translate", "--check", "--json"], {
      cwd: root,
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch (error) {
    // Exit 1 is how Blume reports drift; the JSON on stdout says which.
    stdout = error.stdout;
  }
  let report;
  try {
    report = JSON.parse(stdout);
  } catch {
    console.error("blume translate --check printed no report; run it in docs-site/ to see why");
    process.exit(1);
  }
  const { errors, warnings } = classify(report);
  for (const line of warnings) {
    console.warn(warningLine(line));
  }
  if (errors.length > 0) {
    console.error(`French translations out of date:\n  ${errors.join("\n  ")}`);
    console.error("Run make docs-translate (needs Claude Code), review the diff and commit it with the change.");
    process.exit(1);
  }
  console.log(`French translations up to date (${report.translate?.upToDate ?? 0} files)`);
}

function prune() {
  const ledger = readLedgerFile();
  for (const source of GENERATOR_OWNED) {
    delete ledger.files[source];
  }
  writeFileSync(LEDGER, `${JSON.stringify(ledger, null, 2)}\n`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (process.argv.includes("--prune")) {
    prune();
  } else {
    check();
  }
}
