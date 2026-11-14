# Codex remote control. Codex has no server per folder: one managed app-server daemon per Mac
# holds the remote-control connection and updates itself. All there is to do is to make sure it
# is running and connected, and to notice when it is not.

codex_bin() {
  local c=$(expand_path "$(cfg codex.command)")
  [[ -n $c ]] || c=$(whence -p codex)
  print -r -- $c
}

# Start the daemon with remote control when it is down; print "STATUS DAEMON VERSION SERVER".
# `codex remote-control start` only reports when the daemon already runs, so this is safe to
# repeat. With a deadline, because a codex binary can hang before it prints anything.
codex_ensure() {
  local c=$(codex_bin) out=$(mktemp) last=$(mktemp) rc
  [[ -x $c ]] || { rm -f $out $last; print "missing - - -"; return 1 }
  with_timeout 90 $c remote-control start --json >| $out 2>&1; rc=$?
  grep '^{' $out | tail -1 >| $last
  print -r -- "$(jget $last status || print unknown)" "$(jget $last daemon.status || print -)" \
    "$(jget $last daemon.appServerVersion || print -)" "$(jget $last serverName || print -)"
  rm -f $out $last
  return $rc
}

# Homebrew puts a quarantine flag on every cask it installs, and a quarantined codex binary can
# hang at start, waiting for a first-launch check that needs someone at the unlocked screen. On a
# Mac nobody sits at, that takes Codex down until the next login. Remove the flag, but only from
# binaries that carry OpenAI's Developer ID signature. Run it after `brew upgrade`.
cmd_codex_release_quarantine() {
  local req='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "2DC432GLL2"'
  local f n=0
  for f in /opt/homebrew/Caskroom/codex/*/bin/*(N.x) /usr/local/Caskroom/codex/*/bin/*(N.x); do
    xattr -p com.apple.quarantine $f >/dev/null 2>&1 || continue
    if codesign --verify --strict -R="$req" $f 2>/dev/null; then
      xattr -d com.apple.quarantine $f && (( n += 1 ))
    else
      log "codex: $f is quarantined and not signed by OpenAI; left alone"
    fi
  done
  (( n )) && log "codex: removed the quarantine flag from $n binaries"
  return 0
}
