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
        Get-Content $logFile -Raw | Should Match 'skipping zombie reap.*session file 4201\.json'
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
        Get-Content $logFile -Raw | Should Match 'skipping zombie reap.*daemon status'
    }
}

Describe 'Invoke-ZombieReap with a daemon status that names no supervisor' {
    $logFile     = Join-Path $TestDrive 'rc-watchdog.log'
    $statusFile  = Join-Path $TestDrive 'daemon.status.json'
    $sessionsDir = Join-Path $TestDrive 'sessions'
    New-Item -ItemType Directory -Force $sessionsDir | Out-Null
    '{"workers":{}}' | Set-Content $statusFile

    Mock Get-NetTCPConnection { [pscustomobject]@{ State = 'CloseWait'; OwningProcess = 4501 } }
    Mock Get-Process { [pscustomobject]@{ Id = $Id; Path = 'C:\tools\claude.exe'; StartTime = (Get-Date).AddHours(-1) } }
    Mock Stop-Process {}

    Invoke-ZombieReap -extraProtected @()

    It 'reaps nothing' {
        Assert-MockCalled Stop-Process -Times 0 -Exactly
    }
    It 'logs why it skipped' {
        Get-Content $logFile -Raw | Should Match 'skipping zombie reap.*supervisorPid'
    }
}

Describe 'Invoke-ZombieReap when a session registers between the read and the kill' {
    $logFile     = Join-Path $TestDrive 'rc-watchdog.log'
    $statusFile  = Join-Path $TestDrive 'daemon.status.json'
    $sessionsDir = Join-Path $TestDrive 'sessions'
    New-Item -ItemType Directory -Force $sessionsDir | Out-Null
    '{"supervisorPid":4699,"workers":{}}' | Set-Content $statusFile

    # First read: no sessions. Every later read: pid 4601 has registered.
    $script:reads = 0
    Mock Get-LiveSessionPids { $script:reads++; if ($script:reads -gt 1) { 4601 } }
    Mock Get-NetTCPConnection { [pscustomobject]@{ State = 'CloseWait'; OwningProcess = 4601 } }
    Mock Get-Process { [pscustomobject]@{ Id = $Id; Path = 'C:\tools\claude.exe'; StartTime = (Get-Date).AddHours(-1) } }
    Mock Stop-Process {}

    Invoke-ZombieReap -extraProtected @()

    It 're-reads the protected pids before killing and spares the new session' {
        Assert-MockCalled Stop-Process -Times 0 -Exactly
        $script:reads | Should BeGreaterThan 1
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
    It 'throws on a file that is not JSON, naming the file' {
        $bad = Join-Path $TestDrive 'bad'
        New-Item -ItemType Directory -Force $bad | Out-Null
        'not json' | Set-Content (Join-Path $bad '33.json')
        { Get-LiveSessionPids -Dir $bad } | Should Throw '33.json'
    }
    It 'throws on a file without a pid' {
        $nopid = Join-Path $TestDrive 'nopid'
        New-Item -ItemType Directory -Force $nopid | Out-Null
        '{"kind":"interactive"}' | Set-Content (Join-Path $nopid '44.json')
        { Get-LiveSessionPids -Dir $nopid } | Should Throw
    }
    foreach ($case in @(
        @{ name = 'a non-numeric pid'; json = '{"pid":"abc"}' }
        @{ name = 'a fractional pid';  json = '{"pid":12.5}' }
        @{ name = 'a negative pid';    json = '{"pid":-3}' }
    )) {
        It "throws on a file with $($case.name), naming the file" {
            $d = Join-Path $TestDrive ([guid]::NewGuid())
            New-Item -ItemType Directory -Force $d | Out-Null
            $case.json | Set-Content (Join-Path $d '55.json')
            { Get-LiveSessionPids -Dir $d } | Should Throw '55.json'
        }
    }
}

Describe 'ConvertTo-Pid' {
    It 'accepts a positive whole number' {
        ConvertTo-Pid 4321 | Should Be 4321
    }
    foreach ($bad in @('abc', 12.5, -3, 0, $null, 99999999999)) {
        It "rejects '$bad'" {
            { ConvertTo-Pid $bad } | Should Throw
        }
    }
}

Describe 'Invoke-ZombieReap with a fractional supervisorPid' {
    $logFile     = Join-Path $TestDrive 'rc-watchdog.log'
    $statusFile  = Join-Path $TestDrive 'daemon.status.json'
    $sessionsDir = Join-Path $TestDrive 'sessions'
    New-Item -ItemType Directory -Force $sessionsDir | Out-Null
    '{"supervisorPid":4799.5,"workers":{}}' | Set-Content $statusFile

    Mock Get-NetTCPConnection { [pscustomobject]@{ State = 'CloseWait'; OwningProcess = 4801 } }
    Mock Get-Process { [pscustomobject]@{ Id = $Id; Path = 'C:\tools\claude.exe'; StartTime = (Get-Date).AddHours(-1) } }
    Mock Stop-Process {}

    Invoke-ZombieReap -extraProtected @()

    It 'reaps nothing' {
        Assert-MockCalled Stop-Process -Times 0 -Exactly
    }
}
