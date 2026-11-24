# Browser MCP benchmark

Compares browser MCP servers driven by Claude Code on the public
[BU Bench V2.1](https://github.com/browser-use/benchmark) tasks: Lilo (`lilo-mcp`),
Playwright MCP and Chrome DevTools MCP. Everything runs through the `claude` CLI in print
mode with your existing login, so it uses your Claude subscription: no API key.

## Setup

```sh
git clone --branch v2.1.1 --depth 1 https://github.com/browser-use/benchmark ~/src/browser-use-benchmark
python3 -m pip install cryptography   # decrypts the task file, the only dependency
```

The harness reads two files from that checkout and runs none of its code: `BU_Bench_V2.enc`
(the 200 tasks and rubrics, decrypted in memory with the key derivation the benchmark
publishes) and the judge system prompt in `findings_judge.py` (parsed, not imported). The
v2.1.1 dataset has SHA-256 `0c014b056192e261b06f04ed6da6dcf37f2135150cf58c87ea839bd4e150e5c3`;
every result line records the checksum it ran with.

The benchmark asks that decrypted tasks and rubrics are never published, so this directory
holds only task IDs. Transcripts, final answers, deliverables and judge findings contain task
text: they go to `work/`, which git ignores. Do not commit it.

## Run

```sh
python3 -I bench/mcp/run.py run --tool lilo --bench ~/src/browser-use-benchmark --limit 10
python3 -I bench/mcp/run.py run --tool playwright --bench ~/src/browser-use-benchmark --passes 3
python3 -I bench/mcp/run.py summary bench/mcp/results/*.jsonl
```

- `--tool` picks `servers/<tool>.json`. Each config names its server `browser`, so every tool
  gets the same prompt, the same tool prefix (`mcp__browser__`) and the same allow rule.
- Lilo must be running with Settings > AI agents > "Allow AI agents to control Lilo" on, and
  Claude Code already allowed (Lilo asks the first time it connects, and nobody answers
  during a run). `LILO_MCP` overrides the bridge path
  (default `/Applications/Lilo.app/Contents/MacOS/lilo-mcp`; `make install` puts the app in
  `~/Applications` instead, so point it there). A bridge reaches only the app of
  its own build: to bench a Debug build, set `LILO_MCP` to that build's
  `Lilo.app/Contents/MacOS/lilo-mcp`, which talks to the Debug app's socket under
  `~/Library/Application Support/Lilo-Debug`.
- Results are appended to `results/<tool>.jsonl`; a rerun skips the task passes already there,
  so an interrupted run resumes.
- The run stops at the first task whose browser server did not connect.

## What a task run is

1. `tasks.txt` lists 100 task IDs drawn once from the 200 (`random.Random(0).sample`), in the
   order every tool runs them. `--limit N` takes the first N. Passes run the whole list in turn.
2. The agent: `claude -p` with the benchmark's executor pre-prompt (minus its BrowserCode
   lines), `--model sonnet` by default for every tool, only the browser MCP server
   (`--strict-mcp-config`), the file tools (`Read,Write,Edit,Glob,Grep`) to save deliverables
   in its `outputs/` folder, and no `Bash`, `WebFetch` or `WebSearch`: the browser is its only
   way to the web. No settings, hooks, CLAUDE.md or skills are loaded (`--setting-sources ""`,
   `--disable-slash-commands`),
   MCP tool search is off (`ENABLE_TOOL_SEARCH=false`) so every tool schema counts in the
   tokens, and the task stops at `--timeout` seconds (default 1200) or `--max-turns` (200).
   A timed-out run is still judged on its partial work, as the benchmark does.
3. The judge: a second `claude -p` with no tools, `--model opus --effort high` by default, the
   benchmark's findings system prompt verbatim, the same input sections as its judge (task,
   rubric, numbered trajectory, final answer, text deliverables, with the same clipping) and a
   JSON schema pinning one finding per rubric item. A reply that misses or repeats an item is
   retried once, then left unscored. The score is computed in code, like the benchmark: the
   weight of the `met` items over 100, zero when reward hacking is flagged or the rubric
   canary shows up in the agent's output.

Each JSONL line records the judge score and full-success verdict, wall time, turns, tool calls
per tool and tool errors (with samples), input tokens (uncached + cache reads + cache writes),
cache reads, output tokens, the CLI's list-price cost for the agent and the judge, timeout,
errors, the resolved model names, the CLI version and the 1-minute load average at the start.
The final answer, transcript, deliverables and findings stay in the task's `work/` folder.
`summary` prints, per tool, the mean score with a bootstrap 95% CI (10,000 resamples, seed 0),
full successes, median tokens, wall time and tool calls, and the summed cost.

## Fixture tasks

`fixtures.py` runs 22 small tasks on local pages, each built around one thing browser agents get
wrong: a phone field that reformats as it is typed, buttons in shadow roots, a form in a frame, a list
whose rows are rebuilt every 700 ms, content that shows up late, a slow submit with no progress
(clicking twice fails), a `div` combobox, infinite scroll, instructions hidden in the page, a
`confirm()` dialog, a link that opens a new tab, a hover-only menu, a `contenteditable` editor, a date
input and a paginated table. Three `gate-*` tasks check the approval gate: an icon-only
purchase button in another language and a login must stop for the user's allow (the agent answers
`asked`), and a harmless "Save order" must not.

A page reports what the agent did to the fixture server, and code grades the run from those reports and
the agent's final answer: no judge model, no dataset to download, nothing to keep out of git. A run
costs only the agent's tokens, about a minute per task, so it can run on every change to `Lilo/Agent`.

```sh
make agent-eval                      # every task with Lilo's Debug build (make app first), Sonnet
make agent-eval TOOL=playwright      # the same tasks with Playwright MCP, to compare
make agent-eval TASK=stale-list MODEL=haiku PASSES=3
python3 -I bench/mcp/fixtures.py summary bench/mcp/results/fixtures-*.jsonl
python3 -I bench/mcp/fixtures.py serve   # print one URL per task, to open the pages yourself
```

- Each run gets its own path on the server (`/<run>/<task>/`), so cookies or storage a page left in
  Lilo's agents profile and reports from an earlier run never count for the next one.
- Only the `gate-checkout-icon`, `gate-login` and `flow-gate-pay` tasks (marked `asks`) trigger Lilo's question before consequential actions. A Debug build answers it by itself: `LILO_AGENT_CLICKS=allow` (the default of `make agent-app`, `CLICKS=allow`) says yes to every question, so the other tasks never wait, `deny` says no at once, which the click reports as the `needs_user` of a user who declined, and `expire` lets the question lapse at once, reported as unanswered; both without the 45 s wait. `make agent-eval` runs the `asks` tasks against an app started with `CLICKS=deny` and the rest against one started with `allow`, restarting the app it started between the two (`make agent-app-restart CLICKS=deny`; quit a Debug app started by hand first) and stopping it at the end. Only a Debug build reads the variable.
- `make agent-eval-test` (part of `make validate`) checks the server and that every task's grading
  passes a correct run and fails an empty or doubled one, without a browser or a model.
- Results go to `results/fixtures-<tool>.jsonl` with the same timing, token and tool call fields as
  the BU Bench runs; transcripts go to `work/`.

## Headless runs

The owner's Mac is also the machine the fixtures run on, so a run must not take the keyboard, the mouse or a
Space. `make agent-app`, and so `make agent-eval` and `make agent-call`, start the Debug app headless
(`LILO_HEADLESS=1`); `HEADLESS=0` opts out and shows the window as before. Only a Debug build reads the
variable.

What headless changes (`Lilo/App/LiloApplication.swift`, `AppDelegate.swift`, `LiloWindow`): the app runs as an
accessory app (no Dock icon, no menu bar), `NSApp.activate` is a no-op, and its windows are transparent
(alpha 0), clickless, hidden from Mission Control and never key or main. Everything the agent does goes
through the web views, which stay in those windows, so no tool needed more.

Measured on a Mac with another app frontmost, the frontmost app read every 100 ms (`NSWorkspace`) and the
debug app's windows listed by the window server (`CGWindowListCopyWindowInfo`):

| What | Takes focus? | Evidence |
| --- | --- | --- |
| Launch, `HEADLESS=0` (default of the app) | Yes, by construction | Not measured live: it would take the owner's focus. `AppDelegate.applicationDidFinishLaunching` sets the policy to regular, `makeKeyAndOrderFront` and `NSApp.activate(ignoringOtherApps: true)` |
| Launch, `make agent-app` (headless) | No | Policy `accessory` (`lsappinfo`: `UIElement`), not active, frontmost app unchanged, windows at alpha 0 |
| Agent opens tabs and windows | No | The new-tab fixture passes headless; agent tabs live in the Agents space or in an off-screen parking window at (-20000, 20156), alpha 0. `tabRequestsForeground` already ignores agent tabs |
| Native clicks, drag, keys, scroll | No | `AgentInput` hands `NSEvent`s straight to the `WKWebView` (`mouseDown`, `keyDown`), never through window routing. 15 of 16 fixtures pass with a non-key window, among them contenteditable, custom-combobox, hover-menu and date-input |
| `make agent-eval`, 16 fixtures | No | One frontmost app for the whole run (about 3.5 minutes), 15 of 16 pass (stale-list failed on the agent's behavior: two `done` reports) |
| `make swift-test` | No | `PageWorldTests` and `AgentInputTests` ran with the frontmost app unchanged; the test host runs `.prohibited` under XCTest (`AppDelegate.main`) |
| `make e2e` | No, by configuration | Playwright's `chrome-headless-shell`, not the app; not measured live because that browser was not installed on the measuring Mac |

Native events need a window, not a key window. `AgentInput` reads `webView.window` for the window number of
every event and for the screen point of a scroll, so a web view in no window gets no native scroll; agent tabs
of a space no window shows are therefore parked in an off-screen window. A headless window is not key, so
`document.hasFocus()` reads false there (measured; `visibilityState` stays `visible`): a page that gates on
it behaves as in a background tab, and no fixture does. Tools that only run script, read the page or
screenshot never need a window, and a plain Swift script driving an off-screen `WKWebView` checked the
fixtures' pages with their solutions in JavaScript (no native events), which is the fallback when no app is
wanted at all.

What stays outside headless: a system sheet or an alert the app itself raises (a keychain prompt, a file open
panel, the first notification permission) is modal and takes focus whatever the policy; the Little window,
Picture in Picture panels and extension popups set their own levels and are not hidden; `HEADLESS=0` is the
way to watch a run. The visible Chromium of `TOOL=playwright` and the Chrome of `TOOL=chrome-devtools`
(`--isolated` is headed) are other tools' windows, left alone.

Options weighed and not taken: `LSUIElement` in `Info.plist` is the accessory policy fixed at build time, so it
would reach Release builds; `.prohibited` (what the test host uses) cannot show a window, and the agent needs a
commander window; `launchctl asuser` only re-enters the same user's session, and a second login session needs a
second account with fast user switching; a virtual display hides the window but not the focus, which is per
session, not per display.

## Not comparable with the published leaderboard

These scores compare tools within our runs only. They are not comparable with Browser Use's
published V2.1 results, because:

- the judge is Claude, not their GPT judge, and sees no screenshots: their harness captures
  one after every browser action through CDP, which no MCP server here exposes uniformly. The
  judge is told so and grades from tool results instead;
- the executor is Claude Code with a browser MCP server, not BrowserCode with a CDP shell;
  deliverables are text files (no shell to build `.xlsx` or `.pdf`);
- the default timeout is 20 minutes, not 60, and tasks run one at a time on a local machine.

## Fairness notes

- Lilo runs headless in its Debug build (see Headless runs; `HEADLESS=0` shows its window); Playwright MCP and Chrome DevTools MCP run headed with a
  fresh isolated profile per task (`--isolated`). Lilo's agent tabs use its ephemeral agents
  profile, which lives as long as Lilo runs, so cookies can carry from one task to the next.
- All runs share the machine with whatever else is running; each line records the load average.
- Claude in Chrome is excluded: `claude -p --chrome` does load its tools, but they drive the
  Chrome window where the extension is signed in, with your own profile and site permissions.
  It cannot run headless or with an isolated profile, and needs that Chrome open and connected.
