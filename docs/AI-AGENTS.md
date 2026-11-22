# AI agents

Lilo ships no AI of its own. If you opt in, the agents you already run locally (Claude Code,
Claude Desktop, Codex, Cursor or any MCP client) can drive Lilo through `lilo-mcp`, a small MCP
server inside the app bundle.

## Turning it on

Settings > Agents > "Let agents use Lilo". Lilo can write the MCP configuration for the
clients it finds. The first time a client connects, Lilo asks you to allow it; the approval is
tied to the program behind the connection (its code signature, or its path when unsigned), not to
the name the client announces.

## What agents can do

Agents work in their own Agents Space, in a throwaway profile wiped after each session, and never
take your keyboard or your tabs. They can borrow one of your profiles for a task after you allow it.

- Open, navigate and close tabs in their own folder; click, type, fill forms, take screenshots.
- Read pages (accessibility tree with element refs, page text; `read_page` with `viewport` returns only
  the elements on or near the screen, each with its box), the console and the network.
- Actions that can change the page (clicks, keys, typing, scrolls, `form_input`, file uploads) end their
  reply with what changed: the page's new URL, or a compact diff of the elements it added, removed and
  changed, so a full re-read is only needed for detail.
- `form_input`: set a field and get back what it holds once the page handled the change, with a
  warning when the page reformatted, cut or rejected the value. For a password, card or one-time
  code field the reply only says whether it holds the value given.
- `wait_for`: wait, instead of sleeping, for one of: a text, a CSS selector, an element by the role
  and name `read_page` gives it (each until it shows, is gone, or for an element is enabled), or the
  tab's URL (a substring, or a pattern for the whole URL with `*`). The page is checked at once and
  then after each DOM change, at most every 100 ms, frames left out; the URL when the tab's URL or
  loading state changes. 10 s by default, 50 s at most.
- Use devtools commands, network mocking and emulation.
- `fetch`: send an HTTP request from a tab, as the page would, with its origin, CORS rules and
  cookies. Bodies are capped (1 MB by default); `Set-Cookie` and `Authorization` are never returned.
- `run`: execute a JavaScript program that calls the other tools in a loop, in one call
  (at most 200 tool calls and 60 s by default).

Lilo is the one browser, so it lists no browser to choose. A client written for Claude in Chrome that
still calls `list_connected_browsers`, `select_browser` or `switch_browser` gets an answer instead
of an error, and no schema of them is sent on each turn.

## What Lilo asks you first

Unless you turn it off in Settings, Lilo asks before an agent:

- clicks or presses Enter on something that signs you in, pays, sends, buys, deletes, transfers,
  publishes or signs up (Allow Once, Always Allow on the site, or Deny), inside frames too; a click in
  a frame of another origin, which Lilo cannot read, is always asked. Lilo decides from the page's
  structure first, so it works in any language and for an icon-only button: submitting a form that
  holds a password, a card field or a one-time code, or that sends its data to another origin with a
  method other than GET. A short list of commit verbs (send, pay, buy, delete, publish and their
  translations) is the fallback for buttons outside a form; "order" counts only as a whole label
  ("Order") or in a phrase like "Place order", so "Save order" goes through;
- sends a request other than GET or HEAD with the cookies of one of your profiles.

The question opens in the window that holds the agent's page, and the agent's conversation row turns amber
meanwhile; your other windows, and the site and extension prompts there, are not held up by it.
It counts as a refusal when you decline; one nobody answers in 45 seconds is withdrawn, and the agent
may ask once more; with no window open the agent is told to ask you to open one first.

Sites you always allow are listed in Settings, where you can remove them. Each connected app (and each agent
Lilo has no app for) also has an **Acts on pages** row under it in Settings > Agents: **Ask First**, the default,
follows the setting above; **On Chosen Sites** lets that agent act without asking on the sites listed under it,
their subdomains included; **Everywhere** lets it act without asking on any site. Neither ever covers a sensitive
action, which asks every agent: a control that signs in, pays, buys, orders, deletes or publishes (by its form, a
password or card field, or by its label, buttons included), a form or request that sends data to another origin, a
`DELETE` request, or a frame Lilo cannot read. Removing an app or an agent forgets its choice.
The agent is recognized by the name it gives when it connects. Whatever the setting,
Lilo always asks before an agent hands a page one of your files (`file_upload`, `upload_image`).

Code an agent runs itself through `javascript_tool`, `run` or `devtools_command` is not covered:
the prompt is a safety net for well-behaved agents, not a sandbox.

Agents can never see or act on a private Space.

## Conversations with your agents

Settings > Agents > "Conversations with your agents" lets you talk to the agents you use
(Claude Agent, Codex, Gemini CLI, Copilot and the rest of the [ACP registry](https://agentclientprotocol.com))
in Lilo itself, over the Agent Client Protocol. Lilo still ships no model and holds no API key: it
starts the agent's own program, which signs in to its own account (your subscription) and talks to
its own service. Agents installed with `npx` or `uvx` need Node.js or uv; binaries come from the
registry and are checked against its SHA-256 before they run.

- `⇧⌘A` asks an agent from anywhere, with the page you read and its selection attached; `@` adds
  tabs, folders, a screenshot or files.
- A conversation lives where you started it: a row of its own in the sidebar (or the tab strip),
  with the pages the agent opens under it. The agent drives only those pages, through the same
  tools and the same approvals as above, and never one of your tabs or a private Space.
- When an agent asks for a permission, the row turns amber and the question opens under it; the
  Agents badge next to the keep-awake sun counts what waits on you, and lists every conversation.
- Each prompt saves the project's files as they were, so "Restore to here" can bring them back, and
  Undo puts back one file. An agent can work on its own copy of the project (a git worktree).
- An idle agent stops after ten minutes and resumes its session when you come back.

## Saved flows

An agent can record a task once and replay it later with three tools:

- `flow_start`: start recording. Every mutating call it makes from then on becomes a step - a click or a filled
  field as a stable locator (the role and name `read_page` gives the element, never a ref or a pixel),
  `navigate` and `wait_for` verbatim. Reads, scripts and coordinate clicks record nothing.
- `flow_save` with a name: stop and write the flow as JSONL in `Agents/Flows/` of Lilo's support folder,
  readable only by you, with a hash that fails a file edited on disk.
- `flow_run` with the name and a tab: replay each step through the same tool path a live call takes, so a
  replayed click asks for your approval exactly as the agent's own click would. A saved flow is a recording,
  not a standing authorization.

A value the user must supply each run is a parameter (`{"param": name}` in the file): the agent marks it with
`flowParam` at record time or declares it at `flow_save`, and a password, card or one-time code field always
becomes one - its value is never stored. `flow_run` fails before the first step if a parameter is missing.

Replay stops at the first step whose locator matches nothing (or whose element changed name since the
recording) and reports `{failedStep, reason}` - it never picks a near match. The agent then owns the page
again and can resume with `from`. A consent answer of `denied` or `expired` stops the run the same way.

While agent control is on, a conversation's first prompt carries a short skill describing these tools, the
same way a tab or a selection is attached, so any ACP agent learns them without configuration.

## The action log

Lilo keeps one local line per tool call an agent makes, in `Agents/Actions/` of Lilo's support folder (`~/Library/Application Support/Lilo/Agents/Actions/`). A conversation has its own file (`conversation-<tab id>.jsonl`), and every other client its own (`client-<name>.jsonl`). Nothing leaves your Mac, nothing is written while no agent calls a tool, and no screenshot, page text or video is ever stored. It is the record a replay, a retry or a skill is built from later.

Each line is a JSON object:

```json
{"args":{"ref":"ref_12","tabId":3,"value":{"chars":9}},"duration_ms":41,"host":"example.com","ok":true,"tabId":3,"tool":"form_input","ts":"2026-11-19T10:15:02.317Z"}
```

- `ts`, `tool`, `ok`, `duration_ms`, and `code` (the error code, such as `needs_user`) when the call failed.
- `possibleCommit` when the call sent a write to a site: a retry could happen twice.
- `tabId` and `host`: the tab the call named, and the host of its page, never a path or a query.
- `args`: the arguments with their content removed. Ids, actions, numbers and coordinates stay. A URL keeps its host. Every other string (typed text, scripts, selectors, headers, bodies, cookie values) becomes its length, `{"chars": 9}`, and so does any `value`, even a number, because it can be a one-time code.

What is never logged: what you or the agent typed, a password, a card or a one-time code, cookie values, request or response bodies, page text, screenshots, error messages and URLs past their host.

Each file stops at 1 MB and rotates to a single `.1.jsonl` next to it, so a source never holds more than 2 MB. Closing a conversation deletes its log when Lilo quits. To delete the rest, quit Lilo and remove the `Agents/Actions` folder. To stop logging, turn off Settings > Agents > "Keep a log of agent actions"; lines already written stay until you delete them.

## Known limitations

- An agent's `emulate` and an extension's `chrome.debugger` on the same tab share its Web Inspector, so each can overwrite the other's user agent, media and init script.

## Errors that need you

An error only you can resolve (a declined prompt, agent access turned off, Lilo not running, no window
open) carries the code `needs_user`: in `_meta["lilo/errorCode"]` on a tool result, in
`error.data.code` on a JSON-RPC error, and as a `[needs_user]` prefix in the message. A prompt that ended
without your answer also says how in `_meta["lilo/consent"]`: `denied`, `expired` (nobody answered in
time) or `unavailable` (no window could ask). When Lilo can't take an agent at all, `lilo-mcp` still
answers at once and says why.

A tool call that fails after it sent something that can change the site (a click, Enter, a `fetch`
other than GET, HEAD or OPTIONS, including inside `browser_batch` or `run`) carries
`_meta["lilo/possibleCommit"] = true` and says so in its message: the action may have gone through,
so the agent reads the site back before trying again rather than doing it twice. Any other failed
call changed nothing on the site and is safe to retry.
