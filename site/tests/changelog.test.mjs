import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { parseChangelog } from '../src/lib/changelog.mjs';

test('preserves every version in Changie’s imported release history', () => {
  const source = readFileSync(new URL('../../CHANGELOG.md', import.meta.url), 'utf8');
  const releases = parseChangelog(source);
  const versions = [...source.matchAll(/^## \[([^\]]+)\] - /gm)].map(match => match[1]);
  assert.deepEqual(releases.map(release => release.version), versions);
  assert.match(releases.at(-1).html, /First public release/);
});

test('renders a new release, Markdown and shared reference links without showing unreleased notes', () => {
  const releases = parseChangelog(`# Changelog

## [Unreleased]

- Not published yet.

## [0.9.0] - 2026-10-20

### Fixed

- Read [the docs][guide] and use \`Command K\`.

## [0.10.0] - 2026-10-24

### Added

- A **new feature**.

[guide]: https://getlilo.app/moving/
`);
  assert.deepEqual(releases.map(release => release.version), ['0.10.0', '0.9.0']);
  assert.equal(releases[0].date, '2026-10-24');
  assert.match(releases[0].html, /<strong>new feature<\/strong>/);
  assert.match(releases[1].html, /href="https:\/\/getlilo.app\/moving\/"/);
  assert.match(releases[1].html, /<code>Command K<\/code>/);
  assert.doesNotMatch(releases.map(release => release.html).join(''), /Not published yet/);
});
