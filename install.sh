#!/bin/zsh
# Link the command into ~/.local/bin and create the config from the example.
# Then: edit ~/.config/remote-agents/config and run `remote-agents install`.
emulate -L zsh
root=${0:A:h}
conf=${REMOTE_AGENTS_CONFIG:-$HOME/.config/remote-agents/config}
mkdir -p $HOME/.local/bin ${conf:h}
ln -sf $root/bin/remote-agents $HOME/.local/bin/remote-agents
print "linked $HOME/.local/bin/remote-agents -> $root/bin/remote-agents"
if [[ -e $conf ]]; then
  print "kept the existing config $conf"
else
  cp $root/config/remote-agents.conf.example $conf
  print "created $conf from the example"
fi
[[ :$PATH: == *:$HOME/.local/bin:* ]] || print "note: $HOME/.local/bin is not on your PATH"
print "next: edit $conf, then run: remote-agents install && remote-agents doctor"
