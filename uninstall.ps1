<#
.SYNOPSIS  Remove the Claude Remote Control Keepalive task and stop the server.
.DESCRIPTION
  Unregisters the scheduled task and stops the running remote-control server.
  Leaves the install folder (%USERPROFILE%\.claude-rc-keepalive) in place; delete it
  manually if you also want the logs gone. Run elevated if you installed with
  -WhetherLoggedOn.
#>
$ErrorActionPreference = 'Continue'
$taskName   = 'Claude Remote Control Keepalive'
$installDir = Join-Path $env:USERPROFILE '.claude-rc-keepalive'
$pidFile    = Join-Path $installDir 'state\rc-server.pid'

if (Test-Path $pidFile) {
    try {
        $serverPid = [int]((Get-Content $pidFile -Raw).Trim())
        Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue
        Write-Host "Stopped remote-control server (pid $serverPid)."
    } catch {}
    Remove-Item $pidFile -ErrorAction SilentlyContinue
}

try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
    Write-Host "Removed scheduled task '$taskName'." -ForegroundColor Green
} catch {
    Write-Host "Could not remove task (already gone, or needs elevation): $($_.Exception.Message)" -ForegroundColor Yellow
}
Write-Host "Install folder left at: $installDir (delete manually to remove logs)."
