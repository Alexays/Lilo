import type { Client } from "@modelcontextprotocol/client";
import { Bash, defineCommand, InMemoryFs } from "just-bash/browser";
import type { BashOptions, InitialFiles } from "just-bash/browser";
import { z } from "zod";

export type ShellToolArguments = NonNullable<
  Parameters<Client["callTool"]>[0]["arguments"]
>;

export type ShellResult = Pick<
  Awaited<ReturnType<Bash["exec"]>>,
  "exitCode" | "stderr" | "stdout"
>;

export type ShellEntry = ShellResult & { command: string; cwd: string };

interface ShellOptions {
  callMcp: (
    name: string,
    args: ShellToolArguments,
    signal?: AbortSignal
  ) => Promise<string>;
  files?: InitialFiles;
  listMcp: (signal?: AbortSignal) => Promise<string>;
}

const INITIAL_CWD = "/Users/you/Projects/lilo";
const MAX_HISTORY = 100;
const MAX_TRANSCRIPT = 30;
const MAX_OUTPUT_LENGTH = 64 * 1024;
const MAX_SOURCE_BYTES = 8 * 1024;
const MAX_FILE_BYTES = 1024 * 1024;
const toolArgumentsSchema = z.record(z.string(), z.json());

const executionLimits = {
  maxArrayElements: 2000,
  maxAwkIterations: 1000,
  maxBraceExpansionResults: 1000,
  maxCallDepth: 32,
  maxCommandCount: 1000,
  maxExecDepth: 16,
  maxExecutionTimeMs: 2000,
  maxExtensionCleanupTimeMs: 25,
  maxFileDescriptors: 32,
  maxFileSystemBytes: MAX_FILE_BYTES,
  maxGlobOperations: 4000,
  maxHeredocSize: MAX_SOURCE_BYTES,
  maxInputBytes: 128 * 1024,
  maxJqIterations: 1000,
  maxLiveBytes: 2 * 1024 * 1024,
  maxLoopIterations: 1000,
  maxOutputSize: 32 * 1024,
  maxQueryDepth: 64,
  maxQueryElements: 2000,
  maxSedIterations: 1000,
  maxSourceBytes: MAX_SOURCE_BYTES,
  maxStringLength: 128 * 1024,
  maxTraversalEntries: 2000,
  maxTraversalWork: 4000,
  maxWorkUnits: 20_000,
} satisfies BashOptions["executionLimits"];

const initialFiles: InitialFiles = {
  [`${INITIAL_CWD}/README.md`]: `# Lilo playground

This workspace and its files live in your browser until you reset the demo.

Try:
  ls
  cat notes/todo.md
  printf 'Hello Lilo\\n' > notes/hello.txt
  cat notes/hello.txt | tr '[:lower:]' '[:upper:]'
  mcp list

Use mcp call <tool> '<JSON arguments>' to control the sample browser tabs.
Native executables such as git, node, swift, claude and codex are unavailable.
`,
  [`${INITIAL_CWD}/docs/overview.md`]:
    "# Lilo\n\nA calm workspace for browser tabs, terminals and agents.\n",
  [`${INITIAL_CWD}/notes/ideas.txt`]: "Spaces\nPinned tabs\nSplit views\n",
  [`${INITIAL_CWD}/notes/todo.md`]:
    "# Today\n\n- Explore Spaces\n- Edit a file in the terminal\n- Try a local MCP tool\n",
  [`${INITIAL_CWD}/project.json`]:
    '{"name":"Lilo playground","runtime":"browser"}\n',
};

const success = (stdout: string): ShellResult => ({
  exitCode: 0,
  stderr: "",
  stdout,
});

const failure = (stderr: string, exitCode = 1): ShellResult => ({
  exitCode,
  stderr: `${stderr}\n`,
  stdout: "",
});

const createSession = (fs: InMemoryFs, options: ShellOptions) => {
  const history: string[] = [];
  const transcript: ShellEntry[] = [];
  let output = "";
  let running = false;

  const bash = new Bash({
    commands: [
      "awk",
      "base64",
      "basename",
      "bash",
      "cat",
      "chmod",
      "clear",
      "cp",
      "cut",
      "date",
      "dirname",
      "du",
      "echo",
      "env",
      "expr",
      "false",
      "find",
      "grep",
      "head",
      "help",
      "jq",
      "ln",
      "ls",
      "mkdir",
      "mktemp",
      "mv",
      "paste",
      "printenv",
      "printf",
      "pwd",
      "readlink",
      "rev",
      "rm",
      "rmdir",
      "sed",
      "seq",
      "sh",
      "sleep",
      "sort",
      "stat",
      "tail",
      "tee",
      "touch",
      "tr",
      "tree",
      "true",
      "uniq",
      "wc",
      "which",
      "whoami",
      "xargs",
      "yes",
    ],
    customCommands: [
      defineCommand(
        "mcp",
        async (args, { signal }) => {
          try {
            if (args[0] === "list" && args.length === 1) {
              return success(`${await options.listMcp(signal)}\n`);
            }

            if (args[0] !== "call" || !args[1]) {
              return failure(
                "Usage: mcp list | mcp call <tool> '<JSON arguments>'"
              );
            }

            const toolArguments: ShellToolArguments = toolArgumentsSchema.parse(
              JSON.parse(args.slice(2).join(" ") || "{}")
            );

            return success(
              `${await options.callMcp(args[1], toolArguments, signal)}\n`
            );
          } catch (error) {
            return failure(
              `mcp: ${error instanceof Error ? error.message : "Tool call failed"}`
            );
          }
        },
        { trusted: false }
      ),
      defineCommand("history", () =>
        Promise.resolve(
          success(
            history
              .map((command, index) => `${index + 1}  ${command}\n`)
              .join("")
          )
        )
      ),
    ],
    cwd: INITIAL_CWD,
    env: { HOME: "/Users/you", TERM: "xterm-256color", USER: "you" },
    executionLimitProfile: "hardened",
    executionLimits,
    fs,
  });

  let env = bash.getEnv();

  return {
    get cwd() {
      return env.PWD ?? INITIAL_CWD;
    },
    exec: async (
      command: string,
      signal?: AbortSignal
    ): Promise<ShellResult> => {
      if (running) {
        return failure("shell: a command is already running", 125);
      }

      if (!command.trim()) {
        return success("");
      }

      if (
        command.length > MAX_SOURCE_BYTES ||
        new TextEncoder().encode(command).byteLength > MAX_SOURCE_BYTES
      ) {
        return failure(`shell: command exceeds ${MAX_SOURCE_BYTES} bytes`, 2);
      }

      const cwd = env.PWD ?? INITIAL_CWD;
      history.push(command);

      if (history.length > MAX_HISTORY) {
        history.shift();
      }

      running = true;
      let result: ShellResult;

      try {
        // just-bash isolates exec calls; replay the previous result's environment and directory.
        const {
          env: nextEnv,
          exitCode,
          stderr,
          stdout,
        } = await bash.exec(command, {
          cwd,
          env,
          rawScript: true,
          replaceEnv: true,
          signal,
        });

        env = nextEnv;
        result = { exitCode, stderr, stdout };
      } catch (error) {
        result = failure(
          `shell: ${error instanceof Error ? error.message : "Command failed"}`
        );
      } finally {
        running = false;
      }

      transcript.push({ command, cwd, ...result });

      if (transcript.length > MAX_TRANSCRIPT) {
        transcript.shift();
      }

      output =
        `${output}${cwd} % ${command}\n${result.stdout}${result.stderr}`.slice(
          -MAX_OUTPUT_LENGTH
        );

      return result;
    },
    get history(): readonly string[] {
      return [...history];
    },
    get output() {
      return output;
    },
    get running() {
      return running;
    },
    get transcript(): readonly ShellEntry[] {
      return [...transcript];
    },
  };
};

export const createShell = (options: ShellOptions) => {
  const fs = new InMemoryFs(
    { ...initialFiles, ...options.files },
    { maxTotalBytes: MAX_FILE_BYTES }
  );

  const sessions = new Map<string, ReturnType<typeof createSession>>();

  return {
    fs,
    session: (tabId: string) => {
      let session = sessions.get(tabId);

      if (!session) {
        session = createSession(fs, options);
        sessions.set(tabId, session);
      }

      return session;
    },
  };
};

export type Shell = ReturnType<typeof createShell>;

export type ShellSession = ReturnType<Shell["session"]>;
