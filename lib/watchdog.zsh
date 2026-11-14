# `remote-agents watchdog`: one small loop, run by a LaunchAgent, that looks at everything every
# 20 seconds. It asks the host to start a supervisor that is missing and opens an incident for
# whatever it cannot heal. It never stops, restarts or rewires a server.

is_observed() { is_yes "$(srv $1 observe no)" }

typeset -gA LAST_TRY DOWN_SINCE

# Ask for a supervisor when nothing serves the folder of NAME and none runs.
ensure_server() {  # NAME MIN_SECONDS_BETWEEN_TRIES
  local name=$1 dir=$(srv_dir $1)
  [[ -e $RA_STATE/paused/$name ]] && return 0
  is_observed $name && return 0
  server_pid $dir >/dev/null && return 0
  supervisor_running $name && return 0
  (( EPOCHSECONDS - ${LAST_TRY[$name]:-0} >= ${2:-0} )) || return 0
  LAST_TRY[$name]=$EPOCHSECONDS
  if start_supervisor $name; then
    log "$name: nothing serves $dir and no supervisor runs; asked the host to start one"
  else
    log "$name: nothing serves $dir and the host could not start a supervisor (remote-agents doctor)"
  fi
}

tick_server() {
  local name=$1 dir=$(srv_dir $1) pid env known secs
  [[ -e $RA_STATE/busy.$name ]] && (( $(age $RA_STATE/busy.$name) < 900 )) && return 0   # a restart is in progress

  if pid=$(server_pid $dir); then
    unset "DOWN_SINCE[$name]"
    incident_clear down.$name
    if [[ $(pointer_get $dir pid) == $pid ]]; then
      incident_clear stuck.$name
      env=$(pointer_get $dir environmentId) known=$(known_env $name)
      if [[ -n $env && $env != $known ]]; then
        write_file $RA_STATE/env/$name $env
        if [[ -n $known ]]; then
          write_file $RA_STATE/env/$name.previous $known
          incident_open env.$name "$name came back on a new environment ($known -> $env). Sessions that were open on the old one are detached; list them with: remote-agents sessions"
        fi
      fi
      inventory_update $name $pid $env
    else
      secs=$(proc_age $pid)
      (( secs > 300 )) && incident_open stuck.$name "$name: server pid $pid has been up for $(( secs / 60 )) min without registering (waiting at a prompt, or refused by the service)"
    fi
  else
    [[ -e $RA_STATE/paused/$name ]] && { unset "DOWN_SINCE[$name]"; incident_clear down.$name; return 0 }
    : ${DOWN_SINCE[$name]:=$EPOCHSECONDS}
    (( EPOCHSECONDS - WD_STARTED >= $(cfg start_delay 0) )) && ensure_server $name 120
    (( EPOCHSECONDS - DOWN_SINCE[$name] > $(cfg down_after) )) && incident_open down.$name "$name: no Remote Control server has been running in $dir for $(( (EPOCHSECONDS - DOWN_SINCE[$name]) / 60 )) min"
  fi

  if [[ -e $RA_STATE/flapping.$name ]]; then
    incident_open flap.$name "$name: the server keeps exiting right after it starts"
  else
    incident_clear flap.$name
  fi
  return 0
}

# Inventory of the sessions each server runs: session id, server, environment, last seen. It is
# what tells which sessions were on an environment that is gone. Knowledge only; nothing is done
# with it automatically.
inventory_update() {  # NAME SERVER_PID ENV
  local f=$RA_STATE/sessions.tsv wpid st secs sid line changed=0
  local -A row
  local -a out
  [[ -r $f ]] && while IFS=$'\t' read -r sid line; do row[$sid]=$line; done < $f
  server_sessions $2 | while read -r wpid st secs sid; do
    [[ $sid =~ '^session_[A-Za-z0-9]+$' ]] || continue
    line=${row[$sid]-}
    if [[ -z $line || ${line%$'\t'*} != "$1"$'\t'"$3" ]] || (( EPOCHSECONDS - ${line##*$'\t'} > 300 )); then
      row[$sid]="$1"$'\t'"$3"$'\t'"$EPOCHSECONDS"; changed=1
    fi
  done
  (( changed )) || return 0
  for sid in ${(ko)row}; do
    (( EPOCHSECONDS - ${row[$sid]##*$'\t'} < 30 * 86400 )) && out+=("$sid"$'\t'"${row[$sid]}")
  done
  write_file $f "${out[@]}"
}

# A session brought back with `reattach` is served by a process of its own, which nothing
# restarts: it ends when the session is ended in the app, and also after ten minutes offline.
# Report it once when it is gone; the owner knows whether the session was finished.
tick_reattached() {
  local f sid
  local -a l
  for f in $RA_STATE/reattached/session_*(N); do
    sid=${f:t}
    pgrep -u $UID -f "claude (rc|remote-control) --session-id $sid( |\$)" >/dev/null && continue
    l=("${(@f)$(<$f)}")
    rm -f $f
    incident_open reattach.${sid[-8,-1]} "The process serving the reattached session $sid has exited. If the session was not finished: remote-agents reattach $sid --dir $l[1]${l[2]:+ --like $l[2]}" norepair
  done
}

tick_auth() {
  local tmp exp left
  if [[ -e $RA_STATE/auth-failed ]]; then
    incident_open auth "Claude Code is signed out on this Mac. Sign in there: claude auth login" norepair
    return
  fi
  incident_clear auth
  (( EPOCHSECONDS - ${LAST_AUTH:-0} >= 3600 )) || return 0
  LAST_AUTH=$EPOCHSECONDS
  tmp=$(mktemp)
  claude_auth_status $tmp
  exp=$(jget $tmp loginExpiresAt); rm -f $tmp
  [[ -n $exp ]] || return 0
  left=$(( $(TZ=UTC strftime -r '%Y-%m-%dT%H:%M:%S' ${exp%%.*} 2>/dev/null || print 0) - EPOCHSECONDS ))
  if (( left > 0 && left < 3 * 86400 )); then
    incident_open auth-expiring "The Claude Code login on this Mac expires in $(( left / 3600 )) h. Renew it there: claude auth login" norepair
  else
    incident_clear auth-expiring
  fi
}

tick_codex() {
  local st d ver host line
  is_yes "$(cfg codex.enabled)" || return 0
  (( EPOCHSECONDS - ${LAST_CODEX:-0} >= 600 )) || return 0
  LAST_CODEX=$EPOCHSECONDS
  read -r st d ver host <<< "$(codex_ensure)"
  line="$st daemon=$d version=$ver server=$host"
  [[ $line == ${CODEX_LINE-} ]] || log "codex: $line"
  CODEX_LINE=$line
  write_file $RA_STATE/codex "$EPOCHSECONDS $line"
  if [[ $st == connected ]]; then
    CODEX_OK=$EPOCHSECONDS
    incident_clear codex
  elif (( EPOCHSECONDS - ${CODEX_OK:-$WD_STARTED} > $(cfg codex.alert_after) )); then
    incident_open codex "Codex remote control has not been connected for $(( (EPOCHSECONDS - ${CODEX_OK:-$WD_STARTED}) / 60 )) min (status $st, daemon $d)"
  fi
}

# Incidents about something that happened, not about a state: they stay on the list for a day.
expire_events() {
  local f
  for f in $RA_STATE/incidents/(env|reattach).*(N); do
    (( $(age $f) > 86400 )) && incident_clear ${f:t}
  done
  return 0
}

trim_logs() {
  local f
  for f in $RA_LOGS/*.log(N.Lm+20); do
    tail -c 5242880 $f >| $f.trim && cat $f.trim >| $f
    rm -f $f.trim
  done
}

# `remote-agents ensure`: start whatever is missing, once, now.
cmd_ensure() {
  local name
  load_config || die "no usable config at $RA_CONFIG"; ensure_dirs
  WD_STARTED=${WD_STARTED:-$EPOCHSECONDS}
  for name in $SERVERS; do ensure_server $name 0; done
  if is_yes "$(cfg codex.enabled)"; then print -r -- "codex: $(codex_ensure)"; fi
  return 0
}

cmd_watchdog() {
  local lockfd name last_trim=0 online=1 cfg_ok=1
  load_config || die "no usable config at $RA_CONFIG"
  ensure_dirs
  : >>| $RA_STATE/locks/watchdog.lock
  zsystem flock -t 0 -f lockfd $RA_STATE/locks/watchdog.lock 2>/dev/null || { log "another watchdog is running"; sleep 30; return 0 }
  scrub_env
  WD_STARTED=$EPOCHSECONDS
  trap 'exit 0' TERM INT HUP
  log "watchdog $RA_VERSION started; servers: ${SERVERS[*]:-none}"

  while true; do
    # A config that does not parse keeps the last good one in force.
    if load_config 2>/dev/null; then
      (( cfg_ok )) || log "the config reads again"; cfg_ok=1
    else
      (( cfg_ok )) && log "the config at $RA_CONFIG does not read; keeping the last good one (remote-agents doctor)"; cfg_ok=0
    fi
    (( EPOCHSECONDS - last_trim > 600 )) && { trim_logs; last_trim=$EPOCHSECONDS }
    if network_up; then
      (( online )) || log "network is back"; online=1
      for name in $SERVERS; do tick_server $name; done
      tick_reattached
      tick_auth
      tick_codex
      incidents_service
      expire_events
      repair_expire
    else
      # Offline nothing can be started or announced. The supervisors wait for the network too.
      (( online )) && log "network down ($(cfg probe_url) does not answer)"; online=0
    fi
    sleep 20 &
    wait $!
  done
}
