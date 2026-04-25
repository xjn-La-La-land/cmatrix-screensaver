# cmatrix-screensaver: bash adapter for launching `cmatrix` on prompt idle.

[[ $- == *i* ]] || return 0

if [[ -n ${CMSS_LOADED_BASH:-} ]] && declare -F cmss_disable >/dev/null 2>&1; then
  cmss_disable
fi
declare -g CMSS_LOADED_BASH=1

: "${CMSS_TIMEOUT:=30}"
: "${CMSS_COMMAND:=cmatrix -s -r}"
: "${CMSS_REQUIRE_VISIBLE_PANE:=1}"
: "${CMSS_BASH_WAKE_SIGNAL:=WINCH}"

declare -g CMSS_ENABLED=0
declare -g CMSS_RUNNING=0
declare -g CMSS_IN_COMMAND=0
declare -g CMSS_PROMPT_EMPTY=0
declare -g CMSS_LAST_ACTIVITY
CMSS_LAST_ACTIVITY=$(date +%s)
declare -g CMSS_TIMER_PID=0
declare -g CMSS_BASH_BINDINGS_INSTALLED=0

declare -gA CMSS_BASH_ORIG_BINDINGS=()
declare -gA CMSS_BASH_BIND_KEYSEQS=()
declare -ga CMSS_BASH_INSTALLED_BINDINGS=()
declare -ga CMSS_BASH_ORIG_PROMPT_COMMAND_ARRAY=()
declare -g CMSS_BASH_ORIG_PROMPT_COMMAND=
declare -g CMSS_BASH_PROMPT_COMMAND_WAS_SET=0
declare -g CMSS_BASH_PROMPT_COMMAND_WAS_ARRAY=0
declare -g CMSS_BASH_INSTALLED_WAKE_SIGNAL=
declare -g CMSS_BASH_ORIG_WAKE_TRAP=

__cmss_log() {
  if [[ -n ${CMSS_DEBUG:-} ]]; then
    printf 'cmss: %s\n' "$*" >&2
  fi
}

__cmss_mark_activity() {
  CMSS_LAST_ACTIVITY=$(date +%s)
}

__cmss_ensure_int() {
  local var_name=$1
  local default_value=$2
  local value=${!var_name-}

  if [[ ! $value =~ ^-?[0-9]+$ ]]; then
    printf -v "$var_name" '%s' "$default_value"
  fi
}

__cmss_normalize_state() {
  __cmss_ensure_int CMSS_TIMEOUT 30
  __cmss_ensure_int CMSS_REQUIRE_VISIBLE_PANE 1
  __cmss_ensure_int CMSS_ENABLED 0
  __cmss_ensure_int CMSS_RUNNING 0
  __cmss_ensure_int CMSS_IN_COMMAND 0
  __cmss_ensure_int CMSS_PROMPT_EMPTY 0
  __cmss_ensure_int CMSS_LAST_ACTIVITY "$(date +%s)"
  __cmss_ensure_int CMSS_TIMER_PID 0
  __cmss_ensure_int CMSS_BASH_BINDINGS_INSTALLED 0

  case $CMSS_BASH_WAKE_SIGNAL in
    WINCH | ALRM | INT) ;;
    *) CMSS_BASH_WAKE_SIGNAL=WINCH ;;
  esac
}

__cmss_cancel_timer() {
  __cmss_normalize_state

  if (( CMSS_TIMER_PID > 0 )); then
    kill "$CMSS_TIMER_PID" >/dev/null 2>&1 || true
    CMSS_TIMER_PID=0
  fi
}

__cmss_schedule_timer() {
  __cmss_normalize_state
  local timeout=$CMSS_TIMEOUT
  local target_pid=$BASHPID

  if (( CMSS_ENABLED != 1 || CMSS_RUNNING != 0 || CMSS_IN_COMMAND != 0 )); then
    __cmss_cancel_timer
    return 0
  fi

  if (( CMSS_PROMPT_EMPTY != 1 || timeout <= 0 )); then
    __cmss_cancel_timer
    return 0
  fi

  __cmss_cancel_timer
  CMSS_TIMER_PID=$(
    command sh -c '
      printf "%s\n" "$$"
      exec >/dev/null 2>&1
      sleep_pid=
      trap '\''if [ -n "$sleep_pid" ]; then kill "$sleep_pid" 2>/dev/null; fi; exit 0'\'' TERM INT HUP
      sleep "$1" &
      sleep_pid=$!
      wait "$sleep_pid" || exit 0
      kill -s "$3" "$2" >/dev/null 2>&1
    ' sh "$timeout" "$target_pid" "$CMSS_BASH_WAKE_SIGNAL" &
  )

  if [[ ! $CMSS_TIMER_PID =~ ^[0-9]+$ ]]; then
    CMSS_TIMER_PID=0
  fi

  __cmss_log "armed timer pid=${CMSS_TIMER_PID} timeout=${timeout}s"
}

__cmss_pane_is_visible() {
  __cmss_normalize_state

  if (( CMSS_REQUIRE_VISIBLE_PANE != 1 )); then
    return 0
  fi

  if [[ -z ${TMUX_PANE:-} ]]; then
    return 0
  fi

  if ! command -v tmux >/dev/null 2>&1; then
    __cmss_log "tmux not found while TMUX_PANE is set"
    return 1
  fi

  local tmux_state
  tmux_state=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_active}:#{window_active}:#{session_attached}' 2>/dev/null) || {
    __cmss_log "failed to query tmux pane visibility"
    return 1
  }

  local pane_active window_active session_attached
  IFS=: read -r pane_active window_active session_attached <<< "$tmux_state"
  if [[ -z $pane_active || -z $window_active || -z $session_attached ]]; then
    __cmss_log "unexpected tmux visibility format: ${tmux_state}"
    return 1
  fi

  if [[ $pane_active == 1 && $window_active == 1 && $session_attached != 0 ]]; then
    return 0
  fi

  __cmss_log "pane not visible: ${tmux_state}"
  return 1
}

__cmss_update_readline_state() {
  __cmss_mark_activity

  if [[ -z ${READLINE_LINE-} ]]; then
    CMSS_PROMPT_EMPTY=1
  else
    CMSS_PROMPT_EMPTY=0
  fi

  __cmss_schedule_timer
}

__cmss_bash_insert_char() {
  local hex=$1
  local char
  printf -v char '%b' "\\x${hex}"

  : "${READLINE_LINE:=}"
  : "${READLINE_POINT:=0}"
  READLINE_LINE="${READLINE_LINE:0:READLINE_POINT}${char}${READLINE_LINE:READLINE_POINT}"
  (( READLINE_POINT += 1 ))
  __cmss_update_readline_state
}

__cmss_bash_backward_delete_char() {
  : "${READLINE_LINE:=}"
  : "${READLINE_POINT:=0}"

  if (( READLINE_POINT > 0 )); then
    READLINE_LINE="${READLINE_LINE:0:READLINE_POINT - 1}${READLINE_LINE:READLINE_POINT}"
    (( READLINE_POINT -= 1 ))
  fi

  __cmss_update_readline_state
}

__cmss_bash_delete_char() {
  : "${READLINE_LINE:=}"
  : "${READLINE_POINT:=0}"

  if (( READLINE_POINT < ${#READLINE_LINE} )); then
    READLINE_LINE="${READLINE_LINE:0:READLINE_POINT}${READLINE_LINE:READLINE_POINT + 1}"
  fi

  __cmss_update_readline_state
}

__cmss_bash_backward_char() {
  : "${READLINE_POINT:=0}"
  if (( READLINE_POINT > 0 )); then
    (( READLINE_POINT -= 1 ))
  fi
  __cmss_update_readline_state
}

__cmss_bash_forward_char() {
  : "${READLINE_LINE:=}"
  : "${READLINE_POINT:=0}"
  if (( READLINE_POINT < ${#READLINE_LINE} )); then
    (( READLINE_POINT += 1 ))
  fi
  __cmss_update_readline_state
}

__cmss_bash_beginning_of_line() {
  READLINE_POINT=0
  __cmss_update_readline_state
}

__cmss_bash_end_of_line() {
  : "${READLINE_LINE:=}"
  READLINE_POINT=${#READLINE_LINE}
  __cmss_update_readline_state
}

__cmss_bash_unix_line_discard() {
  READLINE_LINE=
  READLINE_POINT=0
  __cmss_update_readline_state
}

__cmss_bash_kill_line() {
  : "${READLINE_LINE:=}"
  : "${READLINE_POINT:=0}"
  READLINE_LINE="${READLINE_LINE:0:READLINE_POINT}"
  __cmss_update_readline_state
}

__cmss_bash_lookup_for_hex() {
  local hex=$1
  local char

  case $hex in
    22) printf '%s' '\"' ;;
    5c) printf '%s' "\\\\" ;;
    *)
      printf -v char '%b' "\\x${hex}"
      printf '%s' "$char"
      ;;
  esac
}

__cmss_bash_find_binding() {
  local lookup=$1
  local prefix="\"${lookup}\":"
  local line

  while IFS= read -r line; do
    if [[ ${line:0:${#prefix}} == "$prefix" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < <(bind -p)

  return 1
}

__cmss_bash_save_binding() {
  local id=$1
  local lookup=$2
  local keyseq=$3
  local existing=

  existing=$(__cmss_bash_find_binding "$lookup" || true)
  CMSS_BASH_ORIG_BINDINGS[$id]=$existing
  CMSS_BASH_BIND_KEYSEQS[$id]=$keyseq
  CMSS_BASH_INSTALLED_BINDINGS+=("$id")
}

__cmss_bash_install_bind_x() {
  local id=$1
  local lookup=$2
  local keyseq=$3
  local command=$4

  __cmss_bash_save_binding "$id" "$lookup" "$keyseq"
  bind -x "\"${keyseq}\": ${command}"
}

__cmss_bash_install_key_bindings() {
  if (( CMSS_BASH_BINDINGS_INSTALLED == 1 )); then
    return 0
  fi

  local code hex lookup
  for code in {32..126}; do
    printf -v hex '%02x' "$code"
    lookup=$(__cmss_bash_lookup_for_hex "$hex")
    __cmss_bash_install_bind_x "char_${hex}" "$lookup" "\\x${hex}" "__cmss_bash_insert_char ${hex}"
  done

  __cmss_bash_install_bind_x key_ctrl_h '\C-h' '\C-h' __cmss_bash_backward_delete_char
  __cmss_bash_install_bind_x key_ctrl_question '\C-?' '\C-?' __cmss_bash_backward_delete_char
  __cmss_bash_install_bind_x key_delete '\e[3~' '\e[3~' __cmss_bash_delete_char
  __cmss_bash_install_bind_x key_left '\e[D' '\e[D' __cmss_bash_backward_char
  __cmss_bash_install_bind_x key_right '\e[C' '\e[C' __cmss_bash_forward_char
  __cmss_bash_install_bind_x key_home '\e[H' '\e[H' __cmss_bash_beginning_of_line
  __cmss_bash_install_bind_x key_end '\e[F' '\e[F' __cmss_bash_end_of_line
  __cmss_bash_install_bind_x key_home_tilde '\e[1~' '\e[1~' __cmss_bash_beginning_of_line
  __cmss_bash_install_bind_x key_end_tilde '\e[4~' '\e[4~' __cmss_bash_end_of_line
  __cmss_bash_install_bind_x key_ctrl_a '\C-a' '\C-a' __cmss_bash_beginning_of_line
  __cmss_bash_install_bind_x key_ctrl_e '\C-e' '\C-e' __cmss_bash_end_of_line
  __cmss_bash_install_bind_x key_ctrl_u '\C-u' '\C-u' __cmss_bash_unix_line_discard
  __cmss_bash_install_bind_x key_ctrl_k '\C-k' '\C-k' __cmss_bash_kill_line

  CMSS_BASH_BINDINGS_INSTALLED=1
}

__cmss_bash_restore_key_bindings() {
  if (( CMSS_BASH_BINDINGS_INSTALLED != 1 )); then
    return 0
  fi

  local id original keyseq
  for id in "${CMSS_BASH_INSTALLED_BINDINGS[@]}"; do
    original=${CMSS_BASH_ORIG_BINDINGS[$id]-}
    keyseq=${CMSS_BASH_BIND_KEYSEQS[$id]-}

    if [[ -n $original ]]; then
      bind "$original"
    elif [[ $id == char_* ]]; then
      bind "\"${keyseq}\": self-insert"
    elif [[ -n $keyseq ]]; then
      bind -r "$keyseq" >/dev/null 2>&1 || true
    fi
  done

  CMSS_BASH_INSTALLED_BINDINGS=()
  CMSS_BASH_ORIG_BINDINGS=()
  CMSS_BASH_BIND_KEYSEQS=()
  CMSS_BASH_BINDINGS_INSTALLED=0
}

__cmss_bash_install_prompt_command() {
  local prompt_decl
  prompt_decl=$(declare -p PROMPT_COMMAND 2>/dev/null || true)

  CMSS_BASH_PROMPT_COMMAND_WAS_SET=0
  CMSS_BASH_PROMPT_COMMAND_WAS_ARRAY=0
  CMSS_BASH_ORIG_PROMPT_COMMAND=
  CMSS_BASH_ORIG_PROMPT_COMMAND_ARRAY=()

  if [[ $prompt_decl == declare\ -a* ]]; then
    CMSS_BASH_PROMPT_COMMAND_WAS_SET=1
    CMSS_BASH_PROMPT_COMMAND_WAS_ARRAY=1
    CMSS_BASH_ORIG_PROMPT_COMMAND_ARRAY=("${PROMPT_COMMAND[@]}")
    PROMPT_COMMAND=("${PROMPT_COMMAND[@]}" __cmss_prompt_ready)
  else
    if [[ ${PROMPT_COMMAND+x} ]]; then
      CMSS_BASH_PROMPT_COMMAND_WAS_SET=1
      CMSS_BASH_ORIG_PROMPT_COMMAND=$PROMPT_COMMAND
    fi

    if [[ -n ${PROMPT_COMMAND:-} ]]; then
      PROMPT_COMMAND="${PROMPT_COMMAND%;}; __cmss_prompt_ready"
    else
      PROMPT_COMMAND=__cmss_prompt_ready
    fi
  fi
}

__cmss_bash_restore_prompt_command() {
  if (( CMSS_BASH_PROMPT_COMMAND_WAS_ARRAY == 1 )); then
    PROMPT_COMMAND=("${CMSS_BASH_ORIG_PROMPT_COMMAND_ARRAY[@]}")
  elif (( CMSS_BASH_PROMPT_COMMAND_WAS_SET == 1 )); then
    unset PROMPT_COMMAND
    # shellcheck disable=SC2178
    PROMPT_COMMAND=$CMSS_BASH_ORIG_PROMPT_COMMAND
  else
    unset PROMPT_COMMAND
  fi
}

__cmss_bash_install_signal_handler() {
  CMSS_BASH_INSTALLED_WAKE_SIGNAL=$CMSS_BASH_WAKE_SIGNAL
  CMSS_BASH_ORIG_WAKE_TRAP=$(trap -p "$CMSS_BASH_WAKE_SIGNAL" || true)
  trap '__cmss_signal_handler' "$CMSS_BASH_WAKE_SIGNAL"
}

__cmss_bash_restore_signal_handler() {
  local wake_signal=${CMSS_BASH_INSTALLED_WAKE_SIGNAL:-$CMSS_BASH_WAKE_SIGNAL}

  if [[ -n $CMSS_BASH_ORIG_WAKE_TRAP ]]; then
    eval "$CMSS_BASH_ORIG_WAKE_TRAP"
  else
    trap - "$wake_signal"
  fi

  CMSS_BASH_INSTALLED_WAKE_SIGNAL=
  CMSS_BASH_ORIG_WAKE_TRAP=
}

__cmss_prompt_ready() {
  __cmss_normalize_state

  if (( CMSS_ENABLED != 1 )); then
    return 0
  fi

  CMSS_IN_COMMAND=0
  CMSS_PROMPT_EMPTY=1
  __cmss_mark_activity
  __cmss_schedule_timer
  __cmss_log "prompt ready"
}

__cmss_run_screensaver() {
  __cmss_normalize_state
  local now elapsed tty_state rc command_name
  now=$(date +%s)

  if (( CMSS_ENABLED != 1 || CMSS_RUNNING != 0 || CMSS_IN_COMMAND != 0 || CMSS_PROMPT_EMPTY != 1 )); then
    return 0
  fi

  elapsed=$(( now - CMSS_LAST_ACTIVITY ))
  if (( elapsed < CMSS_TIMEOUT )); then
    return 0
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    return 0
  fi

  if ! __cmss_pane_is_visible; then
    return 0
  fi

  read -r command_name _ <<< "$CMSS_COMMAND"
  if [[ -z $command_name ]]; then
    return 0
  fi

  if [[ $command_name == */* ]]; then
    if [[ ! -x $command_name ]]; then
      __cmss_log "command not executable: ${command_name}"
      return 0
    fi
  elif ! command -v "$command_name" >/dev/null 2>&1; then
    __cmss_log "command not found: ${command_name}"
    return 0
  fi

  CMSS_RUNNING=1
  __cmss_cancel_timer
  tty_state=$(stty -g 2>/dev/null || true)
  __cmss_log "launching screensaver"

  eval "$CMSS_COMMAND"
  rc=$?

  if [[ -n $tty_state ]]; then
    stty "$tty_state" >/dev/null 2>&1 || true
  fi

  CMSS_RUNNING=0
  CMSS_PROMPT_EMPTY=1
  __cmss_mark_activity
  __cmss_schedule_timer
  __cmss_log "screensaver exited rc=${rc}"
  return 0
}

__cmss_signal_handler() {
  __cmss_normalize_state
  __cmss_run_screensaver
  __cmss_schedule_timer
}

cmss_enable() {
  __cmss_normalize_state

  if (( CMSS_ENABLED == 1 )); then
    CMSS_PROMPT_EMPTY=1
    __cmss_mark_activity
    __cmss_schedule_timer
    return 0
  fi

  __cmss_bash_install_prompt_command
  __cmss_bash_install_signal_handler
  __cmss_bash_install_key_bindings
  CMSS_ENABLED=1
  CMSS_RUNNING=0
  CMSS_IN_COMMAND=0
  CMSS_PROMPT_EMPTY=1
  __cmss_mark_activity
  __cmss_schedule_timer
  __cmss_log "enabled"
}

cmss_disable() {
  __cmss_normalize_state

  if (( CMSS_ENABLED != 1 )); then
    return 0
  fi

  __cmss_cancel_timer
  __cmss_bash_restore_key_bindings
  __cmss_bash_restore_signal_handler
  __cmss_bash_restore_prompt_command
  CMSS_ENABLED=0
  CMSS_RUNNING=0
  CMSS_IN_COMMAND=0
  CMSS_PROMPT_EMPTY=0
  __cmss_log "disabled"
}

cmss_status() {
  __cmss_normalize_state
  local state=prompt-editing
  local pane_visible=0

  if (( CMSS_RUNNING == 1 )); then
    state=screensaver
  elif (( CMSS_IN_COMMAND == 1 )); then
    state=busy
  elif (( CMSS_PROMPT_EMPTY == 1 )); then
    state=prompt-empty
  fi

  if __cmss_pane_is_visible; then
    pane_visible=1
  fi

  printf 'enabled=%s state=%s timeout=%s require_visible_pane=%s pane_visible=%s last_activity=%s timer_pid=%s\n' \
    "$CMSS_ENABLED" "$state" "$CMSS_TIMEOUT" "$CMSS_REQUIRE_VISIBLE_PANE" "$pane_visible" "$CMSS_LAST_ACTIVITY" "$CMSS_TIMER_PID"
}

__cmss_normalize_state
cmss_enable
