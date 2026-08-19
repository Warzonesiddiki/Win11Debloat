<#
.SYNOPSIS
    Live-registry proof that the winforge-derived features apply and revert correctly.

.DESCRIPTION
    For each of the features ported from winforge in this fork, this script:
      1. imports the apply Regfile into the live registry,
      2. reads every expected value back and compares it,
      3. imports the Undo Regfile to revert.

    HKCU-backed values are verified directly. HKLM-backed values and
    admin-protected keys (notably *\Policies\* and HKEY_USERS\.Default) are only
    touched when running elevated; otherwise they are reported as
    "SKIP (needs admin)" so the run is always safe to invoke.

    This is the live counterpart to the static gates: it proves the harvested
    registry paths actually exist and the values land, not just that the files
    are internally consistent.

    NOTE: always reverts what it applies.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = 'Config/Features.json',
    [string] $RegDir = 'Regfiles'
)

# NOTE: no global $ErrorActionPreference='Stop' -- reg import writes its status
# line to stderr, which PowerShell would otherwise promote to a terminating
# error. We rely on $LASTEXITCODE and local -ErrorAction Stop instead.

# FeatureIds added from winforge in this fork (batches 1 and 2).
$PortedIds = @(
    'DisableNvidiaTelemetry','DenyAppPermissions','DisableDeviceMonitoring',
    'DisableProgramCompatibilityAssistant','DisableCustomerExperienceImprovement',
    'DisablePrivacyExperience','DisableRsopLogging','DisableUserTracking',
    'DisallowMicrosoftAccounts','DisableActivationTelemetry','DisableDiagnosticTracing',
    'EnableDnsOverHttps','DisableSmbBandwidthThrottling','HideRecentFiles',
    'SetThumbnailCacheSize','DisableDynamicLighting','DisableVisualEffects',
    'DisableAeroShake','DisableDesktopPeek','UseCompactModeExplorer','DisableCrossDeviceResume',
    'DisableSettingsTips','EnableLongPaths','UseClassicSearch','DisableNearbySharing',
    'DisableNewsAndInterests','DisableTabletMode','DisableLowDiskWarning',
    'DisableStartupDelay','DisableWpbt',
    'ConfigureQosReservation','DisableNetworkThrottling','DisableMsrtTelemetry',
    'SetBestWallpaperQuality','DisableWarningSounds','DisableItemCheckboxes',
    'DisableMenuDelay','HideDisconnectedSounds','RemoveShortcutSuffix',
    'EnableBlueTooltips','DisableOverlayScrollbars','DisableLoginBlur',
    'ShowBatteryPercentage','DisableStoreAutoUpdates','DisableUsbNotifications',
    'DisableSettingsBanner','ShowMoreDetailsOnTransfer','DisableInvalidShortcutSearch',
    'HideOfficeFilesInQuickAccess','AlwaysFullContextMenu','HideFrequentItems',
    'MinimizeMouseHoverTime','DisableInternetOpenWith','RemoveCastToDevice',
    'DisableTouchVisualFeedback','ShowMorePins','ShowAllControlPanelTasks',
    'DecreaseShutdownTime','EnableVerboseMessages','ForceEndShutdownApps',
    'ConfigureCrashControl','WinXOpensCommandPrompt','HideMeetNow',
    'DisableSoundReduction','EnableDetailedBsod','EnableGameMode','DisableNewOutlook',
    'EnableNumLockOnBoot','EnableS3Sleep'
)

$hiveMap = @{
    'HKEY_CURRENT_USER'   = 'HKCU:'
    'HKEY_LOCAL_MACHINE'  = 'HKLM:'
    'HKEY_CLASSES_ROOT'   = 'HKCR:'
    'HKEY_USERS'          = 'HKU:'
    'HKEY_CURRENT_CONFIG' = 'HKCC:'
}

function ConvertTo-ProviderPath($RegKey) {
    $parts = $RegKey -split '\\', 2
    $hive = $parts[0].ToUpper()
    if (-not $hiveMap.ContainsKey($hive)) { return $null }
    if ($parts.Count -lt 2) { return $hiveMap[$hive] }
    return $hiveMap[$hive] + '\' + $parts[1]
}

function Get-RegEntries($Path) {
    $entries = @()
    $key = $null
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding Unicode)) {
        $s = $line.Trim()
        if ([string]::IsNullOrEmpty($s) -or $s.StartsWith(';') -or $s -match '^Windows Registry Editor Version') { continue }
        $m = [regex]::Match($s, '^\[(-?)(.*)\]$')
        if ($m.Success) {
            $key = $m.Groups[2].Value
            if ($m.Groups[1].Value -eq '-') { $entries += [PSCustomObject]@{ Key = $key; Name = $null; Kind = 'deleted' } }
            continue
        }
        if ($null -eq $key) { continue }
        $vm = [regex]::Match($s, '^(@|"[^"]*")=(.*)$')
        if (-not $vm.Success) { continue }
        $name = if ($vm.Groups[1].Value -eq '@') { '(default)' } else { $vm.Groups[1].Value.Trim('"') }
        $token = $vm.Groups[2].Value
        $kind = if ($token -match '^dword:') { 'dword' } elseif ($token -match '^"') { 'string' } else { 'other' }
        $val = if ($kind -eq 'dword') { [int]('0x' + $token.Substring(6)) } else { $token.Trim('"') }
        $entries += [PSCustomObject]@{ Key = $key; Name = $name; Kind = $kind; Value = $val }
    }
    return $entries
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$catalog = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$featureById = @{}
foreach ($f in $catalog.Features) { $featureById[$f.FeatureId] = $f }

$ok = 0; $bad = 0; $skipped = 0
$failures = @()

foreach ($fid in $PortedIds) {
    if (-not $featureById.ContainsKey($fid)) { $failures += "MISSING FEATURE: ${fid}"; $bad++; continue }
    $f = $featureById[$fid]
    $applyFile = Join-Path $RegDir $f.RegistryKey
    $undoFile = Join-Path $RegDir $f.RegistryUndoKey
    if (-not (Test-Path -LiteralPath $applyFile)) { $failures += "${fid} apply file missing"; $bad++; continue }

    $applyEntries = Get-RegEntries $applyFile

    $appliedOk = $true
    $permSkip = $false
    try {
        & reg import "$applyFile" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $errText = (& reg import "$applyFile" 2>&1 | Out-String)
            if ($errText -match 'accessing the registry|Access is denied|requires elevation') {
                $permSkip = $true
            } else {
                $appliedOk = $false
                $failures += "${fid}: apply failed: $($errText.Trim())"
            }
        }
        if (-not $permSkip -and $appliedOk) {
            foreach ($e in $applyEntries) {
                $prov = ConvertTo-ProviderPath $e.Key
                if ($null -eq $prov) { continue }
                if ($e.Kind -eq 'deleted') {
                    if (Test-Path -LiteralPath $prov) { $failures += "${fid}: key still present after apply: $($e.Key)"; $appliedOk = $false }
                    continue
                }
                try { $actual = (Get-ItemProperty -LiteralPath $prov -Name $e.Name -ErrorAction Stop).($e.Name) }
                catch { $actual = $null }
                if ($null -eq $actual -or $actual -ne $e.Value) {
                    $failures += "${fid}: $($e.Key)\$($e.Name) expected '$($e.Value)' actual '$actual'"
                    $appliedOk = $false
                }
            }
        }
    } catch {
        $failures += "${fid}: apply failed: $_"; $appliedOk = $false
    } finally {
        if (-not $permSkip -and (Test-Path -LiteralPath $undoFile)) { & reg import "$undoFile" 2>$null | Out-Null }
    }

    if ($permSkip) { Write-Host ("SKIP (needs admin) {0}" -f $fid) -ForegroundColor DarkGray; $skipped++; continue }
    if ($appliedOk) { $ok++; Write-Host ("OK   {0}" -f $fid) }
    else { $bad++ }
}

Write-Host ("`nVERIFIED {0} | MISMATCH {1} | SKIPPED(admin) {2}" -f $ok, $bad, $skipped)
if ($failures) { Write-Host "`nFAILURES:"; $failures | ForEach-Object { Write-Host ("  " + $_) } ; exit 1 }
exit 0
