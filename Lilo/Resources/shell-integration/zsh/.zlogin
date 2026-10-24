ZDOTDIR=$_lilo_user_dir
[[ -f $ZDOTDIR/.zlogin ]] && builtin source $ZDOTDIR/.zlogin
_lilo_restore_zdotdir
