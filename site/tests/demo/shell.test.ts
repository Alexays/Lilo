import assert from "node:assert/strict";
import { test } from "node:test";

import { createShell } from "../../src/demo/shell.ts";
import type { ShellToolArguments } from "../../src/demo/shell.ts";

const makeShell = () =>
  createShell({
    callMcp: () => Promise.resolve("tool response"),
    listMcp: () => Promise.resolve("context\nnavigate"),
  });

test("terminal sessions preserve directories, variables, files and command history", async () => {
  const shell = makeShell();
  const terminal = shell.session("terminal");
  const changed = await terminal.exec("cd notes");

  assert.equal(changed.exitCode, 0);
  assert.equal(terminal.cwd, "/Users/you/Projects/lilo/notes");

  const exported = await terminal.exec("export GREETING='Hello Lilo'");

  const written = await terminal.exec(
    'printf "%s\\n" "$GREETING" > greeting.txt'
  );

  const read = await terminal.exec("cat greeting.txt");

  assert.equal(exported.exitCode, 0);
  assert.equal(written.exitCode, 0);
  assert.equal(read.stdout, "Hello Lilo\n");
  assert.equal(
    await shell.fs.readFile("/Users/you/Projects/lilo/notes/greeting.txt"),
    "Hello Lilo\n"
  );
  assert.equal(shell.session("terminal"), terminal);
  assert.ok(terminal.history.includes("cat greeting.txt"));
  assert.ok(terminal.output.includes("Hello Lilo\n"));
  assert.equal(terminal.transcript.at(-1)?.cwd, terminal.cwd);

  const unset = await terminal.exec("unset GREETING");
  const empty = await terminal.exec('printf "%s" "$GREETING"');
  const returned = await terminal.exec("cd -");

  assert.equal(unset.exitCode, 0);
  assert.equal(empty.stdout, "");
  assert.equal(returned.exitCode, 0);
  assert.equal(terminal.cwd, "/Users/you/Projects/lilo");
});

test("shell parsing supports quoted pipelines, redirects, edits and conditional commands", async () => {
  const terminal = makeShell().session("terminal");

  const result = await terminal.exec(
    "printf 'pear\\napple\\npear\\n' | sort | uniq > fruit.txt && sed -i 's/pear/plum/' fruit.txt && cat fruit.txt"
  );

  assert.equal(result.exitCode, 0);
  assert.equal(result.stdout, "apple\nplum\n");

  const appended = await terminal.exec(
    "printf 'cherry\\n' >> fruit.txt; wc -l < fruit.txt"
  );

  const conditional = await terminal.exec("false && echo no || echo yes");

  assert.equal(appended.stdout.trim(), "3");
  assert.equal(conditional.stdout, "yes\n");
});

test("tabs share virtual files while keeping directories and variables isolated", async () => {
  const shell = makeShell();
  const first = shell.session("first");
  const second = shell.session("second");

  await first.exec("cd notes; export LOCAL=first; echo shared > shared.txt");
  assert.equal(second.cwd, "/Users/you/Projects/lilo");

  const isolatedVariable = await second.exec('printf "%s" "$LOCAL"');
  const sharedFile = await second.exec("cat notes/shared.txt");
  const fresh = makeShell().session("first");
  const freshFile = await fresh.exec("cat notes/shared.txt");

  assert.equal(isolatedVariable.stdout, "");
  assert.equal(sharedFile.stdout, "shared\n");
  assert.equal(fresh.history.length, 1);
  assert.equal(freshFile.exitCode, 1);
});

test("mcp commands forward quoted JSON and participate in shell pipelines", async () => {
  const calls: { args: ShellToolArguments; name: string }[] = [];

  const shell = createShell({
    callMcp: (name, args) => {
      calls.push({ args, name });

      return Promise.resolve(JSON.stringify({ title: "Lilo tabs" }));
    },
    listMcp: () => Promise.resolve("context\nnavigate"),
  });

  const terminal = shell.session("terminal");
  const listing = await terminal.exec("mcp list | grep navigate");

  assert.equal(listing.stdout, "navigate\n");

  const result = await terminal.exec(
    'mcp call navigate \'{"tab_id":"agent tab","url":"https://example.com","options":{"replace":true}}\' | jq -r .title'
  );

  assert.equal(result.stdout, "Lilo tabs\n");
  assert.deepEqual(calls, [
    {
      args: {
        options: { replace: true },
        tab_id: "agent tab",
        url: "https://example.com",
      },
      name: "navigate",
    },
  ]);

  const invalidCommands = [
    "mcp call navigate '[]'",
    "mcp call navigate 'null'",
    "mcp call navigate '{broken'",
    "mcp unknown",
  ];

  const invalid = await terminal.exec(
    invalidCommands
      .map((input) => `if ${input}; then echo accepted; else echo rejected; fi`)
      .join("\n")
  );

  assert.equal(invalid.stdout, "rejected\n".repeat(invalidCommands.length));
  assert.equal(calls.length, 1);
});

test("MCP failures are reported as command errors and the session remains usable", async () => {
  const shell = createShell({
    callMcp: () => Promise.reject(new Error("Unknown sample tab")),
    listMcp: () => Promise.resolve("context"),
  });

  const terminal = shell.session("terminal");
  const result = await terminal.exec("mcp call navigate '{}'");
  const recovered = await terminal.exec("echo ready");

  assert.equal(result.exitCode, 1);
  assert.match(result.stderr, /Unknown sample tab/u);
  assert.equal(recovered.stdout, "ready\n");
});

test(
  "cancellation stops a pending MCP call without waiting for its response",
  { timeout: 5000 },
  async () => {
    const started = Promise.withResolvers<AbortSignal | undefined>();
    const response = Promise.withResolvers<string>();

    const shell = createShell({
      callMcp: (_name, _args, signal) => {
        started.resolve(signal);

        return response.promise;
      },
      listMcp: () => Promise.resolve("context"),
    });

    const terminal = shell.session("terminal");
    const controller = new AbortController();

    const execution = terminal.exec(
      "echo kept > before.txt; mcp call context '{}'; echo no > cancelled.txt",
      controller.signal
    );

    const toolSignal = await started.promise;

    assert.ok(toolSignal);
    assert.equal(toolSignal.aborted, false);
    assert.equal(terminal.running, true);
    const overlapping = await terminal.exec("echo overlapping");
    assert.equal(overlapping.exitCode, 125);
    controller.abort();
    const result = await execution;

    assert.equal(toolSignal.aborted, true);
    assert.equal(result.exitCode, 124);
    assert.equal(terminal.running, false);
    assert.equal(
      await shell.fs.readFile("/Users/you/Projects/lilo/before.txt"),
      "kept\n"
    );
    assert.equal(
      await shell.fs.exists("/Users/you/Projects/lilo/cancelled.txt"),
      false
    );
    response.resolve("late response");
    const recovered = await terminal.exec("echo recovered");
    assert.equal(recovered.stdout, "recovered\n");
  }
);

test("an already aborted signal cannot write virtual files", async () => {
  const shell = makeShell();
  const controller = new AbortController();
  controller.abort();

  const result = await shell
    .session("terminal")
    .exec("echo no > cancelled.txt", controller.signal);

  assert.equal(result.exitCode, 124);
  assert.equal(
    await shell.fs.exists("/Users/you/Projects/lilo/cancelled.txt"),
    false
  );
});

test("runaway work, output and source are bounded without breaking later commands", async () => {
  const terminal = makeShell().session("terminal");
  const loop = await terminal.exec("while true; do :; done");
  const output = await terminal.exec("seq 1 20000");
  const source = await terminal.exec(`echo ${"x".repeat(9000)}`);
  const recovered = await terminal.exec("echo recovered");

  assert.notEqual(loop.exitCode, 0);
  assert.match(loop.stderr, /limit|exceed/iu);
  assert.notEqual(output.exitCode, 0);
  assert.ok(output.stdout.length + output.stderr.length < 34 * 1024);
  assert.notEqual(source.exitCode, 0);
  assert.match(source.stderr, /exceed/iu);
  assert.equal(recovered.stdout, "recovered\n");
});

test("virtual filesystem growth and retained terminal history are bounded", async () => {
  const shell = makeShell();
  const terminal = shell.session("terminal");

  await assert.rejects(
    shell.fs.writeFile("/large.txt", "x".repeat(1024 * 1024 + 1))
  );

  for (let index = 0; index < 105; index += 1) {
    // oxlint-disable-next-line no-await-in-loop -- Separate completed executions exercise the session's retained command history.
    await terminal.exec(`echo ${index}`);
  }

  assert.equal(terminal.history.length, 100);
  assert.equal(terminal.history[0], "echo 5");
  assert.equal(terminal.transcript.length, 30);
  assert.equal(terminal.transcript.at(-1)?.stdout, "104\n");

  for (let index = 0; index < 4; index += 1) {
    // oxlint-disable-next-line no-await-in-loop -- Each result fits its execution limit while their retained output exceeds the session limit.
    await terminal.exec("printf '%20000s' x");
  }

  assert.equal(terminal.output.length, 64 * 1024);
});

test("the browser shell cannot invoke native programs or network tools", async () => {
  const terminal = makeShell().session("terminal");

  const commands = [
    "git status",
    "node --version",
    "swift --version",
    "claude",
    "codex",
    "curl https://example.com",
  ];

  const result = await terminal.exec(
    commands
      .map(
        (command) =>
          `if ${command}; then echo available; else echo unavailable; fi`
      )
      .join("\n")
  );

  assert.equal(result.stdout, "unavailable\n".repeat(commands.length));
});
