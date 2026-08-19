<#
    .SYNOPSIS
        Verifies a Win11Debloat working copy on a real Windows machine.

    .DESCRIPTION
        Structural checks (Pester, catalogue parity, documentation parity) prove that the
        repository is internally consistent. They cannot prove that a setting dispatches
        correctly against a live Windows install. This script closes that gap without
        changing anything on the machine.

        Phases:
          1. Environment    - Windows PowerShell 5.1, elevation, OS build.
          2. Test suite     - the full Pester suite via Run-Tests.ps1.
          3. WhatIf sweep   - runs every switch feature through the real pipeline with
                              -WhatIf, so the catalogue, the .reg lookups and the feature
                              dispatch are all exercised while nothing is written.
          4. Drift check    - runs -CheckDrift, which is read-only by design.

        The sweep is safe: -WhatIf short-circuits every mutation, including the Explorer
        restart, and no restore point is requested.

    .PARAMETER FeatureId
        Only sweep these features. Defaults to every switch feature in the catalogue.

    .PARAMETER SkipPester
        Skip phase 2, for a faster dispatch-only check.

    .PARAMETER TimeoutSeconds
        How long a single feature may take before it is treated as hung. Default 120.

    .EXAMPLE
        .\Scripts\Invoke-SmokeTest.ps1

    .EXAMPLE
        .\Scripts\Invoke-SmokeTest.ps1 -FeatureId DisableLLMNR, DisableCEIP -SkipPester
#>
[CmdletBinding()]
param(
    [string[]]$FeatureId,
    [switch]$SkipPester,
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$mainScript = Join-Path $repositoryRoot 'Win11Debloat.ps1'
$catalogPath = Join-Path $repositoryRoot 'Config\Features.json'

$script:Failures = New-Object System.Collections.Generic.List[string]

function Write-Phase {
    param([Parameter(Mandatory)][string]$Text)

    Write-Host ''
    Write-Host "=== $Text" -ForegroundColor Cyan
}

function Add-Failure {
    param([Parameter(Mandatory)][string]$Text)

    $script:Failures.Add($Text)
    Write-Host "  FAIL  $Text" -ForegroundColor Red
}

function Write-Pass {
    param([Parameter(Mandatory)][string]$Text)

    Write-Host "  ok    $Text" -ForegroundColor Green
}

# ---------------------------------------------------------------- 1. Environment
Write-Phase 'Environment'

if ($PSVersionTable.PSEdition -eq 'Core') {
    Add-Failure "Running under PowerShell $($PSVersionTable.PSVersion). Win11Debloat requires Windows PowerShell 5.1."
}
else {
    Write-Pass "Windows PowerShell $($PSVersionTable.PSVersion)"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    Write-Pass 'Running elevated'
}
else {
    Write-Host '  warn  Not elevated. The sweep still works, but run elevated to match real usage.' -ForegroundColor Yellow
}

try {
    $build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
    Write-Pass "Windows build $build"
}
catch {
    Add-Failure "Could not read the Windows build number: $($_.Exception.Message)"
}

# ---------------------------------------------------------------- 2. Test suite
if (-not $SkipPester) {
    Write-Phase 'Pester suite'

    $runTests = Join-Path $PSScriptRoot 'Run-Tests.ps1'
    & $runTests -Bootstrap

    if ($LASTEXITCODE -eq 0) {
        Write-Pass 'All tests passed'
    }
    else {
        Add-Failure "Run-Tests.ps1 exited with code $LASTEXITCODE"
    }
}

# ---------------------------------------------------------------- 3. WhatIf sweep
Write-Phase 'WhatIf sweep (nothing is written)'

$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json

# Only switch parameters can be swept: the rest need a value supplied by the user.
$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($mainScript, [ref]$tokens, [ref]$parseErrors)
$switchParameters = @(
    $ast.ParamBlock.Parameters |
        Where-Object { $_.StaticType.Name -eq 'SwitchParameter' } |
        ForEach-Object { $_.Name.VariablePath.UserPath }
)

$targets = @(
    $catalog.Features |
        ForEach-Object { $_.FeatureId } |
        Where-Object { $switchParameters -contains $_ }
)

if ($FeatureId) {
    $targets = @($targets | Where-Object { $FeatureId -contains $_ })
}

$skipped = @(
    $catalog.Features |
        ForEach-Object { $_.FeatureId } |
        Where-Object { $switchParameters -notcontains $_ }
)

Write-Host "  Sweeping $($targets.Count) features, skipping $($skipped.Count) that need a value ($($skipped -join ', '))"
Write-Host ''

$passed = 0
$index = 0

foreach ($target in $targets) {
    $index++
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()

    Write-Progress -Activity 'WhatIf sweep' -Status $target -PercentComplete (($index / [Math]::Max($targets.Count, 1)) * 100)

    try {
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$mainScript`"",
            '-WhatIf', '-Silent', '-SkipExplorerRestart', '-SkipRegistryBackup', "-$target"
        )

        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru -NoNewWindow `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            Add-Failure "$target timed out after $TimeoutSeconds seconds"
            continue
        }

        $stdErr = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)

        if ($process.ExitCode -ne 0) {
            Add-Failure "$target exited with code $($process.ExitCode)"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($stdErr)) {
            Add-Failure "$target wrote to the error stream: $($stdErr.Trim() -replace '\s+', ' ')"
        }
        else {
            $passed++
        }
    }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Progress -Activity 'WhatIf sweep' -Completed
Write-Pass "$passed of $($targets.Count) features dispatched cleanly"

# ---------------------------------------------------------------- 4. Drift check
Write-Phase 'Drift check (read-only)'

$outFile = [System.IO.Path]::GetTempFileName()
$errFile = [System.IO.Path]::GetTempFileName()

try {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$mainScript`"", '-CheckDrift', '-Silent')
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru -NoNewWindow `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        Add-Failure "-CheckDrift timed out after $TimeoutSeconds seconds"
    }
    elseif ($process.ExitCode -ne 0) {
        Add-Failure "-CheckDrift exited with code $($process.ExitCode)"
    }
    else {
        Write-Pass '-CheckDrift completed'
        $driftOutput = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
        if ($driftOutput) { Write-Host ($driftOutput.Trim() -split "`n" | Select-Object -Last 6 | Out-String).TrimEnd() }
    }
}
finally {
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- Summary
Write-Phase 'Summary'

if ($script:Failures.Count -eq 0) {
    Write-Host '  Everything passed.' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Still needs a human: see docs\WINDOWS_SMOKE_TEST.md for the interface checks'
    Write-Host '  that cannot be automated.'
    exit 0
}

Write-Host "  $($script:Failures.Count) problem(s):" -ForegroundColor Red
foreach ($failure in $script:Failures) {
    Write-Host "    - $failure" -ForegroundColor Red
}

exit 1
