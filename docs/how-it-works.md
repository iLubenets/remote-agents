# How it works

## The pieces

- **Supervisor** (`remote-agents run NAME`): a loop around `claude remote-control`, one per
  server, guarded by a lock. It waits for the network and a valid login before it starts the
  server, and starts it again after it exits: after 10 s, after 60 s when it ran under a minute,
  every 5 min once it keeps failing. Told to stop from outside (logout, uninstall, its terminal
  tab closed), it stops the server with SIGTERM and waits.
- **Watchdog** (`remote-agents watchdog`): one loop under launchd that makes a pass about every
  20 seconds while the Mac is online. It asks the host for a supervisor that is missing, runs the
  Codex check, and opens incidents. It never stops or restarts a server.
- **Host**: where supervisors live. A LaunchAgent per server by default; with `start_command`,
  whatever that command opens, for example a terminal tab (the sessions then inherit the
  terminal's macOS permissions).
- **Incidents**: a file per open problem. Each one is announced on the Mac and, when a
  `notify_command` is configured, sent through it until that succeeds.
- **Repair session** (optional, `[repair] agent = claude`): `claude --model <cheap>
  --remote-control`, one at a time, for incidents a look at the machine can help with (not for
  login problems or an ended reattached session). It gets a short list of read-only commands and
  `remote-agents ensure` without asking; for anything else it asks you in the Claude app. That
  list is a convenience, not a sandbox: permissions already granted in the folder it runs in
  still apply, so give it an empty folder of its own (`[repair] dir`).

What it reads from Claude Code: the process table, the bridge pointer
(`~/.claude/projects/<folder>/bridge-pointer.json`: the environment a server registered and its
pid) and the session state files (`~/.claude/sessions/<pid>.json`). Its own state is in
`~/.local/state/remote-agents`, logs in `~/Library/Logs/remote-agents`.

## Why a restart can lose sessions

A server registers an *environment* with Anthropic, and sessions belong to it. Stopped with
SIGTERM while it owns its bridge pointer, the server keeps the environment, and the next start in
that folder reuses it: the sessions reconnect. A server started with `--no-create-session-in-dir`
does not keep it: the stop archives its sessions. A start that registers a new environment leaves
the old sessions behind.

`remote-agents restart` therefore checks before it stops anything (no such flag, the pointer is
owned by this server, no session at work in the last ten minutes) and compares the environment
after the new server is up. `--force` skips the "at work" check, `--allow-session-loss` the safety
check, `--dry-run` shows the decision, `--if-needed` restarts only when Claude Code or the flags
changed. A server that does not stop within 90 seconds is left alone: `restart` never force-kills
a server.

## What happens when

| What goes wrong | What happens |
|---|---|
| The server exits (crash, network give-up, login problem) | Its supervisor starts it again, after waiting for the network and the login. |
| The supervisor is gone (terminal closed, reboot) | The watchdog asks the host for a new one on one of its next passes (at most once every two minutes per server). |
| Ten minutes or more without the network | The server gives up and exits, keeping its environment; the supervisor brings it back on it. |
| A new Claude Code is installed | The tool does not restart servers for updates; Claude Code decides which version new sessions use. `restart` when you want the server itself on the new version. |
| `--no-create-session-in-dir` in the flags | Dropped at start, whatever the config says. |
| A session is at work during `restart` or `stop` | Refused, unless `--force`. |
| The config is edited or the tool reinstalled | `install` never stops a running server, and `uninstall` refuses while one runs (unless `uninstall --force`). A config that does not parse keeps the last good one in force. |
| The server comes back on a different environment | Incident `env.NAME`. `sessions` lists the detached ones, `reattach` brings one back (one at a time per old environment). |
| The server is up but never registers | Incident `stuck.NAME` after five minutes. |
| The server keeps exiting right after start | Incident `flap.NAME`. |
| No server for five minutes | Incident `down.NAME`. |
| The login expired, or expires within three days | Incident, with the command to run. |
| A reattached session's process ends | Incident, once, with the command to bring it back. |
| A server is started from inside another Claude Code session | The inherited session variables and API keys are cleared first, so servers use the subscription login. |
| Codex daemon down, or `codex` hangs | `codex remote-control start` every ten minutes with a deadline; incident after 30 minutes without a connection. |
| `codex` hangs after a Homebrew upgrade (quarantine flag) | `remote-agents codex-release-quarantine` after `brew upgrade`; it only touches binaries signed by OpenAI. |

## Changing things

- A new server: add a `[server NAME]` section, `remote-agents install`.
- Another folder for a server: `remote-agents stop NAME`, edit the config, `remote-agents install`,
  `remote-agents start NAME`. Two servers cannot share a folder.
- Removing it all: `remote-agents stop NAME...`, then `remote-agents uninstall`. A stopped server
  keeps its environment, so installing again soon after normally finds the same sessions; run
  `remote-agents start NAME` to resume servers that were stopped.
