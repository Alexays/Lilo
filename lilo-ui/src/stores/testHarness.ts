// Shared SSR harness for store tests: one Vite dev server per test file (node:test runs
// each file in its own process), with a fresh store module graph per test.
import { after } from "node:test";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
	createServer,
	createServerModuleRunner,
	type ViteDevServer,
} from "vite";
import type { ModuleRunner } from "vite/module-runner";

const configFile = resolve(dirname(fileURLToPath(import.meta.url)), "../../vite.config.ts");

export interface PostedMessage {
	action: string;
	payload: Record<string, unknown>;
}

/**
 * Installs the minimal WKWebView bridge window and returns the messages stores post to it.
 * Call before freshStores so the re-executed bridge module binds to the fresh stub.
 */
export function stubBridgeWindow(options: { document?: boolean } = {}): PostedMessage[] {
	const posted: PostedMessage[] = [];
	(globalThis as { window?: unknown }).window = {
		__liloBootstrapEvents: [],
		addEventListener() {},
		removeEventListener() {},
		webkit: {
			messageHandlers: {
				lilo: {
					postMessage(message: PostedMessage) {
						posted.push(message);
					},
				},
			},
		},
	};
	if (options.document) {
		(globalThis as { document?: unknown }).document = {
			addEventListener() {},
			removeEventListener() {},
			visibilityState: "visible",
			hidden: false,
		};
	}
	return posted;
}

let serverPromise: Promise<ViteDevServer> | null = null;
let currentRunner: ModuleRunner | null = null;

after(async () => {
	await currentRunner?.close();
	if (serverPromise) await (await serverPromise).close();
});

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- test modules are untyped, like ssrLoadModule's own return
type StoreModule = Record<string, any>;

/**
 * Each call evaluates modules in a fresh module runner, so every test gets fresh module state while modules loaded
 * through the same returned loader share one instance graph.
 */
export async function freshStores(): Promise<(path: string) => Promise<StoreModule>> {
	serverPromise ??= createServer({
		configFile,
		logLevel: "silent",
		server: { middlewareMode: true },
	});
	const server = await serverPromise;
	await currentRunner?.close();
	currentRunner = createServerModuleRunner(server.environments.ssr, { hmr: false });
	const runner = currentRunner;
	return (path) => runner.import(path);
}
