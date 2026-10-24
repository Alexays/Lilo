# Lilo shell integration. Lilo points ZDOTDIR here for the whole startup: each of these files
# sources the user's own counterpart at top level, and the hooks go in after the user's .zshrc,
# so a framework that resets precmd_functions cannot drop them.
_lilo_dir=$ZDOTDIR
if [[ -n "${LILO_ORIG_ZDOTDIR+set}" ]]; then
    _lilo_user_dir=$LILO_ORIG_ZDOTDIR
    _lilo_had_zdotdir=1
    unset LILO_ORIG_ZDOTDIR
else
    _lilo_user_dir=$HOME
    _lilo_had_zdotdir=
fi

# Hands ZDOTDIR back to the user once startup is over.
_lilo_restore_zdotdir() {
    if [[ -n $_lilo_had_zdotdir || $_lilo_user_dir != $HOME ]]; then
        export ZDOTDIR=$_lilo_user_dir
    else
        unset ZDOTDIR
    fi
    unset _lilo_dir _lilo_user_dir _lilo_had_zdotdir
    unfunction _lilo_restore_zdotdir
}

# Taken before the user's config runs, so the programs it starts never inherit it.
if [[ -n $LILO_INITIAL_COMMAND ]]; then
    _lilo_initial_command=$LILO_INITIAL_COMMAND
    unset LILO_INITIAL_COMMAND
fi
if [[ -n $LILO_PREFILL_COMMAND ]]; then
    _lilo_prefill_command=$LILO_PREFILL_COMMAND
    unset LILO_PREFILL_COMMAND
fi

ZDOTDIR=$_lilo_user_dir
[[ -f $ZDOTDIR/.zshenv ]] && builtin source $ZDOTDIR/.zshenv
# The user's .zshenv may move ZDOTDIR itself; their other files live there then.
_lilo_user_dir=$ZDOTDIR
ZDOTDIR=$_lilo_dir

[[ -o interactive ]] || _lilo_restore_zdotdir
