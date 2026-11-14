# What we know about Claude Code Remote Control on disk and in the process table.

claude_bin() {
  local c=$(expand_path "$(cfg claude)")
  [[ -n $c ]] || c=$HOME/.local/bin/claude
  [[ -x $c ]] || c=$(whence -p claude)
  print -r -- $c
}

claude_home() { print -r -- ${CLAUDE_CONFIG_DIR:-$HOME/.claude} }

# Claude Code keeps per-folder state in <home>/projects/<path with every character that is not a
# letter or digit replaced by '-'>. A Remote Control server keeps its "bridge pointer" there:
# the environment it registered and its own pid. A stop keeps the environment on Anthropic's side
# only when the server owns this file, and the next start in the folder then reuses it.
pointer_file() { print -r -- $(claude_home)/projects/${1//[^A-Za-z0-9]/-}/bridge-pointer.json }
pointer_get()  { jget $(pointer_file $1) $2 }

# Print "PID COMMAND" for every Remote Control process of this user.
rc_procs() {
  local pid cmd
  ps -U $UID -o pid=,command= | while read -r pid cmd; do
    [[ $cmd =~ '^([^ ]*/)?claude (rc|remote-control)( |$)' ]] && print -r -- $pid $cmd
  done
  return 0
}

proc_cwd() { lsof -a -p $1 -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' }

# The pid of the server (server mode, many sessions) whose working folder is $1. A process started
# with --session-id or --continue serves one old session and is not the folder's server.
server_pid() {
  local pid cmd
  rc_procs | while read -r pid cmd; do
    [[ $cmd =~ ' (--session-id|--continue|-c)( |=|$)' ]] && continue
    [[ $(proc_cwd $pid) == $1 ]] && { print $pid; return 0 }
  done
  return 1
}

# Version of Claude Code a process runs, from the path of its program file.
proc_version() {
  local p=$(lsof -a -p $1 -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | grep -m1 '/versions/')
  print -r -- ${p:t}
}

installed_version() { local c=$(claude_bin); print -r -- ${${c:A}:t} }

# Seconds a process has been running.
proc_age() {
  local e=${$(ps -o etime= -p $1 2>/dev/null)// /} d=0
  local -a p
  [[ -n $e ]] || { print 0; return }
  [[ $e == *-* ]] && { d=${e%%-*}; e=${e#*-} }
  p=(${(s.:.)e})
  (( $#p == 2 )) && p=(0 $p)
  print $(( 10#$d * 86400 + 10#$p[1] * 3600 + 10#$p[2] * 60 + 10#$p[3] ))
}

# Print "WORKER_PID STATUS SECONDS_IN_STATUS SESSION_ID" for the sessions server pid $1 runs.
server_sessions() {
  local f wpid ms
  for f in $(claude_home)/sessions/*.json(N); do
    wpid=${${f:t}%%.*}
    [[ $(ps -o ppid= -p $wpid 2>/dev/null | tr -d ' ') == $1 ]] || continue
    ms=$(jget $f statusUpdatedAt)
    [[ $ms == <-> ]] || ms=0
    print -r -- $wpid "$(jget $f status)" $(( EPOCHSECONDS - ${ms:-0} / 1000 )) "$(jget $f bridgeSessionId)"
  done
}

# Write `claude auth status` to FILE; fail when it did not answer in time.
claude_auth_status() { with_timeout 30 $(claude_bin) auth status >| $1 2>/dev/null }

claude_logged_in() {
  local tmp=$(mktemp) ok=1
  claude_auth_status $tmp
  [[ $(jget $tmp loggedIn) == true ]] && ok=0
  rm -f $tmp
  return $ok
}

# Set `reply` to the flags a server is started with: the config's, as separate words (quotes in
# the config group words), minus the one flag that makes every stop archive the server's sessions.
server_flags() {
  reply=("${(@Q)${(z)$(srv $1 flags '--permission-mode default')}}")
  reply=("${(@)reply:#--no-create-session-in-dir}")
}

# Set `reply` to the arguments `claude` gets for server NAME.
server_argv() {
  server_flags $1
  reply=(remote-control --name $1 --remote-control-session-name-prefix $1 "${reply[@]}")
}

# The environment a server was last seen registered on, as recorded by the watchdog.
known_env() { [[ -r $RA_STATE/env/$1 ]] && print -r -- "$(<$RA_STATE/env/$1)" }
