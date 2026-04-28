# cmatrix-screensaver: fish prototype for launching `cmatrix` on prompt idle.

if not status is-interactive
    return
end

if set -q CMSS_LOADED_FISH
    return
end
set -g CMSS_LOADED_FISH 1

if not set -q CMSS_TIMEOUT
    set -g CMSS_TIMEOUT 30
end

if not set -q CMSS_COMMAND
    set -g CMSS_COMMAND 'cmatrix -s -r'
end

if not set -q CMSS_REQUIRE_VISIBLE_PANE
    set -g CMSS_REQUIRE_VISIBLE_PANE 1
end

set -g CMSS_CORE (dirname (status filename))/../bin/cmss-core

set -g CMSS_ENABLED 0
set -g CMSS_RUNNING 0
set -g CMSS_IN_COMMAND 0
set -g CMSS_PROMPT_EMPTY 0
set -g CMSS_LAST_ACTIVITY (date +%s)
set -g CMSS_TIMER_PID 0
set -g CMSS_FISH_BINDINGS_INSTALLED 0
set -g CMSS_FISH_DEFAULT_GENERIC_INSTALLED 0

function __cmss_log
    if set -q CMSS_DEBUG
        echo "cmss: $argv" >&2
    end
end

function __cmss_mark_activity
    set -g CMSS_LAST_ACTIVITY (date +%s)
end

function __cmss_ensure_int
    set -l var_name $argv[1]
    set -l default_value $argv[2]

    if not set -q $var_name
        set -g $var_name $default_value
        return 0
    end

    set -l value $$var_name
    if test (count $value) -eq 0
        set -g $var_name $default_value
        return 0
    end

    if not string match -qr '^-?[0-9]+$' -- "$value[1]"
        set -g $var_name $default_value
        return 0
    end

    if test (count $value) -gt 1
        set -g $var_name $value[1]
    end
end

function __cmss_normalize_state
    __cmss_ensure_int CMSS_TIMEOUT 30
    __cmss_ensure_int CMSS_REQUIRE_VISIBLE_PANE 1
    __cmss_ensure_int CMSS_ENABLED 0
    __cmss_ensure_int CMSS_RUNNING 0
    __cmss_ensure_int CMSS_IN_COMMAND 0
    __cmss_ensure_int CMSS_PROMPT_EMPTY 0
    __cmss_ensure_int CMSS_LAST_ACTIVITY (date +%s)
    __cmss_ensure_int CMSS_TIMER_PID 0
    __cmss_ensure_int CMSS_FISH_BINDINGS_INSTALLED 0
    __cmss_ensure_int CMSS_FISH_DEFAULT_GENERIC_INSTALLED 0
end

function __cmss_cancel_timer
    __cmss_normalize_state

    if test "$CMSS_TIMER_PID" -gt 0
        sh "$CMSS_CORE" timer-stop "$CMSS_TIMER_PID" >/dev/null 2>&1
        set -g CMSS_TIMER_PID 0
    end
end

function __cmss_schedule_timer
    __cmss_normalize_state
    set -l timeout $CMSS_TIMEOUT

    if test "$CMSS_ENABLED" -ne 1
        __cmss_cancel_timer
        return 0
    end

    if test "$CMSS_RUNNING" -ne 0
        __cmss_cancel_timer
        return 0
    end

    if test "$CMSS_IN_COMMAND" -ne 0
        __cmss_cancel_timer
        return 0
    end

    if test "$CMSS_PROMPT_EMPTY" -ne 1
        __cmss_cancel_timer
        return 0
    end

    if test "$timeout" -le 0
        __cmss_cancel_timer
        return 0
    end

    __cmss_cancel_timer
    set -l watchdog (sh "$CMSS_CORE" timer-start "$fish_pid" USR1 "$timeout" 2>/dev/null)
    if string match -qr '^[0-9]+$' -- "$watchdog"
        set -g CMSS_TIMER_PID $watchdog
    else
        set -g CMSS_TIMER_PID 0
    end
    __cmss_log "armed timer pid=$CMSS_TIMER_PID timeout=$timeout"
end

function __cmss_pane_is_visible
    __cmss_normalize_state
    CMSS_REQUIRE_VISIBLE_PANE=$CMSS_REQUIRE_VISIBLE_PANE sh "$CMSS_CORE" pane-visible
end

function __cmss_update_prompt_state
    __cmss_mark_activity

    set -l current_buffer (commandline --current-buffer 2>/dev/null)
    if test $status -ne 0
        return 0
    end

    if test -z "$current_buffer"
        set -g CMSS_PROMPT_EMPTY 1
    else
        set -g CMSS_PROMPT_EMPTY 0
    end

    __cmss_schedule_timer
end

function __cmss_note_prompt_activity
    __cmss_normalize_state

    if test "$CMSS_ENABLED" -ne 1
        return 0
    end

    if test "$CMSS_IN_COMMAND" -ne 0
        return 0
    end

    __cmss_update_prompt_state
end

function __cmss_uses_vi_bindings
    if not set -q fish_key_bindings
        return 1
    end

    if string match -q 'fish_vi_*' -- "$fish_key_bindings"
        return 0
    end

    if string match -q 'fish_hybrid_*' -- "$fish_key_bindings"
        return 0
    end

    return 1
end

function __cmss_binding_generic_var
    set -l mode $argv[1]
    set -l key $argv[2]

    if test -z "$key"
        set key generic
    end

    set key (string replace -a '-' '_' -- "$key")
    echo CMSS_BIND_ORIG_$mode'_'$key
end

function __cmss_save_binding
    set -l mode $argv[1]
    set -l key $argv[2]
    set -l var_name (__cmss_binding_generic_var "$mode" "$key")
    set -l existing (bind --user -M "$mode" "$key" 2>/dev/null)

    set -g $var_name $existing
end

function __cmss_restore_binding
    set -l mode $argv[1]
    set -l key $argv[2]
    set -l var_name (__cmss_binding_generic_var "$mode" "$key")

    if set -q $var_name
        set -l existing $$var_name
        if test (count $existing) -gt 0
            eval $existing
        else
            bind --user -e -M "$mode" "$key" >/dev/null 2>&1
        end
        set -e $var_name
    else
        bind --user -e -M "$mode" "$key" >/dev/null 2>&1
    end
end

function __cmss_install_binding
    set -l mode $argv[1]
    set -l key $argv[2]
    set -l commands $argv[3..-1]

    __cmss_save_binding "$mode" "$key"
    bind --user -M "$mode" "$key" $commands
end

function __cmss_install_key_bindings
    if test "$CMSS_FISH_BINDINGS_INSTALLED" -eq 1
        return 0
    end

    if not __cmss_uses_vi_bindings
        __cmss_install_binding default '' self-insert __cmss_note_prompt_activity
        set -g CMSS_FISH_DEFAULT_GENERIC_INSTALLED 1
    end

    __cmss_install_binding insert '' self-insert __cmss_note_prompt_activity

    for mode in default insert visual
        __cmss_install_binding $mode backspace backward-delete-char __cmss_note_prompt_activity
        __cmss_install_binding $mode delete delete-char __cmss_note_prompt_activity
        __cmss_install_binding $mode left backward-char __cmss_note_prompt_activity
        __cmss_install_binding $mode right forward-char __cmss_note_prompt_activity
        __cmss_install_binding $mode up up-or-search __cmss_note_prompt_activity
        __cmss_install_binding $mode down down-or-search __cmss_note_prompt_activity
        __cmss_install_binding $mode home beginning-of-line __cmss_note_prompt_activity
        __cmss_install_binding $mode end end-of-line __cmss_note_prompt_activity
        __cmss_install_binding $mode tab complete __cmss_note_prompt_activity
        __cmss_install_binding $mode enter __cmss_note_prompt_activity execute
        __cmss_install_binding $mode ctrl-c cancel-commandline repaint __cmss_note_prompt_activity
        __cmss_install_binding $mode ctrl-l clear-screen repaint __cmss_note_prompt_activity
    end

    set -g CMSS_FISH_BINDINGS_INSTALLED 1
end

function __cmss_restore_key_bindings
    if test "$CMSS_FISH_BINDINGS_INSTALLED" -ne 1
        return 0
    end

    if test "$CMSS_FISH_DEFAULT_GENERIC_INSTALLED" -eq 1
        __cmss_restore_binding default ''
        set -g CMSS_FISH_DEFAULT_GENERIC_INSTALLED 0
    end

    __cmss_restore_binding insert ''

    for mode in default insert visual
        __cmss_restore_binding $mode backspace
        __cmss_restore_binding $mode delete
        __cmss_restore_binding $mode left
        __cmss_restore_binding $mode right
        __cmss_restore_binding $mode up
        __cmss_restore_binding $mode down
        __cmss_restore_binding $mode home
        __cmss_restore_binding $mode end
        __cmss_restore_binding $mode tab
        __cmss_restore_binding $mode enter
        __cmss_restore_binding $mode ctrl-c
        __cmss_restore_binding $mode ctrl-l
    end

    set -g CMSS_FISH_BINDINGS_INSTALLED 0
end

function __cmss_preexec --on-event fish_preexec
    __cmss_normalize_state

    if test "$CMSS_ENABLED" -ne 1
        return 0
    end

    set -g CMSS_IN_COMMAND 1
    set -g CMSS_PROMPT_EMPTY 0
    __cmss_mark_activity
    __cmss_cancel_timer
    __cmss_log "command started"
end

function __cmss_prompt_ready --on-event fish_prompt
    __cmss_normalize_state

    if test "$CMSS_ENABLED" -ne 1
        return 0
    end

    set -g CMSS_IN_COMMAND 0
    set -g CMSS_PROMPT_EMPTY 1
    __cmss_mark_activity
    __cmss_schedule_timer
    __cmss_log "prompt ready"
end

function __cmss_postexec --on-event fish_postexec
    __cmss_normalize_state

    if test "$CMSS_ENABLED" -ne 1
        return 0
    end

    set -g CMSS_IN_COMMAND 0
    __cmss_update_prompt_state
end

function __cmss_posterror --on-event fish_posterror
    __cmss_normalize_state

    if test "$CMSS_ENABLED" -ne 1
        return 0
    end

    set -g CMSS_IN_COMMAND 0
    __cmss_update_prompt_state
end

function __cmss_cancel_event --on-event fish_cancel
    __cmss_normalize_state

    if test "$CMSS_ENABLED" -ne 1
        return 0
    end

    __cmss_update_prompt_state
end

function __cmss_run_screensaver
    __cmss_normalize_state
    set -l now (date +%s)
    set -l tty_state ''

    if test "$CMSS_ENABLED" -ne 1
        return 0
    end

    if test "$CMSS_RUNNING" -ne 0
        return 0
    end

    if test "$CMSS_IN_COMMAND" -ne 0
        return 0
    end

    if test "$CMSS_PROMPT_EMPTY" -ne 1
        return 0
    end

    set -l elapsed (math "$now - $CMSS_LAST_ACTIVITY")
    if test "$elapsed" -lt "$CMSS_TIMEOUT"
        return 0
    end

    if not isatty stdin
        return 0
    end

    if not isatty stdout
        return 0
    end

    if not __cmss_pane_is_visible
        return 0
    end

    set -l command_argv (string split -n ' ' -- "$CMSS_COMMAND")
    if test (count $command_argv) -eq 0
        return 0
    end

    set -l command_name $command_argv[1]
    if string match -q '*/*' -- "$command_name"
        if not test -x "$command_name"
            __cmss_log "command not executable: $command_name"
            return 0
        end
    else if not type -q "$command_name"
        __cmss_log "command not found: $command_name"
        return 0
    end

    set -g CMSS_RUNNING 1
    __cmss_cancel_timer
    set tty_state (stty -g 2>/dev/null)
    __cmss_log "launching screensaver"

    eval $CMSS_COMMAND
    set -l rc $status

    if test -n "$tty_state"
        stty "$tty_state" >/dev/null 2>&1
    end

    set -g CMSS_RUNNING 0
    set -g CMSS_PROMPT_EMPTY 1
    __cmss_mark_activity
    commandline -f repaint >/dev/null 2>&1
    __cmss_schedule_timer
    __cmss_log "screensaver exited rc=$rc"
    return 0
end

function __cmss_signal_handler --on-signal USR1
    __cmss_normalize_state
    __cmss_run_screensaver
    __cmss_schedule_timer
end

function cmss_enable
    __cmss_normalize_state

    if test "$CMSS_ENABLED" -eq 1
        return 0
    end

    set -g CMSS_ENABLED 1
    set -g CMSS_RUNNING 0
    set -g CMSS_IN_COMMAND 0
    set -g CMSS_PROMPT_EMPTY 1
    __cmss_mark_activity
    __cmss_install_key_bindings
    __cmss_schedule_timer
    __cmss_log "enabled"
end

function cmss_disable
    __cmss_normalize_state

    if test "$CMSS_ENABLED" -ne 1
        return 0
    end

    __cmss_cancel_timer
    __cmss_restore_key_bindings
    set -g CMSS_ENABLED 0
    set -g CMSS_RUNNING 0
    set -g CMSS_IN_COMMAND 0
    set -g CMSS_PROMPT_EMPTY 0
    __cmss_log "disabled"
end

function cmss_now
    __cmss_normalize_state
    set -l tty_state ''

    if test "$CMSS_RUNNING" -eq 1
        echo "cmss: screensaver is already running" >&2
        return 1
    end

    if not isatty stdin; or not isatty stdout
        echo "cmss: not attached to a terminal" >&2
        return 1
    end

    set -l command_argv (string split -n ' ' -- "$CMSS_COMMAND")
    if test (count $command_argv) -eq 0
        echo "cmss: CMSS_COMMAND is empty" >&2
        return 1
    end

    set -l command_name $command_argv[1]
    if string match -q '*/*' -- "$command_name"
        if not test -x "$command_name"
            echo "cmss: command not executable: $command_name" >&2
            return 1
        end
    else if not type -q "$command_name"
        echo "cmss: command not found: $command_name" >&2
        return 1
    end

    set -g CMSS_RUNNING 1
    __cmss_cancel_timer
    set tty_state (stty -g 2>/dev/null)
    __cmss_log "launching screensaver via cmss_now"

    eval $CMSS_COMMAND
    set -l rc $status

    if test -n "$tty_state"
        stty "$tty_state" >/dev/null 2>&1
    end

    set -g CMSS_RUNNING 0
    __cmss_mark_activity
    __cmss_log "screensaver exited rc=$rc"
    return $rc
end

function cmss_status
    __cmss_normalize_state
    set -l state prompt-editing
    set -l pane_visible 0

    if test "$CMSS_RUNNING" -eq 1
        set state screensaver
    else if test "$CMSS_IN_COMMAND" -eq 1
        set state busy
    else if test "$CMSS_PROMPT_EMPTY" -eq 1
        set state prompt-empty
    end

    if __cmss_pane_is_visible
        set pane_visible 1
    end

    echo "enabled=$CMSS_ENABLED state=$state timeout=$CMSS_TIMEOUT require_visible_pane=$CMSS_REQUIRE_VISIBLE_PANE pane_visible=$pane_visible last_activity=$CMSS_LAST_ACTIVITY timer_pid=$CMSS_TIMER_PID"
end

__cmss_normalize_state
cmss_enable
