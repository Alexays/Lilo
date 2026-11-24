# Plugin surface plan

Implementation plan for the app-level plugin architecture argued in [agent-plugin-research.md](agent-plugin-research.md): Lilo maintains a small agent-tooling core (tabs + page tools + consent + isolation + snapshots, serving workflows A and C), and everything orchestrator-shaped grows outward as **manifest + sidecar plugins** — JSON-RPC over stdio, any language, declarative UI, manager panel like the Extensions popover. Nothing here touches browser extensions (MV3/WKWebExtension); that surface stays as is.

## What T3 Code contributes

Studied `pingdotgg/t3code` (2026-11-23). Takeaways, mapped to this plan:

1. **The adapter boundary is the whole trick.** T3's provider docs: "Orchestration and clients read capabilities, never provider names"; "Declare only what the provider actually supports… a capability left enabled that fails at runtime is a bug"; "never emulate what you don't have". Lilo's plugin manifest adopts this verbatim: a plugin declares capabilities and the host renders/honors exactly those; an unimplemented capability is a load-time rejection, not a runtime surprise. T3's rule that first-party drivers may get dedicated adapters while everything generic follows the spec strictly also maps: Lilo core stays spec-strict; per-harness quirks live in plugins (the connectors plugin), never in the host.
2. **Contracts are the versioning unit.** T3: `packages/contracts` is "the typed wire boundary between independently versioned clients and servers". The plugin RPC gets the same treatment: one versioned JSON schema file (`bridge-schema/` already exists as Lilo's pattern for generated bridge contracts), plugins pin a `protocolVersion`, the host negotiates down.
3. **Provider packages reach the host through one interface.** T3: provider packages import only `provider-core/server/*` and reach machine capabilities "through `ProviderHost` rather than `apps/server`". The plugin RPC surface is Lilo's `ProviderHost`: plugins can call only the declared host API, never the app's internals.
4. **Folder-watched files beat a store/UI editor.** T3's Workflows (a Labs feature, off by default) are files in `~/.t3/workflows/` the server watches and hot-reloads, authored by an agent through a shipped `SKILL.md` — no registry, no in-app editor. This is the model for Lilo's plugins and the Automations plugin: a watched plugins folder, agent-authorable, agent-authored via a skill; the panel manages enable/disable and settings, not authoring.
5. **Two tiers of automation.** T3 splits "one prompt on a timer" (ScheduledTaskService) from "multi-stage durable runs" (workflows, Effect-based, resumable steps, webhook/issue triggers, human `ask` with timeout). The Automations plugin should ship both tiers, with durability delegated to coordinate (research §7): timed single actions vs multi-step runs with an approval step, both as queue jobs.
6. **MCP Apps exists as a standard.** T3 renders interactive tool-result apps per the [MCP Apps](https://github.com/modelcontextprotocol/ext-apps) standard (HTML in a sandboxed iframe, agent-emitted). Lilo's conversation surface should *accept* MCP Apps for interop (agents already emit it), while its own plugin UI capability stays the native catalog (research §5, A2UI-shaped) — accept the web standard, render natively where we own the surface.
7. **Process isolation with deadlines.** T3 runs crash-prone native capabilities "in isolated child processes or workers with deadlines". Reinforces the sidecar choice and adds a rule: every plugin RPC call gets a deadline; a plugin that misses it gets killed and shown as stopped, never wedging the host.
8. **Health probes stay passive.** T3: background status probes "must never open a session that starts MCP servers, runs hooks, or launches a login flow". The plugin host's enable/refresh path must not execute plugin code just to list it: read manifests, show badges, launch only on enable.

### WebMCP: evaluated, and the WebKit position decides it

[WebMCP](https://webmachinelearning.github.io/webmcp/) (W3C Web ML CG draft, `document.modelContext.registerTool`, plus a declarative HTML-form API) is the page-side counterpart to MCP Apps: sites expose typed tools that browser agents call instead of actuating the DOM. Chrome runs an origin trial; **WebKit's position is oppose** ([standards-positions#670](https://github.com/WebKit/standards-positions/issues/670), closed June 2026), on grounds that matter directly to Lilo: agents are assistive technology and should drive a site as a user would; a parallel agent-facing tool layer makes "an agent is driving" separately addressable (the screen-reader-blocking problem, again, for agents); the intent descriptions are unverifiable; and the cross-origin, consent and fingerprinting analysis is still TODO.

Consequences for Lilo, in order of weight:

1. **No engine-side implementation.** Lilo is built for the WebKit that ships with macOS and never builds on API only the fork has (AGENTS.md); there is no shipped-WebKit `modelContext` to build on, and WebKit's opposition means there will not be one soon. Implementing the API surface unilaterally would also put Lilo on the wrong side of its own engine's stated user model.
2. **A PageWorld consumer shim is the only defensible move, and only if sites actually adopt.** If Chrome's origin trial makes `document.modelContext.registerTool` common, a `PageWorld` polyfill (the sanctioned page-world mechanism) can host the object sites call, forward registered tools into the MCP tool surface, and map the spec's own annotations onto Lilo's consent tiers — `readOnlyHint` → read, plain → reversible-write, `consequentialHint` → commit (asked each time). The page chose to expose the tools; consuming them makes an agent *more* like assistive tech reading declared semantics, not less, which answers WebKit's core objection from Lilo's side. It stays off the roadmap until adoption is measured, not announced — and it is a core tool-surface feature, **not** a plugin: it needs no manifest, no sidecar and no capability, just the gate.
3. **Not a plugin-surface concern.** Site-provided tools enter through the same tool list as core tools with consent tiers; the plugin architecture is unaffected. The one interaction worth keeping: a plugin could later *filter or annotate* site tools per site (a Boost-like policy layer), but that is the skills/Boosts idea from harness-plan stage 7 wearing a plugin hat — same hold as there.

Verdict: watch and measure, do not build. Revisit when a Lilo-relevant site in the agent fixtures ships `modelContext` tools in practice, or when WebKit's alternative framing (agents via shared HTML/ARIA semantics) produces something concrete to align with.


```
Settings → Plugins (panel)
   │  list from two folders, enable/disable, per-plugin settings (declared), kill
   ▼
PluginHost (Swift, Lilo/App or Lilo/Plugins)
   │  scans, validates manifests, spawns/kills sidecars, routes JSON-RPC,
   │  enforces capabilities, one deadline per call
   ▼
plugin process (any language)  ◄── stdio JSON-RPC (Lilo Plugin Protocol v1)
   ▲  host→plugin: initialize, tool calls, settings changes, schedule fire
   │  plugin→host: ready, tool result, ui:surface update, store get/set, log
   ▼
Host capabilities (the only APIs a plugin can reach)
   tabs:read · tabs:open · page:read · page:act (consent-gated) · schedule ·
   settings:store (per-plugin, Keychain-backed for type=password) · ui:surface ·
   files:plugin-dir (the plugin's own support folder)
```

Placement per the [placement rule](../ARCHITECTURE.md#placement-rule): `Lilo/Plugins/` for host + manifest + RPC + panel models; UI in `lilo-ui/src/lib/plugins/` + a Settings section; tests mirror. A feature folder over ~500 lines gets subfolders (`Lilo/Plugins/Protocol`).

### Manifest (`lilo-plugin.json`, at a plugin folder's root)

```jsonc
{
  "schemaVersion": 1,
  "protocolVersion": 1,
  "id": "com.example.automations",       // reverse-DNS, unique
  "title": "Automations",
  "version": "1.2.0",
  "entry": "bin/automations",            // executable, cwd = plugin folder
  "capabilities": ["schedule", "tabs:read", "settings:store"],
  "contributes": {
    "tools": [                           // merged into the agent tool surface when enabled
      { "name": "schedule_tab_check", "description": "…",
        "inputSchema": { /* JSON Schema */ }, "consent": "reversible-write" }
    ],
    "settings": [                        // rendered by the panel; the plugin never draws UI
      { "name": "interval", "type": "dropdown", "title": "Check every",
        "options": ["15m", "1h", "1d"], "default": "1h" },
      { "name": "token", "type": "password", "title": "API token", "required": true }
    ]
  }
}
```

Validation is strict and load-time: unknown capability → rejected with the reason shown in the panel; unknown schema key → rejected; `entry` not executable → shown, plugin not started. T3's "declare only what you support" rule, enforced.

### Protocol (Lilo Plugin Protocol v1)

ndjson JSON-RPC 2.0 over the sidecar's stdio, the same framing the MCP socket and ACP already use. Handshake mirrors ACP's: host sends `initialize` (protocol version, locale, enabled capabilities actually granted); plugin replies `ready` with its tool list; only then does the host register its contributions. Calls in both directions carry an id and a deadline (default 10 s; `schedule` fires may run long and are async notifications instead). One plugin process per enabled plugin; it may exit when idle and be re-spawned on demand — the host treats a dead sidecar as "not running", never as an error.

### Capabilities and consent

- Capabilities are grant-time: enabling a plugin shows its capability list once (like extension install prompts), revocable per capability in the panel.
- `page:act` and any tool whose `consent` tier is `commit` or `irreversible` go through the existing `askConsent` choke point with the plugin's title as the client name. A plugin tool call is indistinguishable from a core tool call to the gate — no bypass exists.
- The plugin's own process activity (files, network) is its own business, exactly as for ACP agents — Lilo gates only what crosses the host API. Documented, not sandboxed.

### Manager panel (Settings → Plugins)

Mirrors the Extensions popover: rows with icon, title, version, enable toggle, capability summary; an entry per plugin rendering its contributed `settings` (the panel already has form primitives from agents-settings work); "Show in Finder" (plugins are folders), "Stop process" for a running one, and the rejection reason for an invalid manifest. Managed-policy note: a locked `disabledPluginIds` list is possible later via the same pattern T3 uses; not in v1.

Distribution is folders only in v1: `~/Library/Application Support/Lilo/Plugins/` (user) and `Plugins/` next to the app's support folder (bundled, for first-party dogfood plugins). No registry, no store, no code signing beyond macOS's own quarantine. A curated list stays a maybe (research §2.2).

## Delivery plan

One PR per row, Conventional Commits, each with `make check` in session and scope-gated `make validate` at the end. Swift tests that drive a real sidecar use a bundled stub plugin (a small compiled binary or a `#!/bin/sh` + Python-free script — the test must not require Node/Python on CI: a `sh` script speaking ndjson suffices).

| # | PR | Contents | Size |
|---|---|---|---|
| 1 | `feat(plugins): manifest model and loader` | `PluginManifest` (Codable + strict validation), folder scan of both roots, `PluginRegistry` with change detection, `PluginHost` spawn/kill/deadline over stdio JSON-RPC (handshake only), settings storage for enabled-state and grants | ~700 Swift + tests |
| 2 | `feat(plugins): manager panel` | Settings → Plugins section (list, toggle, grants sheet, per-plugin settings rendered from the manifest, rejection reasons), locale keys in all catalogs, captures for the PR | ~400 UI |
| 3 | `feat(plugins): host capabilities for tabs and settings` | `tabs:read`, `tabs:open`, `settings:store` (password → Keychain), `files:plugin-dir`; protocol schemas under `bridge-schema/` if generated, else hand-kept and parity-tested | ~300 |
| 4 | `feat(plugins): plugin tools in the agent surface` | `contributes.tools` merged into the MCP tool list with owner badge, consent tier wiring through `askConsent`, action-log attribution `plugin:<id>` | ~300 |
| 5 | `feat(plugins): connectors plugin (first dogfood)` | Move `HarnessDefinition` rows into a bundled connectors plugin (`detect` + `configure` tools over the RPC), Swift keeps only "install MCP server" for the case where the plugin is disabled. Deleting ~60 lines of core in the same PR as the plugin lands is the extraction proof | plugin + ~-40 core |
| 6 | `feat(plugins): schedule capability via coordinate` | `schedule` capability: plugin shim enqueueing coordinate jobs (`coordinate enqueue` present → durable; absent → in-sidecar timer), job fire calls back over RPC; Automations plugin: timed single actions + multi-step runs with an `ask` approval step, authored as watched files, ship an `SKILL.md` teaching agents to author them (T3's t3-workflows pattern) | ~500, mostly in the plugin |
| 7 | `feat(plugins): ui:surface` | A2UI-shaped native catalog (Text, Row/Column, Button, Input, Select, Card, Table, Chart) rendered in a plugin panel page; actions round-trip as RPC calls; Svelte implementation can lean on json-render's catalog model. Accept MCP Apps in conversations separately (its own discussion) | ~600 UI, held until 1–6 prove the surface |

### PR 6 as built

- **Fire path.** `schedule.set {id, delay}` / `schedule.cancel {id}` (plugin to host, gated by the `schedule` grant) arm a `PluginScheduler`. With `coordinate` on the PATH (or in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`; detected by file check, never by running it) the adapter enqueues `coordinate enqueue --run-at <delay>s --repo "" -- sh -c 'mkdir -p "$1" && : > "$1/$2"' ...`: the job's whole body is dropping a marker file in `Plugin Support/<id>/spool/fired`. The host watches that folder (one kqueue source, nothing while idle) and, at launch, delivers markers left while Lilo was quit. A fire is `session.start()` plus a `schedule.fire {id}` notification: no deadline, delivered at least once, so the plugin dedupes. If `enqueue` fails (a coordinate older than `--run-at`, a broken install) or coordinate is absent, the in-process timer adapter takes the job: not durable, never dropped silently.
- **Watched files.** A plugin holding `schedule` gets `files.changed` when anything under `Plugin Support/<id>/watched/` changes (FSEvents, 0.5 s coalescing) and once at launch. No polling anywhere; the Automations sidecar exits after 2 s idle.
- **Capability seam.** `PluginHost.methodHandlers` maps a plugin-to-host method to the capability that gates it. PR 3 registers `tabs.list` / `tabs.open` there; the approval prompt behind `ask` is registered later. Until then the Automations plugin gets `methodNotFound` and stops the run with `failed at step N`, never a hang.

Not planned in v1, recorded so they are decisions and not drift: a registry or store; swappable/inline UI catalogs; scheduling inside Lilo core; plugin-defined themes; per-plugin permission modes beyond the consent tiers.

## Verification

- `PluginHostTests`: handshake, deadline kill, capability rejection, idle respawn, tool routing — against the bundled stub plugin, no external runtimes.
- Panel tests in `lilo-ui`: enable/disable state, settings render per manifest types, rejection reasons.
- Consent parity test: a plugin tool with tier `commit` produces an identical gate interaction to a core tool (the no-bypass guarantee).
- The connectors PR (5) is measured like any extraction: lines of harness knowledge left in core (target: only the disabled-fallback path), and first-run still configures Claude Code end to end.
- Baseline before PR 1: last 90 days of commits tagged (B)-only vs core-tool-surface (research §4's measurement), so the surface's effect on (B) pressure is a number, not a feel.

## Open questions

0. **How much of this builds off-macOS?** (Dispatchable to a VPS.) The split, audited against current imports:

   - **AppKit-free today:** the plugin host's entire substance — manifest decoding, folder scan, stdio JSON-RPC, deadlines, capability enforcement, settings storage. `AgentMCP`, `ACPConnection`, `HarnessDefinition`, `AgentFlows` import only Foundation/os. The protocol schemas and the Automations/connectors plugin sidecars (any language, plain sh in tests) are platform-neutral by construction.
   - **macOS-bound by nature:** WebKit-dependent tool execution (`AgentTools` imports WebKit; native input, screenshots), `@MainActor` tool dispatch (Swift concurrency on Linux is usable but Lilo targets macOS 26 only — `Package.swift` has no Linux platform), and everything UI. CI cannot run Linux Swift tests for app code as the project stands.
   - **What this means for dispatch:** plan work as three lanes. (1) A `Lilo/Plugins/Protocol`-first build order — PRs 1, 3 and 6's queue logic are AppKit-free and testable on Linux *if* they live in a Swift package with `Foundation`-only deps and their tests avoid `@MainActor` (use plain actors; the host spawns processes — `Process`/`DispatchIO` are portable). This lane is VPS-dispatchable today. (2) The panel (PR 2) and `ui:surface` (PR 7) are Svelte/TS in `lilo-ui/` — UI logic, schemas and parity tests run anywhere via `make ui-lint ui-test`; only the capture steps need a Mac. This lane is also dispatchable. (3) The consent wiring and tool-surface merge (PR 4) and the connectors extraction (PR 5) touch `@MainActor`/WebKit code — those stay local (or CI macOS shards via `make ci-swift`). Practical rule when writing PR 1: keep `PluginHost` in a `// MARK: - portable` section with no `import AppKit`, enforce it with a lint/test that greps the file's imports, and the dispatchable share stays dispatchable as the code grows.

0a. **Keeping it AppKit-free by construction, not by discipline.** A grep rule guards imports; patterns can make the boundary self-enforcing and the portable part *unit-testable anywhere*, macOS or VPS. The honest constraint first: SwiftNIO-grade portability is not the goal — even "portable" Swift here still needs macOS CI to run, because Lilo builds only for macOS 26 and its tests open windows. The realistic target is **two tiers**: (a) truly dispatchable — a `LiloPluginKit` Swift package (`Foundation` only, own tests, runs on Linux CI and on a VPS via `swift test`); (b) mac-only but headless — app-target code with no AppKit/UI imports that runs under `make swift-test` off the UI path. The plan adopts (a) and keeps (b) as the default for app-target plugin code.

   Patterns, chosen to earn their keep under AGENTS.md's no-single-use-protocol rule — each boundary below gets two real implementations on day one, which is what justifies it:

   | Boundary | Pattern | Portable side (protocol) | First real adapter | Second adapter |
   |---|---|---|---|---|
   | Process transport | port | `PluginTransport` (spawn, read/write ndjson, kill, deadline) | stdio/`Process` adapter (Linux OK) | in-process stub adapter for tests — the same stub the parity tests use |
   | Scheduling | port | `PluginScheduler` (arm, cancel, fire) | coordinate enqueue adapter | in-process timer adapter (also the coordinate-absent fallback from PR 6) |
   | Secrets | port | `PluginSecretStore` (get/set/delete) | Keychain adapter (macOS) | settings-file adapter (tests, Linux) |
   | Capability targets | adapter closures, not a protocol | host passes `tabs:open`, `settings:store` … as `Sendable` closures the host resolves | real ones (WebKit, panel) | test closures capturing calls |

   What is deliberately **not** abstracted: WebKit tab execution and the consent UI. The harness plan already rejected ports/adapters for the engine ("outbound ports would have one implementation each, which AGENTS.md forbids") — that verdict stands. The plugin host touches WebKit only through the capability closures above, so WebKit never appears in the portable package.

   Shape: `LiloPluginKit` — package target `PluginCore` (manifest, registry, JSON-RPC framing, `PluginTransport` + `PluginScheduler` + `PluginSecretStore` protocols, an in-memory clock for deterministic deadline tests), plus `TestingSupport` (the stub sidecar script + stub adapters, shared by app tests and PR parity tests). The app target (`Lilo/Plugins/`) holds only the adapters (Keychain, coordinate, capability closures) and the wiring into `AgentTools`/settings — a few hundred lines, all mac-lane. This follows the existing `bridge-schema` precedent of a separate versioned contract surface, and tests in the package need no windows, so they fit the VPS dispatch lane directly (`swift test` in the package, no `LILO_LOCAL_UI_TESTS`).

   Revised PR mapping: PR 1 splits into 1a (`LiloPluginKit`: core + stub adapters, package tests — dispatchable) and 1b (app adapters + registry wiring — mac lane); PR 3's settings capability splits the same way; PR 6's scheduler port lands with 1a so the Automations plugin's queue logic is testable headlessly. Net extra cost: one Package + the closure indirection, roughly +80 lines over the monolith shape; the payoff is the portable lane is enforced by the compiler's import graph, not by grep.



1. **Generate the protocol types?** `bridge-schema/` + `make bridge-gen` exists for the extension bridge; plugin protocol schemas could ride the same generator or stay hand-written with a parity test. Decide at PR 3 by the size of the type surface.
2. **Do plugin tools appear to workflow (A) harnesses too?** They enter the same MCP tool list, so yes by default — but a plugin's tools reaching an external Claude Code session should probably require the same grant the in-app surface uses. Default: yes, same grants; revisit if a plugin wants app-only visibility.
3. **Bundled plugins ship inside the app or beside it?** Inside means code-signed and versioned with Lilo (simpler); beside means the folder is user-editable from day one. Lean inside for the connectors plugin, beside for Automations; decide at PR 5.
