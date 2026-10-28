# claude-remote-control-keepalive review rules

Sent to the adversarial review lenses when a diff touches a matching path. Each rule records a defect that shipped or was caught once. Add a rule when a reviewer could have seen the defect in the diff.

## Watchdog timer must not run short-lived claude commands
paths: scripts/*.ps1 install.ps1

- Nothing the 5-minute watchdog runs may start a short-lived `claude` subcommand (`claude agents --json`, `claude daemon status`). Every `claude` command begins an OAuth refresh when the token is within 5 minutes of expiry, and a command that exits before saving the rotated token leaves `~/.claude/.oauth_refresh.lock` held for 60 seconds. The long-lived process's next refresh then fails, retries with the spent token, gets `invalid_grant`, and the credentials are blanked: this forced a `/login` on the Dev PC every 1 to 3 days until it was traced to the watchdogs (anthropics/claude-code#95822). `Invoke-ZombieReap` used to run `& $claudeExe agents --json`; it now reads live-session pids from `~/.claude/sessions/<pid>.json` (`Get-LiveSessionPids`). Do not bring the CLI call back, and any new one must be skipped unless `expiresAt` in `.credentials.json` is more than 15 minutes away. Starting the long-lived `remote-control` server is fine.
- Read another tool's state from its files (a pid in `daemon.lock`, `daemon.status.json`) instead of asking its CLI.

## Server detection and the reaper
paths: scripts/rc-watchdog.ps1

- The server's health is the PID file plus `Get-Process`. Do not decide "not running" from `Win32_Process.CommandLine`: it is intermittently null for tens of seconds after a process starts, which launched duplicate servers.
- Any command-line match for the server uses `(?<!-)remote-control`, the subcommand only. Interactive sessions carry the `--remote-control` flag, and a plain `-match 'remote-control'` matches every one of them.
- Keep the 90-second `rc-server.laststart` grace window before starting another server; a fresh server takes 15 to 60 seconds to connect.
- The zombie reaper kills a `claude.exe` only when it has at least one `CloseWait` connection, zero `Established`, and is older than 10 minutes, and never the tracked server PID, a discovered server, the daemon supervisor, or a live agent. Do not loosen any of those conditions, and do not reap by process age or name alone.

## Hidden launcher
paths: scripts/run-hidden.vbs

- `WshShell.Run(cmd, 0, True)` returns the exit code as its function value; there is no `shell.ExitCode` property. Reading it throws 800A01B6 and Windows Script Host shows a modal error dialog, which is worse than the console window the wrapper exists to hide. Use `rc = shell.Run(cmd, 0, True) : WScript.Quit rc`.
