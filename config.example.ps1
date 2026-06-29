# Example config. install.ps1 generates a real config.ps1 next to rc-watchdog.ps1
# (in %USERPROFILE%\.claude-rc-keepalive\). Edit that file to change settings later,
# then let the watchdog restart the server (or reboot).

$RcName         = $env:COMPUTERNAME   # name shown in claude.ai/code and the Claude app
$WorkDir        = $env:USERPROFILE    # directory new remote sessions open in (e.g. 'C:\Dev')
$PermissionMode = 'default'           # default | acceptEdits | bypassPermissions | plan | dontAsk | auto
                                      # 'bypassPermissions' = no prompts (powerful but risky)
