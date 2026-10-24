# AI agents

Lilo ships no AI of its own. If you opt in, the agents you already run locally (Claude Code,
Claude Desktop, Codex, Cursor or any MCP client) can drive Lilo through `lilo-mcp`, a small MCP
server inside the app bundle.

## Turning it on

Settings > AI agents > "Let AI agents use Lilo". Lilo can write the MCP configuration for the
clients it finds. The first time a client connects, Lilo asks you to allow it; the approval is
tied to the program behind the connection (its code signature, or its path when unsigned), not to
the name the client announces.

## What agents can do

Agents work in their own Agents Space, in a throwaway profile wiped after each session, and never
take your keyboard or your tabs. They can borrow one of your profiles for a task after you allow it.

- Open, navigate and close tabs in their own folder; click, type, fill forms, take screenshots.
- Read pages (accessibility tree with element refs, page text), the console and the network.
- Use devtools commands, network mocking and emulation.
- `fetch`: send an HTTP request from a tab, as the page would, with its origin, CORS rules and
  cookies. Bodies are capped (1 MB by default); `Set-Cookie` and `Authorization` are never returned.
- `run`: execute a JavaScript program that calls the other tools in a loop, in one call
  (at most 200 tool calls and 60 s by default).

## What Lilo asks you first

Unless you turn it off in Settings, Lilo asks before an agent:

- clicks or presses Enter on something that sends, pays, buys, orders, deletes, transfers,
  publishes or signs up (Allow Once, Always Allow on the site, or Deny), inside frames too; a click in
  a frame of another origin, which Lilo cannot read, is always asked;
- sends a request other than GET or HEAD with the cookies of one of your profiles.

Sites you always allow are listed in Settings, where you can remove them. Whatever the setting,
Lilo always asks before an agent hands a page one of your files (`file_upload`, `upload_image`).

Code an agent runs itself through `javascript_tool`, `run` or `devtools_command` is not covered:
the prompt is a safety net for well-behaved agents, not a sandbox.

Agents can never see or act on a private Space.

## Known limitations

- An agent's `emulate` and an extension's `chrome.debugger` on the same tab share its Web Inspector, so each can overwrite the other's user agent, media and init script.

## Errors that need you

An error only you can resolve (a denied prompt, agent access turned off, Lilo not running, no window
open) carries the code `needs_user`: in `_meta["lilo/errorCode"]` on a tool result, in
`error.data.code` on a JSON-RPC error, and as a `[needs_user]` prefix in the message. When Lilo
can't take an agent at all, `lilo-mcp` still answers at once and says why.
