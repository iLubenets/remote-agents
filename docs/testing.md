# How this was tested

## Automated

`zsh tests/run` (about a minute; `zsh tests/run quick` skips the lifecycle part). It uses a
temporary HOME and `tests/fake-claude`, a stand-in that looks like a Remote Control server to
this tool: a process named `claude remote-control …` that writes a bridge pointer, reuses the
environment of an existing one, and exits on SIGTERM. Covered: config parsing and validation,
argument quoting, the timeout wrapper, incident bookkeeping, the supervisor, guarded restart and
stop (busy session, pointer owned by someone else), stop/start, environment-change detection, the
session inventory.

## Against real servers

macOS 27, Claude Code 2.1.325, Codex CLI 0.169.0, throwaway servers in empty folders, hosted both
ways (a terminal tab via `start_command`, and a LaunchAgent).

| Test | Result |
|---|---|
| `remote-agents restart` | Same environment, new server registered after about 6 s. |
| `kill -9` of the server | The supervisor started it again after its backoff; same environment. |
| The terminal tab with the supervisor closed | The watchdog opened a new one within a minute; same environment. |
| `launchctl kickstart -k` of a launchd-hosted supervisor | The supervisor stopped its server with SIGTERM ("Environment preserved"); the new one came back on the same environment. |
| `remote-agents stop`, then `start` | Same environment. |
| Ten minutes without the network. One server ran behind a local CONNECT proxy and the proxy was stopped; the rest of the Mac stayed online. | After 627 s the server printed "Server unreachable for 10 minutes, giving up", then "Environment preserved", and exited with code 4. With the proxy back, the supervisor started it and it registered on the same environment. |
| Start with a bridge pointer whose file time was five hours old | Same environment. (Whether the service itself drops an environment that nobody served for many hours was not tested: that needs a server that is really down that long.) |
| Bridge pointer removed while the server was stopped | The server registered a new environment after about three minutes; the watchdog opened `env.NAME`; `remote-agents sessions` showed the old sessions as detached. |
| `remote-agents reattach` for a detached session | A single-session process started in the helper folder and connected. |
| A server kept down on purpose | `down.NAME` after the configured time; local notification; a repair session started from the launchd watchdog, appeared in the Claude app, sent a push notification, ran `status`, `doctor`, `incidents`, `sessions` and `logs` without asking, and stopped at a permission request for a command outside its list. |

Two behaviours that older write-ups describe did not reproduce on this version, and the tool has
no code for them: losing the environment after the ten-minute give-up, and losing it because the
pointer file is older than four hours.

## Not tested

- A reboot of the Mac (the LaunchAgents are standard `RunAtLoad` + `KeepAlive` jobs).
- An expired login (the check reads `claude auth status`).
- Codex going down for real: the check and the incident were exercised only with Codex connected.
- Any Claude Code version other than the one above.
