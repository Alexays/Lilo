# Fish discovers this snippet through XDG_DATA_DIRS; startup programs inherit the user's value.
if set -q LILO_ORIG_XDG_DATA_DIRS
    set -gx XDG_DATA_DIRS "$LILO_ORIG_XDG_DATA_DIRS"
    set -e LILO_ORIG_XDG_DATA_DIRS
else
    set -e XDG_DATA_DIRS
end

if set -q LILO_INITIAL_COMMAND
    set -g _lilo_initial_command "$LILO_INITIAL_COMMAND"
    set -e LILO_INITIAL_COMMAND
end
if set -q LILO_PREFILL_COMMAND
    set -g _lilo_prefill_command "$LILO_PREFILL_COMMAND"
    set -e LILO_PREFILL_COMMAND
end

status is-interactive; or return

function _lilo_precmd --on-event fish_prompt
    if test "$PWD" != "$_lilo_last_cwd"
        set -g _lilo_last_cwd "$PWD"
        printf '\e]7;file://%s%s\a' "$hostname" (string escape --style=url -- "$PWD")
    end
    printf '\e]133;A\a'
end

function _lilo_preexec --on-event fish_preexec
    printf '\e]133;C;cmdline_url=%s\a' (string escape --style=url -- "$argv[1]")
end

function _lilo_postexec --on-event fish_postexec
    set -l exit_code $status
    printf '\e]133;D;%d\a' $exit_code
end

function _lilo_first_prompt --on-event fish_prompt
    functions --erase _lilo_first_prompt
    if set -q _lilo_initial_command
        commandline --replace -- "$_lilo_initial_command"
        set -e _lilo_initial_command
    else if set -q _lilo_prefill_command
        commandline --replace -- "$_lilo_prefill_command"
        commandline --cursor (string length -- "$_lilo_prefill_command")
        set -e _lilo_prefill_command
    end
end
