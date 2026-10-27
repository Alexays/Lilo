if set -q LILO_FISH_INTEGRATION
    if set -q LILO_ORIG_XDG_DATA_DIRS
        set -gx XDG_DATA_DIRS "$LILO_ORIG_XDG_DATA_DIRS"
    else
        set -e XDG_DATA_DIRS
    end
    set -e LILO_FISH_INTEGRATION
    set -e LILO_ORIG_XDG_DATA_DIRS
end

set -l initial_command "$LILO_INITIAL_COMMAND"
set -l prefill_command "$LILO_PREFILL_COMMAND"
set -e LILO_INITIAL_COMMAND
set -e LILO_PREFILL_COMMAND

status is-interactive; or return
if test -n "$initial_command"
    function _lilo_fish_initial_command --on-event fish_prompt --inherit-variable initial_command
        functions --erase _lilo_fish_initial_command
        commandline --replace -- "$initial_command"
        commandline --function execute
    end
else if test -n "$prefill_command"
    function _lilo_fish_prefill --on-event fish_prompt --inherit-variable prefill_command
        functions --erase _lilo_fish_prefill
        commandline --replace -- "$prefill_command"
    end
end
