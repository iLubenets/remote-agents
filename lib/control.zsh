# Starting supervisors, and the commands a person runs: restart, stop, start, reattach.

launchd_label() { print -r -- "$(cfg label_prefix).$1" }
launchd_pid() {
  launchctl print gui/$UID/$1 2>/dev/null | awk '$1 == "pid" && $2 == "=" { print $3; exit }'
}

# The start_command of a server: its own, or the one at the top of the config. Empty: launchd.
start_template() { srv $1 start_command "$(cfg start_command)" }

# Run a long-lived command where the user wants such things to live.
#   TEMPLATE set: a command that opens it somewhere, e.g. in a terminal tab. Each word of the
#     template is one argument of that command. {name} and {dir} are replaced as they are;
#     {run} becomes the command line to run, quoted for a shell, because a terminal hands it to
#     one.
#   TEMPLATE empty: detached from us, output in the log folder.
spawn_hosted() {  # LABEL DIR TEMPLATE COMMAND ARG...
  local label=$1 dir=$2 tmpl=$3 setup=$(cfg start_setup) line
  shift 3
  local -a words
  if [[ -n $tmpl ]]; then
    [[ -n $setup ]] && { config_words $setup; with_timeout 60 "${reply[@]}" >/dev/null 2>&1 }
    line=$(shell_line "$@")
    config_words $tmpl; words=("${reply[@]}")
    words=("${(@)words//\{name\}/$label}")
    words=("${(@)words//\{dir\}/$dir}")
    words=("${(@)words//\{run\}/$line}")
    with_timeout 60 "${words[@]}" >/dev/null 2>&1
    return
  fi
  ( cd $dir && exec perl -MPOSIX -e 'setsid(); exec @ARGV' "$@" </dev/null >>$RA_LOGS/$label.log 2>&1 ) &!
}

# Ask the host to start the supervisor of server NAME (which starts the server). Under launchd
# that is the LaunchAgent written by `remote-agents install`. Fails when the host refused.
start_supervisor() {
  local name=$1 label tmpl=$(start_template $1)
  if [[ -n $tmpl ]]; then
    spawn_hosted $name "$(srv_dir $name)" "$tmpl" $RA_ROOT/bin/remote-agents run $name
    return
  fi
  label=$(launchd_label server.$name)
  launchctl kickstart gui/$UID/$label 2>/dev/null && return 0
  [[ -e $HOME/Library/LaunchAgents/$label.plist ]] || return 1
  launchctl bootstrap gui/$UID $HOME/Library/LaunchAgents/$label.plist 2>/dev/null
}

# ---------------------------------------------------------------- guarded restart

# Print why stopping server pid $2 of NAME would lose its open sessions; fail when the stop keeps
# them. A stop keeps the environment (and with it the sessions) only when the server runs without
# --no-create-session-in-dir and owns its bridge pointer.
unsafe_reason() {
  local dir=$(srv_dir $1) owner
  if [[ $(ps -o command= -p $2) == *--no-create-session-in-dir* ]]; then
    print "it runs with --no-create-session-in-dir"; return 0
  fi
  if [[ ! -r $(pointer_file $dir) ]]; then
    print "it has no bridge pointer ($(pointer_file $dir))"; return 0
  fi
  owner=$(pointer_get $dir pid)
  if [[ $owner != $2 ]]; then
    print "its bridge pointer belongs to pid ${owner:-?}"; return 0
  fi
  if [[ $(pointer_get $dir environmentId) != env_* ]]; then
    print "its bridge pointer names no environment"; return 0
  fi
  return 1
}

# Print which session of server pid $2 is at work or was a moment ago; fail when all are idle.
busy_reason() {
  local wpid st secs sid min=$(cfg min_idle)
  server_sessions $2 | while read -r wpid st secs sid; do
    if [[ $st != idle ]]; then print "session $sid is $st"; return 0; fi
    if (( secs < min )); then print "session $sid was active ${secs}s ago"; return 0; fi
  done
  return 1
}

# Print what a restart would change; fail when the server already runs the installed Claude Code
# with the flags in the config.
restart_reason() {
  local have=$(proc_version $2) want=$(installed_version)
  if [[ -z $have || $have != $want ]]; then print "it runs ${have:-an unknown version}, installed is $want"; return 0; fi
  server_argv $1
  if [[ $(ps -o command= -p $2) != *" ${reply[*]}" ]]; then print "its flags differ from the config"; return 0; fi
  return 1
}

cmd_restart() {
  local force=0 loss=0 dry=0 needed=0 name pid why dir before after np i rc=0
  while [[ $1 == --* ]]; do
    case $1 in
      --force) force=1 ;;
      --allow-session-loss) loss=1 ;;
      --dry-run) dry=1 ;;
      --if-needed) needed=1 ;;
      *) die "usage: remote-agents restart [--if-needed] [--force] [--allow-session-loss] [--dry-run] NAME..." ;;
    esac
    shift
  done
  load_config || die "no usable config at $RA_CONFIG"
  ensure_dirs
  (( $# )) || die "name the server(s) to restart: ${SERVERS[*]}"
  for name in "$@"; do
    need_server $name
    dir=$(srv_dir $name)
    if ! pid=$(server_pid $dir); then log "$name: no server running"; rc=1; continue; fi
    if (( needed )) && ! why=$(restart_reason $name $pid); then
      log "$name: already runs $(installed_version) with the config's flags; not restarted"; continue
    fi
    if (( ! force )) && why=$(busy_reason $name $pid); then
      log "$name: not restarted: $why (a restart cuts a running turn; --force does it anyway)"; rc=1; continue
    fi
    if why=$(unsafe_reason $name $pid); then
      if (( ! loss )); then
        log "$name: UNSAFE, not restarted: $why, so stopping it would archive its open sessions"
        rc=1; continue
      fi
      log "$name: $why; stopping it anyway (--allow-session-loss): its open sessions get archived"
      before=''
    else
      before=$(pointer_get $dir environmentId)
    fi
    if (( dry )); then log "$name: would restart pid $pid (environment ${before:-unknown})"; continue; fi

    print $EPOCHSECONDS >| $RA_STATE/busy.$name
    log "$name: stopping pid $pid (environment ${before:-unknown})"
    kill -TERM $pid 2>/dev/null
    if ! wait_gone $pid 90; then
      log "$name: pid $pid did not stop within 90 s; left as it is, nothing was force-killed"
      rm -f $RA_STATE/busy.$name; rc=1; continue
    fi
    np=
    for (( i = 0; i < 90; i++ )); do
      np=$(server_pid $dir) && break
      (( i == 15 )) && ! supervisor_running $name && start_supervisor $name
      sleep 2
    done
    if [[ -z $np ]]; then
      log "$name: no new server within 3 min"; rm -f $RA_STATE/busy.$name; rc=1; continue
    fi
    for (( i = 0; i < 60; i++ )); do [[ $(pointer_get $dir pid) == $np ]] && break; sleep 2; done
    after=$(pointer_get $dir environmentId)
    if [[ $(pointer_get $dir pid) != $np ]]; then
      log "$name: ALERT: new server pid $np has not registered within 2 min"; rc=1
    elif [[ -z $before ]]; then
      log "$name: up, pid $np, $(proc_version $np), environment $after"
    elif [[ $after == $before ]]; then
      log "$name: up, pid $np, $(proc_version $np), same environment $after: open sessions kept"
    else
      log "$name: ALERT: environment changed, $before -> $after; sessions on $before are detached (remote-agents sessions)"
      rc=1
    fi
    rm -f $RA_STATE/busy.$name
  done
  return $rc
}

# stop: end the server on purpose and keep it stopped. Its environment and sessions are kept and
# come back with `start`. Refuses when the stop would lose them, or cut a running turn.
#
# The whole decision runs under the lock the supervisor starts servers under, with the pause mark
# written first: from that moment no server can be started, so the process that is found, checked
# and signalled is the only one there can be.
stop_locked() {  # NAME FORCE -> 0 signalled (pid in STOP_PID), 1 refused, 2 nothing was running
  local name=$1 dir=$(srv_dir $1) pid='' why i
  STOP_PID=
  mark_paused $name
  for (( i = 0; i < 6; i++ )); do pid=$(server_pid $dir) && break; sleep 0.5; done
  [[ -n $pid ]] || return 2
  if why=$(unsafe_reason $name $pid); then
    rm -f $RA_STATE/paused/$name
    log "$name: UNSAFE, not stopped: $why, so stopping it would archive its open sessions"; return 1
  fi
  if (( ! $2 )) && why=$(busy_reason $name $pid); then
    rm -f $RA_STATE/paused/$name
    log "$name: not stopped: $why (--force stops it anyway and cuts the running turn)"; return 1
  fi
  kill -TERM $pid 2>/dev/null
  STOP_PID=$pid
  return 0
}

cmd_stop() {
  local force=0 name rc=0 r
  [[ $1 == --force ]] && { force=1; shift }
  load_config || die "no usable config at $RA_CONFIG"; ensure_dirs
  (( $# )) || die "usage: remote-agents stop [--force] NAME..."
  for name in "$@"; do
    need_server $name
    with_lock $(op_lock $name) stop_locked $name $force; r=$?
    case $r in
      0) if wait_gone $STOP_PID 90; then log "$name: stopped and paused"; else log "$name: paused; pid $STOP_PID is still shutting down"; rc=1; fi ;;
      2) log "$name: paused (no server was running)" ;;
      *) rc=1 ;;
    esac
  done
  return $rc
}

cmd_start() {
  local name
  load_config || die "no usable config at $RA_CONFIG"; ensure_dirs
  (( $# )) || die "usage: remote-agents start NAME..."
  for name in "$@"; do
    need_server $name
    rm -f $RA_STATE/paused/$name
    if supervisor_running $name; then log "$name: resumed"
    elif start_supervisor $name; then log "$name: asked the host to start its supervisor"
    else log "$name: the host could not start its supervisor (remote-agents doctor)"; fi
  done
}

# reattach: bring one detached session back with its own single-session process.
# Needed after the environment changed under a server (see `remote-agents sessions`). Claude Code
# allows one such process per old environment, and it must run in a folder no server uses.
cmd_reattach() {
  local usage="usage: remote-agents reattach SESSION_ID [--dir FOLDER] [--like SERVER]"
  local sid='' dir='' from='' pid cmd name env other i
  local -a flags sf
  while (( $# )); do
    case $1 in
      --dir)  (( $# >= 2 )) || die $usage; dir=$2; shift 2 ;;
      --like) (( $# >= 2 )) || die $usage; from=$2; shift 2 ;;
      *) [[ -z $sid ]] || die $usage; sid=$1; shift ;;
    esac
  done
  [[ $sid =~ '^session_[A-Za-z0-9]+$' ]] || die $usage
  load_config || die "no usable config at $RA_CONFIG"; ensure_dirs
  dir=$(expand_path "${dir:-$(cfg reattach_dir)}")
  [[ -d $dir ]] || die "give a trusted folder that no server uses: --dir FOLDER (or reattach_dir in the config)"
  dir=${dir:A}
  for name in $SERVERS; do
    [[ $(srv_dir $name) == $dir ]] && die "$dir is the folder of server $name; pick a folder no server uses"
  done
  # One single-session process per old environment: a second one is refused by the service.
  env=$(awk -F'\t' -v s=$sid '$1 == s { print $3 }' $RA_STATE/sessions.tsv 2>/dev/null)
  rc_procs | while read -r pid cmd; do
    [[ $(proc_cwd $pid) == $dir ]] && die "$dir is in use by Remote Control pid $pid; pick another folder"
    [[ $cmd =~ '--session-id (session_[A-Za-z0-9]+)' ]] || continue
    [[ $match[1] == $sid ]] && die "$sid is already served by pid $pid"
    other=$(awk -F'\t' -v s=$match[1] '$1 == s { print $3 }' $RA_STATE/sessions.tsv 2>/dev/null)
    [[ -n $env && $other == $env ]] && die "pid $pid already serves $match[1] from the same old environment ($env); only one at a time. End that one first."
  done
  # Carry over what a single-session process accepts from the server the session came from.
  if [[ -n $from ]]; then
    need_server $from
    server_flags $from; sf=("${reply[@]}")
    (( ${sf[(I)--chrome]} )) && flags+=(--chrome)
    i=${sf[(i)--permission-mode]}
    (( i < $#sf )) && flags+=(--permission-mode $sf[i+1])
  fi
  spawn_hosted reattach-${sid[-6,-1]} $dir "$(cfg start_command)" $(claude_bin) remote-control --session-id $sid "${flags[@]}"
  for (( i = 0; i < 15; i++ )); do
    sleep 2
    if pgrep -u $UID -f "claude (rc|remote-control) --session-id $sid( |\$)" >/dev/null; then
      # Written down, one file per session, so the watchdog can tell when this process goes away.
      mkdir -p $RA_STATE/reattached
      write_file $RA_STATE/reattached/$sid "$dir" "$from"
      log "$sid is being served from $dir; it shows up in the app within a minute"
      return 0
    fi
  done
  log "no process for $sid appeared (is $dir trusted by Claude Code? is the session ended in the app?)"
  return 1
}
