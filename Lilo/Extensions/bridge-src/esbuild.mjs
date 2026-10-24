import * as esbuild from 'esbuild';
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const common = {
  bundle: true,
  platform: 'browser',
  target: 'safari27',
  minify: true,
  sourcemap: false,
};

// Each module src/shared/gap-modules.ts lists is a chunk: a function under globalThis.__liloGapModules, which the
// bundles' gap-modules.ts calls on the module's first read, handing it the bundle's modules it imports (`core`).
const src = path.resolve('src');
const gapModulesFile = path.join(src, 'shared/gap-modules.ts');
const gapModuleFiles = new Map(
  [...readFileSync(gapModulesFile, 'utf8').matchAll(/from '\.\.\/augmentation\/(\w+)\.ts'/g)]
    .map(([, name]) => [path.join(src, 'augmentation', `${name}.ts`), name]),
);
// The manifest names (permissions, or keys as `omnibox`) under which a module's namespace exists, when not the
// module's own name.
const needs = {
  declarativeNetRequest: ['declarativeNetRequest', 'declarativeNetRequestWithHostAccess', 'declarativeNetRequestFeedback'],
  instanceID: ['gcm'],
  system: ['system.cpu', 'system.memory', 'system.storage', 'system.display'],
};

// Chrome's constants for a gap module's namespaces go in its chunk, the others in the bundles. The chunk hands them
// over on its own, as WebKit may give the namespace while the module stays unread.
const constantsFile = path.join(src, 'shared/chrome-constants.gen.ts');
const allConstants = JSON.parse(readFileSync(constantsFile, 'utf8').match(/= (\{[\s\S]*\});\n$/)[1]);
const gapNames = new Set(gapModuleFiles.values());
const constantsOf = (owner) => Object.fromEntries(Object.entries(allConstants).filter(([namespace]) => owner(namespace.split('.')[0])));

// The files the bundles hold without any gap module: a chunk takes these from the bundle, and holds any other it imports.
const { metafile: coreMetafile } = await esbuild.build({
  ...common,
  write: false,
  metafile: true,
  entryPoints: ['src/augmentation-entry.ts', 'src/background-entry.ts'],
  outdir: 'unused',
  plugins: [{
    name: 'no-gap-modules',
    setup(build) {
      build.onLoad({ filter: /[/\\]shared[/\\]gap-modules\.ts$/ }, () => ({ contents: 'export const gapModules = {};', loader: 'js' }));
    },
  }],
});
const coreFiles = new Set(Object.keys(coreMetafile.inputs).map((input) => path.resolve(input)));

const coreKey = (file) => path.relative(src, file).replace(/\.ts$/, '');
// The names the chunks import from each bundle module, by file.
const coreImports = new Map();
const exportNames = new Map();

async function exportsOf(file) {
  if (!exportNames.has(file)) {
    const { metafile } = await esbuild.build({ entryPoints: [file], write: false, metafile: true, format: 'esm' });
    exportNames.set(file, Object.values(metafile.outputs)[0].exports);
  }
  return exportNames.get(file);
}

// What a chunk's files import from the bundle: only the names they use, as an unused read would stay.
const chunkImports = (own) => {
  const imported = new Map();
  const visited = new Set();
  const visit = (file) => {
    visited.add(file);
    for (const [, names, specifier] of readFileSync(file, 'utf8').matchAll(/^import \{([^}]*)\} from '([^']+)'/gm)) {
      const target = path.resolve(path.dirname(file), specifier);
      if (coreFiles.has(target)) imported.set(target, new Set([...imported.get(target) ?? [], ...names.split(',').map((name) => name.trim())]));
      else if (!visited.has(target) && !gapModuleFiles.has(target)) visit(target);
    }
  };
  visit(own);
  return {
    name: 'gap-module-chunk',
    setup(build) {
      build.onResolve({ filter: /^\./ }, (args) => {
        const file = path.resolve(args.resolveDir, args.path);
        if (gapModuleFiles.has(file) && file !== own) throw new Error(`${coreKey(own)} imports ${coreKey(file)}: gap modules must not import each other`);
        return coreFiles.has(file) ? { path: file, namespace: 'core' } : undefined;
      });
      build.onLoad({ filter: /.*/, namespace: 'core' }, async (args) => {
        const runtime = new Set(await exportsOf(args.path));
        const names = [...imported.get(args.path) ?? []].filter((name) => runtime.has(name));
        coreImports.set(args.path, new Set([...coreImports.get(args.path) ?? [], ...names]));
        return { contents: `export const { ${names.join(', ')} } = core[${JSON.stringify(coreKey(args.path))}];`, loader: 'js' };
      });
    },
  };
};

const chunks = [];
for (const [file, name] of gapModuleFiles) {
  const names = (await exportsOf(file)).join(', ');
  const { outputFiles } = await esbuild.build({
    ...common,
    write: false,
    stdin: { contents: `import { ${names} } from ${JSON.stringify(file)};\ngapExports = { ${names} };`, resolveDir: src, loader: 'js' },
    format: 'iife',
    banner: { js: `(globalThis.__liloGapModules??={})[${JSON.stringify(name)}]={constants:${JSON.stringify(constantsOf((namespace) => namespace === name))},load:core=>{let gapExports;` },
    footer: { js: 'return gapExports}};' },
    plugins: [chunkImports(file)],
  });
  chunks.push({ needs: needs[name] ?? [name], source: outputFiles[0].text });
}

// The bundles' gap-modules.ts: each module evaluated on first read, `{}` when the context lacks its chunk. The
// bundles' constants are those of no gap module, to which each chunk present adds its own.
const lazyGapModules = {
  name: 'lazy-gap-modules',
  setup(build) {
    build.onLoad({ filter: /[/\\]shared[/\\]chrome-constants\.gen\.ts$/ }, (args) => (args.path === constantsFile
      ? { contents: `export const CHROME_CONSTANTS = ${JSON.stringify(constantsOf((namespace) => !gapNames.has(namespace)))};`, loader: 'js' }
      : undefined));
    build.onLoad({ filter: /[/\\]shared[/\\]gap-modules\.ts$/ }, (args) => {
      if (args.path !== gapModulesFile) return undefined;
      // Sorted: esbuild loads the core modules concurrently, so their insertion order varies between builds.
      const imports = [...coreImports].sort(([a], [b]) => (a < b ? -1 : 1)).map(([file, names]) => [file, [...names].sort().join(', ')]);
      return {
        contents: `${imports.map(([file, names]) => `import { ${names} } from ${JSON.stringify(file)};`).join('\n')}
import { CHROME_CONSTANTS } from ${JSON.stringify(constantsFile)};
const core = { ${imports.map(([file, names]) => `${JSON.stringify(coreKey(file))}: { ${names} }`).join(', ')} };
const factories = globalThis.__liloGapModules ?? {};
delete globalThis.__liloGapModules;
export const gapModules = {};
for (const name of ${JSON.stringify([...gapModuleFiles.values()])}) {
  Object.assign(CHROME_CONSTANTS, factories[name]?.constants);
  Object.defineProperty(gapModules, name, {
    configurable: true,
    get() {
      const value = factories[name]?.load(core) ?? {};
      Object.defineProperty(gapModules, name, { value });
      return value;
    },
  });
}`,
        loader: 'js',
        resolveDir: path.dirname(gapModulesFile),
      };
    });
  },
};

// Every gap module goes into the page bundle, whose pages each evaluate only those they use. A worker's prelude
// takes from ChromeAPIGapModules.json only the chunks its manifest may need (ExtensionBackgroundPreparer).
const page = await esbuild.build({
  ...common,
  write: false,
  entryPoints: ['src/augmentation-entry.ts'],
  format: 'iife',
  plugins: [lazyGapModules],
});
writeFileSync('../ChromeAPIAugmentation.js', chunks.map((chunk) => chunk.source).join('') + page.outputFiles[0].text);

await esbuild.build({
  ...common,
  entryPoints: ['src/background-entry.ts'],
  outfile: '../ChromeAPIBackgroundPrelude.js',
  format: 'iife',
  plugins: [lazyGapModules],
});
writeFileSync('../ChromeAPIGapModules.json', `${JSON.stringify(chunks, null, 1)}\n`);

// Store shim for REGULAR tabs (the Chrome Web Store is a normal https tab, not an extension page,
// so it never receives the augmentation bundle). Self-guards on the store hostname.
await esbuild.build({
  ...common,
  entryPoints: ['src/webstore-entry.ts'],
  outfile: '../ChromeWebStoreShim.js',
  format: 'iife',
  globalName: 'LiloWebStoreShim',
});

// Compat shim for extension CONTENT SCRIPTS (isolated world). Prepended to each extension's
// content_scripts via manifest patching so it runs before the vendor scripts.
await esbuild.build({
  ...common,
  entryPoints: ['src/content-compat-entry.ts'],
  outfile: '../ChromeContentCompat.js',
  format: 'iife',
  globalName: 'LiloContentCompat',
});

await esbuild.build({
  ...common,
  entryPoints: ['src/static-rules-entry.ts'],
  outfile: '../ChromeStaticRules.js',
  format: 'iife',
  globalName: 'LiloStaticRules',
});

console.log('✓ Built ChromeAPIAugmentation.js for extension page contexts');
console.log('✓ Built ChromeAPIBackgroundPrelude.js and ChromeAPIGapModules.json for extension background contexts');
console.log('✓ Built ChromeWebStoreShim.js for regular tab contexts');
console.log('✓ Built ChromeContentCompat.js for extension content-script contexts');
console.log('✓ Built ChromeStaticRules.js for static declarativeNetRequest rulesets');
