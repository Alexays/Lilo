---
name: lilo-automations
description: Author Lilo automations, files that open tabs at a set time and can pause for the user's approval. Use when asked to schedule something in Lilo, to open pages later, or to run a short sequence in the browser that needs a yes/no from the user.
---

# Lilo automations

An automation is a plain text file. Write it, and Lilo's Automations plugin picks it up within a second or two: no restart, no editor, no registration. Delete the file to cancel it.

## Where

`<support>/watched/<name>.auto`, where `<support>` is the plugin's support folder: `~/Library/Application Support/Lilo/Plugin Support/app.lilo.automations/` (the Plugins settings page shows it as the support folder). Create `watched/` if it does not exist.

`<name>` uses only letters, digits, `.`, `-` and `_`. It is the automation's id.

## Format

One step per line. Blank lines and lines starting with `#` are ignored.

```
# Weekly report
at 2026-11-25T09:00:00Z
open https://example.com/dashboard
ensure https://example.com/inbox
ask Open the weekly report too?
open https://example.com/weekly
```

| Line | Meaning |
| --- | --- |
| `at <UTC time>` | When to start, as `YYYY-MM-DDTHH:MM:SSZ`. Required, exactly once, in UTC. |
| `open <url>` | Open the URL in a new tab. |
| `ensure <url>` | Open the URL unless a tab already shows exactly it. |
| `ask <question>` | Stop and ask the user. Approve and the run continues; decline, ignore or let it expire and the run stops there. |

A one-line automation (`at` plus one `open`) is a timed single action. Add more steps, or an `ask`, for a run.

## Behavior to rely on

- A run happens once. After it, the file stays but never runs again; write a new file (new name) for a new run. The outcome is in `<support>/state/<name>.done`: `completed`, `stopped at step N: not approved`, `failed at step N: ...`, or `expired`.
- A start time more than a day in the past is marked `expired` and never runs. One that is late by less than a day runs as soon as Lilo is up.
- Editing a file before its time re-arms it with the new content. Editing it after the run starts has no effect.
- If the `coordinate` job queue is installed (`coordinate` on the PATH, daemon running), the start time survives Lilo being quit: the run happens when Lilo next opens. Without it, the start time is only kept while Lilo stays open, and Lilo re-arms the files at each launch.
- `ask` waits for an answer for the "Approval step expires" time set in the plugin's settings (60 minutes by default).

## Do not

- Do not write local times or relative times (`in 10m`); convert to UTC first.
- Do not put secrets in a file: it is plain text and the steps are logged nowhere else.
- Do not invent step words. An unknown first word fails the run at that step.
