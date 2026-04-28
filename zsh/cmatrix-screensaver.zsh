# cmatrix-screensaver: zsh prototype for launching `cmatrix -s` on prompt idle.

if [[ -n ${CMSS_LOADED:-} ]]; then
  return 0
fi
typeset -g CMSS_LOADED=1

if [[ ! -o interactive ]]; then
  return 0
fi

autoload -Uz add-zsh-hook
zmodload zsh/datetime || return 1

typeset -gi CMSS_TIMEOUT=${CMSS_TIMEOUT:-30}
typeset -g CMSS_COMMAND=${CMSS_COMMAND:-'cmatrix -s -r'}
typeset -gi CMSS_REQUIRE_VISIBLE_PANE=${CMSS_REQUIRE_VISIBLE_PANE:-1}

typeset -gi CMSS_ENABLED=0
typeset -gi CMSS_RUNNING=0
typeset -gi CMSS_IN_COMMAND=0
typeset -gi CMSS_PROMPT_EMPTY=0
typeset -gi CMSS_LAST_ACTIVITY=$EPOCHSECONDS
typeset -gi CMSS_TIMER_PID=0
typeset -gA CMSS_ORIG_WIDGETS

function __cmss_log() {
  if [[ -n ${CMSS_DEBUG:-} ]]; then
    print -u2 -- "cmss: $*"
  fi
}

function __cmss_cancel_timer() {
  if (( CMSS_TIMER_PID > 0 )); then
    kill "${CMSS_TIMER_PID}" 2>/dev/null || true
    CMSS_TIMER_PID=0
  fi
}

function __cmss_schedule_timer() {
  local timeout=${CMSS_TIMEOUT:-300}

  if (( ! CMSS_ENABLED || CMSS_RUNNING || CMSS_IN_COMMAND )); then
    __cmss_cancel_timer
    return 0
  fi

  if (( ! CMSS_PROMPT_EMPTY )); then
    __cmss_cancel_timer
    return 0
  fi

  if (( timeout <= 0 )); then
    __cmss_cancel_timer
    return 0
  fi

  __cmss_cancel_timer
  (
    sleep "${timeout}"
    kill -s USR1 "$$" 2>/dev/null
  ) >/dev/null 2>&1 &!
  CMSS_TIMER_PID=$!
  __cmss_log "armed timer pid=${CMSS_TIMER_PID} timeout=${timeout}s"
}

function __cmss_mark_activity() {
  CMSS_LAST_ACTIVITY=$EPOCHSECONDS
}

function __cmss_pane_is_visible() {
  local tmux_state
  local -a tmux_fields

  if (( ! CMSS_REQUIRE_VISIBLE_PANE )); then
    return 0
  fi

  if [[ -z ${TMUX_PANE:-} ]]; then
    return 0
  fi

  if (( ! ${+commands[tmux]} )); then
    __cmss_log "tmux not found while TMUX_PANE is set"
    return 1
  fi

  tmux_state=$(tmux display-message -p -t "${TMUX_PANE}" '#{pane_active}:#{window_active}:#{session_attached}' 2>/dev/null) || {
    __cmss_log "failed to query tmux pane visibility"
    return 1
  }

  tmux_fields=(${(s.:.)tmux_state})
  if (( ${#tmux_fields[@]} != 3 )); then
    __cmss_log "unexpected tmux visibility format: ${tmux_state}"
    return 1
  fi

  if [[ ${tmux_fields[1]} == 1 && ${tmux_fields[2]} == 1 && ${tmux_fields[3]} != 0 ]]; then
    return 0
  fi

  __cmss_log "pane not visible: ${tmux_state}"
  return 1
}

function __cmss_save_widget() {
  local widget=$1
  local alias="__cmss_orig_${widget//-/_}"

  if (( ${+widgets[$widget]} )); then
    zle -A "${widget}" "${alias}"
    CMSS_ORIG_WIDGETS[$widget]="${alias}"
  else
    CMSS_ORIG_WIDGETS[$widget]=''
  fi
}

function __cmss_restore_widget() {
  local widget=$1
  local alias=${CMSS_ORIG_WIDGETS[$widget]:-}

  if [[ -n ${alias} ]]; then
    zle -A "${alias}" "${widget}"
    zle -D "${alias}" 2>/dev/null || true
  else
    zle -D "${widget}" 2>/dev/null || true
  fi

  unset "CMSS_ORIG_WIDGETS[$widget]"
}

function __cmss_call_saved_widget() {
  local widget=$1
  local alias=${CMSS_ORIG_WIDGETS[$widget]:-}

  if [[ -n ${alias} && -n ${widgets[$alias]:-} ]]; then
    zle "${alias}"
  fi
}

function __cmss_update_prompt_state() {
  __cmss_mark_activity

  if [[ -z ${BUFFER:-} ]]; then
    CMSS_PROMPT_EMPTY=1
  else
    CMSS_PROMPT_EMPTY=0
  fi

  __cmss_schedule_timer
}

function __cmss_preexec() {
  CMSS_IN_COMMAND=1
  CMSS_PROMPT_EMPTY=0
  __cmss_mark_activity
  __cmss_cancel_timer
  __cmss_log "command started"
}

function __cmss_precmd() {
  CMSS_IN_COMMAND=0
  CMSS_PROMPT_EMPTY=1
  __cmss_mark_activity
  __cmss_schedule_timer
  __cmss_log "prompt ready"
}

function __cmss_zle_line_init() {
  __cmss_call_saved_widget zle-line-init
  __cmss_update_prompt_state
}

function __cmss_zle_line_pre_redraw() {
  __cmss_call_saved_widget zle-line-pre-redraw
  __cmss_update_prompt_state
}

function __cmss_zle_keymap_select() {
  __cmss_call_saved_widget zle-keymap-select
  __cmss_update_prompt_state
}

function __cmss_zle_line_finish() {
  __cmss_cancel_timer
  __cmss_call_saved_widget zle-line-finish
}

function __cmss_run_screensaver() {
  local now=$EPOCHSECONDS
  local timeout=${CMSS_TIMEOUT:-300}
  local tty_state rc
  local -a command_argv

  if (( ! CMSS_ENABLED || CMSS_RUNNING || CMSS_IN_COMMAND || ! CMSS_PROMPT_EMPTY )); then
    return 0
  fi

  if (( now - CMSS_LAST_ACTIVITY < timeout )); then
    return 0
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    return 0
  fi

  if ! __cmss_pane_is_visible; then
    return 0
  fi

  command_argv=(${(z)CMSS_COMMAND})
  if (( ${#command_argv[@]} == 0 )); then
    return 0
  fi

  if [[ ${command_argv[1]} == */* ]]; then
    if [[ ! -x ${command_argv[1]} ]]; then
      __cmss_log "command not executable: ${command_argv[1]}"
      return 0
    fi
  elif (( ! ${+commands[${command_argv[1]}]} )); then
    __cmss_log "command not found: ${command_argv[1]}"
    return 0
  fi

  CMSS_RUNNING=1
  __cmss_cancel_timer
  tty_state=$(stty -g 2>/dev/null) || tty_state=
  __cmss_log "launching screensaver"

  "${command_argv[@]}"
  rc=$?

  if [[ -n ${tty_state} ]]; then
    stty "${tty_state}" 2>/dev/null || true
  fi

  CMSS_RUNNING=0
  CMSS_PROMPT_EMPTY=1
  __cmss_mark_activity
  zle reset-prompt >/dev/null 2>&1 || true
  __cmss_schedule_timer
  __cmss_log "screensaver exited rc=${rc}"
  return 0
}

function TRAPUSR1() {
  __cmss_run_screensaver
  __cmss_schedule_timer
  return 0
}

function cmss_enable() {
  if (( CMSS_ENABLED )); then
    return 0
  fi

  add-zsh-hook preexec __cmss_preexec
  add-zsh-hook precmd __cmss_precmd
  __cmss_save_widget zle-line-init
  __cmss_save_widget zle-line-pre-redraw
  __cmss_save_widget zle-keymap-select
  __cmss_save_widget zle-line-finish
  zle -N zle-line-init __cmss_zle_line_init
  zle -N zle-line-pre-redraw __cmss_zle_line_pre_redraw
  zle -N zle-keymap-select __cmss_zle_keymap_select
  zle -N zle-line-finish __cmss_zle_line_finish

  CMSS_ENABLED=1
  CMSS_RUNNING=0
  CMSS_IN_COMMAND=0
  CMSS_PROMPT_EMPTY=1
  __cmss_mark_activity
  __cmss_schedule_timer
  __cmss_log "enabled"
}

function cmss_disable() {
  if (( ! CMSS_ENABLED )); then
    return 0
  fi

  add-zsh-hook -d preexec __cmss_preexec 2>/dev/null || true
  add-zsh-hook -d precmd __cmss_precmd 2>/dev/null || true
  __cmss_restore_widget zle-line-init
  __cmss_restore_widget zle-line-pre-redraw
  __cmss_restore_widget zle-keymap-select
  __cmss_restore_widget zle-line-finish
  __cmss_cancel_timer
  CMSS_ENABLED=0
  CMSS_RUNNING=0
  CMSS_IN_COMMAND=0
  CMSS_PROMPT_EMPTY=0
  __cmss_log "disabled"
}

function cmss_now() {
  local tty_state rc
  local -a command_argv

  if (( CMSS_RUNNING )); then
    print -u2 -- "cmss: screensaver is already running"
    return 1
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    print -u2 -- "cmss: not attached to a terminal"
    return 1
  fi

  command_argv=(${(z)CMSS_COMMAND})
  if (( ${#command_argv[@]} == 0 )); then
    print -u2 -- "cmss: CMSS_COMMAND is empty"
    return 1
  fi

  if [[ ${command_argv[1]} == */* ]]; then
    if [[ ! -x ${command_argv[1]} ]]; then
      print -u2 -- "cmss: command not executable: ${command_argv[1]}"
      return 1
    fi
  elif (( ! ${+commands[${command_argv[1]}]} )); then
    print -u2 -- "cmss: command not found: ${command_argv[1]}"
    return 1
  fi

  CMSS_RUNNING=1
  __cmss_cancel_timer
  tty_state=$(stty -g 2>/dev/null) || tty_state=
  __cmss_log "launching screensaver via cmss_now"

  "${command_argv[@]}"
  rc=$?

  if [[ -n ${tty_state} ]]; then
    stty "${tty_state}" 2>/dev/null || true
  fi

  CMSS_RUNNING=0
  __cmss_mark_activity
  __cmss_log "screensaver exited rc=${rc}"
  return $rc
}

function cmss_status() {
  local state
  local pane_visible="unknown"

  if (( CMSS_RUNNING )); then
    state="screensaver"
  elif (( CMSS_IN_COMMAND )); then
    state="busy"
  elif (( CMSS_PROMPT_EMPTY )); then
    state="prompt-empty"
  else
    state="prompt-editing"
  fi

  if __cmss_pane_is_visible; then
    pane_visible="1"
  else
    pane_visible="0"
  fi

  print -- "enabled=${CMSS_ENABLED} state=${state} timeout=${CMSS_TIMEOUT} require_visible_pane=${CMSS_REQUIRE_VISIBLE_PANE} pane_visible=${pane_visible} last_activity=${CMSS_LAST_ACTIVITY} timer_pid=${CMSS_TIMER_PID}"
}

cmss_enable
