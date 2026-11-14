# Repair runbook

For the repair session that `remote-agents` starts when it opens an incident, and for a person
doing the same by hand.

## Rules

- Look first. `remote-agents status`, `doctor`, `incidents`, `sessions` and `logs` change nothing.
- The only fix to apply without asking is `remote-agents ensure`: it starts what is missing and
  does nothing else.
- Everything else is the owner's decision. Name the exact command and the reason, and let them
  approve it.
- Never stop, kill or restart a server on your own. Never use `--force` or
  `--allow-session-loss`. Never edit or delete anything under `~/.claude` or the state folder
  (`~/.local/state/remote-agents`). Never archive, merge or delete sessions. Never start another
  repair session.
- A server that is up and registered is healthy, even when an incident about something else is
  open. Leave it alone.

## What each incident means

| Incident | Meaning | What to check | What usually fixes it |
|---|---|---|---|
| `down.NAME` | No server has been running in the folder for several minutes | `status`: is the supervisor running? `logs NAME` (launchd host) or the terminal tab: why does the server exit? | `ensure`. If the supervisor runs but the server keeps exiting, see `flap.NAME`. If the terminal app that hosts the tabs does not answer, the owner has to restart it. |
| `flap.NAME` | The server exits within a minute of every start | The last lines the server printed: a trust prompt, "already served", a login error | Trust prompt: the owner runs `claude` once in that folder and accepts. "Already served": another Remote Control process uses the folder; find it with `ps` and tell the owner. |
| `stuck.NAME` | The server process is up but never registered | The server's output: waiting at a prompt, or refused by the service (refusals end by themselves within a few minutes after a recent stop) | Wait ten minutes. Still stuck: recommend `remote-agents restart NAME` to the owner. |
| `env.NAME` | The server came back on a new environment; sessions that were open on the old one are detached | `sessions` lists them | Nothing is lost: each detached session comes back with `remote-agents reattach SESSION_ID --dir FOLDER --like NAME`, one at a time per old environment. Which ones matter is the owner's call. |
| `auth` | Claude Code is signed out on this Mac | `claude auth status` | Only the owner can sign in: `claude auth login` on the Mac. |
| `auth-expiring` | The login expires within three days | `claude auth status` shows the date | The owner renews it: `claude auth login`. |
| `codex` | Codex remote control has not been connected for a while | `doctor` prints the daemon's state; does `codex --version` answer at all? | `ensure` starts the daemon. A `codex` that hangs right after a Homebrew upgrade: `remote-agents codex-release-quarantine`. Signed out: the owner runs `codex login`. |

## Reporting

End with three things: the cause, what you did, what is left for the owner. If you could not
find the cause, say so and list what you ruled out.
