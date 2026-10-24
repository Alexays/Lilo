import { readFileSync, writeFileSync } from 'node:fs';

const check = process.argv.includes('--check');
const read = (file) => readFileSync(file, 'utf8');
const { version } = JSON.parse(read('package.json'));
if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error(`Invalid app version: ${version}`);

function update(file, content) {
  if (read(file) === content) return;
  if (check) throw new Error(`${file} is out of sync with package.json; run make changeset-version`);
  writeFileSync(file, content);
}

const configPath = 'Xcode/Configs/Base.xcconfig';
let config = read(configPath);
const marketingVersion = config.match(/^MARKETING_VERSION = (\S+)$/m)?.[1];
const build = config.match(/^CURRENT_PROJECT_VERSION = (\d+)$/m)?.[1];
if (!marketingVersion || !build) throw new Error(`Missing app version or build number in ${configPath}`);
if (marketingVersion !== version) {
  config = config.replace(/^MARKETING_VERSION = \S+$/m, `MARKETING_VERSION = ${version}`)
    .replace(/^CURRENT_PROJECT_VERSION = \d+$/m, `CURRENT_PROJECT_VERSION = ${Number(build) + 1}`);
}
update(configPath, config);

for (const directory of ['.', 'lilo-ui', 'Lilo/Extensions/bridge-src']) {
  for (const name of ['package.json', 'package-lock.json']) {
    const file = `${directory}/${name}`;
    const data = JSON.parse(read(file));
    data.version = version;
    if (name === 'package-lock.json') data.packages[''].version = version;
    update(file, `${JSON.stringify(data, null, 2)}\n`);
  }
}
