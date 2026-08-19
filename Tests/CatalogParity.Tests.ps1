<#
    Catalogue, registry-file, and CLI parity checks.

    These are "meta" tests: they validate the DATA in Config/ and Regfiles/ and its
    consistency with the command-line surface, rather than the behaviour of a single
    function. They exist because the feature catalogue, the .reg corpus, the Sysprep and
    Undo variants, and the two parameter blocks are all hand-synchronised, and a mismatch
    between them fails SILENTLY at runtime:

      - a feature whose undo file misses a value can never be fully reverted;
      - a feature whose Sysprep variant misses a value silently skips new user profiles;
      - a parameter that maps to no feature is accepted, reports success, and does nothing.

    The .reg parsing below is deliberately an INDEPENDENT reimplementation rather than a
    call into Get-RegFileOperations. A parity check that shares a parser with the code it
    is checking cannot detect a parser-level mistake. It is also intentionally coarse: it
    compares WHICH keys and values a file touches, never the data written, so that
    legitimate value differences between apply and undo (0 vs 1) do not register as drift.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:RegfilesPath = Join-Path $script:RepoRoot 'Regfiles'

    # Parameters that are declared on the entry points but resolve to no feature in
    # Config/Features.json. Passing one of these would do nothing at all. The list is
    # empty and should stay that way: it exists so that a deliberate, documented
    # exception is possible without weakening the check for everything else.
    $script:KnownOrphanedParameters = @()

    # Parameters that exist only on the Get.ps1 launcher.
    $script:LauncherOnlyParameters = @('Dev', 'Verbose', 'WhatIf')

    function ConvertTo-NormalizedKey {
        param([Parameter(Mandatory)][string]$KeyPath)

        $parts = $KeyPath -split '\\', 2
        $hive = switch ($parts[0].Trim().ToUpperInvariant()) {
            'HKEY_CURRENT_USER'   { 'HKCU' }
            'HKEY_LOCAL_MACHINE'  { 'HKLM' }
            'HKEY_CLASSES_ROOT'   { 'HKCR' }
            'HKEY_USERS'          { 'HKU' }
            'HKEY_CURRENT_CONFIG' { 'HKCC' }
            default               { $parts[0].Trim().ToUpperInvariant() }
        }

        $subKey = if ($parts.Count -gt 1) { $parts[1].Trim().ToLowerInvariant() } else { '' }
        return "$hive\$subKey"
    }

    # Sysprep variants target the mounted Default user hive instead of the live HKCU.
    function ConvertTo-SysprepKey {
        param([Parameter(Mandatory)][string]$NormalizedKey)

        if ($NormalizedKey.StartsWith('HKCU\', [System.StringComparison]::Ordinal)) {
            return 'HKU\default\' + $NormalizedKey.Substring(5)
        }

        return $NormalizedKey
    }

    function Test-KeyIsUnder {
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$Key,
            [Parameter(Mandatory)][AllowEmptyString()][string]$Ancestor
        )

        return ($Key -eq $Ancestor) -or $Key.StartsWith(($Ancestor + '\'), [System.StringComparison]::Ordinal)
    }

    function Get-RegFileTargets {
        param([Parameter(Mandatory)][string]$Path)

        $setEntries = [System.Collections.Generic.List[object]]::new()
        $setTargets = [System.Collections.Generic.HashSet[string]]::new()
        $createdKeys = [System.Collections.Generic.HashSet[string]]::new()
        $deletedKeys = [System.Collections.Generic.HashSet[string]]::new()
        $currentKey = $null

        foreach ($rawLine in (Get-Content -LiteralPath $Path)) {
            $line = $rawLine.Trim()

            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith(';')) { continue }
            if ($line -match '^Windows Registry Editor Version') { continue }

            if ($line -match '^\[(?<deleted>-)?(?<keyPath>[^\]]+)\]$') {
                $currentKey = ConvertTo-NormalizedKey -KeyPath $matches.keyPath
                if ($matches.deleted -eq '-') {
                    [void]$deletedKeys.Add($currentKey)
                }
                else {
                    [void]$createdKeys.Add($currentKey)
                }
                continue
            }

            if ($null -eq $currentKey) { continue }

            if ($line -match '^(?<valueName>@|"[^"]+")\s*=') {
                $valueName = if ($matches.valueName -eq '@') { '' } else { $matches.valueName.Trim('"') }
                $valueName = $valueName.ToLowerInvariant()
                $composite = '{0}::{1}' -f $currentKey, $valueName

                if ($setTargets.Add($composite)) {
                    $setEntries.Add([PSCustomObject]@{
                        Key       = $currentKey
                        ValueName = $valueName
                        Composite = $composite
                    })
                }
            }
        }

        return [PSCustomObject]@{
            SetEntries  = $setEntries
            SetTargets  = $setTargets
            CreatedKeys = $createdKeys
            DeletedKeys = $deletedKeys
        }
    }

    # Mirrors Resolve-UndoRegFilePath in Scripts/Features/Invoke-Changes.ps1: undo files
    # live in Regfiles\Undo, but mutually exclusive option groups (taskbar combine mode,
    # search box style, Explorer launch target) reuse a sibling apply file at the root.
    function Resolve-UndoRegFile {
        param([Parameter(Mandatory)][string]$FileName)

        $undoPath = Join-Path (Join-Path $script:RegfilesPath 'Undo') $FileName
        if (Test-Path -LiteralPath $undoPath) { return $undoPath }

        return (Join-Path $script:RegfilesPath $FileName)
    }

    $catalogPath = Join-Path $script:RepoRoot 'Config\Features.json'
    $script:Catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    $script:Features = @($script:Catalog.Features)
    $script:RegistryFeatures = @($script:Features | Where-Object { $_.RegistryKey })

    $appsPath = Join-Path $script:RepoRoot 'Config\Apps.json'
    $script:AppCatalog = Get-Content -LiteralPath $appsPath -Raw | ConvertFrom-Json

    $script:MainScriptPath = Join-Path $script:RepoRoot 'Win11Debloat.ps1'
    $script:LauncherScriptPath = Join-Path $script:RepoRoot 'Scripts\Get.ps1'

    function Get-ScriptParameterName {
        param([Parameter(Mandatory)][string]$Path)

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
        return @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    }

    $script:MainParameters = Get-ScriptParameterName -Path $script:MainScriptPath
    $script:LauncherParameters = Get-ScriptParameterName -Path $script:LauncherScriptPath

    # Control parameters are those that steer the run rather than map to a feature.
    $controlLine = Select-String -LiteralPath $script:MainScriptPath -Pattern '^\s*\$script:ControlParams\s*=' |
        Select-Object -First 1
    $script:ControlParameters = @(
        [regex]::Matches($controlLine.Line, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
    )
}

Describe 'Feature catalogue integrity' {
    It 'declares a unique FeatureId for every feature' {
        $duplicates = @(
            $script:Features | Group-Object -Property FeatureId | Where-Object { $_.Count -gt 1 } |
                ForEach-Object { $_.Name }
        )

        $duplicates | Should -BeNullOrEmpty -Because "FeatureIds are used as dictionary keys: $($duplicates -join ', ')"
    }

    It 'assigns every categorised feature to a declared category' {
        # Features reference a category by its display Name (e.g. "Privacy & Suggested
        # Content"), not by CategoryId. Some names happen to equal their id ("System",
        # "Taskbar"), so match on Name and treat CategoryId as an accepted alias.
        $categoryNames = @($script:Catalog.Categories | ForEach-Object { $_.Name })
        $categoryIds = @($script:Catalog.Categories | ForEach-Object { $_.CategoryId })
        $unknown = @(
            $script:Features |
                Where-Object { $_.Category -and $categoryNames -notcontains $_.Category -and $categoryIds -notcontains $_.Category } |
                ForEach-Object { "$($_.FeatureId) -> $($_.Category)" }
        )

        $unknown | Should -BeNullOrEmpty -Because "features must map to a category declared in Categories: $($unknown -join ', ')"
    }

    It 'points every RegistryKey at a file that exists' {
        $missing = @(
            $script:RegistryFeatures |
                Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:RegfilesPath $_.RegistryKey)) } |
                ForEach-Object { "$($_.FeatureId) -> $($_.RegistryKey)" }
        )

        $missing | Should -BeNullOrEmpty -Because "a missing apply file makes the feature a no-op: $($missing -join ', ')"
    }

    It 'points every RegistryUndoKey at a file that exists' {
        $missing = @(
            $script:Features |
                Where-Object { $_.RegistryUndoKey -and -not (Test-Path -LiteralPath (Resolve-UndoRegFile -FileName $_.RegistryUndoKey)) } |
                ForEach-Object { "$($_.FeatureId) -> $($_.RegistryUndoKey)" }
        )

        $missing | Should -BeNullOrEmpty -Because "a missing undo file makes the feature irreversible: $($missing -join ', ')"
    }

    It 'ships a Sysprep variant for every apply file' {
        $missing = @(
            $script:RegistryFeatures |
                Where-Object {
                    -not (Test-Path -LiteralPath (Join-Path (Join-Path $script:RegfilesPath 'Sysprep') $_.RegistryKey))
                } |
                ForEach-Object { "$($_.FeatureId) -> $($_.RegistryKey)" }
        )

        $missing | Should -BeNullOrEmpty -Because "without a Sysprep variant the feature skips new user profiles: $($missing -join ', ')"
    }
}

Describe 'Registry apply/undo parity' {
    It 'covers every applied value with a matching undo operation' {
        $failures = @()

        foreach ($feature in @($script:RegistryFeatures | Where-Object { $_.RegistryUndoKey })) {
            $applyPath = Join-Path $script:RegfilesPath $feature.RegistryKey
            $undoPath = Resolve-UndoRegFile -FileName $feature.RegistryUndoKey
            if (-not (Test-Path -LiteralPath $applyPath) -or -not (Test-Path -LiteralPath $undoPath)) { continue }

            $apply = Get-RegFileTargets -Path $applyPath
            $undo = Get-RegFileTargets -Path $undoPath
            $uncovered = @()

            # Every value the apply file writes must be rewritten by the undo file, or
            # sit under a key the undo file deletes outright.
            foreach ($entry in $apply.SetEntries) {
                if ($undo.SetTargets.Contains($entry.Composite)) { continue }

                $coveredByDelete = $false
                foreach ($deletedKey in $undo.DeletedKeys) {
                    if (Test-KeyIsUnder -Key $entry.Key -Ancestor $deletedKey) { $coveredByDelete = $true; break }
                }

                if (-not $coveredByDelete) { $uncovered += "$($entry.Key) :: $($entry.ValueName)" }
            }

            # Every key the apply file deletes must be recreated by the undo file.
            foreach ($deletedKey in $apply.DeletedKeys) {
                $recreated = $false
                foreach ($createdKey in $undo.CreatedKeys) {
                    if (Test-KeyIsUnder -Key $createdKey -Ancestor $deletedKey) { $recreated = $true; break }
                }

                if (-not $recreated) { $uncovered += "$deletedKey (key is never recreated)" }
            }

            if ($uncovered.Count -gt 0) {
                $failures += "$($feature.FeatureId) [$($feature.RegistryKey) -> $($feature.RegistryUndoKey)]: $($uncovered -join '; ')"
            }
        }

        $failures | Should -BeNullOrEmpty -Because "undo must fully reverse apply:`n$($failures -join "`n")"
    }
}

Describe 'Registry Sysprep parity' {
    It 'mirrors every applied value into the Sysprep variant' {
        $failures = @()

        foreach ($feature in $script:RegistryFeatures) {
            $applyPath = Join-Path $script:RegfilesPath $feature.RegistryKey
            $sysprepPath = Join-Path (Join-Path $script:RegfilesPath 'Sysprep') $feature.RegistryKey
            if (-not (Test-Path -LiteralPath $applyPath) -or -not (Test-Path -LiteralPath $sysprepPath)) { continue }

            $apply = Get-RegFileTargets -Path $applyPath
            $sysprep = Get-RegFileTargets -Path $sysprepPath
            $missing = @()

            foreach ($entry in $apply.SetEntries) {
                $expected = '{0}::{1}' -f (ConvertTo-SysprepKey -NormalizedKey $entry.Key), $entry.ValueName
                if (-not $sysprep.SetTargets.Contains($expected)) { $missing += $expected }
            }

            foreach ($deletedKey in $apply.DeletedKeys) {
                $expectedKey = ConvertTo-SysprepKey -NormalizedKey $deletedKey
                if (-not $sysprep.DeletedKeys.Contains($expectedKey)) { $missing += "$expectedKey (key deletion)" }
            }

            if ($missing.Count -gt 0) {
                $failures += "$($feature.FeatureId) [Sysprep\$($feature.RegistryKey)]: $($missing -join '; ')"
            }
        }

        $failures | Should -BeNullOrEmpty -Because "Sysprep variants must cover the same values so new profiles are not skipped:`n$($failures -join "`n")"
    }
}

Describe 'Command-line surface parity' {
    It 'exposes a parameter for every feature in the catalogue' {
        $missing = @($script:Features | ForEach-Object { $_.FeatureId } | Where-Object { $script:MainParameters -notcontains $_ })

        $missing | Should -BeNullOrEmpty -Because "each feature needs a CLI switch: $($missing -join ', ')"
    }

    It 'maps every non-control parameter to a feature' {
        $featureIds = @($script:Features | ForEach-Object { $_.FeatureId })
        $orphans = @(
            $script:MainParameters |
                Where-Object {
                    $featureIds -notcontains $_ -and
                    $script:ControlParameters -notcontains $_ -and
                    $script:KnownOrphanedParameters -notcontains $_
                }
        )

        $orphans | Should -BeNullOrEmpty -Because "a parameter with no feature is silently ignored at runtime: $($orphans -join ', ')"
    }

    It 'keeps the Get.ps1 launcher in sync with the main script' {
        $missingFromLauncher = @($script:MainParameters | Where-Object { $script:LauncherParameters -notcontains $_ })
        $extraOnLauncher = @(
            $script:LauncherParameters |
                Where-Object { $script:MainParameters -notcontains $_ -and $script:LauncherOnlyParameters -notcontains $_ }
        )

        $missingFromLauncher | Should -BeNullOrEmpty -Because "the launcher cannot forward a parameter it does not declare: $($missingFromLauncher -join ', ')"
        $extraOnLauncher | Should -BeNullOrEmpty -Because "the launcher declares a parameter the main script will reject: $($extraOnLauncher -join ', ')"
    }
}

Describe 'App catalogue integrity' {
    It 'declares each AppId only once' {
        $seen = @{}
        $duplicates = @()

        foreach ($app in $script:AppCatalog.Apps) {
            foreach ($appId in @($app.AppId)) {
                if ($seen.ContainsKey($appId)) { $duplicates += $appId } else { $seen[$appId] = $true }
            }
        }

        $duplicates | Should -BeNullOrEmpty -Because "duplicate AppIds cause an app to be processed twice: $($duplicates -join ', ')"
    }

    It 'gives every app a friendly name and at least one AppId' {
        $incomplete = @(
            $script:AppCatalog.Apps |
                Where-Object { -not $_.FriendlyName -or -not @($_.AppId).Count -or -not @($_.AppId)[0] } |
                ForEach-Object { $_.FriendlyName }
        )

        $incomplete | Should -BeNullOrEmpty -Because "the selection UI needs a name and an id for every entry"
    }

    It 'uses a known safety recommendation for every app' {
        $valid = @('safe', 'optional', 'unsafe')
        $invalid = @(
            $script:AppCatalog.Apps |
                Where-Object { $valid -notcontains $_.Recommendation } |
                ForEach-Object { "$($_.FriendlyName) -> $($_.Recommendation)" }
        )

        $invalid | Should -BeNullOrEmpty -Because "an unrecognised recommendation breaks the unsafe-removal confirmation: $($invalid -join ', ')"
    }

    It 'uses a supported removal method for every app' {
        $valid = @('Appx', 'WinGet')
        $invalid = @(
            $script:AppCatalog.Apps |
                Where-Object { $valid -notcontains $_.RemovalMethod } |
                ForEach-Object { "$($_.FriendlyName) -> $($_.RemovalMethod)" }
        )

        $invalid | Should -BeNullOrEmpty -Because "an unrecognised removal method silently skips the app: $($invalid -join ', ')"
    }

    It 'resolves every preset entry to a catalogue app' {
        $knownIds = @{}
        foreach ($app in $script:AppCatalog.Apps) {
            foreach ($appId in @($app.AppId)) { $knownIds[$appId] = $true }
        }

        $unknown = @(
            foreach ($preset in $script:AppCatalog.Presets) {
                foreach ($appId in $preset.AppIds) {
                    if (-not $knownIds.ContainsKey($appId)) { "$($preset.Name) -> $appId" }
                }
            }
        )

        $unknown | Should -BeNullOrEmpty -Because "a preset must not reference an app that is not in the catalogue: $($unknown -join ', ')"
    }
}
