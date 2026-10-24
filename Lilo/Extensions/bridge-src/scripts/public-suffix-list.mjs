// Writes Lilo/Extensions/public-suffix-list.dat for chrome.publicSuffix: every rule, ICANN and private as Chrome has
// both, canonicalized like a URL host (lowercase, punycode). Usage: `make public-suffix-list`.
import { writeFileSync } from 'node:fs';
import { domainToASCII } from 'node:url';

const response = await fetch('https://publicsuffix.org/list/public_suffix_list.dat');
if (!response.ok) throw new Error(`Public Suffix List download failed: ${response.status}`);
const lines = (await response.text()).split('\n');

const header = lines.filter((line) => /^\/\/ (This Source Code|License, v|file, You|VERSION:|COMMIT:)/.test(line));
const rules = [];
for (const line of lines) {
  const rule = line.trim().split(/\s/)[0];
  if (!rule || rule.startsWith('//')) continue;
  const prefix = rule.startsWith('!') ? '!' : rule.startsWith('*.') ? '*.' : '';
  const host = domainToASCII(rule.slice(prefix.length));
  if (!host) throw new Error(`Unparsable rule: ${rule}`);
  rules.push(prefix + host);
}

writeFileSync(new URL('../../public-suffix-list.dat', import.meta.url), `${[...header, ...rules].join('\n')}\n`);
console.log(`Wrote ${rules.length} rules`);
