<#
.SYNOPSIS
    Read-only drift check for Win11Debloat's applied registry state.

.DESCRIPTION
    Compares the expected registry state derived from Config/Features.json and the
    Regfiles/ corpus against the live registry, and reports any deviation. This is
    the scheduled counterpart (U-09) to the catalogue parity gates: the gates prove
    the catalogue is self-consistent, this proves the live machine still matches it.

    This script is strictly READ-ONLY. It never calls Set-ItemProperty, reg.exe, or
    any other mutating operation. It is safe to schedule.

    NOTE: this file was authored in a sandbox without a PowerShell runtime and has
    not been executed on Windows. Run it once on a Windows host to confirm it parses
    and reports correctly before relying on it (see docs/WINDOWS_VERIFICATION_RUNBOOK.md).

.PARAMETER ConfigPath
    Path to Config/Features.json (default: Config/Features.json next to the repo root).

.PARAMETER RegDir
    Path to the Regfiles directory (default: Regfiles next to the repo root).

.PARAMETER AsTable
    Emit a PowerShell table object instead of a text report (useful for scheduling).
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = 'Config/Features.json',
    [string] $RegDir = 'Regfiles',
    [switch] $AsTable
)

$ErrorActionPreference = 'Stop'

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

function ConvertFrom-RegValue($Token) {
    if ($Token -match '^dword:([0-9a-fA-F]+)$') {
        return [PSCustomObject]@{ Type = 'dword'; Value = [int]('0x' + $Matches[1]) }
    }
    if ($Token -match '^hex\([0-9a-fA-F]+\):(.*)$') {
        return [PSCustomObject]@{ Type = 'binary'; Value = $Matches[1] }
    }
    if ($Token -match '^hex:(.*)$') {
        return [PSCustomObject]@{ Type = 'binary'; Value = $Matches[1] }
    }
    $v = $Token -replace '^"', '' -replace '"$', ''
    return [PSCustomObject]@{ Type = 'string'; Value = $v }
}

function Get-RegFileEntries($Path) {
    $entries = @()
    $key = $null
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding Unicode)) {
        $s = $line.Trim()
        if ([string]::IsNullOrEmpty($s) -or $s.StartsWith(';')) { continue }
        if ($s -match '^Windows Registry Editor Version') { continue }
        $m = [regex]::Match($s, '^\[(-?)(.*)\]$')
        if ($m.Success) {
            $key = $m.Groups[2].Value
            if ($m.Groups[1].Value -eq '-') {
                $entries += [PSCustomObject]@{ Key = $key; Name = $null; Kind = 'deleted' }
            }
            continue
        }
        if ($null -eq $key) { continue }
        $vm = [regex]::Match($s, '^(@|"[^"]*")=(.*)$')
        if (-not $vm.Success) { continue }
        $name = if ($vm.Groups[1].Value -eq '@') { '(default)' } else { $vm.Groups[1].Value.Trim('"') }
        $parsed = ConvertFrom-RegValue $vm.Groups[2].Value
        $entries += [PSCustomObject]@{ Key = $key; Name = $name; Kind = $parsed.Type; Value = $parsed.Value }
    }
    return $entries
}

$catalog = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$regRoot = Resolve-Path $RegDir

$drift = @()

foreach ($feature in $catalog.Features) {
    if ([string]::IsNullOrEmpty($feature.RegistryKey)) { continue }
    $applyFile = Join-Path $regRoot $feature.RegistryKey
    if (-not (Test-Path -LiteralPath $applyFile)) {
        $drift += [PSCustomObject]@{ Feature = $feature.FeatureId; Key = '(file)'; Name = $feature.RegistryKey; Expected = 'present'; Actual = 'missing regfile' }
        continue
    }
    foreach ($entry in (Get-RegFileEntries $applyFile)) {
        $prov = ConvertTo-ProviderPath $entry.Key
        if ($null -eq $prov) { continue }
        if ($entry.Kind -eq 'deleted') {
            if (Test-Path -LiteralPath $prov) {
                $drift += [PSCustomObject]@{ Feature = $feature.FeatureId; Key = $entry.Key; Name = '(key)'; Expected = 'absent'; Actual = 'key still present' }
            }
            continue
        }
        $actual = $null
        try {
            $prop = Get-ItemProperty -LiteralPath $prov -Name $entry.Name -ErrorAction Stop
            $actual = $prop.($entry.Name)
        } catch {
            $actual = $null
        }
        $expected = $entry.Value
        if ($null -eq $actual) {
            $drift += [PSCustomObject]@{ Feature = $feature.FeatureId; Key = $entry.Key; Name = $entry.Name; Expected = "$($entry.Kind)=$expected"; Actual = 'value missing' }
        } elseif ($actual -ne $expected) {
            $drift += [PSCustomObject]@{ Feature = $feature.FeatureId; Key = $entry.Key; Name = $entry.Name; Expected = "$($entry.Kind)=$expected"; Actual = "$($actual)" }
        }
    }
}

if ($AsTable) {
    return $drift
}

if ($drift.Count -eq 0) {
    Write-Host "DRIFT CHECK OK: no deviations from the expected catalogue state." -ForegroundColor Green
    exit 0
}

Write-Host "DRIFT CHECK FOUND $($drift.Count) deviation(s):" -ForegroundColor Yellow
foreach ($d in $drift) {
    Write-Host ("  [{0}] {1}\{2}: expected '{3}', actual '{4}'" -f $d.Feature, $d.Key, $d.Name, $d.Expected, $d.Actual)
}
exit 1
