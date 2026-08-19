<#
    .SYNOPSIS
        Writes a machine-readable summary of a Win11Debloat run.

    .DESCRIPTION
        The transcript log is written for humans. Anyone deploying this across more than a
        handful of machines needs to answer "did it work?" without reading prose, which
        currently means parsing console output. This emits the same information as JSON.

        Opt-in: nothing is written unless -RunSummaryPath is supplied.
#>

<#
    .SYNOPSIS
        Builds the run summary object.

    .DESCRIPTION
        Kept separate from writing the file so the shape can be tested without touching
        the filesystem.

    .PARAMETER AppliedFeatureIds
        Features selected to be applied during this run.

    .PARAMETER UndoneFeatureIds
        Features selected to be undone during this run.

    .PARAMETER StartedAt
        When the run began.

    .OUTPUTS
        PSCustomObject
#>
function New-RunSummary {
    param(
        [string[]]$AppliedFeatureIds = @(),
        [string[]]$UndoneFeatureIds = @(),
        [datetime]$StartedAt = (Get-Date)
    )

    $notInEffect = @($script:NotInEffectFeatureIds)

    $failures = [PSCustomObject]@{
        RegistryImports = [int]$script:RegistryImportFailures
        AppRemovals     = [int]$script:AppRemovalFailures
        Features        = [int]$script:FeatureFailures
        NotInEffect     = $notInEffect.Count
    }

    $totalFailures = $failures.RegistryImports + $failures.AppRemovals + $failures.Features + $failures.NotInEffect

    $result = if ($script:CancelRequested) { 'Cancelled' }
        elseif ($totalFailures -gt 0) { 'CompletedWithFailures' }
        else { 'Success' }

    return [PSCustomObject]@{
        Schema      = 'win11debloat-run/1.0'
        Version     = [string]$script:Version
        StartedAt   = $StartedAt.ToUniversalTime().ToString('o')
        CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
        Computer    = $env:COMPUTERNAME
        Result      = $result
        Mode        = [PSCustomObject]@{
            WhatIf  = $script:Params.ContainsKey('WhatIf')
            Sysprep = $script:Params.ContainsKey('Sysprep')
            Silent  = $script:Params.ContainsKey('Silent')
            User    = if ($script:Params.ContainsKey('User')) { [string]$script:Params['User'] } else { $null }
        }
        Applied     = @($AppliedFeatureIds)
        Undone      = @($UndoneFeatureIds)
        NotInEffect = $notInEffect
        Failures    = $failures
    }
}

<#
    .SYNOPSIS
        Writes the run summary to disk as JSON.

    .PARAMETER Path
        Destination file. Its directory is created if missing.

    .PARAMETER Summary
        The object produced by New-RunSummary.
#>
function Write-RunSummary {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        $Summary
    )

    try {
        $directory = Split-Path -Parent $Path

        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        $Summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
        Write-Host "Run summary written to $Path"
    }
    catch {
        # A reporting failure must never fail the run itself.
        Write-Warning "Could not write the run summary to '$Path': $($_.Exception.Message)"
    }
}
