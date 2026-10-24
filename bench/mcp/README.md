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

- Lilo runs headed in its own window; Playwright MCP and Chrome DevTools MCP run headed with a
  fresh isolated profile per task (`--isolated`). Lilo's agent tabs use its ephemeral agents
  profile, which lives as long as Lilo runs, so cookies can carry from one task to the next.
- All runs share the machine with whatever else is running; each line records the load average.
- Claude in Chrome is excluded: `claude -p --chrome` does load its tools, but they drive the
  Chrome window where the extension is signed in, with your own profile and site permissions.
  It cannot run headless or with an isolated profile, and needs that Chrome open and connected.
