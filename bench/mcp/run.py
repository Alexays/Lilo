#!/usr/bin/env python3
"""Runs BU Bench V2.1 tasks through `claude -p` with one browser MCP server, then judges each run
with a separate `claude -p` call. Needs the `claude` CLI (logged in) and the `cryptography` module.

  python3 -I bench/mcp/run.py run --tool lilo --bench ~/src/browser-use-benchmark --limit 10
  python3 -I bench/mcp/run.py summary bench/mcp/results/*.jsonl
"""

import argparse
import ast
import base64
import datetime
import hashlib
import json
import os
import random
import signal
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATASET = "BU_Bench_V2"
# The BrowserCode pre-prompt of the benchmark, minus its BrowserCode-specific lines.
PROMPT = """You are an agent with browser access working autonomously to complete a task. Nobody will answer questions.
The browser tools are your only access to the web.
Save every file deliverable under {outputs}. Those files and your final response are returned to the user.
Use the browser and available tools to obtain evidence. Your final response should be clear and honest.
To search the web, prefer DuckDuckGo. If using Google, open its homepage and type the query instead of opening a cold search URL.

Task: {task}"""
# File tools write deliverables; no Bash, WebFetch or WebSearch, so the browser is the only way to the web.
AGENT_TOOLS = "Read,Write,Edit,Glob,Grep"
EVIDENCE_NOTE = ("This harness captures no screenshots. Judge from the tool calls and tool results in the "
                 "trajectory, the final result and the output files.")
# The findings judge's own section caps.
TRAJECTORY_MAX, FINAL_MAX, FILES_MAX = 700_000, 100_000, 600_000


def claude(args, cwd, timeout, stdin=None):
    """Runs `claude -p` in its own process group, killed with every child (MCP servers, browsers) when done."""
    env = {**os.environ, "ENABLE_TOOL_SEARCH": "false"}
    with open(cwd / f"{args[0]}.out", "w") as out, open(cwd / f"{args[0]}.err", "w") as err:
        proc = subprocess.Popen(["claude", "-p", *args[1:], "--no-session-persistence", "--setting-sources", "",
                                 "--strict-mcp-config", "--disable-slash-commands"],
                                cwd=cwd, stdout=out, stderr=err, env=env, start_new_session=True,
                                stdin=subprocess.PIPE if stdin else subprocess.DEVNULL, text=True)
        timed_out = False
        try:
            proc.communicate(stdin, timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(proc.pid, sig)
            # macOS answers EPERM, not ESRCH, once only zombies are left in the group.
            except (ProcessLookupError, PermissionError):
                break
            time.sleep(3)
        proc.wait()
    return (cwd / f"{args[0]}.out").read_text(), proc.returncode, timed_out


def clip(text, limit):
    """Clips the middle like the findings judge does."""
    if len(text) <= limit:
        return text
    half = limit // 2
    return f"{text[:half]}\n... [{len(text) - limit} characters omitted] ...\n{text[-half:]}"


def flatten(content):
    if isinstance(content, str):
        return content
    return "\n".join(part.get("text", "") if part.get("type") == "text" else f"[{part.get('type')}]"
                     for part in content or [])


def parse_stream(text):
    """Trajectory steps, tool stats and token usage from a stream-json transcript, complete or cut short."""
    init, result, steps, names, calls, errors, usage = {}, {}, [], {}, {}, [], {}
    for line in text.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = event.get("type")
        if kind == "system" and event.get("subtype") == "init":
            init = event
        elif kind == "result":
            result = event
        elif kind == "assistant":
            message = event["message"]
            # One API message arrives as several events, one per block, sharing its usage.
            usage[message["id"]] = message.get("usage") or {}
            for block in message.get("content", []):
                if block["type"] == "text":
                    steps.append("assistant: " + block["text"])
                elif block["type"] == "tool_use":
                    names[block["id"]] = block["name"]
                    calls[block["name"]] = calls.get(block["name"], 0) + 1
                    steps.append(f"tool_call {block['name']}: {json.dumps(block['input'], ensure_ascii=False)}")
        elif kind == "user" and isinstance(event["message"].get("content"), list):
            for block in event["message"]["content"]:
                if block.get("type") != "tool_result":
                    continue
                name, output = names.get(block.get("tool_use_id"), "?"), flatten(block.get("content"))
                if block.get("is_error"):
                    errors.append(f"{name}: {output[:300]}")
                steps.append(f"tool_result {name}{' (error)' if block.get('is_error') else ''}: {output}")
    tokens = {key: sum(u.get(key) or 0 for u in usage.values()) for key in
              ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens")}
    tokens["messages"] = len(usage)
    return init, result, steps, calls, errors, tokens


def deliverables(outputs):
    texts = []
    for path in sorted(p for p in outputs.rglob("*") if p.is_file()):
        try:
            texts.append(f"File: {path.relative_to(outputs)}\n{path.read_text(encoding='utf-8')}")
        except (OSError, UnicodeDecodeError) as error:
            texts.append(f"File: {path.relative_to(outputs)}\n[unreadable: {type(error).__name__}]")
    return "\n\n".join(texts)


def judge(task, system_prompt, steps, final, files, args, cwd):
    items = list(task["weights"])
    schema = {
        "type": "object", "additionalProperties": False,
        "required": ["agent_task_reading", "findings", "observations", "infra_error", "pii_present",
                     "reward_hacking_suspected", "flag_notes"],
        "properties": {
            "agent_task_reading": {"type": "string"},
            "findings": {"type": "array", "items": {
                "type": "object", "additionalProperties": False,
                "required": ["item", "evidence", "status", "not_assessable_reason"],
                "properties": {
                    "item": {"enum": items}, "evidence": {"type": "string"},
                    "status": {"enum": ["met", "violated", "not_assessable"]},
                    "not_assessable_reason": {"enum": ["missing_evidence", "absent_scope", None]}}}},
            "observations": {"type": "array", "items": {"type": "string"}},
            "infra_error": {"type": "boolean"}, "pii_present": {"type": "boolean"},
            "reward_hacking_suspected": {"type": "boolean"}, "flag_notes": {"type": ["string", "null"]}}}
    files_section = f"\n<output_files>\n{clip(files, FILES_MAX)}\n</output_files>\n" if files else ""
    user = f"""
<task>
{task['task']}
</task>

<website>
No website provided
</website>

<rubric_path>
rubrics/{task['id']}.md
</rubric_path>

<rubric>
{task['rubric']}
</rubric>

<agent_trajectory>
{clip(chr(10).join(f'[step {i}] {s}' for i, s in enumerate(steps, 1)), TRAJECTORY_MAX) or 'No agent trajectory provided'}
</agent_trajectory>

<final_result>
{clip(final, FINAL_MAX) or 'No final result provided'}
</final_result>
{files_section}
<evidence_notes>
{EVIDENCE_NOTE}
</evidence_notes>
<screenshots>
0 screenshots are attached.
</screenshots>
"""
    for _ in range(2):
        out, _, _ = claude(["judge", "--model", args.judge_model, "--effort", args.judge_effort, "--tools", "",
                            "--system-prompt", system_prompt, "--json-schema", json.dumps(schema),
                            "--output-format", "json"], cwd, 1800, stdin=user)
        try:
            response = json.loads(out)
            verdict = response["structured_output"]
            found = [f["item"] for f in verdict["findings"]]
        except (json.JSONDecodeError, KeyError, TypeError):
            continue
        # Fails closed like the benchmark: every rubric item exactly once.
        if sorted(found) == sorted(items):
            return verdict, response
    return None, None


def run(args):
    from cryptography.fernet import Fernet

    bench = Path(args.bench).expanduser()
    raw = (bench / f"{DATASET}.enc").read_bytes()
    key = base64.urlsafe_b64encode(hashlib.sha256(DATASET.encode()).digest())
    tasks = {t["id"]: t for t in json.loads(Fernet(key).decrypt(base64.b64decode(raw)))["tasks"]}
    tree = ast.parse((bench / "findings_judge.py").read_text())
    system_prompt = next(ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign)
                         and any(getattr(t, "id", None) == "FINDINGS_SYSTEM_PROMPT" for t in node.targets))
    ids = Path(args.tasks).read_text().split()[:args.limit]
    out_path = Path(args.out or HERE / "results" / f"{args.tool}.jsonl")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    done = {(r["task_id"], r["pass"]) for r in map(json.loads, out_path.read_text().splitlines())} \
        if out_path.exists() else set()
    work = Path(args.work).expanduser().resolve() / args.tool
    version = subprocess.run(["claude", "--version"], capture_output=True, text=True).stdout.strip()

    for run_pass in range(1, args.passes + 1):
        for task_id in ids:
            if (task_id, run_pass) in done:
                continue
            task = tasks[task_id]
            cwd = work / f"{task_id}-p{run_pass}"
            outputs = cwd / "outputs"
            outputs.mkdir(parents=True, exist_ok=True)
            print(f"[{args.tool}] {task_id} pass {run_pass}", file=sys.stderr, flush=True)
            started, load = datetime.datetime.now(datetime.UTC).isoformat(timespec="seconds"), os.getloadavg()[0]
            clock = time.monotonic()
            stream, code, timed_out = claude(
                ["agent", PROMPT.format(outputs=outputs, task=task["task"]), "--output-format", "stream-json",
                 "--verbose", "--model", args.model, "--mcp-config", str(HERE / "servers" / f"{args.tool}.json"),
                 "--tools", AGENT_TOOLS, "--allowedTools", "mcp__browser", "--permission-mode", "acceptEdits",
                 "--permission-prompts", "none", "--max-turns", str(args.max_turns)], cwd, args.timeout)
            wall = time.monotonic() - clock
            init, result, steps, calls, tool_errors, tokens = parse_stream(stream)
            # The stream's per-message output counts stop early: the final result has the exact totals,
            # and a run cut short by the timeout keeps the stream's (exact input, low output) counts.
            tokens |= result.get("usage") or {}
            final = result.get("result") or ""
            (cwd / "final.txt").write_text(final)
            servers = {s["name"]: s["status"] for s in init.get("mcp_servers", [])}
            connected = servers.get("browser") == "connected"
            errors = [f"timed out after {args.timeout}s"] if timed_out else []
            if not connected:
                errors.append(f"browser MCP server {servers.get('browser', 'missing')}")
            if result.get("is_error"):
                errors.append(f"agent ended with {result.get('subtype')}: {str(result.get('result'))[:300]}")
            elif code and not timed_out:
                errors.append(f"claude exited with {code}")

            files = deliverables(outputs)
            verdict, response = judge(task, system_prompt, steps, final, files, args, cwd) if connected else (None, None)
            record = {
                "tool": args.tool, "task_id": task_id, "pass": run_pass, "started": started,
                "load_avg_1m": round(load, 2), "claude_version": version, "model": init.get("model"),
                "judge_model": next(iter((response or {}).get("modelUsage", {})), None),
                "score": None, "verdict": None, "wall_s": round(wall, 1),
                "turns": result.get("num_turns", tokens["messages"]),
                "tool_calls": sum(calls.values()), "tool_calls_by_name": calls,
                "tool_errors": len(tool_errors), "tool_error_samples": tool_errors[:10],
                "input_tokens": tokens["input_tokens"] + tokens["cache_read_input_tokens"]
                + tokens["cache_creation_input_tokens"],
                "cache_read_tokens": tokens["cache_read_input_tokens"], "output_tokens": tokens["output_tokens"],
                "cost_usd": result.get("total_cost_usd"), "judge_cost_usd": (response or {}).get("total_cost_usd"),
                "timed_out": timed_out, "errors": errors, "dataset_sha256": hashlib.sha256(raw).hexdigest(),
                "work_dir": str(cwd),
            }
            if verdict:
                (cwd / "judge.json").write_text(json.dumps(verdict, indent=1, ensure_ascii=False))
                status = {f["item"]: f["status"] for f in verdict["findings"]}
                # The rubric canary only leaks to an agent that read the answer key.
                leaked = task["canary"] in "\n".join([final, files, *steps])
                zeroed = verdict["reward_hacking_suspected"] or leaked
                earned = sum(w for item, w in task["weights"].items() if status[item] == "met")
                record.update(score=0.0 if zeroed else earned / sum(task["weights"].values()),
                              verdict=not zeroed and all(s == "met" for s in status.values()),
                              rh_zeroed=zeroed, infra_error=verdict["infra_error"])
            else:
                record["errors"].append("judge failed")
            with out_path.open("a") as out:
                out.write(json.dumps(record) + "\n")
            print(f"  score={record['score']} wall={record['wall_s']}s tokens={record['input_tokens']}"
                  f"+{record['output_tokens']} errors={errors}", file=sys.stderr, flush=True)
            if not connected:
                sys.exit(f"The browser MCP server did not connect ({servers.get('browser')}): stopping.")
    summary(argparse.Namespace(files=[str(out_path)]))


def summary(args):
    rows = [json.loads(line) for name in args.files for line in Path(name).read_text().splitlines() if line]
    print("| tool | runs | judged | mean score (95% CI) | full success | median input tok | median output tok "
          "| median wall s | median tool calls | timeouts | tool errors | cost USD (list) |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    rng = random.Random(0)
    for tool in sorted({r["tool"] for r in rows}):
        runs = [r for r in rows if r["tool"] == tool]
        scores = [r["score"] for r in runs if r["score"] is not None]
        means = sorted(statistics.fmean(rng.choices(scores, k=len(scores))) for _ in range(10_000)) if scores else []
        mean = f"{statistics.fmean(scores):.3f} ({means[249]:.3f}-{means[9749]:.3f})" if scores else "-"
        median = lambda key: statistics.median(r[key] for r in runs)  # noqa: E731
        print(f"| {tool} | {len(runs)} | {len(scores)} | {mean} | {sum(bool(r['verdict']) for r in runs)} "
              f"| {median('input_tokens'):,.0f} | {median('output_tokens'):,.0f} | {median('wall_s'):.0f} "
              f"| {median('tool_calls'):.0f} | {sum(r['timed_out'] for r in runs)} "
              f"| {sum(r['tool_errors'] for r in runs)} "
              f"| {sum((r['cost_usd'] or 0) + (r['judge_cost_usd'] or 0) for r in runs):.2f} |")


parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
commands = parser.add_subparsers(required=True)
run_command = commands.add_parser("run", help="run and judge tasks with one browser MCP server")
run_command.add_argument("--tool", required=True, choices=[p.stem for p in (HERE / "servers").glob("*.json")])
run_command.add_argument("--bench", required=True, help="checkout of github.com/browser-use/benchmark")
run_command.add_argument("--tasks", default=str(HERE / "tasks.txt"), help="task IDs, run in this order")
run_command.add_argument("--limit", type=int, default=None, help="first N task IDs only")
run_command.add_argument("--passes", type=int, default=1)
run_command.add_argument("--timeout", type=int, default=1200, help="seconds per task")
run_command.add_argument("--max-turns", type=int, default=200)
run_command.add_argument("--model", default="sonnet", help="agent model, the same for every tool")
run_command.add_argument("--judge-model", default="opus")
run_command.add_argument("--judge-effort", default="high")
run_command.add_argument("--out", help="JSONL results, appended; finished task passes are skipped")
run_command.add_argument("--work", default=str(HERE / "work"), help="transcripts and deliverables (task text)")
run_command.set_defaults(handler=run)
summary_command = commands.add_parser("summary", help="summary table of JSONL results")
summary_command.add_argument("files", nargs="+")
summary_command.set_defaults(handler=summary)
parsed = parser.parse_args()
parsed.handler(parsed)
