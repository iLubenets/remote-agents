# install / uninstall: the LaunchAgents. One for the watchdog; one per server, unless the server
# has a start_command (then its supervisor lives where that command puts it, e.g. a terminal tab).
#
# Neither command stops a running server behind your back: a LaunchAgent whose supervisor runs a
# server is only removed after `remote-agents stop NAME`.

xml_esc() { local s=${1//&/&amp;}; s=${s//</&lt;}; print -r -- ${s//>/&gt;} }

write_agent() {  # LABEL LOGNAME ARG...
  local label=$1 logf=$RA_LOGS/$2.log f=$HOME/Library/LaunchAgents/$1.plist a i
  shift 2
  {
    print -r -- '<?xml version="1.0" encoding="UTF-8"?>'
    print -r -- '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    print -r -- '<plist version="1.0"><dict>'
    print -r -- "  <key>Label</key><string>$(xml_esc $label)</string>"
    print -r -- '  <key>ProgramArguments</key><array>'
    for a in "$@"; do print -r -- "    <string>$(xml_esc $a)</string>"; done
    print -r -- '  </array>'
    print -r -- '  <key>EnvironmentVariables</key><dict>'
    print -r -- "    <key>HOME</key><string>$(xml_esc $HOME)</string>"
    print -r -- "    <key>PATH</key><string>$(xml_esc "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")</string>"
    [[ -n ${REMOTE_AGENTS_CONFIG-} ]] && print -r -- "    <key>REMOTE_AGENTS_CONFIG</key><string>$(xml_esc $RA_CONFIG)</string>"
    [[ -n ${REMOTE_AGENTS_STATE-} ]] && print -r -- "    <key>REMOTE_AGENTS_STATE</key><string>$(xml_esc $RA_STATE)</string>"
    [[ -n ${REMOTE_AGENTS_LOGS-} ]] && print -r -- "    <key>REMOTE_AGENTS_LOGS</key><string>$(xml_esc $RA_LOGS)</string>"
    print -r -- '  </dict>'
    print -r -- '  <key>RunAtLoad</key><true/>'
    print -r -- '  <key>KeepAlive</key><true/>'
    print -r -- '  <key>ThrottleInterval</key><integer>30</integer>'
    print -r -- '  <key>ProcessType</key><string>Interactive</string>'
    # When launchd stops a supervisor it must give it time to stop its server cleanly, and must
    # not kill a server that is still shutting down.
    print -r -- '  <key>ExitTimeOut</key><integer>150</integer>'
    print -r -- '  <key>AbandonProcessGroup</key><true/>'
    print -r -- "  <key>StandardOutPath</key><string>$(xml_esc $logf)</string>"
    print -r -- "  <key>StandardErrorPath</key><string>$(xml_esc $logf)</string>"
    print -r -- '</dict></plist>'
  } >| $f.new
  plutil -lint -s $f.new || { rm -f $f.new; die "could not write a valid plist for $label" }
  launchctl bootout gui/$UID/$label 2>/dev/null
  for i in {1..40}; do launchctl print gui/$UID/$label >/dev/null 2>&1 || break; sleep 0.5; done
  mv -f $f.new $f
  launchctl bootstrap gui/$UID $f || die "launchd refused $f"
  print -r -- "installed $label"
}

remove_agent() {
  local f=$HOME/Library/LaunchAgents/$1.plist
  launchctl bootout gui/$UID/$1 2>/dev/null
  rm -f $f
  print -r -- "removed $1"
}

# May the LaunchAgent of server NAME be unloaded? Only when that cannot take a server down:
# no supervisor runs, or the server was stopped on purpose (`remote-agents stop`), which is also
# what keeps the supervisor from starting one in the meantime.
agent_idle() {
  local label=$(launchd_label server.$1) p
  p=$(launchd_pid $label)
  [[ -z $p ]] && return 0
  [[ -e $RA_STATE/paused/$1 ]] && ! pgrep -P $p -f 'claude (rc|remote-control)' >/dev/null
}

cmd_install() {
  local name f label
  load_config || die "no usable config at $RA_CONFIG (copy config/remote-agents.conf.example there and edit it)"
  (( $#SERVERS )) || is_yes "$(cfg codex.enabled)" || die "the config has no [server NAME] section and Codex is off: nothing to keep alive"
  for name in $SERVERS; do [[ -d $(srv_dir $name) ]] || die "server $name: dir '$(srv $name dir)' is not a folder"; done
  ensure_dirs
  mkdir -p $HOME/Library/LaunchAgents
  # LaunchAgents of servers the config no longer wants under launchd.
  for f in $HOME/Library/LaunchAgents/$(cfg label_prefix).server.*.plist(N); do
    label=${f:t:r}; name=${label#$(cfg label_prefix).server.}
    (( ${SERVERS[(Ie)$name]} )) && [[ -z $(start_template $name) ]] && ! is_observed $name && continue
    if agent_idle $name; then
      remove_agent $label
    else
      print -r -- "$name: its LaunchAgent is no longer wanted by the config, but its supervisor is running. Left in place. Stop the server first (remote-agents stop $name, while it is still in the config), then run install again."
    fi
  done
  for name in $SERVERS; do
    is_observed $name && continue
    [[ -z $(start_template $name) ]] || continue
    label=$(launchd_label server.$name)
    if supervisor_running $name || server_pid "$(srv_dir $name)" >/dev/null; then
      [[ -e $HOME/Library/LaunchAgents/$label.plist ]] || print -r -- "$name: something already serves its folder; no LaunchAgent written. Stop that first, then run install again."
      continue
    fi
    write_agent $label $name /bin/zsh $RA_ROOT/bin/remote-agents run $name
  done
  write_agent $(launchd_label watchdog) watchdog /bin/zsh $RA_ROOT/bin/remote-agents watchdog
  print -r -- "done. Check with: remote-agents status"
}

cmd_uninstall() {
  local f label name force=0 serving=()
  [[ $1 == --force ]] && force=1
  load_config
  for f in $HOME/Library/LaunchAgents/$(cfg label_prefix).server.*.plist(N); do
    name=${${f:t:r}#$(cfg label_prefix).server.}
    agent_idle $name || serving+=$name
  done
  if (( $#serving && ! force )); then
    die "these servers are running: ${serving[*]}. Stop them first (remote-agents stop ${serving[*]}), which checks that their sessions are kept; or uninstall --force."
  fi
  for f in $HOME/Library/LaunchAgents/$(cfg label_prefix).(watchdog|server.*).plist(N); do remove_agent ${f:t:r}; done
  print -r -- "the config ($RA_CONFIG), state ($RA_STATE) and logs ($RA_LOGS) were left in place"
}
