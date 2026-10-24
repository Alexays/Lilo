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
// The manifest names (permissions, or keys as `omnibox`) under which installGapAPIs installs a module's
// namespace, when not the module's own name.
const needs = { instanceID: ['gcm'], system: ['system.cpu', 'system.memory', 'system.storage', 'system.display'] };

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

// What a chunk's module imports from the bundle: only the names it uses, as an unused read would stay.
const chunkImports = (own) => {
  const imported = new Map();
  for (const [, names, specifier] of readFileSync(own, 'utf8').matchAll(/^import \{([^}]*)\} from '([^']+)'/gm)) {
    imported.set(path.resolve(path.dirname(own), specifier), names.split(',').map((name) => name.trim()));
  }
  return {
    name: 'gap-module-chunk',
    setup(build) {
      build.onResolve({ filter: /^\./ }, (args) => {
        const file = path.resolve(args.resolveDir, args.path);
        if (gapModuleFiles.has(file)) throw new Error(`${coreKey(own)} imports ${coreKey(file)}: gap modules must not import each other`);
        return { path: file, namespace: 'core' };
      });
      build.onLoad({ filter: /.*/, namespace: 'core' }, async (args) => {
        const runtime = new Set(await exportsOf(args.path));
        const names = (imported.get(args.path) ?? []).filter((name) => runtime.has(name));
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
    banner: { js: `(globalThis.__liloGapModules??={})[${JSON.stringify(name)}]=core=>{let gapExports;` },
    footer: { js: 'return gapExports};' },
    plugins: [chunkImports(file)],
  });
  chunks.push({ needs: needs[name] ?? [name], source: outputFiles[0].text });
}

// The bundles' gap-modules.ts: each module evaluated on first read, `{}` when the context lacks its chunk.
const lazyGapModules = {
  name: 'lazy-gap-modules',
  setup(build) {
    build.onLoad({ filter: /[/\\]shared[/\\]gap-modules\.ts$/ }, (args) => {
      if (args.path !== gapModulesFile) return undefined;
      const imports = [...coreImports].map(([file, names]) => [file, [...names].join(', ')]);
      return {
        contents: `${imports.map(([file, names]) => `import { ${names} } from ${JSON.stringify(file)};`).join('\n')}
const core = { ${imports.map(([file, names]) => `${JSON.stringify(coreKey(file))}: { ${names} }`).join(', ')} };
const factories = globalThis.__liloGapModules ?? {};
delete globalThis.__liloGapModules;
export const gapModules = {};
for (const name of ${JSON.stringify([...gapModuleFiles.values()])}) {
  Object.defineProperty(gapModules, name, {
    configurable: true,
    get() {
      const value = factories[name]?.(core) ?? {};
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
