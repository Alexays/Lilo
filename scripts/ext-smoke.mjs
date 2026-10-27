// Usage: node scripts/ext-smoke.mjs [--top 100] [--ids a,b] [--shards 6]. Exits non-zero on a regression.
// Each shard takes every shards-th extension so slow ones spread evenly; past six, shards only load the machine.
import { spawn, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';

const root = join(import.meta.dirname, '..');
const { values: options } = parseArgs({ options: { top: { type: 'string', default: '100' }, ids: { type: 'string', default: '' }, shards: { type: 'string', default: '6' } } });
const { extensions: list, extra = [] } = JSON.parse(readFileSync(join(root, 'LiloTests/Extensions/top-extensions.json'), 'utf8'));
const only = options.ids ? new Set(options.ids.split(',')) : null;
// The extra extensions, outside the most used, run every time.
const selected = only ? [...list, ...extra].filter(({ id }) => only.has(id)) : [...list.slice(0, Number(options.top)), ...extra];
const shardCount = Math.max(1, Math.min(Number(options.shards), selected.length));
const out = join(root, '.derived.noindex/ext-smoke');
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

// Signed and identified as make's test targets do (Makefile, TEST): the test host is its own app.
const team = process.env.LILO_DEBUG_TEAM_ID || process.env.LILO_TEAM_ID;
const signing = team ? [`DEVELOPMENT_TEAM=${team}`, `CODE_SIGN_IDENTITY=${process.env.LILO_DEBUG_CODE_SIGN_IDENTITY || 'Apple Development'}`, 'CODE_SIGN_STYLE=Manual'] : [];
const xcodebuild = ['-project', 'Lilo.xcodeproj', '-scheme', 'Lilo', '-configuration', 'Debug', '-destination', 'platform=macOS',
  '-derivedDataPath', join(root, '.derived.noindex/xcode'),
  'LILO_BUNDLE_ID_SUFFIX=.tests', ...signing];
const start = Date.now();
const build = spawnSync('xcodebuild', ['build-for-testing', ...xcodebuild, '-quiet'], { cwd: root, stdio: 'inherit' });
if (build.status !== 0) process.exit(build.status ?? 1);
const built = Date.now();

const shards = await Promise.all(Array.from({ length: shardCount }, (_, shard) => new Promise((resolve) => {
  const ids = selected.filter((_, index) => index % shardCount === shard).map(({ id }) => id);
  const report = join(out, `shard-${shard}.jsonl`);
  // The MV3 probe and the feature checks run once, beside the first share.
  const tests = ['-only-testing:LiloTests/RealExtensionSmokeTests/testStoreExtensionsInstallStartAndShowTheirPopup',
    ...shard === 0 ? ['-only-testing:LiloTests/RealExtensionSmokeTests/testProbeReportsEveryDeclaredNamespaceComplete',
      '-only-testing:LiloTests/RealExtensionSmokeTests/testStoreExtensionFeaturesWorkOnALocalPage'] : []];
  const log = join(out, `shard-${shard}.log`);
  // An isolated data folder keeps the extensions off the native hosts installed on this Mac and their
  // downloads out of ~/Downloads. In the temporary folder, as the agent socket inside it must fit a socket path.
  const support = mkdtempSync(join(tmpdir(), 'lilo-smoke-'));
  mkdirSync(join(support, 'Downloads'));
  const child = spawn('xcodebuild', ['test-without-building', ...xcodebuild, ...tests, '-resultBundlePath', join(out, `shard-${shard}.xcresult`)], {
    cwd: root,
    env: { ...process.env, TEST_RUNNER_LILO_EXTENSIONS_NOT_INSPECTABLE: '1', TEST_RUNNER_LILO_SMOKE_IDS: ids.join(','), TEST_RUNNER_LILO_SMOKE_REPORT: report, TEST_RUNNER_LILO_APP_SUPPORT_DIR: support },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const output = [];
  child.stdout.on('data', (chunk) => output.push(chunk));
  child.stderr.on('data', (chunk) => output.push(chunk));
  child.on('close', (status) => {
    rmSync(support, { recursive: true, force: true });
    writeFileSync(log, Buffer.concat(output));
    let results = [];
    try { results = readFileSync(report, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line)); } catch { /* none written */ }
    console.log(`shard ${shard}: ${results.length}/${ids.length} extensions in ${Math.round((Date.now() - built) / 1000)} s, xcodebuild ${status}`);
    resolve({ shard, ids, results, status, log });
  });
})));

const byId = new Map(shards.flatMap(({ results }) => results.map((result) => [result.id, result])));
const results = selected.map(({ id }) => byId.get(id)).filter(Boolean);
const failed = results.filter(({ problems }) => problems.length);
const newFailures = failed.filter(({ known, intermittent }) => !known && !intermittent);
const staleKnown = results.filter(({ problems, known }) => known && !problems.length);
const intermittent = results.filter(({ intermittent }) => intermittent);
const missing = shards.flatMap(({ ids, shard, log }) => ids.filter((id) => !byId.has(id)).map((id) => `${id} (shard ${shard} did not report it: ${log})`));
const staleChrome = results.filter(({ staleChrome }) => staleChrome);
// XCTest fails a run on exactly the regressions above, so a failed run without one failed elsewhere (the probe, a crash).
const failedRuns = shards.filter(({ status, results }) => status !== 0 && !results.some((r) => newFailures.includes(r) || staleKnown.includes(r)));
const knownFailing = failed.filter(({ known }) => known);
const line = ({ id, name, version, problems, details = [] }, suffix = '') => [
  `  ${id} ${name} ${version}${problems.length ? `: ${problems.join('; ').replace(/\s*\n\s*/g, ' ')}` : ''}${suffix}`,
  ...problems.length ? details.map((detail) => `      | ${detail.replace(/\s*\n\s*/g, ' ')}`) : [],
].join('\n');
const minutes = (ms) => `${(ms / 60000).toFixed(1)} min`;
// Each check RealExtensionSmokeTests runs, by the problems it reports.
const checks = [
  ['install', /^install|^does not load/], ['worker', /service worker|worker never connects|^degraded|worker does not start again/],
  ['popup', /^the popup/], ['popup after a worker restart', /^once its worker restarts/], ['options page', /^the options page/],
  ['test page', /^the test page/], ['context menus', /context menu items|context menus show/], ['errors', /^error: /],
];
const failing = checks.map(([check, pattern]) => [check, failed.filter(({ problems }) => problems.some((problem) => pattern.test(problem)))])
  .filter(([, entries]) => entries.length);
const steps = ['worker', 'popup', 'options', 'restart', 'restartPopup'].map((step) => {
  const times = results.map(({ timings }) => timings?.[step]).filter((ms) => ms !== undefined).sort((a, b) => a - b);
  return times.length ? `${step} ${times[Math.floor(times.length / 2)]} ms (${times.length})` : null;
}).filter(Boolean);
// A section only when it lists something.
const section = (title, lines) => (lines.length ? [`\n${title} (${lines.length}):`, ...lines] : []);
const report = [
  `ext-smoke ${new Date().toISOString()}: ${selected.length} extensions, ${shardCount} shards, build ${minutes(built - start)}, tests ${minutes(Date.now() - built)}`,
  `ok ${results.length - failed.length}, fail ${failed.length} (known ${knownFailing.length}, intermittent ${failed.filter(({ intermittent }) => intermittent).length}, new ${newFailures.length}), not run ${missing.length}`,
  ...failing.length ? [`failing checks: ${failing.map(([check, entries]) => `${check} ${entries.length}`).join(', ')}`] : [],
  ...steps.length ? [`median times: ${steps.join(', ')}`] : [],
  ...failedRuns.map(({ shard, status, log }) => `shard ${shard} failed outside the extensions (xcodebuild ${status}, MV3 probe, feature checks or crash): ${log}`),
  ...section('new failures', newFailures.map((result) => line(result))),
  ...section('known failures that now run cleanly, to drop from knownFailures', staleKnown.map((result) => line(result, ` (${result.known})`))),
  ...section('not run', missing.map((entry) => `  ${entry}`)),
  ...section('stale Chrome references', staleChrome.map(({ id, name, version, staleChrome: recorded }) => `  ${id} ${name}: recorded ${recorded}, installed ${version}`)),
  ...staleChrome.length ? [`  make chrome-smoke IDS=${staleChrome.map(({ id }) => id).join(',')}`] : [],
  ...section('slow, reported only', results.filter(({ slow }) => slow?.length).map(({ id, name, slow }) => `  ${id} ${name}: ${slow.join(', ')}`)),
  ...section('intermittent', intermittent.map((result) => line(result, result.problems.length ? '' : ': ok'))),
  ...section('known failures', knownFailing.map((result) => line(result, ` (${result.known})`))),
].join('\n');
writeFileSync(join(out, 'report.txt'), `${report}\n`);
console.log(`\n${report}\n\nreport: ${join(out, 'report.txt')}`);
process.exit(newFailures.length || staleKnown.length || missing.length || failedRuns.length ? 1 : 0);
