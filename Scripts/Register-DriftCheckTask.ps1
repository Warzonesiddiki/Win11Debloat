<#
.SYNOPSIS
    Register a scheduled task that runs the read-only configuration drift check.

.DESCRIPTION
    Creates a scheduled task (default: daily) that invokes Scripts/Invoke-DriftCheck.ps1
    and writes its report to a log file. The drift check never writes to the registry
    (see Scripts/Invoke-DriftCheck.ps1), so scheduling it is safe and supports the
    U-09 "scheduled drift check" requirement: a machine that has drifted from its
    intended Win11Debloat state is reported automatically.

    NOTE: authored in a sandbox without a PowerShell runtime; parse-checked only.
    Run on a Windows host (as Administrator) to register the task.

.PARAMETER TaskName
    Name of the scheduled task to create.

.PARAMETER LogPath
    File the drift report is appended to.

.PARAMETER At
    Time of day the task runs (default 03:00).
#>
[CmdletBinding()]
param(
    [string] $TaskName = 'Win11DebloatDriftCheck',
    [string] $LogPath = "$env:ProgramData\Win11Debloat\drift-check.log",
    [datetime] $At = (Get-Date -Hour 3 -Minute 0 -Second 0)
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$driftScript = Join-Path $repoRoot 'Scripts\Invoke-DriftCheck.ps1'
if (-not (Test-Path -LiteralPath $driftScript)) {
    throw "Cannot find $driftScript"
}

$logDir = Split-Path -Parent $LogPath
if (-not (Test-Path -LiteralPath $logDir)) {
    $null = New-Item -ItemType Directory -Path $logDir -Force
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$driftScript`" -AsTable | " +
    "Out-String | Add-Content -LiteralPath `"$LogPath`""
)
$trigger = New-ScheduledTaskTrigger -Daily -At $At
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force

Write-Host "Registered scheduled task '$TaskName' (daily at $($At.ToShortTimeString())), log: $LogPath"
