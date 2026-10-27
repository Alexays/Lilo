[[ $- == *i* && -z ${_lilo_bash_loaded:-} ]] || return 0
_lilo_bash_loaded=1

# Standard Bash loads ENV in POSIX mode. Apple's Bash needs this file sourced manually instead.
if [[ -n ${LILO_BASH_FLAGS+set} ]]; then
    if [[ -n ${LILO_ORIG_ENV+set} ]]; then
        export ENV=$LILO_ORIG_ENV
    else
        unset ENV
    fi
    unset LILO_ORIG_ENV
    set +o posix
    shopt -u inherit_errexit 2>/dev/null
    if [[ -n ${LILO_BASH_UNEXPORT_HISTFILE:-} ]]; then
        export -n HISTFILE
    fi
    unset LILO_BASH_UNEXPORT_HISTFILE

    _lilo_bash_flags=$LILO_BASH_FLAGS
    _lilo_bash_rcfile=${LILO_BASH_RCFILE:-$HOME/.bashrc}
    unset LILO_BASH_FLAGS LILO_BASH_RCFILE
    if shopt -q login_shell; then
        if [[ $_lilo_bash_flags != *--noprofile* ]]; then
            [[ -r /etc/profile ]] && builtin source /etc/profile
            for _lilo_profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
                if [[ -r $_lilo_profile ]]; then
                    builtin source "$_lilo_profile"
                    break
                fi
            done
        fi
    elif [[ $_lilo_bash_flags != *--norc* ]]; then
        [[ -r $_lilo_bash_rcfile ]] && builtin source "$_lilo_bash_rcfile"
    fi
    unset _lilo_bash_flags _lilo_bash_rcfile _lilo_profile
fi

# macOS ships Bash 3.2: use builtins and a DEBUG trap rather than the newer PS0 hook.
_lilo_urlencode() {
    local LC_ALL=C text=$1 char encoded index
    REPLY=
    for ((index = 0; index < ${#text}; index++)); do
        char=${text:index:1}
        case $char in
            [a-zA-Z0-9/._~-]) REPLY+=$char ;;
            *)
                # Bash 3.2's printf treats bytes above 127 as signed.
                builtin printf -v encoded '%d' "'$char"
                builtin printf -v encoded '%%%02X' "$((encoded & 255))"
                REPLY+=$encoded
                ;;
        esac
    done
}

_lilo_restore_status() { return "$1"; }

_lilo_precmd() {
    local exit_code=$? hook REPLY
    _lilo_at_prompt=
    if [[ -n $_lilo_command_running ]]; then
        builtin printf '\e]133;D;%d\a' "$exit_code"
        _lilo_command_running=
    fi
    for hook in "${_lilo_prompt_commands[@]}"; do
        _lilo_restore_status "$exit_code"
        builtin eval "$hook"
    done
    if [[ ${_lilo_last_cwd:-} != "$PWD" ]]; then
        _lilo_last_cwd=$PWD
        _lilo_urlencode "$PWD"
        builtin printf '\e]7;file://%s%s\a' "$HOSTNAME" "$REPLY"
    fi
    builtin printf '\e[<99u\e]133;A\a'
    _lilo_at_prompt=1
    return "$exit_code"
}

_lilo_preexec() {
    local exit_code=$? REPLY command=$1 history_item
    if [[ -n $_lilo_at_prompt && $BASH_SUBSHELL == 0 && ${#FUNCNAME[@]} == 1 && $1 != _lilo_precmd ]]; then
        _lilo_at_prompt=
        _lilo_command_running=1
        history_item=$(HISTTIMEFORMAT= builtin history 1)
        if [[ -n $history_item && $history_item != "$_lilo_last_history" ]]; then
            command=${history_item#*[0-9]  }
        fi
        _lilo_last_history=$history_item
        _lilo_urlencode "$command"
        builtin printf '\e]133;C;cmdline_url=%s\a' "$REPLY"
    fi
    return "$exit_code"
}

_lilo_prompt_commands=("${PROMPT_COMMAND[@]}")
_lilo_at_prompt=
_lilo_command_running=
_lilo_last_history=$(HISTTIMEFORMAT= builtin history 1)

_lilo_prepare_debug_hook() {
    # trap -p quotes its body for the shell; decode it without executing the user's trap.
    if [[ -n $_lilo_debug_trap ]]; then
        _lilo_debug_trap=${_lilo_debug_trap#trap -- }
        _lilo_debug_trap=${_lilo_debug_trap% DEBUG}
        builtin eval "_lilo_debug_command=$_lilo_debug_trap"
        _lilo_debug_hook='_lilo_preexec "$BASH_COMMAND"; builtin eval "$_lilo_debug_command"'
    else
        _lilo_debug_hook='_lilo_preexec "$BASH_COMMAND"; :'
    fi
    unset _lilo_debug_trap
    PROMPT_COMMAND=_lilo_precmd
}

# Bash restores DEBUG after a sourced file or function returns. Install it at top level on the
# first prompt, when the user's trap is visible again, then keep only the normal prompt hook.
PROMPT_COMMAND='_lilo_debug_trap=$(trap -p DEBUG); _lilo_prepare_debug_hook; trap "$_lilo_debug_hook" DEBUG; unset _lilo_debug_hook; _lilo_precmd'
