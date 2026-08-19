<#
    .SYNOPSIS
        Lists preinstalled apps on this PC that the Win11Debloat catalogue does not know about.

    .DESCRIPTION
        Apps.json cannot possibly list every app that ships on every OEM machine. Vendors
        change their bundles constantly, and an app the catalogue has never heard of cannot
        be offered for removal.

        This script compares the packages actually installed on this PC against the
        catalogue and reports the difference, so you can see what is on your machine that
        Win11Debloat would not currently offer to remove - and report it so the catalogue
        can cover it.

        It is read-only. Nothing is uninstalled, and nothing is written outside the
        optional report file.

        Note that this only sees MSIX/Appx packages. A large amount of OEM software
        (Acer Collection, ASUS Armoury Crate, vendor update agents and similar) is
        installed as ordinary desktop software and will not appear here; use
        Settings > Apps > Installed apps, sorted by publisher, for those.

    .PARAMETER IncludeFrameworks
        Also list framework and runtime packages. These are dependencies of other apps,
        never bloatware, and removing them breaks the apps that depend on them. Off by
        default for that reason.

    .PARAMETER OutputPath
        Write a markdown report to this path, ready to paste into a bug report.

    .EXAMPLE
        .\Scripts\Find-UnlistedApps.ps1

    .EXAMPLE
        .\Scripts\Find-UnlistedApps.ps1 -OutputPath "$env:USERPROFILE\Desktop\unlisted-apps.md"
#>
[CmdletBinding()]
param(
    [switch]$IncludeFrameworks,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$appsCatalogPath = Join-Path $repositoryRoot 'Config\Apps.json'

<#
    .SYNOPSIS
        Returns every app identifier the catalogue knows, flattened.
#>
function Get-CatalogAppId {
    param([Parameter(Mandatory)][string]$Path)

    $catalog = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $ids = New-Object System.Collections.Generic.List[string]

    foreach ($app in $catalog.Apps) {
        foreach ($appId in @($app.AppId)) {
            if ($appId -is [string] -and -not [string]::IsNullOrWhiteSpace($appId)) {
                $ids.Add($appId.Trim())
            }
        }
    }

    return $ids
}

<#
    .SYNOPSIS
        Tests whether an installed package is covered by a catalogue entry.

    .DESCRIPTION
        Mirrors how Remove-AppxApp matches packages: the catalogue identifier is treated
        as a substring of the package name, so an entry covers every variant of that
        package.
#>
function Test-PackageIsListed {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PackageName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CatalogIds
    )

    foreach ($catalogId in $CatalogIds) {
        if ($PackageName -like "*$catalogId*") { return $true }
    }

    return $false
}

$catalogIds = @(Get-CatalogAppId -Path $appsCatalogPath)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$packages = if ($isAdmin) {
    Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue
}
else {
    Write-Warning 'Not running elevated, so only apps for the current user are visible. Re-run as administrator for the full picture.'
    Get-AppxPackage -ErrorAction SilentlyContinue
}

$candidates = @(
    $packages | Where-Object {
        # Packages Windows refuses to remove are not actionable, and frameworks are
        # dependencies of other apps rather than bloatware.
        if ($_.NonRemovable) { return $false }
        if ($_.IsFramework -and -not $IncludeFrameworks) { return $false }

        return (-not (Test-PackageIsListed -PackageName $_.Name -CatalogIds $catalogIds))
    } | Sort-Object -Property @('Publisher', 'Name')
)

Write-Host ''
Write-Host "Catalogue entries: $($catalogIds.Count)"
Write-Host "Installed packages inspected: $(@($packages).Count)"
Write-Host "Not covered by the catalogue: $($candidates.Count)" -ForegroundColor Cyan
Write-Host ''

if ($candidates.Count -eq 0) {
    Write-Host 'Every removable app on this PC is already in the catalogue.' -ForegroundColor Green
    return
}

$candidates |
    Select-Object @{ Name = 'App'; Expression = { $_.Name } },
                  @{ Name = 'Publisher'; Expression = { ($_.Publisher -split ',')[0] -replace '^CN=', '' } } |
    Format-Table -AutoSize

Write-Host 'Some of these are handled by a dedicated setting rather than the app list'
Write-Host '(Copilot, Widgets and the Xbox apps, for example), so not everything here is a gap.'
Write-Host ''
Write-Host 'Reminder: this only covers MSIX/Appx packages. Vendor desktop software such as'
Write-Host 'Acer Collection or ASUS Armoury Crate will not appear here.'

if ($OutputPath) {
    $report = New-Object System.Collections.Generic.List[string]
    $report.Add('### Preinstalled apps not covered by the Win11Debloat catalogue')
    $report.Add('')
    $report.Add("Windows build: $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild)")
    $report.Add("Catalogue entries: $($catalogIds.Count)")
    $report.Add('')
    $report.Add('| App | Publisher |')
    $report.Add('| --- | --- |')

    foreach ($candidate in $candidates) {
        $publisher = ($candidate.Publisher -split ',')[0] -replace '^CN=', ''
        $report.Add("| ``$($candidate.Name)`` | $publisher |")
    }

    Set-Content -LiteralPath $OutputPath -Value $report -Encoding UTF8
    Write-Host ''
    Write-Host "Report written to $OutputPath" -ForegroundColor Green
}
