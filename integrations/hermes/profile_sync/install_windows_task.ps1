$ErrorActionPreference = 'Stop'
$Root = Join-Path $env:LOCALAPPDATA 'hermes\profile-sync\orialis'
$ScriptPath = Join-Path $Root 'run_sync.py'
$CoreScriptPath = Join-Path $Root 'profile_sync.py'
$ConfigPath = Join-Path $Root 'config.json'
if (!(Test-Path -LiteralPath $ScriptPath) -or !(Test-Path -LiteralPath $CoreScriptPath) -or !(Test-Path -LiteralPath $ConfigPath)) {
    throw 'Install the sync script and config before registering the task.'
}
$Python = (& python -c 'import sys; print(sys.executable)').Trim()
$PythonW = Join-Path (Split-Path $Python) 'pythonw.exe'
if (!(Test-Path -LiteralPath $PythonW)) { throw 'pythonw.exe was not found.' }
$Config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$Marker = @{
    node = 'windows'; config = $ConfigPath
    status = (Join-Path $Config.state_dir 'status.json')
    command = @($Python, $CoreScriptPath, 'sync', '--config', $ConfigPath)
}
[IO.File]::WriteAllText((Join-Path $Config.profile '.profile-sync.json'),
    ($Marker | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
$Name = 'Hermes-Orialis-Profile-Sync'
$Existing = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
if ($Existing -and !($Existing.Actions.Arguments -like '*profile-sync*orialis*sync.py*')) {
    throw 'A different task already uses this name.'
}
$User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Action = New-ScheduledTaskAction -Execute $PythonW `
    -Argument ('"{0}" sync --config "{1}"' -f $ScriptPath, $ConfigPath) -WorkingDirectory $Root
$EveryMinute = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 1)
$AtLogin = New-ScheduledTaskTrigger -AtLogOn -User $User
$Settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
$Principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $Name -Action $Action -Trigger @($EveryMinute, $AtLogin) `
    -Settings $Settings -Principal $Principal -Description 'Sync Orialis skills, curated memories and SOUL; Hermes stays local.' `
    -Force | Out-Null
Start-ScheduledTask -TaskName $Name
Get-ScheduledTask -TaskName $Name | Select-Object TaskName, State | ConvertTo-Json -Compress
