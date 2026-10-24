# /etc/zshrc derives HISTFILE from ZDOTDIR while it still points here; history belongs with the user's config.
[[ $HISTFILE == $_lilo_dir/* ]] && HISTFILE=$_lilo_user_dir/.zsh_history

ZDOTDIR=$_lilo_user_dir
[[ -f $ZDOTDIR/.zshrc ]] && builtin source $ZDOTDIR/.zshrc
ZDOTDIR=$_lilo_dir

autoload -Uz add-zsh-hook

# Percent-encodes $1 byte by byte into REPLY: the C locale makes each byte of a multibyte character its own match.
_lilo_urlencode() {
    builtin emulate -L zsh -o extendedglob
    local LC_ALL=C
    REPLY=${1//(#m)[^a-zA-Z0-9\/._~-]/%${(l:2::0:)$(( [##16] #MATCH ))}}
}

_lilo_report_cwd() {
    local REPLY
    _lilo_urlencode "$PWD"
    builtin printf '\e]7;file://%s%s\a' "$HOST" "$REPLY"
}

_lilo_precmd() {
    local exit_code=$?
    if [[ -n $_lilo_command_running ]]; then
        builtin printf '\e]133;D;%d\a' "$exit_code"
        _lilo_command_running=
    fi
    _lilo_report_cwd
    # zsh reads legacy keys only: drop the kitty keyboard flags a program died without popping,
    # or Ctrl+C arrives as ESC[99;5u.
    builtin printf '\e[<99u\e]133;A\a'
}

# The command line rides along so Lilo can name what runs (sidebar, notifications, close prompts).
_lilo_preexec() {
    local REPLY
    _lilo_command_running=1
    _lilo_urlencode "$1"
    builtin printf '\e]133;C;cmdline_url=%s\a' "$REPLY"
}

add-zsh-hook precmd _lilo_precmd
add-zsh-hook preexec _lilo_preexec

# The command a terminal was opened with is accepted at the first prompt, like a typed line: it
# lands in history, and an async prompt cannot swallow it the way it can typed-ahead input.
if [[ -n $_lilo_initial_command ]]; then
    autoload -Uz add-zle-hook-widget
    _lilo_run_initial_command() {
        add-zle-hook-widget -d line-init _lilo_run_initial_command
        BUFFER=$_lilo_initial_command
        unset _lilo_initial_command
        zle accept-line
    }
    add-zle-hook-widget line-init _lilo_run_initial_command
fi

# A restored terminal offers its last program again: typed at the first prompt, never run on its own.
if [[ -n $_lilo_prefill_command ]]; then
    autoload -Uz add-zle-hook-widget
    _lilo_prefill() {
        add-zle-hook-widget -d line-init _lilo_prefill
        BUFFER=$_lilo_prefill_command
        CURSOR=${#BUFFER}
        unset _lilo_prefill_command
    }
    add-zle-hook-widget line-init _lilo_prefill
fi

[[ -o login ]] || _lilo_restore_zdotdir
