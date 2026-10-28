import { defineConfig, type Plugin } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";
import { releaseNotesPlugin } from "./releaseNotesPlugin";

function cspPlugin(): Plugin {
	return {
		name: "inject-csp",
		enforce: "post",
		generateBundle(_, bundle) {
			const htmlKey = Object.keys(bundle).find((k) => k.endsWith(".html"));
			if (!htmlKey) return;
			const htmlAsset = bundle[htmlKey];
			if (htmlAsset.type !== "asset") return;

			// Strict CSP for the privileged chrome web view, served over lilo-chrome://
			// (ChromeUISchemeHandler). 'self' covers the entry script, lazy chunks and the
			// stylesheet; style-src keeps 'unsafe-inline' for style attributes (pager pane
			// opacity/blur); img-src adds 'self' for the native file icons the scheme serves;
			// img-src/font-src allow data: for inline assets and future @font-face; connect-src 'self' covers Vite's modulepreload polyfill fetches.
			// Build-only (`generateBundle` never runs in `vite dev`), so HMR is unaffected.
			const csp =
				"default-src 'none'; " +
				"script-src 'self'; " +
				"style-src 'self' 'unsafe-inline'; " +
				"img-src 'self' data: blob:; " +
				"font-src data:; " +
				"connect-src 'self'; " +
				"base-uri 'none'; " +
				"form-action 'none'";
			htmlAsset.source = (htmlAsset.source as string).replace(
				/<head>/,
				`<head>\n    <meta http-equiv="Content-Security-Policy" content="${csp}" />`,
			);
		},
	};
}

// The catalogs' `native` namespace holds AppKit strings, compiled into Swift by
// generate_native_strings.py; the web UI never reads it, so it stays out of the bundle.
function stripNativeStringsPlugin(): Plugin {
	return {
		name: "strip-native-strings",
		enforce: "pre",
		transform(code, id) {
			if (!/\/i18n\/locales\/[a-z]+\.json$/.test(id)) return null;
			const catalog = JSON.parse(code);
			delete catalog.native;
			return { code: JSON.stringify(catalog), map: null };
		},
	};
}

export default defineConfig({
	plugins: [
		// Scoped class names repeat thousands of times across the CSS and templates, so a
		// one-letter prefix instead of the default "svelte-" trims the embedded bundle.
		svelte({
			compilerOptions: {
				cssHash: ({ filename, css, hash }) => `s${hash(filename ?? css)}`,
				discloseVersion: false,
			},
		}),
		cspPlugin(),
		stripNativeStringsPlugin(),
		releaseNotesPlugin(),
	],
	build: {
		outDir: "../build/chrome-ui",
		emptyOutDir: true,
		// The bundle only ever runs in the app's WKWebView on macOS 27+ (Safari 27
		// engine), so target it exactly and skip legacy transpilation/polyfills.
		target: "safari27",
		minify: "terser",
		cssMinify: "lightningcss",
		terserOptions: {
			compress: {
				passes: 3,
				drop_console: true,
				drop_debugger: true,
			},
			mangle: true,
		},
		assetsInlineLimit: 0,
		// public/ holds images the app bundle ships as resources (project.yml); the embed is text only.
		copyPublicDir: false,
		// WebKit supports <link rel="modulepreload"> natively.
		modulePreload: { polyfill: false },
		rollupOptions: {
			output: {
				entryFileNames: "index.js",
			},
		},
	},
	base: "./",
});
