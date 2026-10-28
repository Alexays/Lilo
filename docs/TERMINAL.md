# Terminal shells

Lilo starts the login shell configured for your macOS account. zsh and Fish 4 or later are
integrated automatically, with the same terminal-tab behavior. No startup-file edits are needed.

- Your normal shell configuration, prompt, key bindings, and history are kept.
- Fish history is offered in the command bar alongside programs on your login shell's PATH.
- A terminal opened with a command accepts it at the first prompt, as if you typed it.
- A restored terminal offers its last command at the prompt. It runs only when you press Return.
- Command results, duration, directory changes, prompt navigation, and output selection work
  with either shell.

Fish loads Lilo's startup snippet through its vendor configuration mechanism. The snippet
restores the original environment before your configuration runs, preserves your event handlers,
and does no work at idle.
