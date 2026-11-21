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
- Read pages (accessibility tree with element refs, page text), the console and the network.
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
  translations) is the fallback for buttons outside a form; a bare "order" is not on it, so "Save
  order" goes through;
- sends a request other than GET or HEAD with the cookies of one of your profiles.

The question opens in the window that holds the agent's page, and the agent's conversation row turns amber
meanwhile; your other windows, and the site and extension prompts there, are not held up by it.
It counts as a refusal when you decline; one nobody answers in 45 seconds is withdrawn, and the agent
may ask once more; with no window open the agent is told to ask you to open one first.

Sites you always allow are listed in Settings, where you can remove them. Whatever the setting,
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
