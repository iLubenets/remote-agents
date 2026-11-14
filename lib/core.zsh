# Paths, configuration, logging and small helpers. Sourced by bin/remote-agents.

umask 077   # state and logs hold session ids
zmodload zsh/datetime zsh/system
zmodload -F zsh/stat b:zstat

: ${RA_CONFIG:=${REMOTE_AGENTS_CONFIG:-$HOME/.config/remote-agents/config}}
: ${RA_STATE:=${REMOTE_AGENTS_STATE:-$HOME/.local/state/remote-agents}}
: ${RA_LOGS:=${REMOTE_AGENTS_LOGS:-$HOME/Library/Logs/remote-agents}}
RA_VERSION=$(<$RA_ROOT/VERSION)

log()  { print -r -- "$(strftime '%F %T' $EPOCHSECONDS) $*" }
warn() { print -ru2 -- "remote-agents: $*" }
die()  { warn "$*"; exit 1 }

# ---------------------------------------------------------------- config

# CFG holds every setting: "key" for the top of the file, "codex.key" and "repair.key" for those
# sections, "server.NAME.key" for a [server NAME] section. SERVERS lists the server names in
# file order.
typeset -gA CFG
typeset -ga SERVERS

expand_path() { print -r -- ${1/#\~/$HOME} }

# Read the config. On any error nothing changes: the previous CFG and SERVERS stay, so a typo
# saved while the watchdog runs does not take its servers away.
load_config() {
  setopt local_options extended_glob
  local -A c seen_dir
  local -a s
  local line sec='' key val name d
  c=(
    label_prefix     com.remote-agents
    probe_url        https://api.anthropic.com/
    min_idle         600
    down_after       300
    codex.enabled    no
    codex.alert_after 1800
    repair.agent     none
    repair.model     haiku
    repair.permission_mode default
    repair.ttl       7200
  )
  [[ -r $RA_CONFIG ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ '^[[:space:]]*([#;].*)?$' ]] && continue
    if [[ $line =~ '^[[:space:]]*\[([^]]+)\][[:space:]]*$' ]]; then
      sec=${match[1]}
      if [[ $sec == server\ * ]]; then
        name=${${sec#server }//[[:space:]]/}
        [[ $name =~ '^[A-Za-z0-9._-]+$' ]] || { warn "config: bad server name '$name' (letters, digits, . _ -)"; return 1 }
        (( ${s[(Ie)$name]} )) && { warn "config: two [server $name] sections"; return 1 }
        s+=$name
        sec=server.$name
      elif [[ $sec != (codex|repair) ]]; then
        warn "config: unknown section [$sec]"; return 1
      fi
      continue
    fi
    [[ $line == *=* ]] || { warn "config: cannot read line: $line"; return 1 }
    key=${${line%%=*}//[[:space:]]/}
    val=${line#*=}
    val=${${val##[[:space:]]#}%%[[:space:]]#}
    c[${sec:+$sec.}$key]=$val
  done < $RA_CONFIG
  # Numbers are used in arithmetic later; take nothing but digits.
  for key in min_idle down_after start_delay codex.alert_after repair.ttl; do
    [[ -z ${c[$key]-} || ${c[$key]} =~ '^[0-9]{1,9}$' ]] || { warn "config: $key must be a number of seconds"; return 1 }
  done
  # One server per folder: two would fight over the same Remote Control registration.
  for name in $s; do
    d=$(expand_path "${c[server.$name.dir]-}")
    [[ -n $d ]] || { warn "config: [server $name] has no dir"; return 1 }
    d=${d:A}
    [[ -n ${seen_dir[$d]-} ]] && { warn "config: servers ${seen_dir[$d]} and $name use the same folder $d"; return 1 }
    seen_dir[$d]=$name
  done
  CFG=("${(@kv)c}")
  SERVERS=($s)
  return 0
}

cfg() { print -r -- ${CFG[$1]:-${2-}} }
srv() { print -r -- ${CFG[server.$1.$2]:-${3-}} }
is_yes() { [[ ${1:l} == (yes|true|1|on) ]] }

# The folder a server runs in, resolved.
srv_dir() { local d=$(expand_path "$(srv $1 dir)"); print -r -- ${d:A} }

need_server() {
  (( ${SERVERS[(Ie)$1]} )) || die "no [server $1] in $RA_CONFIG"
  [[ -d $(srv_dir $1) ]] || die "server $1: dir '$(srv $1 dir)' is not a folder"
}

ensure_dirs() { mkdir -p $RA_STATE/{locks,env,paused,incidents} $RA_LOGS }

# with_lock FILE CMD...: run a command while holding a lock, so that two processes cannot both be
# in the middle of a step that must not interleave. Waits up to 30 s for the other one.
with_lock() {
  local f=$1 fd rc
  shift
  : >>| $f
  zsystem flock -t 30 -f fd $f || return 1
  "$@"; rc=$?
  zsystem flock -u $fd
  return $rc
}

# ---------------------------------------------------------------- helpers

# jget FILE KEY: one value of a JSON file (plutil reads JSON on every Mac).
jget() { [[ -r $1 ]] && plutil -extract $2 raw -o - $1 2>/dev/null }

mtime() { zstat +mtime -- $1 2>/dev/null || print 0 }
age()   { print $(( EPOCHSECONDS - $(mtime $1) )) }

# write_file FILE LINE...: replace a small state file in one step.
write_file() {
  local f=$1; shift
  print -rl -- "$@" >| $f.tmp.$$ && mv -f $f.tmp.$$ $f
}

# with_timeout SECONDS CMD...: run a command with a deadline. The command gets its own session
# (no terminal: in a terminal tab a background process group that touches the terminal would be
# stopped) and the whole group is ended at the deadline, so a hung child cannot outlive it. Send
# the output to a file, not a pipe: a pipe stays open for as long as any descendant holds it.
with_timeout() {
  perl -MPOSIX -e '
    my $t = shift; my $pid = fork; defined $pid or exit 125;
    if (!$pid) { POSIX::setsid(); exec @ARGV; exit 127 }
    $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 2; kill "KILL", -$pid; exit 124 };
    alarm $t; waitpid $pid, 0; exit($? >> 8 || ($? & 127 ? 128 + ($? & 127) : 0))' "$@"
}

# Does anything answer at probe_url? Any HTTP reply counts.
network_up() { curl -s -o /dev/null -m 8 "$(cfg probe_url)" }

# Set `reply` to the words of a command written in the config: quotes group words, and a leading
# ~ in a word is the home folder. Nothing else is interpreted; the words are run as they are.
config_words() {
  reply=("${(@Q)${(z)1}}")
  reply=("${(@)reply/#\~\//$HOME/}")
}

# Quote words into one command line a shell reads back as the same words.
shell_line() { print -r -- "${(j: :)${(@q)@}}" }

# Variables a parent Claude Code session leaks into its children. A server started with them
# would take that session's identity; an API key would switch it from the subscription login.
scrub_env() {
  local v
  for v in ${(k)parameters[(R)*export*]}; do
    case $v in
      CLAUDE_CONFIG_DIR) ;;
      CLAUDECODE|CLAUDE_PID|CLAUDE_EFFORT|AI_AGENT|CLAUDE_CODE_*|CLAUDE_REMOTE_CONTROL_*) unset $v ;;
      ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN) unset $v ;;
    esac
  done
}
