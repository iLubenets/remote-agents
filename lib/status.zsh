# status, sessions, logs, doctor: everything that only looks.

# A JSON string: control characters become spaces, backslash and quote are escaped.
json_str() { local s=${1//[[:cntrl:]]/ }; s=${s//\\/\\\\}; print -rn -- "\"${s//\"/\\\"}\"" }

# Print the facts about one server as "key value" lines.
server_facts() {
  local name=$1 dir=$(srv_dir $1) pid state busy=0 idle=0 wpid st secs sid f
  f=$(pointer_file $dir)
  if pid=$(server_pid $dir); then
    state=up
    server_sessions $pid | while read -r wpid st secs sid; do
      if [[ $st == idle ]]; then (( idle += 1 )); else (( busy += 1 )); fi
    done
  elif [[ -e $RA_STATE/paused/$name ]]; then state=paused
  else state=down; fi
  print -r -- "name $name"
  print -r -- "dir $dir"
  print -r -- "state $state"
  print -r -- "pid ${pid:-0}"
  print -r -- "version ${pid:+$(proc_version $pid)}"
  print -r -- "environment $(jget $f environmentId)"
  print -r -- "registered $([[ -n $pid && $(jget $f pid) == $pid ]] && print yes || print no)"
  print -r -- "supervisor $(supervisor_running $name && print yes || print no)"
  print -r -- "observed $(is_observed $name && print yes || print no)"
  print -r -- "busy $busy"
  print -r -- "idle $idle"
}

watchdog_running() {
  local fd f=$RA_STATE/locks/watchdog.lock
  [[ -e $f ]] || return 1
  if zsystem flock -t 0 -f fd $f 2>/dev/null; then zsystem flock -u $fd; return 1; fi
  return 0
}

cmd_status() {
  local json=0 name k v first=1 n
  local -A f
  local -a inc
  [[ $1 == --json ]] && json=1
  if [[ $1 == --watch ]]; then
    # A live view: the same report every five seconds, until Ctrl+C.
    while true; do
      v=$(cmd_status)
      clear
      print -r -- "$v"$'\n\n'"$(strftime '%T' $EPOCHSECONDS)  every 5 s, Ctrl+C to leave"
      sleep 5
    done
  fi
  load_config || die "no usable config at $RA_CONFIG"; ensure_dirs
  inc=($RA_STATE/incidents/*(N:t))
  if (( json )); then
    print -n -- "{\"version\":$(json_str $RA_VERSION),\"watchdog\":$(watchdog_running && print true || print false),\"servers\":["
    for name in $SERVERS; do
      (( first )) || print -n ,
      first=0 n=0
      print -n '{'
      server_facts $name | while read -r k v; do
        (( n++ )) && print -n ,
        if [[ $k == (pid|busy|idle) ]]; then print -n -- "\"$k\":$v"; else print -n -- "\"$k\":$(json_str "$v")"; fi
      done
      print -n '}'
    done
    print -n -- "],\"codex\":$(json_str "$([[ -r $RA_STATE/codex ]] && <$RA_STATE/codex)"),\"incidents\":["
    first=1
    for k in $inc; do (( first )) || print -n ,; first=0; json_str $k; done
    print ']}'
    return 0
  fi
  print -r -- "remote-agents $RA_VERSION   watchdog: $(watchdog_running && print running || print NOT RUNNING)"
  for name in $SERVERS; do
    f=()
    server_facts $name | while read -r k v; do f[$k]=$v; done
    print -r -- ""
    print -r -- "$name  ${(U)f[state]}  $f[dir]$([[ $f[observed] == yes ]] && print '  (observed only)')"
    if [[ $f[state] == up ]]; then
      print -r -- "  pid $f[pid], Claude Code $f[version], sessions: $f[busy] busy, $f[idle] idle"
      print -r -- "  environment ${f[environment]:-?}$([[ $f[registered] == yes ]] && print ', registered' || print ', NOT REGISTERED')"
    fi
    print -r -- "  supervisor: $([[ $f[supervisor] == yes ]] && print running || print 'not running')"
  done
  if is_yes "$(cfg codex.enabled)"; then
    print -r -- ""
    if [[ -r $RA_STATE/codex ]]; then
      v=$(<$RA_STATE/codex)
      print -r -- "codex  ${v#* }  (checked $(( (EPOCHSECONDS - ${v%% *}) / 60 )) min ago)"
    else print -r -- "codex  not checked yet"; fi
  fi
  print -r -- ""
  if (( $#inc )); then print -r -- "open incidents: ${inc[*]}  (remote-agents incidents)"; else print -r -- "no open incidents"; fi
  (( $#inc == 0 ))
}

cmd_sessions() {
  local f=$RA_STATE/sessions.tsv sid name env seen cur
  load_config || die "no usable config at $RA_CONFIG"
  [[ -s $f ]] || { print "no sessions recorded yet"; return 0 }
  while IFS=$'\t' read -r sid name env seen; do
    [[ -n $sid ]] || continue
    (( ${SERVERS[(Ie)$name]} )) && cur=$(pointer_get "$(srv_dir $name)" environmentId) || cur=''
    print -r -- "$sid  $name  $([[ $env == $cur ]] && print attached || print "DETACHED (was on $env)")  seen $(strftime '%F %H:%M' $seen)"
  done < $f
  print -r -- ""
  print -r -- "A detached session comes back with: remote-agents reattach SESSION_ID --dir FOLDER --like SERVER"
  print -r -- "(one at a time per old environment; FOLDER is a trusted folder no server uses)"
}

cmd_logs() {
  local name=${1:-watchdog} n=${2:-60} f
  [[ $name =~ '^[A-Za-z0-9._-]+$' && $n =~ '^[0-9]{1,5}$' ]] || die "usage: remote-agents logs [NAME] [LINES]"
  f=$RA_LOGS/$name.log
  [[ -r $f ]] || die "no log $f (logs: $(print $RA_LOGS/*.log(N:t:r)))"
  tail -n $n $f
}

# doctor only looks. It reports Codex from the watchdog's last check instead of asking Codex.
cmd_doctor() {
  local bad=0 name dir pid c v why
  ok()  { print -r -- "  ok    $*" }
  bad() { print -r -- "  FAIL  $*"; bad=1 }
  note(){ print -r -- "  note  $*" }
  if load_config; then ok "config $RA_CONFIG, servers: ${SERVERS[*]:-none}"; else bad "no usable config at $RA_CONFIG"; return 1; fi
  ensure_dirs
  c=$(claude_bin)
  if [[ -x $c ]]; then ok "Claude Code $(installed_version) at $c"; else bad "claude not found (set claude = /path in the config)"; fi
  if claude_logged_in; then ok "signed in to Claude"; else bad "not signed in: claude auth login"; fi
  network_up && ok "network: $(cfg probe_url) answers" || bad "network: $(cfg probe_url) does not answer"
  watchdog_running && ok "watchdog is running" || bad "watchdog is not running: remote-agents install"
  for name in $SERVERS; do
    dir=$(srv_dir $name)
    [[ -d $dir ]] || { bad "$name: $dir is not a folder"; continue }
    [[ $(srv $name flags) == *--no-create-session-in-dir* ]] && note "$name: --no-create-session-in-dir in the config is ignored (it makes every stop archive the sessions)"
    if pid=$(server_pid $dir); then
      if why=$(unsafe_reason $name $pid); then bad "$name: server pid $pid cannot be stopped without losing its sessions: $why"
      else ok "$name: server pid $pid, environment $(pointer_get $dir environmentId), a stop keeps its sessions"; fi
      supervisor_running $name || note "$name: not under this tool's supervisor$(is_observed $name && print ' (observed only)')"
    elif [[ -e $RA_STATE/paused/$name ]]; then note "$name: paused (remote-agents start $name)"
    else bad "$name: no server running in $dir"; fi
    is_observed $name || [[ -n $(start_template $name) || -e $HOME/Library/LaunchAgents/$(launchd_label server.$name).plist ]] || bad "$name: no LaunchAgent for its supervisor: remote-agents install"
  done
  if is_yes "$(cfg codex.enabled)"; then
    c=$(codex_bin)
    if [[ ! -x $c ]]; then bad "codex not found (set command = /path under [codex])"
    elif [[ -r $RA_STATE/codex ]]; then
      v=$(<$RA_STATE/codex)
      [[ ${v#* } == connected* ]] && ok "codex: ${v#* } ($(( (EPOCHSECONDS - ${v%% *}) / 60 )) min ago)" || bad "codex: ${v#* } ($(( (EPOCHSECONDS - ${v%% *}) / 60 )) min ago)"
    else note "codex: not checked yet (the watchdog checks every 10 min; remote-agents ensure checks now)"; fi
  fi
  if [[ $(cfg repair.agent) == claude ]]; then
    dir=$(expand_path "$(cfg repair.dir)")
    [[ -n $dir && -d $dir ]] && ok "repair sessions start in $dir (model $(cfg repair.model))" || bad "[repair] dir is not set to an existing folder: no repair session can start (or set agent = none)"
  fi
  [[ -n $(cfg repair.notify_command) ]] || note "no notify_command: an incident is announced on this Mac and by the repair session only"
  return $bad
}
