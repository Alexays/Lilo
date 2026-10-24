import * as esbuild from 'esbuild';

const common = {
  bundle: true,
  platform: 'browser',
  target: 'safari27',
  minify: true,
  sourcemap: false,
};

await esbuild.build({
  ...common,
  entryPoints: ['src/augmentation-entry.ts'],
  outfile: '../ChromeAPIAugmentation.js',
  format: 'iife',
  globalName: 'LiloAugmentation',
});

await esbuild.build({
  ...common,
  entryPoints: ['src/background-entry.ts'],
  outfile: '../ChromeAPIBackgroundPrelude.js',
  format: 'iife',
  globalName: 'LiloBackgroundPrelude',
});

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
console.log('✓ Built ChromeAPIBackgroundPrelude.js for extension background contexts');
console.log('✓ Built ChromeWebStoreShim.js for regular tab contexts');
console.log('✓ Built ChromeContentCompat.js for extension content-script contexts');
console.log('✓ Built ChromeStaticRules.js for static declarativeNetRequest rulesets');
