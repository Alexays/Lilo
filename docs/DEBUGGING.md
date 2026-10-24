# Debugging

How to inspect, diagnose, and get logs out of a development build of Lilo. Everything below assumes a debug build (`make install-debug` or `make app`). Lilo's own Web Inspector works on page content in every build, and on the chrome overlay in debug builds; Safari's Develop menu sees them, and extension contexts, in debug builds only.

## 1. Inspecting the chrome overlay

The browser UI (sidebar, command bar, panels) is a Svelte app in a transparent WKWebView. To open Web Inspector on it in a debug build, use **Develop > Open Chrome Devtools**, or pick the Lilo chrome web view in Safari under Develop > your Mac.

The overlay is served over the app-private `lilo-chrome://` scheme (`lilo-chrome://ui/index.html`). Under `make run-ui-dev` it is served from the Vite dev server at `http://localhost:5173` instead, so URLs in the inspector will differ between the two modes.

## 2. Inspecting page content and extension contexts

Any page tab can be inspected from Lilo's own **Develop** menu (**Show Web Inspector**, `Cmd+Opt+I`; **Inspect Element**; **Show Console**), which **Settings > Advanced** can hide. In debug builds, content web views also have `isInspectable` enabled for Safari's Develop menu, and extension contexts (background service workers, popups) are marked inspectable too: they show up in the Develop menu named after the extension (for example "uBlock Origin - Background").

## 3. Diagnostics panel

**Help > Diagnostics** opens an in-app panel with three tabs:

- **Startup**: startup metrics (boot, chrome ready, latest marks and traces)
- **Memory**: tab lifecycle states (loaded web views, sleeping and restoring tabs, saved page states), with **Run trim** to apply the automatic sleep policy now
- **Log**: extension diagnostics, the lifecycle and API logs of extension workers, popups, the bridge and DNR

The copy button in the header (**Copy report**) copies the startup metrics and tab lifecycle states, and **Copy extension logs** in the Log tab the extension diagnostics, ready to paste into a bug report.

**Develop > Process Manager** lists every WebKit process (WebContent, network, GPU, ...) with its memory and CPU use and the tabs it serves.

## 4. Hitbox debug overlay

**Develop > Show Hitbox Debug Overlay** (debug builds) visualizes the interactive zones the chrome overlay registers with the native event router. Use it when clicks land on the wrong layer (page instead of UI, or vice versa). The setting persists in `UserDefaults` across launches; select the menu item again to turn it off.

## 5. Design System panel

**Develop > Design System** (debug builds) opens a panel showing the UI tokens and components. Use it when working on `lilo-ui/` styling.

## 6. Logs

Lilo logs through `os_log` under the subsystem `fr.arouillard.lilo`.

```bash
make logs                       # dump the last 15 minutes to ./lilo-log.txt
make logs SINCE=1h OUT=/tmp/lilo.txt
make logs-stream                # follow the log live
```

The `logs` target passes `--info --debug` to `log show` because os_log info and debug messages are memory-only: without those flags they are silently absent from the output.

A debug build keeps its data apart from the installed app's: bundle id `fr.arouillard.lilo.debug`, data in `~/Library/Application Support/Lilo-Debug`, preferences in `~/Library/Preferences/fr.arouillard.lilo.debug.plist` (see [CONTRIBUTING.md](../CONTRIBUTING.md#dev-data)). Its logs share the `fr.arouillard.lilo` subsystem.

Release builds ship with `trace` logging off; `defaults write ~/Library/Preferences/fr.arouillard.lilo.plist LiloTracingEnabled -bool true` re-enables it (debug builds always trace).

### Debug switches

The `defaults` commands below name the preferences file rather than the `fr.arouillard.lilo` domain: when a `~/Library/Containers/fr.arouillard.lilo` folder is left over from a sandboxed build, the domain form writes into that container, which the unsandboxed app never reads.

| Switch | Effect |
|--------|--------|
| `LILO_APP_SUPPORT_DIR=<path>` (environment) | Store the database, sessions, extensions and the agent socket under `<path>` instead of `~/Library/Application Support/Lilo` (`Lilo-Debug` in a debug build); handy for a throwaway profile. Keep it short: the socket path must fit in 104 bytes. `lilo-mcp` run with the same variable connects there and never opens the app |

## 7. UI hot reload

```bash
make ui-dev        # terminal 1: Vite dev server on localhost:5173
make run-ui-dev    # terminal 2: build and launch the app against it
```

`run-ui-dev` sets `LILO_UI_DEV_SERVER` so the chrome web view loads from the dev server, giving hot module reload on every edit under `lilo-ui/src/`. It still builds the full app bundle first: `swift run` lacks Info.plist and bundle resources, and the app needs the embedded UI assets to compile even when they are overridden at runtime.

## 8. Extension debugging

Load `test-extensions/extension-probe/` with **Develop > Load Unpacked Extension...**; it exercises the MV3 surface (messaging channels, DNR, tabGroups, content-script worlds, gap events). Combined with inspectable extension contexts (section 2) this covers most extension-side debugging.

WebKit keeps only the first argument of a `console.error`, and no stack, in an extension's errors. Debug builds record each error whole, with its stack, in the extension's diagnostics (Diagnostics panel), from its pages and its worker; `make ext-smoke` prints them under each failing extension.

## 9. Measuring energy

`make energy-sample` samples the running Lilo once a second for `DURATION` seconds (default 120) and writes `OUT/LABEL.summary.tsv` (default `~/lilo-energy/run.summary.tsv`): average and peak CPU, idle wakeups and energy impact per process role (app, WebContent, networking, GPU, power helper, terminal shells, git, other children). By default it runs `powermetrics` under `sudo`, grouped by the `fr.arouillard.lilo` coalition; `SUDO=0` falls back to `top` over the processes alive at start, which misses short-lived ones such as git and counts every `com.apple.WebKit.*` process (quit Safari and Mail first). `GIT=1` also counts the git processes Lilo spawns, through `eslogger`: it needs `sudo` and Full Disk Access for the terminal.

To compare two builds, build the "before" app from its commit outside the checkout, as `scripts/bench_startup.sh --variant` expects, then run the same workload under each app:

```bash
git worktree add /tmp/lilo-before <commit>
make -C /tmp/lilo-before vt-build ui-build ext-bridge-build
xcodebuild -project /tmp/lilo-before/Lilo.xcodeproj -scheme Lilo -configuration Release -destination 'platform=macOS' \
    -derivedDataPath /tmp/lilo-before/.derived CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
open /tmp/lilo-before/.derived/Build/Products/Release/Lilo.app && make energy-sample LABEL=before
# quit it, launch the current build, then:
make energy-sample LABEL=after
make energy-compare            # BEFORE=before AFTER=after
git worktree remove --force /tmp/lilo-before
```

To see which events cause the wakeups, the `energy` signpost category (`PerfSignposts.energy`) marks git runs, FSEvents callbacks, terminal snapshots and git refreshes, bridge sends that ship or are skipped, session and Spotlight writes, filter splices, location starts and stops, and worker wakes. Signposts cost nothing until a tool records them. Stream them live, or count them by name over a run:

```bash
/usr/bin/log stream --signpost --predicate 'subsystem == "fr.arouillard.lilo" AND category == "energy"'
/usr/bin/log show --signpost --style ndjson --last 5m --predicate 'subsystem == "fr.arouillard.lilo" AND category == "energy"' \
    | jq -r 'select(.eventType == "signpostEvent" and .signpostType != "end") | .signpostName' | sort | uniq -c
```

The full path matters in zsh, whose `log` builtin shadows the tool. `--signpost` adds signposts to the regular log lines rather than replacing them, and the output ends with a `{"count": ...}` summary, hence the `eventType` filter. Each signpost line carries `signpostName`, `signpostType` (`event`, `begin` or `end`) and `eventMessage`; interval messages such as `saveSnapshots`' "2 saved" are on the `end` line. Add `AND processIdentifier == <pid>` to the predicate to leave out another Lilo running at the same time.

`make e2e-energy` turns this into an idle check: it builds the Release app like `make startup-bench`, launches it against a throwaway profile (`CFFIXED_USER_HOME` and `LILO_APP_SUPPORT_DIR` in a temporary directory) with `TABS` restored local pages (default 3), opens a terminal tab and hides it behind the first page, waits for its one snapshot save, then stays idle for `IDLE` seconds (default 45). It prints the energy signposts of that window and fails on any `git` run, `workerWake`, or `saveSnapshots` that saved something. The terminal is opened with System Events keystrokes, which needs Accessibility access for the terminal running `make`; `TERMINAL=0` skips it. It takes about three minutes and is not part of `make e2e`.

In Instruments, add the os_signpost instrument filtered on that subsystem to see the events and intervals on a timeline next to CPU and energy (Points of Interest only shows the `PointsOfInterest` category).

## 10. Common failure modes

| Symptom | Fix |
|---------|-----|
| `xcodebuild` fails with `cannot find 'ChromeUIAssets'` or `'NativeStrings'` in scope | The git-ignored generated sources are missing: run `make ui-build` (or `make app`, which includes it) |
| Chrome UI shows old changes | The embedded UI bundle is stale: run `make ui-build` before rebuilding the app |
| Blank chrome UI under `make run-ui-dev` | The Vite dev server is not running: start `make ui-dev` first |
| `xcodebuild` fails after adding a Swift file | The Xcode project is out of sync with the file system: run `make project-sync` |
| Build stops with `make vt-build requires Zig 0.16.x` | Install Zig 0.16 (`brew install zig`): every app build compiles libghostty-vt once per pinned Ghostty commit |
| Keychain (or camera and microphone) prompt on every rebuild or test run | Debug builds and the test host (`fr.arouillard.lilo.tests`) are ad-hoc signed by default; set `LILO_DEBUG_TEAM_ID` in a git-ignored `Makefile.local` (see `Makefile.local.example`) |
