# rc-watchdog.ps1 — keep a `claude remote-control` server alive on this Windows PC
# so the machine ALWAYS shows up as a selectable environment in claude.ai/code and
# the Claude mobile app, letting you spawn/drive LOCAL sessions from your phone
# (full access to your local files, SSH, tools) even after a crash.
#
# Why a server (not a background agent): `claude remote-control` is the mechanism
# that registers this machine as a remote ENVIRONMENT you can create new sessions in.
# It runs independently of your editor, so an editor/CLI crash doesn't take it down;
# only a full OS crash does, and the scheduled task brings it back at boot/logon.
#
# Run every few minutes by the "Claude Remote Control Keepalive" scheduled task
# (via run-hidden.vbs so there's no console flash). Safe to run by hand to test.
#
# Config: edit config.ps1 next to this file (install.ps1 generates it).

$ErrorActionPreference = 'Continue'

# ---------------- config (defaults; overridden by config.ps1) ----------------
$RcName         = $env:COMPUTERNAME   # name shown in claude.ai/code & the app
$WorkDir        = $env:USERPROFILE    # directory new remote sessions open in
$PermissionMode = 'default'           # default|acceptEdits|bypassPermissions|plan|dontAsk|auto
$cfg = Join-Path $PSScriptRoot 'config.ps1'
if (Test-Path $cfg) { . $cfg }

# ---------------- paths ----------------
$stateDir = Join-Path $PSScriptRoot 'state'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Force $stateDir | Out-Null }
$logFile     = Join-Path $stateDir 'rc-watchdog.log'
$pidFile     = Join-Path $stateDir 'rc-server.pid'
$startMarker = Join-Path $stateDir 'rc-server.laststart'
$statusFile  = Join-Path $env:USERPROFILE '.claude\daemon.status.json'  # Claude's own daemon file (reaper protection)
$sessionsDir = Join-Path $env:USERPROFILE '.claude\sessions'            # one <pid>.json per live session (reaper protection)

function Log($msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logFile -Value "[$ts] $msg"
}
if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) {
    Get-Content $logFile -Tail 200 | Set-Content $logFile
}

# ---------------- helpers ----------------
# Find a running remote-control SERVER by command line. Matches the `remote-control`
# SUBCOMMAND only, NOT the `--remote-control` flag that ordinary interactive sessions
# carry. The (?<!-) lookbehind rejects `--remote-control` while accepting the bare
# subcommand. (Used only as a secondary signal + reaper protection — NOT for the
# managed-server health check, because Win32_Process.CommandLine is intermittently
# null right after a process starts.)
function Get-RcServer {
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop |
                 Where-Object { $_.CommandLine -and $_.CommandLine -match '(?<!-)remote-control' -and $_.CommandLine -notmatch '--help' })
    } catch {
        Log "WARN: could not query processes: $_"
        return @()
    }
}

# PIDs of live sessions, read from Claude's own session registry (~/.claude/sessions/<pid>.json,
# the same pids `claude agents --json` reports). Never ask the CLI: a short-lived `claude`
# command on this 5-minute timer can spend the OAuth refresh token and force a /login
# (anthropics/claude-code#95822). Background agents have no pid there and none in `agents`.
# Throws when the registry is missing or any file is unreadable (e.g. mid-write): a
# session we cannot see must never look like a zombie.
function Get-LiveSessionPids {
    param([string] $Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { throw "session registry not found: $Dir" }
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File -ErrorAction Stop)) {
        $s = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $s.pid) { throw "session file has no pid: $($f.Name)" }
        [int]$s.pid
    }
}

# Reap zombie claude.exe processes: after Remote Control's ~20-min idle timeout the
# CLI's socket is left in TCP CloseWait and the process never reconnects; these pile
# up over a long uptime. Kill ONLY clearly-dead ones, with safety gates so we never
# touch a live session/server:
#   - is a claude.exe, >=1 CloseWait AND 0 Established, older than 10 min
#   - not the daemon supervisor / not a live interactive session / not the RC server
# Every input comes from files and Get-Process; it never runs the claude CLI (see
# Get-LiveSessionPids).
function Invoke-ZombieReap {
    param([int[]] $extraProtected)
    $conns = $null
    try { $conns = Get-NetTCPConnection -ErrorAction SilentlyContinue } catch { return }
    if (-not $conns) { return }

    $protected = @{}
    foreach ($x in $extraProtected) { if ($x) { $protected[[int]$x] = $true } }
    if (Test-Path -LiteralPath $statusFile) {   # no file = no daemon
        try { $st = Get-Content -LiteralPath $statusFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { Log "WARN: skipping zombie reap, cannot read daemon status: $_"; return }
        if ($st.supervisorPid) { $protected[[int]$st.supervisorPid] = $true }
    }
    try { $live = @(Get-LiveSessionPids -Dir $sessionsDir) }
    catch { Log "WARN: skipping zombie reap, cannot read live sessions: $_"; return }
    foreach ($x in $live) { $protected[$x] = $true }

    $byPid = @{}
    foreach ($c in $conns) {
        if ($c.State -ne 'CloseWait' -and $c.State -ne 'Established') { continue }
        $opid = [int]$c.OwningProcess
        if ($opid -le 0 -or $protected.ContainsKey($opid)) { continue }
        $p = Get-Process -Id $opid -ErrorAction SilentlyContinue
        if (-not $p -or $p.Path -notmatch 'claude') { continue }
        if (-not $byPid.ContainsKey($opid)) { $byPid[$opid] = @{ cw = 0; est = 0; start = $p.StartTime } }
        if ($c.State -eq 'CloseWait') { $byPid[$opid].cw++ } else { $byPid[$opid].est++ }
    }
    foreach ($opid in @($byPid.Keys)) {
        $s = $byPid[$opid]
        $ageMin = ((Get-Date) - $s.start).TotalMinutes
        if ($s.cw -ge 1 -and $s.est -eq 0 -and $ageMin -gt 10) {
            try { Stop-Process -Id $opid -Force -ErrorAction Stop
                  Log ("reaped zombie claude.exe pid={0} (CloseWait={1}, Established=0, age={2:n0}m)" -f $opid, $s.cw, $ageMin)
            } catch { Log "WARN: failed to reap pid=$opid : $_" }
        }
    }
}

# Dot-sourcing (the Pester tests) loads the helpers above and stops here.
if ($MyInvocation.InvocationName -eq '.') { return }

# ---------------- resolve the claude executable ----------------
# Prefer the native claude.exe; if PATH only has a .cmd/.ps1 shim, find the exe beside it.
$claudeExe = $null
$cmd = Get-Command claude -ErrorAction SilentlyContinue
if ($cmd) {
    if ($cmd.Source -match '\.exe$') {
        $claudeExe = $cmd.Source
    } else {
        $guess = Join-Path (Split-Path $cmd.Source) 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
        $claudeExe = if (Test-Path $guess) { $guess } else { $cmd.Source }
    }
}
if (-not $claudeExe) { Log 'ERROR: claude CLI not found on PATH'; exit 1 }

# ---------------- ensure the server is running ----------------
# Primary health check = PID FILE + Get-Process (reliable). CommandLine scan is only
# used to adopt a manually-started server and to protect the reaper.
$trackedPid  = $null
$serverAlive = $false
if (Test-Path $pidFile) {
    try {
        $trackedPid = [int]((Get-Content $pidFile -Raw).Trim())
        $proc = Get-Process -Id $trackedPid -ErrorAction SilentlyContinue
        if ($proc -and $proc.Path -match 'claude') { $serverAlive = $true }
    } catch {}
}

$cmdServers  = Get-RcServer
$protectPids = @(@($cmdServers | ForEach-Object { [int]$_.ProcessId }) + @($trackedPid) | Where-Object { $_ })
Invoke-ZombieReap -extraProtected $protectPids

if ($serverAlive) { exit 0 }  # healthy

if ($cmdServers.Count -ge 1) {
    Set-Content -Path $pidFile -Value ([int]$cmdServers[0].ProcessId) -NoNewline   # adopt existing
    exit 0
}

# Grace period: a freshly launched server can take ~15-60s to connect. Don't start a
# second one if we launched one in the last 90s (prevents duplicate servers).
if (Test-Path $startMarker) {
    try {
        $last = [datetime]((Get-Content $startMarker -Raw).Trim())
        if (((Get-Date) - $last).TotalSeconds -lt 90) {
            Log 'server not confirmed yet but one was launched <90s ago -- waiting'
            exit 0
        }
    } catch {}
}

Log "starting remote-control server (name='$RcName', dir='$WorkDir', perm='$PermissionMode')"
Set-Content -Path $startMarker -Value (Get-Date -Format 'o') -NoNewline
$proc = Start-Process -FilePath $claudeExe `
    -ArgumentList 'remote-control','--name',$RcName,'--permission-mode',$PermissionMode `
    -WorkingDirectory $WorkDir -WindowStyle Hidden -PassThru
if ($proc) {
    Set-Content -Path $pidFile -Value ([int]$proc.Id) -NoNewline
    Start-Sleep -Seconds 10
    if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) {
        Log "remote-control server started (pid $($proc.Id))"
    } else {
        Log "WARN: server pid $($proc.Id) exited within 10s -- will retry next cycle"
    }
} else {
    Log 'ERROR: Start-Process returned no handle for the server'
}
