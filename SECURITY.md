# Security policy

## Reporting a vulnerability

Please **do not** open a public issue, discussion or pull request for a security vulnerability.

Report it privately through a [GitHub security advisory](https://github.com/Alexays/Lilo/security/advisories/new)
(Security tab, "Report a vulnerability"). Only the maintainers see it. Include:

- what the vulnerability is and what an attacker gains
- the steps or a proof of concept to reproduce it
- the Lilo version (About Lilo) or commit, and the macOS version
- any mitigation you suggest

What happens next:

1. The report is acknowledged within **7 days**.
2. The maintainers confirm the issue, agree on its severity with you, and keep you updated in the
   advisory until it is resolved.
3. The fix ships in a release, and the advisory is published with credit to you, unless you prefer
   to stay anonymous.

Please give the maintainers a reasonable time to ship a fix before disclosing the issue publicly.
There is no bug bounty: Lilo is an unfunded open-source project.

## Supported versions

| Version | Supported |
|---------|-----------|
| Latest release | Yes |
| `main` | Yes |
| Older releases | No: Lilo updates itself, so update first |

## Scope

In scope:

- The Lilo app itself (Swift backend, Svelte chrome UI)
- The Gap API / extension surface exposed to extensions
- The JS bridge between the chrome UI and Swift
- The Chrome Web Store install pipeline (CRX download, signature verification, extraction)
- Download quarantine handling
- The Web Serial bridge (which origin can reach which serial device)
- AI agent control: the agent socket, `lilo-mcp`, and the consent and approval prompts
- Browser import (reading and decrypting other browsers' data on this Mac)

Out of scope:

- Bugs in the WebKit engine itself: report those to the [WebKit project](https://bugs.webkit.org/)
- Vulnerabilities in third-party extensions
- Content served by filter lists (EasyList, EasyPrivacy, uBO assets)

## AI agent control

Agents reach Lilo over a Unix socket only the same user can open. A client's MCP name (`clientInfo.name`) is no credential: Lilo binds each approval, and each profile an agent was let into, to the program behind the connection (the agent that launched `lilo-mcp`, or the socket's peer): its signing identifier and team when Apple's certificate chain vouches for them, else its executable path. The consent prompt shows that program. Anything running as the same user can still reach Lilo's own data, so this guards against a program borrowing an approved agent's name, not against malware that already runs as you.

An agent can hand a page one of your files (`file_upload`, `upload_image` with a path) only after you allow that file for that site in the consent drawer, every time.

The approval prompt before an agent's consequential actions covers clicks, Enter, and requests other than GET or HEAD that `fetch` sends from one of your own profiles. It does not cover code the agent runs itself (`javascript_tool`, `run`, `devtools_command`): an agent working in one of your profiles can act there with your sign-ins.

## Local files

A `file://` page you open may read the folder it sits in only when it is an HTML page (`.html`, `.htm`, `.xhtml`), so the images, styles and scripts beside it load; any other file, an SVG or a text file included, can read only itself.

## Safe harbor

Good-faith security research on your own installation, reported privately as described above, will not be met with legal action.
