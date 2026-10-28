# Claude Remote Control Keepalive (Windows)

Keep your Windows PC **always available** in [claude.ai/code](https://claude.ai/code) and the
Claude mobile app, so you can open the app and **start or resume a session on your own
machine** — with full access to your local files, SSH, build tools, and credentials —
even after your editor, the CLI, or the whole machine crashes.

It does this by keeping a [`claude remote-control`](https://docs.claude.com/en/docs/claude-code)
**server** running via a Windows Scheduled Task, restarting it whenever it dies and bringing
it back at boot/logon.

> **Why not the cloud option?** The Claude app can spawn a cloud/sandbox session tied to a
> GitHub repo, but that container can't reach *your* machine — no local files, no SSH to your
> other hosts, no local credentials. For anything that has to run on your actual PC (deploys,
> SSH-driven scripts, local toolchains), you need a **local** remote-control environment. This
> repo keeps one alive.

---

## What it gives you

- A persistent **"environment"** for your PC in claude.ai/code + the mobile app that you can
  spawn new local sessions into, any time.
- **Survives editor/CLI crashes:** the server runs as its own process, independent of VS Code /
  your terminal, so a VS Code or Node/Bun crash doesn't take it down.
- **Comes back after a reboot:** the scheduled task restarts it at logon (or at startup, before
  login — see options).
- A small **zombie reaper** that cleans up dead `claude.exe` processes left in `CloseWait` after
  Remote Control's idle timeout, so they don't pile up over long uptimes.

## Requirements

- Windows 10 / 11.
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and on your `PATH`
  (`claude --version` works).
- A Claude account with Remote Control available (Pro/Max or eligible plan), already logged in
  (`claude` once, signed in).

## Install

```powershell
git clone https://github.com/curran-gehring/claude-remote-control-keepalive
cd claude-remote-control-keepalive

# Run in an ELEVATED PowerShell (Run as administrator):
.\install.ps1 -Name "Dev" -WorkDir C:\Dev
```

Within ~30 seconds, **"Dev"** appears in claude.ai/code and the Claude app. Tap it to start a
session on your PC.

### Options

| Option | Default | Meaning |
|---|---|---|
| `-Name` | computer name | Label shown in claude.ai/code and the app. |
| `-WorkDir` | your user profile | Directory new remote sessions open in (e.g. `C:\Dev`). |
| `-PermissionMode` | `default` | `default` / `acceptEdits` / `bypassPermissions` / `plan` / `dontAsk` / `auto`. See the security note below. |
| `-WhetherLoggedOn` | off | Also run **before you log in** (covers unattended reboots). Requires your Windows **password** — see below. |

### Running before login (`-WhetherLoggedOn`)

By default the task runs **at logon**, which is enough if your machine stays logged in. If your
PC reboots unattended (e.g. overnight updates) and sits at the lock screen, add
`-WhetherLoggedOn` so it starts at boot:

```powershell
.\install.ps1 -Name "Dev" -WorkDir C:\Dev -WhetherLoggedOn
```

You'll be prompted for your Windows account **password**. Important:

- **A Windows Hello PIN will not work** — Task Scheduler can only store an account *password*.
- On **Microsoft Entra / Azure AD** machines the password is your work-account password
  (`you@your-tenant.onmicrosoft.com`). If registration fails with a logon error, re-run and try
  your full UPN as the username, and double-check you typed the password (not the PIN).

## Security note

`-PermissionMode bypassPermissions` means sessions spawned on this machine run **without
permission prompts** — convenient from your phone, but it lets a remote session run anything on
your PC with your privileges. Use it only on a machine you control and trust. The default
(`default`) keeps normal prompts.

## How it works

- A Scheduled Task (`Claude Remote Control Keepalive`) runs `scripts/rc-watchdog.ps1` every
  5 minutes (hidden, via `run-hidden.vbs` so there's no console flash), plus at logon/startup.
- The watchdog:
  1. Checks a **PID file** with `Get-Process` (reliable) to see if its server is alive.
  2. If not, and one wasn't launched in the last 90s, starts
     `claude remote-control --name <Name> --permission-mode <mode>` in `<WorkDir>`, hidden, and
     records its PID.
  3. Reaps dead `claude.exe` zombies (only ones in `CloseWait` with zero live connections,
     >10 min old, and never the server, the daemon, or a live interactive session). Live
     sessions come from `~/.claude/sessions/<pid>.json`, not the `claude` CLI; if that registry
     or `~/.claude/daemon.status.json` can't be read, the reaper skips the cycle.
- Files live in `%USERPROFILE%\.claude-rc-keepalive\` (`rc-watchdog.ps1`, `run-hidden.vbs`,
  `config.ps1`, and `state\` with the log + PID file).

Edit `%USERPROFILE%\.claude-rc-keepalive\config.ps1` to change the name, directory, or
permission mode later; the change takes effect when the server next restarts (or on reboot).

## Known limitation: "ghost" sessions after a hard crash

After a **hard crash** (power loss, BSOD), sessions that were connected can keep showing as
green/"connected" in the app for a while — the server didn't get to disconnect cleanly, and the
backend doesn't immediately prune them. Tapping a ghost just hangs. This is a Claude Code /
backend behavior, not something this tool can fix. Recovery is automatic: on reboot the watchdog
brings your environment back online — just start a **fresh** session on it and ignore the stale
entries (the live one is the most recent). The reaper keeps your machine's *local* process list
clean in the meantime.

## Verify / troubleshoot

```powershell
# Is the server running?
Get-CimInstance Win32_Process -Filter "Name='claude.exe'" |
  Where-Object { $_.CommandLine -match '(?<!-)remote-control' } |
  Select-Object ProcessId, CommandLine

# Watchdog log
Get-Content "$env:USERPROFILE\.claude-rc-keepalive\state\rc-watchdog.log" -Tail 20

# Run the watchdog by hand (foreground)
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude-rc-keepalive\rc-watchdog.ps1"
```

- **"Dev" doesn't appear:** make sure you're logged in (`claude` → signed in) and your plan has
  Remote Control. Check the log for errors.
- **It only offers a cloud session in the app:** that means no local environment is registered —
  i.e. the server isn't running. Check the task ran and the log.

## Uninstall

```powershell
.\uninstall.ps1
```

Stops the server and removes the task. Delete `%USERPROFILE%\.claude-rc-keepalive\` to remove the
logs too.

## License

MIT — see [LICENSE](LICENSE).
