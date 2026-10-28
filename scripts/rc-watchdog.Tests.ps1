# Pester 3.4 (ships with Windows): Invoke-Pester .\scripts\rc-watchdog.Tests.ps1
. (Join-Path $PSScriptRoot 'rc-watchdog.ps1')

Describe 'Invoke-ZombieReap' {
    $zombie = 4101; $session = 4102; $supervisor = 4103; $live = 4104; $young = 4105; $server = 4106

    $logFile     = Join-Path $TestDrive 'rc-watchdog.log'
    $statusFile  = Join-Path $TestDrive 'daemon.status.json'
    $sessionsDir = Join-Path $TestDrive 'sessions'
    New-Item -ItemType Directory -Force $sessionsDir | Out-Null
    "{`"supervisorPid`":$supervisor,`"workers`":{}}" | Set-Content $statusFile
    "{`"pid`":$session,`"kind`":`"interactive`",`"status`":`"idle`"}" | Set-Content (Join-Path $sessionsDir "$session.json")

    # Stand-in for the claude CLI: leaves a marker if anything launches it.
    $marker = Join-Path $TestDrive 'claude-was-run'
    $claudeExe = Join-Path $TestDrive 'claude.cmd'
    "@echo off`r`necho ran> `"$marker`"`r`necho []" | Set-Content $claudeExe

    Mock Get-NetTCPConnection {
        foreach ($p in $zombie, $session, $supervisor, $young, $server) {
            [pscustomobject]@{ State = 'CloseWait'; OwningProcess = $p }
        }
        [pscustomobject]@{ State = 'CloseWait';   OwningProcess = $live }
        [pscustomobject]@{ State = 'Established'; OwningProcess = $live }
    }
    Mock Get-Process {
        $age = if ($Id -eq $young) { 2 } else { 60 }
        [pscustomobject]@{ Id = $Id; Path = 'C:\tools\claude.exe'; StartTime = (Get-Date).AddMinutes(-$age) }
    }
    Mock Stop-Process {}

    Invoke-ZombieReap -extraProtected @($server)

    It 'reaps the CloseWait-only claude.exe older than 10 minutes' {
        Assert-MockCalled Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq $zombie }
    }
    It 'reaps nothing else (session, supervisor, live, young, server)' {
        Assert-MockCalled Stop-Process -Times 1 -Exactly
    }
    It 'never launches the claude CLI' {
        Test-Path $marker | Should Be $false
    }
}

Describe 'Invoke-ZombieReap with an unreadable session registry' {
    $logFile     = Join-Path $TestDrive 'rc-watchdog.log'
    $statusFile  = Join-Path $TestDrive 'daemon.status.json'
    $sessionsDir = Join-Path $TestDrive 'sessions-broken'
    New-Item -ItemType Directory -Force $sessionsDir | Out-Null
    '{"supervisorPid":4299,"workers":{}}' | Set-Content $statusFile
    '{"pid":4201,"kind":"inter' | Set-Content (Join-Path $sessionsDir '4201.json')   # mid-write

    Mock Get-NetTCPConnection { [pscustomobject]@{ State = 'CloseWait'; OwningProcess = 4201 } }
    Mock Get-Process { [pscustomobject]@{ Id = $Id; Path = 'C:\tools\claude.exe'; StartTime = (Get-Date).AddHours(-1) } }
    Mock Stop-Process {}

    Invoke-ZombieReap -extraProtected @()

    It 'reaps nothing when it cannot tell which sessions are live' {
        Assert-MockCalled Stop-Process -Times 0 -Exactly
    }
    It 'logs why it skipped' {
        Get-Content $logFile -Raw | Should Match 'skipping zombie reap, cannot read live sessions'
    }
}

Describe 'Invoke-ZombieReap with an unreadable daemon status' {
    $logFile     = Join-Path $TestDrive 'rc-watchdog.log'
    $statusFile  = Join-Path $TestDrive 'daemon.status.json'
    $sessionsDir = Join-Path $TestDrive 'sessions'
    New-Item -ItemType Directory -Force $sessionsDir | Out-Null
    '{"supervisorPid":43' | Set-Content $statusFile   # mid-write

    Mock Get-NetTCPConnection { [pscustomobject]@{ State = 'CloseWait'; OwningProcess = 4301 } }
    Mock Get-Process { [pscustomobject]@{ Id = $Id; Path = 'C:\tools\claude.exe'; StartTime = (Get-Date).AddHours(-1) } }
    Mock Stop-Process {}

    Invoke-ZombieReap -extraProtected @()

    It 'reaps nothing when it cannot tell which pid is the supervisor' {
        Assert-MockCalled Stop-Process -Times 0 -Exactly
    }
}

Describe 'Invoke-ZombieReap with no daemon status file' {
    $logFile     = Join-Path $TestDrive 'rc-watchdog.log'
    $statusFile  = Join-Path $TestDrive 'absent-daemon.status.json'
    $sessionsDir = Join-Path $TestDrive 'sessions'
    New-Item -ItemType Directory -Force $sessionsDir | Out-Null

    Mock Get-NetTCPConnection { [pscustomobject]@{ State = 'CloseWait'; OwningProcess = 4401 } }
    Mock Get-Process { [pscustomobject]@{ Id = $Id; Path = 'C:\tools\claude.exe'; StartTime = (Get-Date).AddHours(-1) } }
    Mock Stop-Process {}

    Invoke-ZombieReap -extraProtected @()

    It 'reaps nothing when the supervisor pid is unknown' {
        Assert-MockCalled Stop-Process -Times 0 -Exactly
    }
    It 'logs why it skipped' {
        Get-Content $logFile -Raw | Should Match 'skipping zombie reap, cannot read daemon status'
    }
}

Describe 'Get-LiveSessionPids' {
    $dir = Join-Path $TestDrive 'sessions'
    New-Item -ItemType Directory -Force $dir | Out-Null
    '{"pid":11,"kind":"interactive"}' | Set-Content (Join-Path $dir '11.json')
    '{"pid":22,"kind":"interactive"}' | Set-Content (Join-Path $dir '22.json')

    It 'returns the pid of every session file' {
        @(Get-LiveSessionPids -Dir $dir | Sort-Object) -join ',' | Should Be '11,22'
    }
    It 'throws when the directory is missing' {
        { Get-LiveSessionPids -Dir (Join-Path $TestDrive 'absent') } | Should Throw
    }
    It 'throws on a file that is not JSON' {
        $bad = Join-Path $TestDrive 'bad'
        New-Item -ItemType Directory -Force $bad | Out-Null
        'not json' | Set-Content (Join-Path $bad '33.json')
        { Get-LiveSessionPids -Dir $bad } | Should Throw
    }
    It 'throws on a file without a pid' {
        $nopid = Join-Path $TestDrive 'nopid'
        New-Item -ItemType Directory -Force $nopid | Out-Null
        '{"kind":"interactive"}' | Set-Content (Join-Path $nopid '44.json')
        { Get-LiveSessionPids -Dir $nopid } | Should Throw
    }
}
