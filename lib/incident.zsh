# Incidents: things the watchdog found and cannot heal. Each one is announced, from plain code,
# and then a repair session on a cheap model is started to diagnose it.
#
# An incident is a file $RA_STATE/incidents/KEY with five lines:
#   1 when it opened            2 when notify_command took it (0 = not yet)
#   3 repair session: -1 none wanted, 0 not started yet, else when it started
#   4 when a repair session was last tried            5 the message
# It lasts until the watchdog sees the condition gone. Opening an incident only records it;
# `incidents_service` does the announcing and the repair, and repeats what did not work.

incident_file() { print -r -- $RA_STATE/incidents/$1 }

incident_open() {  # KEY MESSAGE [norepair]
  local f=$(incident_file $1) msg=${2//[[:cntrl:]]/ }
  [[ -e $f ]] && return 0
  write_file $f $EPOCHSECONDS 0 ${${3:+-1}:-0} 0 "$msg"
  log "INCIDENT $1: $msg"
  notify_local "$msg"
}

incident_clear() {  # KEY
  local f=$(incident_file $1)
  local -a l
  [[ -e $f ]] || return 0
  l=("${(@f)$(<$f)}")
  rm -f $f
  log "RESOLVED $1 after $(( (EPOCHSECONDS - l[1]) / 60 )) min"
  notify_local "resolved: $l[5]"
  (( l[2] > 0 )) && notify_hook "remote-agents: resolved: $l[5]"
  return 0
}

# Announce what is not announced yet and start the repair session that is still owed.
incidents_service() {
  local f changed
  local -a l
  for f in $RA_STATE/incidents/*(N); do
    l=("${(@f)$(<$f)}")
    (( $#l == 5 )) || continue
    changed=0
    if (( l[2] == 0 )) && notify_hook "remote-agents: $l[5]"; then l[2]=$EPOCHSECONDS; changed=1; fi
    if (( l[3] == 0 )); then
      if [[ $(cfg repair.agent) != claude ]]; then l[3]=-1; changed=1
      elif (( EPOCHSECONDS - l[4] >= 600 )); then
        l[4]=$EPOCHSECONDS; changed=1
        repair_start ${f:t} "$l[5]" && l[3]=$EPOCHSECONDS
      fi
    fi
    (( changed )) && [[ -e $f ]] && write_file $f "${l[@]}"
  done
}

# Tell the owner: a notification on this Mac, and notify_command, which gets the text as its
# last argument (a webhook script, a messenger CLI). When that command fails the announcement is
# tried again on the next tick, so it survives an outage.
notify_local() {
  with_timeout 15 osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "remote-agents"' -e 'end run' "$1" >/dev/null 2>&1
  return 0
}
notify_hook() {
  local hook=$(cfg repair.notify_command)
  [[ -n $hook ]] || return 0
  config_words $hook
  with_timeout 30 "${reply[@]}" "$1" >/dev/null 2>&1
}

# What the repair session may run without asking: commands that only look, and `ensure`.
# Everything else it wants to do shows up as a permission request in the Claude app, where the
# owner decides. This is a convenience list, not a sandbox: the session also has whatever the
# folder it runs in allows, so give it a folder of its own ([repair] dir).
REPAIR_TOOLS='Bash(remote-agents status) Bash(remote-agents status --json) Bash(remote-agents doctor) Bash(remote-agents sessions) Bash(remote-agents incidents) Bash(remote-agents ensure) Bash(remote-agents logs) Bash(remote-agents logs *) Bash(ps *) Bash(pgrep *) Bash(launchctl print *) Read Grep Glob'

# The pid of the running repair session, if any (the claude process, not its pty wrapper).
repair_pid() { pgrep -u $UID -f '(^|/)claude --model .* --remote-control remote-agents repair: ' | head -1 | grep . }

# Start the repair session for incident KEY: an interactive Claude Code session with Remote
# Control on, so it shows up in the Claude app next to the other sessions and can be talked to.
# One at a time. Fails (and is tried again ten minutes later) while another one is open, while
# offline or signed out, and when the session did not come up.
repair_start() {  # KEY MESSAGE
  local dir prompt name="remote-agents repair: $1" logf=$RA_LOGS/repair-$1.log i
  repair_pid >/dev/null && return 1
  dir=$(expand_path "$(cfg repair.dir)")
  [[ -n $dir && -d $dir ]] || return 1
  network_up && claude_logged_in || return 1
  prompt="You are the repair session of remote-agents on this Mac. It keeps Claude Code Remote Control servers and Codex remote control running, and it has just found a problem it cannot heal by itself.

Incident $1: $2

Do this, in order:
1. Send the owner one push notification (the PushNotification tool; find it with ToolSearch if it is not loaded): what is broken, in under 200 characters. If the tool answers that it was not sent, carry on.
2. Follow the runbook below. Diagnose with: remote-agents status, remote-agents doctor, remote-agents incidents, remote-agents sessions, remote-agents logs (these run without asking).
3. The only fix you may apply on your own is: remote-agents ensure. Then check with remote-agents status whether the incident is gone.
4. Anything else (a restart, a login, a reattach) is the owner's decision: say exactly which command you recommend and why, and let them approve it here.
5. Finish with a short report: cause, what you did, what is left for the owner. Send a second push notification with the outcome.

Never: stop, kill or restart a server yourself; use --force or --allow-session-loss; edit or delete anything under ~/.claude or the state folder; archive, merge or delete sessions; start another repair session.

$(<$RA_ROOT/docs/repair-runbook.md)"
  (
    cd $dir && scrub_env
    exec perl -MPOSIX -e 'setsid(); exec @ARGV' script -q $logf \
      $(claude_bin) --model "$(cfg repair.model)" --remote-control "$name" \
      --permission-mode "$(cfg repair.permission_mode)" --allowedTools "$REPAIR_TOOLS" -- "$prompt" </dev/null >/dev/null 2>&1
  ) &!
  for (( i = 0; i < 15; i++ )); do
    sleep 2
    repair_pid >/dev/null && { log "repair session started for $1 (model $(cfg repair.model), folder $dir)"; return 0 }
  done
  log "the repair session for $1 did not come up (is $dir trusted by Claude Code?); trying again in 10 min"
  return 1
}

# Close a repair session that has been idle for [repair] ttl seconds: it stays open after its
# report so the owner can talk to it, but it should not sit there forever and block the next one.
repair_expire() {
  local p f ms
  p=$(repair_pid) || return 0
  f=$(claude_home)/sessions/$p.json
  [[ $(jget $f status) == idle ]] || return 0
  ms=$(jget $f statusUpdatedAt)
  [[ $ms == <-> ]] || return 0
  (( EPOCHSECONDS - ms / 1000 > $(cfg repair.ttl) )) || return 0
  kill -TERM $p 2>/dev/null
  log "repair session pid $p closed after $(( $(cfg repair.ttl) / 60 )) min idle"
}

cmd_incidents() {
  local f
  local -a l
  load_config; ensure_dirs
  if [[ $1 == clear && -n $2 ]]; then rm -f $(incident_file ${2:t}); return; fi
  for f in $RA_STATE/incidents/*(N); do
    l=("${(@f)$(<$f)}")
    print -r -- "${f:t}  since $(strftime '%F %T' $l[1])  notify_command: $( (( l[2] > 0 )) && print done || print pending)  repair session: $( (( l[3] > 0 )) && print started || { (( l[3] < 0 )) && print none || print pending })"
    print -r -- "    $l[5]"
  done
  [[ -n $f ]] || print "no open incidents"
}
