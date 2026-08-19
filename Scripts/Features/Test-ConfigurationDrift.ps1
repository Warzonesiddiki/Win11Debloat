<#
    Drift detection.

    Windows does not leave a debloated machine alone. Cumulative and feature updates
    re-enable settings, re-provision apps and reset policy keys, so a configuration that
    was applied weeks ago is not necessarily the configuration that is live today. Until
    now the only way to find out was to re-run the whole tool and watch what it changed.

    These functions compare the configuration the user last applied against the current
    state of the machine and report what Windows has taken back, without changing
    anything. Repair-ConfigurationDrift then re-applies only the settings that actually
    drifted, instead of blindly re-running everything.

    Detection reuses Test-FeatureApplied, so a feature only needs to describe its state
    once. Features whose state cannot be determined are reported as such rather than
    being counted as reverted - see Test-FeatureSupportsStateDetection.
#>

# Drift status values, used as an enum-like set of constants.
$script:DriftStatus_Applied = 'Applied'
$script:DriftStatus_Reverted = 'Reverted'
$script:DriftStatus_NotCheckable = 'NotCheckable'
$script:DriftStatus_Unknown = 'Unknown'

<#
    .SYNOPSIS
        Returns the feature ids the user last chose to apply.

    .DESCRIPTION
        Reads LastUsedSettings.json and returns the names of every setting that was
        enabled and that still exists in the feature catalogue. Returns an empty array
        when the file is absent or unreadable, so callers can treat "nothing was ever
        applied" and "nothing to compare" identically.

    .OUTPUTS
        System.String[]
#>
function Get-IntendedFeatureId {
    $settingsJson = Import-JsonFile -filePath $script:SavedSettingsFilePath -expectedVersion '1.0' -optionalFile

    if (-not $settingsJson -or -not $settingsJson.Settings) {
        return @()
    }

    $featureIds = New-Object System.Collections.Generic.List[string]

    foreach ($setting in $settingsJson.Settings) {
        if ($setting.Value -eq $false) { continue }
        if (-not $setting.Name) { continue }
        if (-not $script:Features.ContainsKey($setting.Name)) { continue }

        $featureIds.Add([string]$setting.Name)
    }

    return $featureIds.ToArray()
}

<#
    .SYNOPSIS
        Compares the intended configuration against the live state of the machine.

    .DESCRIPTION
        For each feature, reports one of four states:
          Applied      - the setting is still in effect.
          Reverted     - the setting was applied before but the machine no longer
                         matches it, typically because a Windows update reset it.
          NotCheckable - the feature has no detectable state (for example app removal),
                         so nothing can be concluded either way.
          Unknown      - the feature is not in the catalogue, or the check itself failed.

        This function never writes to the system.

    .PARAMETER FeatureIds
        The features to check. Defaults to the configuration the user last applied.

    .OUTPUTS
        PSCustomObject[] with FeatureId, Label, Status and Detail properties.
#>
function Get-ConfigurationDrift {
    param(
        [string[]]$FeatureIds
    )

    if (-not $FeatureIds -or $FeatureIds.Count -eq 0) {
        $FeatureIds = @(Get-IntendedFeatureId)
    }

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($featureId in $FeatureIds) {
        $feature = if ($script:Features.ContainsKey($featureId)) { $script:Features[$featureId] } else { $null }
        $label = if ($feature -and $feature.Label) { [string]$feature.Label } else { [string]$featureId }

        if (-not $feature) {
            $results.Add([PSCustomObject]@{
                FeatureId = $featureId
                Label     = $label
                Status    = $script:DriftStatus_Unknown
                Detail    = 'This setting is no longer defined in the feature catalogue.'
            })
            continue
        }

        if (-not (Test-FeatureSupportsStateDetection -FeatureId $featureId)) {
            $results.Add([PSCustomObject]@{
                FeatureId = $featureId
                Label     = $label
                Status    = $script:DriftStatus_NotCheckable
                Detail    = 'This setting has no detectable state, so drift cannot be determined.'
            })
            continue
        }

        try {
            $isApplied = [bool](Test-FeatureApplied -FeatureId $featureId)
        }
        catch {
            $results.Add([PSCustomObject]@{
                FeatureId = $featureId
                Label     = $label
                Status    = $script:DriftStatus_Unknown
                Detail    = "State check failed: $($_.Exception.Message)"
            })
            continue
        }

        if ($isApplied) {
            $results.Add([PSCustomObject]@{
                FeatureId = $featureId
                Label     = $label
                Status    = $script:DriftStatus_Applied
                Detail    = 'Still applied.'
            })
        }
        else {
            $results.Add([PSCustomObject]@{
                FeatureId = $featureId
                Label     = $label
                Status    = $script:DriftStatus_Reverted
                Detail    = 'No longer applied. Windows or another program has changed this back.'
            })
        }
    }

    return $results.ToArray()
}

<#
    .SYNOPSIS
        Checks that changes just applied actually took effect, and reports any that did not.

    .DESCRIPTION
        Applying a registry change and having it stick are different things. Group Policy
        on a managed device silently reimposes its own values, a security product can
        block a write, and some settings only materialise after a restart. Without a check
        the run reports success either way, which is exactly the sort of quiet failure a
        user discovers weeks later.

        This re-uses the drift comparison against the features that were just applied.
        Features that declare RequiresReboot are reported as pending rather than failed,
        because their state legitimately does not reflect until the machine restarts.

        Only meaningful for changes applied to the current user on the running system, so
        callers must not use it for Sysprep or another-user runs, where the live registry
        is not the registry that was modified.

    .PARAMETER FeatureIds
        The features that were just applied.

    .OUTPUTS
        System.Int32
        The number of changes that did not take effect.
#>
function Write-AppliedChangesReport {
    param(
        [string[]]$FeatureIds = @()
    )

    if ($FeatureIds.Count -eq 0) { return 0 }

    $results = @(Get-ConfigurationDrift -FeatureIds $FeatureIds)
    $notInEffect = @($results | Where-Object { $_.Status -eq $script:DriftStatus_Reverted })

    if ($notInEffect.Count -eq 0) { return 0 }

    $pendingReboot = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[object]

    foreach ($result in $notInEffect) {
        $feature = if ($script:Features.ContainsKey($result.FeatureId)) { $script:Features[$result.FeatureId] } else { $null }

        if ($feature -and $feature.RequiresReboot) {
            $pendingReboot.Add($result)
        }
        else {
            $failed.Add($result)
        }
    }

    if ($pendingReboot.Count -gt 0) {
        Write-Host ""
        Write-Host "$($pendingReboot.Count) change(s) will take effect after you restart:" -ForegroundColor Yellow
        foreach ($result in $pendingReboot) {
            Write-Host "    - $($result.Label)" -ForegroundColor Yellow
        }
    }

    if ($failed.Count -gt 0) {
        Write-Host ""
        Write-Warning "$($failed.Count) change(s) were applied but are not in effect:"
        foreach ($result in $failed) {
            Write-Host "    - $($result.Label)" -ForegroundColor Red
        }
        Write-Host "This usually means Group Policy, a management tool or security software is enforcing its own value." -ForegroundColor Yellow
    }

    return $failed.Count
}

<#
    .SYNOPSIS
        Prints a drift report to the console.

    .PARAMETER Results
        Results produced by Get-ConfigurationDrift.
#>
function Write-ConfigurationDriftReport {
    param(
        [object[]]$Results = @()
    )

    if ($Results.Count -eq 0) {
        Write-Host "No previously applied settings were found, so there is nothing to compare."
        return
    }

    $reverted = @($Results | Where-Object { $_.Status -eq $script:DriftStatus_Reverted })
    $applied = @($Results | Where-Object { $_.Status -eq $script:DriftStatus_Applied })
    $notCheckable = @($Results | Where-Object { $_.Status -eq $script:DriftStatus_NotCheckable })
    $unknown = @($Results | Where-Object { $_.Status -eq $script:DriftStatus_Unknown })

    Write-Host ""
    Write-Host "Checked $($Results.Count) previously applied setting(s)."
    Write-Host "  Still applied: $($applied.Count)" -ForegroundColor Green

    if ($reverted.Count -gt 0) {
        Write-Host "  Reverted by Windows: $($reverted.Count)" -ForegroundColor Yellow
        Write-Host ""

        foreach ($result in $reverted) {
            Write-Host "    - $($result.Label)" -ForegroundColor Yellow
        }
    }

    if ($notCheckable.Count -gt 0) {
        Write-Host "  Cannot be checked: $($notCheckable.Count)" -ForegroundColor DarkGray
    }

    if ($unknown.Count -gt 0) {
        Write-Host "  Could not be determined: $($unknown.Count)" -ForegroundColor DarkGray

        foreach ($result in $unknown) {
            Write-Host "    - $($result.Label): $($result.Detail)" -ForegroundColor DarkGray
        }
    }

    Write-Host ""

    if ($reverted.Count -eq 0) {
        Write-Host "Your configuration is intact." -ForegroundColor Green
    }
    else {
        Write-Host "Re-apply the reverted settings to restore your configuration." -ForegroundColor Yellow
    }
}

<#
    .SYNOPSIS
        Re-applies only the settings that have drifted.

    .DESCRIPTION
        Applies the features reported as Reverted by Get-ConfigurationDrift, leaving
        everything else untouched. A failure on one feature does not stop the rest, in
        line with Invoke-ApplyFeatures.

    .PARAMETER Results
        Results produced by Get-ConfigurationDrift.

    .OUTPUTS
        System.Int32
        The number of features successfully re-applied.
#>
function Repair-ConfigurationDrift {
    param(
        [object[]]$Results = @()
    )

    $reverted = @($Results | Where-Object { $_.Status -eq $script:DriftStatus_Reverted })

    if ($reverted.Count -eq 0) {
        return 0
    }

    $repaired = 0

    foreach ($result in $reverted) {
        try {
            Invoke-FeatureApply -FeatureId $result.FeatureId
            $repaired++
        }
        catch {
            Write-Warning "Failed to re-apply '$($result.FeatureId)': $($_.Exception.Message)"
        }
    }

    return $repaired
}
