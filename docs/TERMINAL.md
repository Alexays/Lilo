# Terminal shell integration

Lilo uses shell integration to report the current directory, running command, exit status and
duration. It also marks commands in the terminal's history for prompt navigation and output
selection. The hooks run when a command starts or a prompt appears; they do no work at idle.

Integration loads automatically for zsh and standard Bash, including Homebrew Bash. Lilo keeps
the shell's login behavior and reads its usual startup files before adding the hooks.

## macOS Bash

Apple's `/bin/bash` ignores the startup mechanism standard Bash uses. Add this at the end of
`~/.bash_profile` for login shells, or `~/.bashrc` for non-login shells:

```bash
if [[ -n ${LILO_BASH_INTEGRATION:-} ]]; then
    source "$LILO_BASH_INTEGRATION"
fi
```

Lilo provides the path when launching Bash. The hook supports macOS's Bash 3.2, keeps existing
prompt commands and DEBUG traps, and can be sourced more than once without duplicating hooks.
