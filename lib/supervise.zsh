# `remote-agents run NAME`: keep one Remote Control server running in the foreground.
#
# This is the process a host (a LaunchAgent, a terminal tab) runs for each server. It starts
# `claude remote-control` in the server's folder and starts it again whenever it exits: the server
# exits on its own after ten minutes without the network (it keeps its environment when it does),
# when its login expires, on a crash, and when `remote-agents restart` stops it.

supervisor_lock() { print -r -- $RA_STATE/locks/server.$1.lock }
# Held for the moment in which a server is started, or marked as stopped on purpose.
op_lock() { print -r -- $RA_STATE/locks/op.$1.lock }
mark_paused() { : >| $RA_STATE/paused/$1 }

# Is a supervisor alive for NAME? It holds the lock for as long as it runs.
supervisor_running() {
  local f=$(supervisor_lock $1) fd
  [[ -e $f ]] || return 1
  if zsystem flock -t 0 -f fd $f 2>/dev/null; then
    zsystem flock -u $fd
    return 1
  fi
  return 0
}

wait_gone() {  # PID SECONDS: wait until the process is gone; fail when it is still there
  local i
  for (( i = 0; i < $2 * 5; i++ )); do kill -0 $1 2>/dev/null || return 0; sleep 0.2; done
  return 1
}

cmd_run() {
  local name=$1
  [[ -n $name ]] || die "usage: remote-agents run NAME"
  load_config || die "no usable config at $RA_CONFIG"
  need_server $name
  ensure_dirs
  local dir=$(srv_dir $name) lock=$(supervisor_lock $name) lockfd
  cd $dir || die "cannot enter $dir"
  : >>| $lock
  if ! zsystem flock -t 0 -f lockfd $lock 2>/dev/null; then
    log "$name: another supervisor already runs this server"
    sleep 30   # a host that restarts us at once would otherwise spin
    return 0
  fi
  scrub_env

  local child=0 last_int=0 started ran pause said='' pid exe short=0 code
  local -a sargv
  trap 'last_int=$EPOCHSECONDS' INT
  # Told to stop from outside (the host is going away: logout, the tab was closed, uninstall).
  # Stop the server the way that keeps its environment, and wait for it.
  trap '(( child )) && { kill -TERM $child 2>/dev/null; wait_gone $child 90 }; exit 0' TERM HUP

  say_once() { [[ $said == $1 ]] || { said=$1; log "$name: $1" } }
  spawn_server() {
    [[ -e $RA_STATE/paused/$name ]] && return 0
    log "$name: starting claude ${sargv[*]}"
    if [[ -t 1 ]]; then
      $exe "${sargv[@]}" &
    else
      $exe "${sargv[@]}" > >(log_filter) 2>&1 &
    fi
    child=$!
  }

  while true; do
    load_config   # a broken config keeps the last good one
    (( ${SERVERS[(Ie)$name]} )) || { log "$name: no longer in the config; supervisor ends"; return 0 }
    if [[ $(srv_dir $name) != $dir ]]; then
      log "$name: its folder changed in the config ($dir -> $(srv_dir $name)); supervisor ends, the host starts a new one there"
      return 0
    fi
    if [[ -e $RA_STATE/paused/$name ]]; then
      say_once "paused (remote-agents start $name resumes it)"
      sleep 5; continue
    fi
    if pid=$(server_pid $dir); then
      say_once "the folder is already served by pid $pid, which this supervisor did not start; waiting for it to end"
      sleep 30; continue
    fi
    # Starting offline only burns the server's ten minutes of patience.
    if ! network_up; then
      say_once "waiting for the network"
      sleep 15; continue
    fi
    if ! claude_logged_in; then
      : >| $RA_STATE/auth-failed
      say_once "Claude Code is not signed in (claude auth login); checking again every 5 minutes"
      sleep 300; continue
    fi
    rm -f $RA_STATE/auth-failed
    said=''

    exe=$(claude_bin)
    server_argv $name; sargv=("${reply[@]}")
    started=$EPOCHSECONDS
    # `stop` may have paused the server while we were waiting for the network or the login.
    # Looking at the mark and starting the server is one step, under the lock `stop` takes too.
    child=0
    with_lock $(op_lock $name) spawn_server || { log "$name: could not take the operation lock; trying again"; sleep 5; continue }
    (( child )) || continue
    wait $child
    code=$?
    wait_gone $child 120   # `wait` returns early when a signal arrives
    child=0
    ran=$(( EPOCHSECONDS - started ))
    if (( EPOCHSECONDS - last_int < 15 )); then
      log "$name: stopped with Ctrl+C"
      return 0
    fi

    # Three short runs in a row that nobody asked to end: the server cannot stay up. Slow down
    # and leave a mark for the watchdog. A stop or a restart on purpose does not count.
    if [[ -e $RA_STATE/paused/$name || -e $RA_STATE/busy.$name ]]; then
      short=0 pause=2          # stopped on purpose: no reason to wait
    elif (( ran >= 60 )); then
      short=0 pause=10
      rm -f $RA_STATE/flapping.$name
    elif (( ++short >= 3 )); then
      : >| $RA_STATE/flapping.$name
      pause=300
    else
      pause=60
    fi
    log "$name: claude remote-control exited (code $code) after ${ran}s; starting again in ${pause}s"
    sleep $pause
    (( EPOCHSECONDS - last_int < 15 )) && { log "$name: stopped with Ctrl+C"; return 0 }
  done
}

# Without a terminal the server still redraws its status screen about once a second. Keep the log
# readable: strip the control codes and let each distinct line through at most three times in ten
# minutes.
log_filter() {
  local line key n window=$EPOCHSECONDS
  local -A seen
  while IFS= read -r line; do
    line=${line//$'\e']([^$'\a'])#$'\a'/}
    line=${line//$'\e'\[[0-9;?]#[A-Za-z]/}
    line=${line//[[:cntrl:]]/}
    [[ -n ${line//[[:space:]]/} ]] || continue
    (( EPOCHSECONDS - window >= 600 )) && { seen=(); window=$EPOCHSECONDS }
    key=${line//[^[:alnum:] ]/_}
    n=$(( ${seen[$key]:-0} + 1 ))
    seen[$key]=$n
    (( n <= 3 )) && print -r -- "$(strftime '%F %T' $EPOCHSECONDS) | $line"
  done
}
