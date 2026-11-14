# remote-agents

Keep Claude Code Remote Control servers and Codex remote control always on, on a Mac that nobody
sits at, so that the sessions you drive from your phone or browser are there when you need them
and are still there tomorrow.

`claude remote-control` is a foreground program. It exits after a long network outage, when the
login expires, when it crashes; a restart done the wrong way archives every open session; and
nothing tells you. This tool is the missing part around it: a supervisor per server, one small
watchdog, a guarded restart, and an alarm with a repair session when something breaks that it
cannot heal.

Unofficial. It relies on how Claude Code and Codex behave today (versions below); a release can
change that.

## What it does

| What goes wrong | What happens with remote-agents |
|---|---|
| The server exits (crash, network give-up, login problem) | Its supervisor starts it again: after 10 s, after 60 s when it ran under a minute, every 5 min once it keeps failing. It waits for the network and for a valid login instead of burning starts. |
| The supervisor itself is gone (terminal closed, reboot) | The watchdog starts a new one within two minutes. |
| The network is down for ten minutes or more: the server gives up and exits | The supervisor waits for the network and starts it again. The server keeps its environment when it gives up, so the sessions are there afterwards (tested, see below). |
| Someone restarts the server to load a new Claude Code and the open sessions get archived | Nothing restarts a server automatically. `remote-agents restart` is the only way, and it refuses when the stop would lose sessions (see below). New sessions run the newly installed Claude Code without a restart anyway. |
| `--no-create-session-in-dir` in the flags. With it every stop archives the server's sessions | The flag is dropped at start, whatever the config says. |
| A session is at work when you restart or stop | `restart` and `stop` refuse while any session was active in the last ten minutes. |
| Editing the config or reinstalling takes a server down | `install` and `uninstall` never stop a running server; they tell you to `stop` it first, which checks that its sessions are kept. A config that does not parse keeps the last good one in force. |
| The server comes back on a different environment and the old sessions are detached | Incident. `remote-agents sessions` lists the detached ones, `remote-agents reattach` brings one back. Nothing is rewired automatically. |
| The server is up but never registers (waits at a prompt, refused) | Incident after five minutes. |
| The login expired, or expires within three days | Incident, with the command to run. |
| A session started from inside another Claude Code session inherits its identity or an API key | The supervisor and the watchdog clear those variables first, so servers always use the subscription login. |
| Codex: the daemon is down, or its binary hangs | The watchdog runs `codex remote-control start` every ten minutes with a deadline, and opens an incident after 30 minutes without a connection. |
| Codex hangs after a Homebrew upgrade (quarantine flag, waits for someone at the screen) | `remote-agents codex-release-quarantine`, to run after `brew upgrade`. It only touches binaries signed by OpenAI. |

An incident is announced once on the Mac, then through your own `notify_command` if you set
one, and a repair session is started: Claude Code on a cheap model with Remote Control on, so it
shows up in the Claude app next to your other sessions. It can look (`status`, `doctor`, logs,
process list) and run `remote-agents ensure`. Anything else it has to ask you for, in that
session. [examples/notify-telegram](examples/notify-telegram) is a ready `notify_command` that
sends the message to a Telegram chat. The list of commands it may run without asking is a convenience, not a sandbox: give it
a folder of its own (`[repair] dir`) so no project's settings apply to it.

## What it does not do

- It does not make a running turn survive a restart. A restart keeps the sessions; the turn that
  was running is cut and the session continues on your next message.
- It does not repair environments by itself. When a server lost its environment, it tells you and
  gives you the command; it does not rewrite Claude Code's files or delete registrations.
- It does not update Claude Code or Codex. Leave that to their own updaters.
- It does not keep the Mac awake or log it in. A LaunchAgent runs inside a login session: after a
  reboot someone (or automatic login) has to log in.

## Requirements

- macOS with zsh (the system one). No other dependencies.
- Claude Code, signed in with a claude.ai account (`claude auth login`). Remote Control does not
  work with an API key.
- Every server folder trusted by Claude Code: run `claude` there once and accept, then run
  `claude remote-control` there once by hand and answer its first-run question.
- For Codex: the `codex` CLI, signed in, with remote control paired once (`codex remote-control pair`).

## Install

```sh
git clone https://github.com/iLubenets/remote-agents ~/remote-agents
cd ~/remote-agents
./install.sh                 # links the command into ~/.local/bin, creates the config
$EDITOR ~/.config/remote-agents/config
remote-agents install        # writes and loads the LaunchAgents
remote-agents doctor
```

`remote-agents uninstall` removes the LaunchAgents. The supervisors stop their servers with a
plain SIGTERM, which keeps the environments, so installing again finds the same sessions.

## Configuration

`~/.config/remote-agents/config`, see [config/remote-agents.conf.example](config/remote-agents.conf.example):

```ini
[server projects]
dir = ~/projects
flags = --chrome --permission-mode auto

[codex]
enabled = yes

[repair]
agent = claude
model = haiku
dir = ~/agents-repair
```

One `[server NAME]` per folder; the name is what the Claude app shows. Up to 32 sessions per
server is Claude Code's own default, so one server per folder is enough.

By default the supervisors are LaunchAgents. With `start_command` they run wherever that command
puts them, for example in tabs of a terminal app, which lets the sessions inherit the terminal's
macOS permissions.

To change a server's folder: `remote-agents stop NAME`, edit the config, `remote-agents install`,
`remote-agents start NAME`. Two servers cannot share a folder.

## Commands

```
remote-agents status [--json] [--watch]   every server, Codex, open incidents
remote-agents doctor                      check the setup and say what is wrong
remote-agents sessions                    sessions per server; which ones are detached
remote-agents incidents                   open incidents
remote-agents logs [NAME] [LINES]         the watchdog's log, or a server's

remote-agents ensure                      start whatever is missing
remote-agents restart NAME                restart on purpose, keeping the sessions
remote-agents stop NAME / start NAME      keep a server stopped / let it run again (stop is guarded like restart)
remote-agents reattach SESSION_ID --dir FOLDER [--like NAME]
```

### restart

```
$ remote-agents restart projects
projects: stopping pid 54834 (environment env_01YQ…)
projects: up, pid 56265, 2.1.325, same environment env_01YQ…: open sessions kept
```

It refuses, and says why, when a session is at work, or when the stop would archive the
sessions: the server runs with `--no-create-session-in-dir`, or does not own its bridge pointer.
`--force` overrides the first, `--allow-session-loss` the second, `--dry-run` shows the decision,
`--if-needed` restarts only when Claude Code or the flags changed. A server that does not stop
within 90 seconds is left alone; nothing is force-killed.

## How it works

```
LaunchAgent  ──▶  remote-agents watchdog        every 20 s: looks, asks for a supervisor
                                                that is missing, opens incidents
LaunchAgent  ──▶  remote-agents run NAME   ──▶  claude remote-control …     (one per server)
   or your start_command
```

- **Supervisor** (`run NAME`): a loop around `claude remote-control`. One per server, guarded by
  a lock. Stopped from outside, it stops the server with SIGTERM and waits.
- **Watchdog**: never stops or restarts a server. It reads the process table, Claude Code's
  bridge pointer (`~/.claude/projects/<folder>/bridge-pointer.json`: the environment a server
  registered and its pid) and the session state files (`~/.claude/sessions/<pid>.json`).
- **State** in `~/.local/state/remote-agents`, **logs** in `~/Library/Logs/remote-agents`.

Why a restart can lose sessions: a server registers an *environment* with Anthropic, and sessions
belong to it. Stopped with SIGTERM while it owns its bridge pointer, the server keeps the
environment and the next start in that folder reuses it: sessions reconnect. Stopped any other
way that deregisters the environment, or started in a way that registers a new one, the old
sessions stay behind. `restart` checks the conditions before, and compares the environment after.

## Tested

`zsh tests/run` runs the unit and lifecycle tests against a stand-in for the claude binary; it
needs no Claude Code and touches nothing outside a temporary folder.

Against the real thing, on macOS 27 with Claude Code 2.1.325 and Codex CLI 0.169.0, on throwaway
servers (details in [docs/testing.md](docs/testing.md)):

- guarded restart, SIGKILL of the server, closing the host terminal tab, restart of the launchd
  supervisor: the same environment every time;
- ten minutes without the network (one server behind a local proxy, proxy stopped): the server
  gave up and exited with its environment preserved, and came back on it;
- an environment change (pointer removed while stopped): detected, incident raised, the detached
  session brought back with `reattach`;
- a repair session: started by the watchdog from launchd, visible in the Claude app, diagnosed
  with its allowed commands and asked for permission for the rest.

## License

MIT
